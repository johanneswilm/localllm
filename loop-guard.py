#!/usr/bin/env python3
"""loop-guard.py - reverse proxy in front of Strata that breaks agent loops.

AI-agent harnesses (Kilo Code, omp, ...) drive the local Qwen3.8-Flash-Next
server (Strata, port 8080) and hit two failure modes:

1. Harnesses send temperature: 0 (greedy). Strata's own sampling config does
   NOT override an explicit client temperature, and greedy decoding makes the
   model deterministically repeat the same action across turns - the same
   task N times, or two tasks in alternation (ABAB...). Strata issue #1560
   measured ~69% loop reproduction with greedy decoding vs ~0% with the
   published Qwen sampling settings (temperature 1.0, top_p 0.95, top_k 20).
   So the proxy rewrites greedy/absent sampling on every request.
2. Loops can still start with sampling fixed, so the proxy also scans the
   trailing assistant turns for a repeated (period 1) or alternating
   (period 2) cycle and appends a one-shot user "nudge" message - plus merges
   repetition_penalty=1.1 / penalty_last_n=512 into that request only (also
   field-tested per #1560), unless the client sent a penalty of its own.

Extension point: only POST paths ending in /v1/chat/completions are
transformed; /v1/responses and /v1/messages pass through untouched. To guard
them too, extend the suffix check in ProxyHandler._proxy() and reuse
apply_fixes() against their body shape.
"""

import argparse
import collections
import hashlib
import http.client
import http.server
import json
import re
import sys
import time

CHAT_SUFFIX = "/v1/chat/completions"

# Hop-by-hop headers: never forward. Host/Content-Length/Connection are
# re-derived by http.client from the outgoing request; Accept-Encoding is
# dropped so upstream answers in plain identity (we stream raw bytes).
HOP_REQ = {"host", "content-length", "connection", "accept-encoding",
           "transfer-encoding", "keep-alive", "proxy-authenticate",
           "proxy-authorization", "te", "trailer", "upgrade", "expect"}
# Response side: also drop server/date (send_response adds our own) and
# content-encoding (we asked for identity; the body must stay decodable).
HOP_RESP = {"connection", "keep-alive", "transfer-encoding", "te",
            "trailer", "upgrade", "content-encoding", "server", "date"}

LOG_PATH = None

def log(msg):
    line = "%s %s" % (time.strftime("%Y-%m-%d %H:%M:%S"), msg)
    sys.stderr.write(line + "\n")
    sys.stderr.flush()
    if LOG_PATH:
        try:
            with open(LOG_PATH, "a") as f:
                f.write(line + "\n")
        except OSError:
            pass

def _text_of(content):
    # OpenAI message content: a plain string or a list of parts.
    if isinstance(content, list):
        return " ".join(str(p.get("text", "")) if isinstance(p, dict) else str(p)
                        for p in content)
    if content is None:
        return ""
    return content if isinstance(content, str) else str(content)

def message_sig(msg):
    """(signature, short description) for one assistant message.

    Tool calls are canonicalized (args parsed + re-dumped with sorted keys)
    so the same call serializes identically across turns.
    """
    tcs = msg.get("tool_calls")
    if tcs:
        pairs = []
        for tc in tcs:
            fn = tc.get("function", {}) if isinstance(tc, dict) else {}
            name = fn.get("name", "?")
            raw = fn.get("arguments", "")
            if not isinstance(raw, str):
                raw = json.dumps(raw)
            try:
                args = json.dumps(json.loads(raw), sort_keys=True)
            except (ValueError, TypeError):
                args = raw
            pairs.append([name, args])
        sig = "TC:" + json.dumps(pairs, sort_keys=True)
        desc = "; ".join("%s(%s)" % (n, a[:120]) for n, a in pairs)
        return sig, desc[:200]
    norm = re.sub(r"\s+", " ", _text_of(msg.get("content"))).strip()
    return "TXT:" + norm, norm[:80]

def trailing_repeats(sigs, period):
    """How many times the last `period` sigs repeat consecutively at the tail.

    Only the trailing run counts: a cycle buried in old history with newer
    different turns after it returns 1.
    """
    n = len(sigs)
    if n < period:
        return 0
    block = sigs[n - period:]
    r = 1
    while (r + 1) * period <= n and sigs[n - (r + 1) * period:n - r * period] == block:
        r += 1
    return r

