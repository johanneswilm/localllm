# localllm

Local chat models for an AMD Ryzen AI 9 HX 370 laptop (AVX512, 91 GiB RAM)
with an AORUS RTX 5060 Ti AI BOX eGPU (16 GB VRAM) over Thunderbolt 5.

## What is here

- `runtime/llama.cpp` — llama.cpp from source. Two builds:
  - `build/` — CPU-only (`-march=native`, AVX512), fallback when the eGPU is down
  - `build-cuda/` — CUDA backend (`sm_120` for the RTX 5060 Ti Blackwell)
- `runtime/strata/` — Strata inference engine (flash-next only; see below)
- `models/` — GGUF model files.
- `run.sh` — model switcher: starts/stops/checks llama-server instances (OpenAI-compatible API). Auto-picks the CUDA build when the GPU is up.
- `egpu-bringup.sh` — brings the eGPU up safely (run after connecting the cable).

## The eGPU (AORUS RTX 5060 Ti AI BOX)

The box works reliably only with a specific bring-up (root cause, journey
and wedge facets: `EGPU.md` "Stabilization record"). Key facts:

- **The box wedges on unclean events** (crash, shutdown with the GPU attached)
  and then enumerates dead or at 2.5 GT/s x1 until its own power is cycled.
- **Daily workflow**: power-cycle the box if it was crashed/shut down with the
  GPU attached (PSU off 30 s) -> boot the laptop -> connect the Thunderbolt
  cable -> `./run.sh aibox` (checks state, runs the bring-up via sudo when
  needed; it is safe to re-run). The underlying script is `egpu-bringup.sh`
  (pin ASPM off + Gen4 + retrain, verify link, load driver, force P0).
- Do not hot-unplug under load. For shutdowns there is a detach hook
  (`egpu-down.service`, installed by `setup-egpu-stage10.sh`) but power-cycling
  the box after any crash is still the safe habit.
- `nvidia-smi` should show `Persistence-M On` and `P0` after bring-up.
- VRAM is 16 GB total, ~15.2 GB usable for models; the desktop (when running)
  uses the AMD iGPU only — the NVIDIA modeset/drm modules stay blocked
  (`/etc/modprobe.d/zz-egpu.conf`) so the display stack can never touch the box.
- Every system change behind this setup (driver 615, kernel 7.3, modprobe
  rules, GRUB cmdline, systemd units) and the exact revert for each:
  `EGPU.md` + `egpu-undo.sh` (`sudo bash egpu-undo.sh status` shows what
  is applied).

## External monitor

The external monitor currently works via **DisplayPort** only. The Framework
HDMI expansion card gives no signal on this host — from the very first boot
screen — while the same cable + monitor work on the old laptop. Appears
host-side (not cable/monitor); revisit after a BIOS update or the 26.10
upgrade. Details: `EGPU.md` ("External monitor").

## Measured speeds (2026-10-14, llama.cpp master 411d5485)

| model | config | pp (t/s) | tg (t/s) | CPU baseline tg |
|---|---|---|---|---|
| `qwen3.8-27b` (UD-IQ4_XS, full-resident) | `-ngl 99 -fa` | 1033 | 27.5 | 3.5 |
| `qwen3.8-27b` + MTP draft (GPU, 4k ctx) | `-ngld 99` | - | 39.3 | 3.5 |
| `qwen3.8-27b` server, 64k ctx, MTP draft on CPU | see `run.sh` | - | ~25 | 3.5 |
| `qwen3.6-35b-a3b` (hybrid: attention GPU, experts RAM) | `-ncmoe 99` | 53 | 47.5 | 17.5 |
| `qwen3.8-27b-q4km` (partial offload) | `-ngl 40` | 209 | 7.1 (10.0 w/ MTP) | 3.5 |
| `qwen3.8-flash-next` (hybrid, llama.cpp) | `-ngl 99 -ncmoe 99` | 96 | 21.1 | 7.15 |
| `qwen3.8-flash-next` (Strata, IQ3_S) | engine auto-split | 396 (long doc) | **52.1** | 7.15 |

## GLM-5.3-Flash via Project Maya (tested 2026-10-16)

[GLM-5.3-Flash](https://huggingface.co/zai-org/GLM-5.3-Flash) (zai-org, MIT; 321B MoE, ~18B
active/token) runs via [Project Maya](https://github.com/mw00/project-maya), installed in
`runtime/maya` (engine) + `runtime/Maya-data/` (Maya-S v2 IQ2_XXS, 96.5 GB, SHA-256 verified).
Measured on this box with the official `./maya.sh --bench` (Maya v1.1.13):

| metric | value |
|---|---|
| decode | **9.1 t/s** (mean of 3 prompts, greedy, thinking off) |
| prefill | 133 t/s @ 2k-token prompt, 364 t/s @ 8k |
| load / VRAM | ~59 s first load; ~15.5 of 16.3 GB VRAM; 32k context |

Start: `runtime/maya/run-maya-maya-s-v2-iq2_xxs.sh` — OpenAI API on port **8082**, model id
`glm-5.3-flash`, vision included. One GPU engine at a time (stop Strata/llama.cpp first).
Maya-S keeps ~98% of the FP8 model's zero-shot accuracy (Maya's measurement) — a clearly
smarter model than flash-next, but ~6x slower at generation; prefill is on par with Strata.
Verdict: kept as the "hard questions" option; flash-next remains the daily driver.
Calibrated 2026-10-17 (`./maya.sh --calibrate`): the engine's own settings are
already the fastest here (9.2 tok/s) — nothing to redo. Optional upgrade if GLM
becomes a daily driver: Maya-S24 (4-bit attention, ~+14% decode on <=24 GB cards).

## Flash-Next: llama.cpp vs Strata

Two ways to serve flash-next, both hybrid CPU+GPU:

- **llama.cpp** (`./run.sh start qwen3.8-flash-next`): 21.1 t/s tg, uses the
  88 GB GGUF you already have. Vision works (F16 mmproj). Best for: vision,
  proven llama.cpp behavior, no extra disk.
- **Strata** (`./run.sh start qwen3.8-flash-next-strata`, OpenAI API on port
  8080): **52.1 t/s** decode
  (verified 2026-10-14, MTP accepts ~58%), 396 t/s long-doc prompt ingestion,
  ~54 GB RAM + ~15.7 GB VRAM. Uses its own IQ3_S download
  (~90 GB in `runtime/Strata-data/`); the existing Q4_K_M shards are NOT
  usable by Strata (checked with `setup.sh --inspect`).
  First load ~40 s. Stop other GPU models first — 16 GB VRAM fits only one
  of them. `run.sh stop 8080` stops it like any other server.
  Benchmark: `runtime/strata/bench_decode.py gen|prompt`.
  Calibrated 2026-10-17 (`./setup.sh --calibrate`, 20 min): the defaults are
  already the fastest on this box (fast CPU + TB5 link) — nothing to redo.

## Quick start

```bash
# after boot + plugging in the Thunderbolt cable: bring up the eGPU (sudo once)
./run.sh aibox

# list available models
./run.sh list

# switch CPU power profile to performance (no sudo needed on this system)
./run.sh perf on        # performance
./run.sh perf off       # back to balanced

# start a model on port 18035
./run.sh start qwen3.6-35b-a3b
./run.sh start qwen3.8-flash-next 18037

# OpenAPI-compatible endpoint
curl http://localhost:18035/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"qwen3.6-35b-a3b","messages":[{"role":"user","content":"Hello"}]}'

# stop servers
./run.sh stop          # stop all
./run.sh stop 18036    # stop one port

# what is running where
./run.sh show          # default port 18035
./run.sh show 18037

# plain terminal chat (no server)
./run.sh chat qwen3.6-35b-a3b
```

## Models

| model | speed (tg) | resident | notes |
|---|---|---|---|
| `qwen3.6-35b-a3b` | ~47 t/s GPU / ~17 t/s CPU | ~21 GB RAM (+3 GB VRAM) | fast daily driver (MoE hybrid) |
| `qwen3.8-27b` (UD-IQ4_XS) | ~25-39 t/s GPU / ~3.5 t/s CPU | ~13.5 GB VRAM | dense; vision disabled on GPU (VRAM) |
| `qwen3.8-27b-q4km` | ~10 t/s GPU | 40/48 layers VRAM, rest RAM | better quality than IQ4_XS, slower |
| `qwen3.8-flash-next` | ~52 t/s Strata / ~21 t/s llama.cpp GPU / ~7 t/s CPU | ~55 GB RAM | best quality; vision on both engines; huge context is cheap |