def detect_loop(messages, min_repeats, cycles):
    """Find a trailing assistant cycle.

    Returns (period, repeats, sigs, descs) or None. Period 1 (same turn
    repeated) is checked before period 2 (AB alternation).
    """
    sigs, descs = [], []
    for m in messages:
        if isinstance(m, dict) and m.get("role") == "assistant":
            s, d = message_sig(m)
            sigs.append(s)
            descs.append(d)
    for period, needed in ((1, min_repeats), (2, cycles)):
        r = trailing_repeats(sigs, period)
        if r >= needed:
            return period, r, sigs, descs
    return None

def nudge_text(period, repeats, descs):
    if period == 1:
        return ("[loop-guard] The last %d steps repeat the same action: %s. "
                "It is not working — do NOT run it again. First diagnose why it "
                "fails (run it once manually and read the complete output), then "
                "take a fundamentally different approach. If still stuck, "
                "summarize what you tried and ask me how to proceed."
                % (repeats, descs[-1]))
    return ("[loop-guard] The last %d steps alternate between two actions: "
            "(A) %s and (B) %s. Both keep failing — stop alternating them. "
            "Diagnose the actual failure, then try one fundamentally different "
            "approach. If still stuck, summarize and ask me."
            % (repeats * 2, descs[-2], descs[-1]))

def fix_sampling(body, opts, decisions):
    """Rewrite greedy/absent sampling to the published Qwen settings."""
    t = body.get("temperature")
    if isinstance(t, (int, float)) and not isinstance(t, bool):
        if t > 0.05:
            return
        # Explicit greedy (0): the client tuned everything for it (e.g. Codex
        # sends 0/1/20), so override top_p/top_k alongside temperature.
        body["temperature"] = opts.temperature
        body["top_p"] = opts.top_p
        body["top_k"] = opts.top_k
        decisions.append("sampling %s->%s" % (t, opts.temperature))
        return
    # Absent or null: fill in, but keep any client-provided top_p/top_k.
    body["temperature"] = opts.temperature
    body.setdefault("top_p", opts.top_p)
    body.setdefault("top_k", opts.top_k)
    decisions.append("sampling unset->%s" % opts.temperature)

def apply_fixes(body, opts, episodes):
    """Apply the sampling fix and loop nudge/penalty to a parsed body.

    `episodes` is an OrderedDict used as an LRU set of sha256 episode ids
    already nudged (max 512). Mutates body in place; returns the decision
    strings (empty list = nothing changed, forward the original bytes).
    """
    decisions = []
    if not isinstance(body, dict):
        return decisions
    if opts.sampling_fix:
        fix_sampling(body, opts, decisions)
    hit = detect_loop(body.get("messages") or [], opts.min_repeats, opts.cycles)
    if hit:
        period, repeats, sigs, descs = hit
        episode = hashlib.sha256("\n".join(sigs[-period:]).encode()).hexdigest()
        if episode in episodes:
            decisions.append("loop p=%d r=%d already-nudged" % (period, repeats))
        else:
            episodes[episode] = True
            episodes.move_to_end(episode)
            while len(episodes) > 512:
                episodes.popitem(last=False)
            body.setdefault("messages", []).append(
                {"role": "user", "content": nudge_text(period, repeats, descs)})
            decisions.append("loop p=%d r=%d nudge" % (period, repeats))
            if opts.penalty and not any(k in body for k in
                                        ("repetition_penalty", "presence_penalty",
                                         "frequency_penalty")):
                body["repetition_penalty"] = 1.1
                body["penalty_last_n"] = 512
                decisions.append("penalty")
    return decisions