Run one big model at a time: `qwen3.8-flash-next` + any other model is tight in 91 GiB
with a desktop running. `./run.sh stop` before switching is the safe habit.

Any OpenAI SDK works against `http://localhost:PORT/v1` (key: `EMPTY`).

## Adding a new model (e.g. a future Qwen4)

All Qwen3.5/3.6/3.8 models share the same architecture (except Flash-Next, which is the new `qwen4exp` arch), so usually only the model file changes.

1. Edit `run.sh`: add one line to the `MODELS` map, e.g.
   ```bash
   [qwen4-35b-a3b]="$MODELS_DIR/qwen4-35b-a3b/quantized.gguf"
   ```
2. Download the GGUF into `models/qwen4-35b-a3b/`.
3. `./run.sh list` and `./run.sh start qwen4-35b-a3b`

## Speed tuning

- `./run.sh start <model>` uses benchmarked per-model thread counts (12 MoE / 10 dense).
- GPU models get `-fa on` and a q4 KV cache (`-ctk/-ctv q4_0`) so the default 64k
  context fits in 16 GB VRAM. Pass `--ctx-size 16384` after the port for more
  speed (frees ~0.9 GB -> the MTP draft can run on the GPU: ~39 t/s).
- `./run.sh perf on|off` switches the CPU power profile.
- `./run.sh fast` / `./run.sh thinking` restart running servers with reasoning OFF/ON.
  Reasoning OFF cuts response latency massively (~19-65 s -> ~0.3 s) by skipping the thinking chain — best for casual chat; turn it ON for complex reasoning.
- MTP speculative decoding is enabled for the 27B models via the `DRAFTS` map
  (`--spec-type draft-mtp --spec-draft-n-max 3`). flash-next MTP is still broken
  upstream — details: `TODO.md`.

## Qwen3.8-Flash-Next notes

- Build: AtomicChat `AD-4.27bpw-Q4_K_M-M64` (88 GiB on disk, 33 shards). The 51B n-gram table lives in its own shard and pages from SSD via mmap — keep mmap on (no `--no-mmap`).
- ~54.5 GB resident + tiny KV cache (~25 KB/token vs ~10x that for the dense 27B), so 64k context is cheap.
- Requires `--jinja --fit off` (auto-fit mis-sizes this arch) — set in the `EXTRA` map.
- Vision works through the shared `mmproj-Qwen3.8-Flash-Next-F16.gguf`.

## Using the local models from Kilo

Added an `openai-compatible`-style provider in `~/.config/kilo/kilo.json`:

- `local/qwen3.6-35b-a3b` — Qwen3.6 35B-A3B (async, tool_call, reasoning)
- `local/qwen3.8-27b` — Qwen3.8 27B (async, tool_call, vision)

(`local/qwen3.8-flash-next` can be added the same way, pointing at port 18037.)

Start a server first, then pick the model via `/models` or:
`kilo --model local/qwen3.6-35b-a3b`

## Qwen Code CLI

`qwen.sh` wraps the official Qwen Code CLI against the local server:

```bash
./qwen.sh                      # interactive (starts server if needed)
./qwen.sh "your prompt"        # non-interactive
QWEN_LOCAL_MODEL=qwen3.8-27b ./qwen.sh   # pick model
```

The `fetch` MCP server is registered in Qwen Code (`uvx --from mcp-server-fetch --with mcp==1.13.0 mcp-server-fetch`) for web access, but **Qwen Code is impractical against a local CPU model**: it injects a ~20k-token system prompt that takes minutes to process on CPU and times out. For fast, tool-capable chat use **Kilo with the local models** instead.

## Web access / tool calling

- **Kilo** (`local/qwen3.6-35b-a3b`): tool calling works — the model calls `WebFetch`/`WebSearch` and Kilo executes them. Verified against https://example.com.
- **llama-server web UI / `run.sh chat`**: no tools, so the model truthfully reports it cannot fetch data.
- **Qwen Code**: fetch MCP installed, but its agent scaffold is impractical on CPU (see above).

The model itself is fully capable of tool calling (verified at the API level); whether it can "go online" depends on the host app supplying a fetch tool.

## Connecting a chat interface

Every server here speaks the **OpenAI API**, so any OpenAI-compatible
client works. You always need exactly three parameters (shown by
`./run.sh start` and `./run.sh show <port>`):