class ProxyHandler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"  # lets us stream without buffering
    server_version = "loop-guard/1.0"

    def log_message(self, fmt, *args):
        pass  # one line per request is logged from _proxy() instead

    def _read_body(self):
        if "chunked" in self.headers.get("Transfer-Encoding", "").lower():
            data = bytearray()
            while True:
                line = self.rfile.readline(65536)
                if not line:
                    break
                size = int(line.split(b";", 1)[0].strip(), 16)
                if size == 0:  # trailers run until an empty line
                    while self.rfile.readline(65536) not in (b"\r\n", b"\n", b""):
                        pass
                    break
                data += self.rfile.read(size)
                self.rfile.read(2)  # trailing CRLF
            return bytes(data)
        n = int(self.headers.get("Content-Length") or 0)
        return self.rfile.read(n) if n > 0 else b""

    def _proxy(self):
        body = b""
        if self.command in ("POST", "PUT", "PATCH", "DELETE"):
            body = self._read_body()
        out = body
        decisions = []
        if (self.command == "POST" and body
                and self.path.split("?", 1)[0].endswith(CHAT_SUFFIX)):
            try:
                parsed = json.loads(body)
                decisions = apply_fixes(parsed, self.server.opts,
                                        self.server.episodes)
                if decisions:
                    out = json.dumps(parsed).encode()
            except (ValueError, TypeError):
                decisions = ["unparsed"]
        log("%s %s %s" % (self.command, self.path,
                          ", ".join(decisions) if decisions else "ok"))
        headers = {k: v for k, v in self.headers.items()
                   if k.lower() not in HOP_REQ}
        try:
            conn = http.client.HTTPConnection(*self.server.upstream, timeout=900)
            conn.request(self.command, self.path, body=out, headers=headers)
            resp = conn.getresponse()
        except Exception as e:
            log("upstream error: %s" % e)
            self.send_error(502, "upstream unreachable: %s" % e)
            return
        try:
            self.send_response(resp.status, resp.reason)
            has_len = False
            for k, v in resp.getheaders():
                if k.lower() in HOP_RESP:
                    continue
                if k.lower() == "content-length":
                    has_len = True  # body is untouched, so it stays correct
                self.send_header(k, v)
            self.end_headers()
            if self.command == "HEAD":
                return
            # Stream as it arrives; read1() de-chunks transparently, so both
            # chunked and Content-Length upstream responses work.
            while True:
                chunk = resp.read1(65536)
                if not chunk:
                    break
                self.wfile.write(chunk)
                self.wfile.flush()
            if not has_len:
                self.close_connection = True  # close-delimited body
        except (BrokenPipeError, ConnectionResetError, OSError) as e:
            log("stream aborted: %s" % e)
        finally:
            conn.close()

    do_GET = do_POST = do_PUT = do_DELETE = do_PATCH = do_HEAD = _proxy