| parameter | value |
|---|---|
| Base URL | `http://localhost:<port>/v1` (llama.cpp default port 18035, Strata 8080) |
| Model id | the short name, e.g. `qwen3.8-flash-next` (run.sh passes it as `--alias`; it must match `/v1/models` exactly) |
| API key | none required — if a client insists on a non-empty field, put `EMPTY` |

**Built-in web chat UI** — point a browser at `http://localhost:<port>`
while a llama.cpp server is running (no extra software).

**Strata (the fast flash-next engine, 52 t/s)** — same model name, different
engine. Start it like any model (default port 8080):
```bash
./run.sh start qwen3.8-flash-next-strata     # first load ~40 s
curl -s http://localhost:8080/v1/models      # confirms model id + readiness
```
For chat use Strata; it reads pictures too since 2026-10-16 (CPU image
encoder, `--vision cpu`; ~700 MiB VRAM reserved, 262144 context kept — measured fine).
Use the llama.cpp flash-next server (port 18037) for 256k context or
bit-familiar behavior. The two engines do not share VRAM — `./run.sh stop`
the other GPU model first.

**Loop guard (recommended for agent harnesses)** — `loop-guard.py` sits in
front of Strata and fixes the two ways agent harnesses get stuck: it rewrites
greedy sampling (`temperature: 0`, which makes the model repeat the same
task forever — Strata issue #1560) to the published Qwen settings
(temperature 1.0, top_p 0.95, top_k 20), and it detects trailing repeated or
alternating assistant turns and injects a one-time "stop repeating" nudge.
`./run.sh start qwen3.8-flash-next-strata` starts it automatically on port
8081 (`./run.sh guard [port]` / `./run.sh guard stop [port]` to manage it).
Point Kilo Code / omp / aider at `http://localhost:8081/v1` instead of 8080.

**Zed** — `~/.config/zed/settings.json`:
```json
{
  "language_models": {
    "openai_compatible": {
      "local-llama": {
        "api_url": "http://localhost:8080/v1",
        "api_key": "EMPTY",
        "available_models": [
          {
            "name": "qwen3.8-flash-next",
            "display_name": "Flash Next (local)",
            "max_tokens": 65536
          }
        ]
      }
    }
  }
}
```
Start the server first, then pick the model with `/model` (or in the Agent
panel). Point `api_url` at 18035/18037 instead to use a llama.cpp model.
More options: https://zed.dev/docs/ai/openai-compatible

**Open WebUI** (nice self-hosted ChatGPT-style UI):
```bash
pipx install open-webui && open-webui serve    # listens on 8081
```
Admin Settings → Connections → OpenAI API: URL `http://localhost:8080/v1`,
key `EMPTY`.

**aider** (terminal pair-programming):
```bash
aider --model openai/qwen3.8-flash-next \
  --openai-api-base http://localhost:8080/v1 --openai-api-key EMPTY
```

**VS Code (Continue / Cline / Roo Code)** — provider "OpenAI Compatible",
apiBase `http://localhost:8080/v1`, apiKey `EMPTY`, model `qwen3.8-flash-next`.

**Any OpenAI SDK:**
```python
from openai import OpenAI
client = OpenAI(base_url="http://localhost:8080/v1", api_key="EMPTY")
r = client.chat.completions.create(model="qwen3.8-flash-next",
    messages=[{"role": "user", "content": "Hello"}])
print(r.choices[0].message.content)
```

## Notes

- Default context 65536 tokens for llama.cpp servers; reduce with `--ctx-size` for lower RAM.
  The Strata flash-next config runs 262144 with vision enabled (since 2026-10-16, `--vision cpu`:
  the image encoder runs on the CPU, ~700 MiB of VRAM reserved for the image path). The setup
  tool recommends 65536 with vision on a 16 GB card, but 262144 was measured working here
  (57k-token prompt + image: VRAM flat at ~15.7 GB) thanks to the 32k KV-resident window.
- Ports are prefixed 180xx to avoid common dev-server ports. Default is 18035.
- Server options can be appended after the port, e.g. `./run.sh start qwen3.6-35b-a3b 18035 --parallel 4`.
- Threads come from the `THREADS` map (benchmarked per model); the fallback is `default_threads()` = physical cores (12).
- Logs and PID files live in `logs/`.