def selftest():
    def mkopts(**kw):
        base = dict(sampling_fix=True, penalty=True, temperature=1.0,
                    top_p=0.95, top_k=20, min_repeats=4, cycles=3)
        base.update(kw)
        return argparse.Namespace(**base)

    def tc(name, **args):
        return {"role": "assistant", "content": None,
                "tool_calls": [{"id": "x", "type": "function",
                                "function": {"name": name,
                                             "arguments": json.dumps(args)}}]}

    def u(text):
        return {"role": "user", "content": text}

    def txt(text):
        return {"role": "assistant", "content": text}

    failed = 0
    total = 0

    def check(name, cond):
        nonlocal failed, total
        total += 1
        if not cond:
            failed += 1
        print("%s %s" % ("PASS" if cond else "FAIL", name))

    # 1. AAAA tool-call loop -> nudge + penalty merge
    eps = collections.OrderedDict()
    b = {"messages": [u("do it")] + [tc("run_cmd", cmd="ls -la")] * 4}
    d = apply_fixes(b, mkopts(), eps)
    check("aaaa: loop p=1 r=4 detected", any("loop p=1 r=4 nudge" in x for x in d))
    check("aaaa: penalty merged", b.get("repetition_penalty") == 1.1
          and b.get("penalty_last_n") == 512)
    check("aaaa: nudge appended", b["messages"][-1]["role"] == "user"
          and b["messages"][-1]["content"].startswith("[loop-guard] The last 4 steps"))
    # 1b. same episode again -> already-nudged, no second nudge
    n_msgs = len(b["messages"])
    d = apply_fixes(b, mkopts(), eps)
    check("aaaa: episode not re-nudged", any("already-nudged" in x for x in d)
          and len(b["messages"]) == n_msgs)

    # 2. ABABAB -> period 2, 3 cycles
    eps = collections.OrderedDict()
    b = {"messages": [u("x")] + [tc("step_a", n=1), tc("step_b", n=2)] * 3}
    d = apply_fixes(b, mkopts(), eps)
    check("ababab: loop p=2 r=3 detected", any("loop p=2 r=3 nudge" in x for x in d))
    check("ababab: nudge names both actions", "(A)" in b["messages"][-1]["content"]
          and "(B)" in b["messages"][-1]["content"])

    # 3. loop buried mid-history, newer different turns after -> no trigger
    eps = collections.OrderedDict()
    b = {"temperature": 0.7,
         "messages": [u("x")] + [tc("stuck", k=1)] * 5 + [tc("fresh_1"), tc("fresh_2")]}
    check("buried: no trigger", apply_fixes(b, mkopts(), eps) == [])

    # 4. only 3 identical turns -> below threshold
    eps = collections.OrderedDict()
    b = {"temperature": 0.7, "messages": [u("x")] + [tc("same")] * 3}
    check("3x: below threshold", apply_fixes(b, mkopts(), eps) == [])

    # 5. normal chat -> nothing
    eps = collections.OrderedDict()
    b = {"temperature": 0.7, "top_p": 0.5,
         "messages": [u("hi"), txt("hello!"), u("2+2?"), txt("4")]}
    d = apply_fixes(b, mkopts(), eps)
    check("normal: untouched", d == [] and b["temperature"] == 0.7
          and b["top_p"] == 0.5)

    # 6. temperature 0 (Codex-style 0/1/20) -> all three overridden
    eps = collections.OrderedDict()
    b = {"temperature": 0, "top_p": 1, "top_k": 20,
         "messages": [u("hi"), txt("hello")]}
    d = apply_fixes(b, mkopts(), eps)
    check("greedy: sampling overridden", b["temperature"] == 1.0
          and b["top_p"] == 0.95 and b["top_k"] == 20
          and any(x.startswith("sampling 0->") for x in d))
    # 6b. null temperature -> filled, client top_p kept
    b = {"temperature": None, "top_p": 0.8, "messages": [u("hi"), txt("hello")]}
    apply_fixes(b, mkopts(), collections.OrderedDict())
    check("null temp: filled, top_p kept", b["temperature"] == 1.0
          and b["top_p"] == 0.8 and b["top_k"] == 20)

    # 7. temperature 0.7 -> sampling left alone
    b = {"temperature": 0.7, "messages": [u("hi"), txt("hello")]}
    check("temp 0.7: untouched", apply_fixes(b, mkopts(),
          collections.OrderedDict()) == [])

    # 8. loop + client-sent presence_penalty -> nudge, no penalty merge
    eps = collections.OrderedDict()
    b = {"presence_penalty": 0.3, "messages": [u("x")] + [tc("run")] * 4}
    d = apply_fixes(b, mkopts(), eps)
    check("client penalty: no merge", any("nudge" in x for x in d)
          and "repetition_penalty" not in b and b["presence_penalty"] == 0.3)

    print("%d/%d checks passed" % (total - failed, total))
    return 1 if failed else 0

def parse_host_port(s):
    host, _, port = s.rpartition(":")
    return (host or "127.0.0.1", int(port))

def main():
    global LOG_PATH
    ap = argparse.ArgumentParser(description="Loop-guard reverse proxy for Strata.")
    ap.add_argument("--listen", default="127.0.0.1:8081")
    ap.add_argument("--upstream", default="127.0.0.1:8080")
    ap.add_argument("--sampling-fix", choices=["on", "off"], default="on")
    ap.add_argument("--penalty", choices=["on", "off"], default="on")
    ap.add_argument("--temperature", type=float, default=1.0)
    ap.add_argument("--top-p", type=float, default=0.95)
    ap.add_argument("--top-k", type=int, default=20)
    ap.add_argument("--min-repeats", type=int, default=4)
    ap.add_argument("--cycles", type=int, default=3)
    ap.add_argument("--log", help="also append request lines to this file")
    ap.add_argument("--selftest", action="store_true")
    a = ap.parse_args()
    if a.selftest:
        return selftest()
    LOG_PATH = a.log
    opts = argparse.Namespace(
        sampling_fix=a.sampling_fix == "on", penalty=a.penalty == "on",
        temperature=a.temperature, top_p=a.top_p, top_k=a.top_k,
        min_repeats=a.min_repeats, cycles=a.cycles)
    server = http.server.ThreadingHTTPServer(parse_host_port(a.listen), ProxyHandler)
    server.upstream = parse_host_port(a.upstream)
    server.opts = opts
    server.episodes = collections.OrderedDict()
    log("listening on %s -> upstream %s (sampling-fix=%s penalty=%s)"
        % (a.listen, a.upstream, a.sampling_fix, a.penalty))
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    return 0

if __name__ == "__main__":
    sys.exit(main())
