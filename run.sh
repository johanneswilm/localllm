#!/usr/bin/env bash
set -euo pipefail

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNTIME="$BASE_DIR/runtime/llama.cpp"
MODELS_DIR="$BASE_DIR/models"

# Backend selection: CUDA build when the eGPU driver is up, else CPU build.
CUDA_BUILD="$RUNTIME/build-cuda/bin"
CPU_BUILD="$RUNTIME/build/bin"
if [[ -x "$CUDA_BUILD/llama-server" ]] && nvidia-smi >/dev/null 2>&1; then
  SERVER="$CUDA_BUILD/llama-server"
  [[ -x "$CUDA_BUILD/llama" ]] && CLI="$CUDA_BUILD/llama" || CLI="$CUDA_BUILD/llama-cli"
  BACKEND="cuda"
else
  SERVER="$CPU_BUILD/llama-server"
  [[ -x "$CPU_BUILD/llama" ]] && CLI="$CPU_BUILD/llama" || CLI="$CPU_BUILD/llama-cli"
  BACKEND="cpu"
fi

declare -A MODELS=(
  [qwen3.6-35b-a3b]="$MODELS_DIR/qwen3.6-35b-a3b/Qwen3.6-35B-A3B-UD-Q4_K_M.gguf"
  [qwen3.8-27b]="$MODELS_DIR/qwen3.8-27b/Qwen3.8-27B-UD-IQ4_XS.gguf"
  [qwen3.8-27b-q4km]="$MODELS_DIR/qwen3.8-27b/Qwen3.8-27B-Q4_K_M.gguf"
  [qwen3.8-flash-next]="$MODELS_DIR/qwen3.8-flash-next/Qwen3.8-Flash-Next-AD-4.27bpw-Q4_K_M-M64-00001-of-00033.gguf"
)

# Vision (mmproj) is disabled for the 27B GPU configs: the 930 MB BF16
# mmproj does not fit in the remaining VRAM and mtmd aborts the server.
# It stays enabled for flash-next (CPU-served) and for the CPU backend.
declare -A MMPROJS=(
  [qwen3.8-flash-next]="$MODELS_DIR/qwen3.8-flash-next/mmproj-Qwen3.8-Flash-Next-F16.gguf"
)

# MTP draft models for speculative decoding. Standalone MTP files work with
# --spec-type draft-mtp since llama.cpp master ~Oct 2026 (the old graph_mtp
# crash is fixed). Measured 2026-10-14 on the 5060 Ti:
#   27B IQ4_XS full-resident: draft on GPU (-ngld 99) -> 39.3 t/s (vs 27.5)
#   27B Q4_K_M partial (-ngl 40): draft on CPU -> 10.0 t/s (GPU draft was 9.1)
declare -A DRAFTS=(
  [qwen3.8-27b]="$MODELS_DIR/qwen3.8-27b/mtp-Qwen3.8-27B-Q4_0.gguf"
  [qwen3.8-27b-q4km]="$MODELS_DIR/qwen3.8-27b/mtp-Qwen3.8-27B-Q4_0.gguf"
)

# Which device the MTP draft runs on (only used when BACKEND=cuda).
# Empty = draft on CPU. Full-resident 27B uses the CPU draft: at 64k server
# ctx the GPU has no room for the draft, and with the main model fully on
# GPU the CPU is idle enough to run the draft in parallel.
declare -A GPU_NGLD=(
)

# Per-model extra server flags.
declare -A EXTRA=(
  [qwen3.8-flash-next]="--jinja --fit off"
)

# GPU offload (only used when BACKEND=cuda):
# GPU_NGL  - layers on the eGPU; 99 = everything that fits; 0 = CPU only.
# GPU_XTRA - extra GPU-side flags (e.g. keeping MoE experts on CPU/RAM).
# Values measured on the RTX 5060 Ti (16 GB, TB5 Gen4 x4), 2026-10-14:
#   27B IQ4_XS full-resident: pp 1033 / tg 27.5 (tg 39.3 with MTP)
#   27B Q4_K_M partial -ngl 40: pp 209 / tg 7.1 (tg 10.0 with MTP draft-CPU)
#   35B-A3B MoE hybrid attention-GPU/experts-CPU: tg 47.5
#   flash-next hybrid attention-GPU/experts-RAM: tg 21.1 (was kept on CPU
#   by mistake after an early -ngl 6 test; needs -ngl 99 -ncmoe 99)
declare -A GPU_NGL=(
  [qwen3.8-27b]=99
  [qwen3.8-27b-q4km]=40
  [qwen3.8-flash-next]=99
)
declare -A GPU_XTRA=(
  [qwen3.6-35b-a3b]="-ncmoe 99"
  [qwen3.8-flash-next]="-ncmoe 99"
)

# Per-model optimal thread counts (benchmarked on Ryzen AI 9 HX 370):
# MoE is faster at 12 threads; dense models prefer fewer due to memory bandwidth.
declare -A THREADS=(
  [qwen3.6-35b-a3b]=12
  [qwen3.8-27b]=10
  [qwen3.8-flash-next]=12
)

# Strata engine (the fast flash-next path, ~52 t/s vs llama.cpp's 21 t/s).
# Selected by model name; same OpenAI API, different server binary.
# Invocation mirrors runtime/strata/run-iq3_s.sh, with a configurable port.
STRATA_NAME="qwen3.8-flash-next-strata"
STRATA_DIR="$BASE_DIR/runtime/strata"
STRATA_PY="$STRATA_DIR/.venv/bin/python"
STRATA_CFG="$STRATA_DIR/strata-iq3_s.json"
STRATA_MODEL_ID="qwen3.8-flash-next"   # the id its /v1/models reports

# Loop guard (loop-guard.py): reverse proxy in front of Strata that rewrites
# greedy sampling and nudges the model out of repeated/alternating task loops.
# Agent harnesses (Kilo Code, omp, aider, ...) should point at the guard port.
GUARD_PORT=8081

usage() {
  echo "Usage:"
  echo "  $(basename "$0") list                          - list available models"
  echo "  $(basename "$0") aibox                         - check the eGPU; bring it up if needed"
  echo "  $(basename "$0") show <port>                   - show running model on port"
  echo "  $(basename "$0") stop [port]                   - stop server(s) (default: all)"
  echo "  $(basename "$0") fast                          - (re)start current models with reasoning OFF"
  echo "  $(basename "$0") thinking                      - (re)start current models with reasoning ON"
  echo "  $(basename "$0") start <model> [port] [opts...] - start model (default port 18035)"
  echo "  $(basename "$0") chat <model> [port]           - one-shot prompt in terminal"
  echo "  $(basename "$0") perf [on|off]                - set power profile (performance/balance)"
  echo "  $(basename "$0") guard [port]                  - start the loop guard proxy for agent harnesses (default port 8081; 'guard stop [port]' stops it)"
  echo ""
  echo "Start prints the connection parameters (API URL, model id, key, web UI)."
  echo "Client setup recipes (Zed, Open WebUI, aider, ...): README.md \"Connecting a chat interface\"."
  echo ""
  echo "Available models:"
  for m in "${!MODELS[@]}"; do
    printf "  %-30s %s\n" "$m" "${MODELS[$m]}"
  done
  echo ""
  echo "Engine variants:"
  printf "  %-30s %s\n" "$STRATA_NAME" "flash-next via the Strata engine (fast, ~52 t/s, needs eGPU); default port 8080; auto-starts the loop guard on 8081"
}

model_file() {
  local name="$1"
  if [[ -z "${MODELS[$name]:-}" ]]; then
    echo "Unknown model: $name" >&2
    usage
    exit 1
  fi
  local f="${MODELS[$name]}"
  if [[ ! -f "$f" ]]; then
    echo "Model file not found: $f (run ./run.sh download first)" >&2
    exit 1
  fi
  echo "$f"
}

default_threads() {
  # Physical cores only: SMT oversubscription hurts memory-bound generation.
  local tpc
  tpc="$(lscpu | awk '/^Thread\(s\) per core:/ {print $4}')"
  local phys
  phys="$(nproc)"
  if [[ -n "$tpc" && "$tpc" -gt 0 && "$phys" -gt "$tpc" ]]; then
    echo "$((phys / tpc))"
  else
    echo "12"
  fi
}

do_start() {
  local name="$1"
  if [[ "$name" == "$STRATA_NAME" ]]; then
    shift
    do_start_strata "$@"
    return
  fi
  shift
  local port="18035"
  if [[ "${1:-}" == --* ]]; then :; else
    port="${1:-18035}"
    shift || true
  fi
  local file
  file="$(model_file "$name")"
  local threads="${THREADS[$name]:-$(default_threads)}"
  local mmproj="${MMPROJS[$name]:-}"
  local draft="${DRAFTS[$name]:-}"
  local draft_ngl="${GPU_NGLD[$name]:-}"
  local extra="${EXTRA[$name]:-}"

  if curl -s "http://localhost:$port/health" >/dev/null 2>&1; then
    echo "Port $port already has a server running; stop it first (run.sh stop $port)" >&2
    exit 1
  fi

  echo "Starting $name on port $port ..."
  echo "  model: $file"
  echo "  backend: $BACKEND"
  echo "  threads: $threads"
  echo "  OpenAI-compatible API: http://localhost:$port/v1"
  local args=()
  [[ -n "$mmproj" && -f "$mmproj" ]] && args+=(--mmproj "$mmproj")
  if [[ -n "$draft" && -f "$draft" ]]; then
    args+=(--model-draft "$draft" --spec-type draft-mtp --spec-draft-n-max 3)
    if [[ "$BACKEND" == "cuda" ]]; then
      # server defaults the draft to the GPU (OOMs at 64k ctx) - pin it
      args+=(-ngld "${draft_ngl:-0}")
      echo "  MTP draft: $draft (GPU layers: ${draft_ngl:-0})"
    else
      echo "  MTP draft: $draft (CPU)"
    fi
  fi
  if [[ "$BACKEND" == "cuda" ]]; then
    args+=(-ngl "${GPU_NGL[$name]:-99}" -fa on)
    # q4 KV cache: keeps 64k ctx within 16 GB VRAM (measured: f16 needs 4 GB
    # for the 27B alone and OOMs)
    [[ "${GPU_NGL[$name]:-99}" != "0" ]] && args+=(-ctk q4_0 -ctv q4_0)
    [[ -n "${GPU_XTRA[$name]:-}" ]] && args+=(${GPU_XTRA[$name]})
    echo "  GPU offload: -ngl ${GPU_NGL[$name]:-99}"
  fi
  # shellcheck disable=SC2206
  [[ -n "$extra" ]] && args+=($extra)
  if [[ "${REASONING:-on}" == "off" ]]; then
    args+=(--reasoning off)
  fi
  nohup "$SERVER" \
    --model "$file" \
    --alias "$name" \
    --port "$port" \
    --host 127.0.0.1 \
    --threads "$threads" \
    --ctx-size 65536 \
    --parallel 1 \
    "${args[@]}" \
    "$@" \
    >"$BASE_DIR/logs/$name-$port.log" 2>&1 &
  echo $! > "$BASE_DIR/logs/$name-$port.pid"
  echo "$name" > "$BASE_DIR/logs/$name-$port.model"
  echo "PID: $!  Log: $BASE_DIR/logs/$name-$port.log"
  print_connect_info "$name" "$port"
}

do_start_strata() {
  local port="${1:-8080}"
  if ! nvidia-smi >/dev/null 2>&1; then
    echo "Strata serves from VRAM+RAM and needs the eGPU. Run: ./run.sh aibox" >&2
    exit 1
  fi
  if curl -s "http://localhost:$port/health" >/dev/null 2>&1; then
    echo "Port $port already has a server running; stop it first (run.sh stop $port)" >&2
    exit 1
  fi
  echo "Starting $STRATA_NAME on port $port ..."
  echo "  engine: Strata (runtime/strata) - the fast flash-next path (~52 t/s)"
  echo "  model:  $STRATA_MODEL_ID (IQ3_S; ~54 GB RAM + ~15.7 GB VRAM)"
  echo "  note:   first load takes ~40 s; API answers once /health is 200"
  nohup "$STRATA_PY" "$STRATA_DIR/serve/server.py" \
    --engine strata --config "$STRATA_CFG" --port "$port" \
    >"$BASE_DIR/logs/$STRATA_NAME-$port.log" 2>&1 &
  echo $! > "$BASE_DIR/logs/$STRATA_NAME-$port.pid"
  echo "$STRATA_NAME" > "$BASE_DIR/logs/$STRATA_NAME-$port.model"
  echo "PID: $!  Log: $BASE_DIR/logs/$STRATA_NAME-$port.log"
  print_connect_info "$STRATA_MODEL_ID" "$port"
  # Best effort: auto-start the loop guard so agent harnesses get the
  # sampling fix + loop nudge. Guard failure must not fail the Strata start.
  if curl -s "http://localhost:$GUARD_PORT/health" >/dev/null 2>&1; then
    echo ""
    echo "  Loop guard already running on port $GUARD_PORT (harnesses: http://localhost:$GUARD_PORT/v1)."
  elif ! do_guard "$GUARD_PORT"; then
    echo "  WARNING: loop guard failed to start; start it manually: ./run.sh guard $GUARD_PORT" >&2
  fi
}

# loop-guard.py reverse proxy: rewrites greedy sampling (temperature 0) to the
# published Qwen settings and injects a one-shot nudge when the conversation
# tail repeats (AAAA) or alternates (ABAB). Strata itself stays untouched.
do_guard() {
  if [[ "${1:-}" == "stop" ]]; then
    shift
    do_guard_stop "$@"
    return
  fi
  local port="${1:-$GUARD_PORT}"
  if curl -s "http://localhost:$port/health" >/dev/null 2>&1; then
    echo "Port $port already has a server running; stop it first (run.sh guard stop $port)" >&2
    return 1
  fi
  if ! curl -s "http://localhost:8080/health" >/dev/null 2>&1; then
    echo "WARNING: upstream Strata (127.0.0.1:8080) does not answer /health yet; starting the guard anyway" >&2
  fi
  echo "Starting loop guard on port $port ..."
  echo "  upstream: 127.0.0.1:8080 (Strata) - sampling fix + loop nudge on /v1/chat/completions"
  nohup python3 "$BASE_DIR/loop-guard.py" \
    --listen "127.0.0.1:$port" --upstream "127.0.0.1:8080" \
    >"$BASE_DIR/logs/loop-guard-$port.log" 2>&1 &
  echo $! > "$BASE_DIR/logs/loop-guard-$port.pid"
  echo "PID: $!  Log: $BASE_DIR/logs/loop-guard-$port.log"
  echo ""
  echo "  Harnesses (Kilo Code, omp, aider, ...) should use: http://localhost:$port/v1"
  echo "  Strata itself stays on its own port (8080). Stop the guard: run.sh guard stop $port"
}

do_guard_stop() {
  local port="${1:-}" f
  local files=()
  shopt -s nullglob
  if [[ -n "$port" ]]; then
    files=( "$BASE_DIR/logs/loop-guard-$port.pid" )
  else
    files=( "$BASE_DIR/logs/loop-guard-"*.pid )
  fi
  local stopped=0
  for f in "${files[@]}"; do
    [[ -e "$f" ]] || continue
    kill "$(cat "$f")" 2>/dev/null || true
    rm -f "$f" "${f%.pid}.log"
    echo "Stopped loop guard ($f)."
    stopped=1
  done
  shopt -u nullglob
  [[ "$stopped" == 1 ]] || echo "No loop guard running${port:+ on port $port}."
}

print_connect_info() {
  local name="$1" port="$2"
  cat <<EOF

  ── how to connect ─────────────────────────────────────────
  Web chat UI : http://localhost:$port
  API (OpenAI): http://localhost:$port/v1
  Model id    : $name
  API key     : none required (if a client insists on one, use: EMPTY)

  curl check (fails while the model is still loading; /health turns 200 when ready):
    curl -s http://localhost:$port/v1/chat/completions -H 'Content-Type: application/json' \\
      -d '{"model":"$name","messages":[{"role":"user","content":"Hello"}]}'

  Client recipes (Zed, Open WebUI, aider, ...): README.md, section
  "Connecting a chat interface".
  ────────────────────────────────────────────────────────────
EOF
}

do_aibox() {
  if nvidia-smi >/dev/null 2>&1; then
    echo "AIBOX: driver already up, nothing to do."
    nvidia-smi --query-gpu=name,pstate,pcie.link.gen.current,pcie.link.width.current --format=csv,noheader | sed 's/^/  /'
    return 0
  fi
  # PCI enumeration lags the cable plug by a few seconds; don't report
  # "not connected" inside that window (hit this on 2026-10-16).
  # NOTE: never pipe lspci into `grep -q` here — run.sh runs with pipefail and
  # grep -q exits on first match, lspci dies on SIGPIPE (exit 141) and the
  # pipeline "fails" even though the box IS present (burned us twice on
  # 2026-10-16: false "box not connected" with a healthy, enumerated GPU).
  # Capture lspci's output first and grep the string instead.
  local lspci_out=""
  for _ in $(seq 1 10); do
    lspci_out="$(lspci -nn 2>/dev/null)"
    grep -q '10de:2d04' <<<"$lspci_out" && break
    sleep 1
  done
  if ! grep -q '10de:2d04' <<<"$lspci_out"; then
    echo "AIBOX: box not connected." >&2
    echo "  1. power-cycle the box (PSU off ~30 s, then on)" >&2
    echo "  2. plug in the Thunderbolt cable (the known-good USB-C port)" >&2
    echo "  3. re-run: ./run.sh aibox" >&2
    return 1
  fi
  echo "AIBOX: box connected, driver not loaded - bringing up ..."
  if sudo bash "$BASE_DIR/egpu-bringup.sh" --gen4 && nvidia-smi >/dev/null 2>&1; then
    echo "AIBOX: up."
    nvidia-smi --query-gpu=name,pstate,pcie.link.gen.current,pcie.link.width.current --format=csv,noheader | sed 's/^/  /'
    echo "Now: ./run.sh start <model>   (fast chat: ./run.sh start qwen3.8-flash-next-strata)"
  else
    echo "AIBOX: bring-up FAILED (full log: logs/egpu-bringup.log)." >&2
    echo "  The box is probably wedged: power-cycle it (PSU off 30 s), re-plug, retry." >&2
    return 1
  fi
}

do_stop() {
  local port="${1:-}"
  local pidfile
  if [[ -n "$port" ]]; then
    pidfile="$BASE_DIR/logs/"*.pid
  else
    pidfile="$BASE_DIR/logs/"*.pid
  fi
  # shellcheck disable=SC2086
  if [[ -z "$port" ]]; then
    # the *.pid glob also catches loop-guard-<port>.pid, so stop-all stops guards
    find "$BASE_DIR/logs" -name '*.pid' -print0 2>/dev/null | while IFS= read -r -d '' f; do
      kill "$(cat "$f")" 2>/dev/null || true
      rm -f "$f" "${f%.pid}.log" "${f%.pid}.model"
    done
    echo "Stopped all servers." 
  else
    local f="$BASE_DIR/logs/"*"-$port.pid"
    shopt -s nullglob
    for f in $BASE_DIR/logs/*-$port.pid; do
      kill "$(cat "$f")" 2>/dev/null || true
      rm -f "$f" "${f%.pid}.log" "${f%.pid}.model"
      echo "Stopped server on port $port."
    done
    shopt -u nullglob
  fi
}

do_chat() {
  local model="$1"
  if [[ "$model" == "$STRATA_NAME" ]]; then
    echo "Terminal chat uses the llama.cpp engine. For Strata, use its API" >&2
    echo "(http://localhost:8080/v1) or the plain model: ./run.sh chat qwen3.8-flash-next" >&2
    exit 1
  fi
  local port="${2:-18035}"
  local file
  file="$(model_file "$model")"
  exec "$CLI" cli \
    --model "$file" \
    --threads "$(default_threads)" \
    -ngl 99 \
    -cnv -p "You are a helpful assistant, answer concisely."
}

do_show() {
  local port="${1:-18035}"
  if curl -s "http://localhost:$port/health" >/dev/null 2>&1; then
    local name=""
    for f in "$BASE_DIR/logs/"*"-$port.model"; do
      [[ -e "$f" ]] && name="$(cat "$f")"
    done
    if [[ -z "$name" ]]; then
      name="$(curl -s "http://localhost:$port/props" | grep -o '"model_alias":[^,]*' | cut -d'"' -f4 | xargs basename 2>/dev/null)"
    fi
    echo "Port $port: ${name:-running (unknown model)}"
    echo "  web UI : http://localhost:$port"
    echo "  API    : http://localhost:$port/v1  (model id: ${name:-?}, no key required)"
  else
    echo "Port $port: no server running"
  fi
}

do_perf() {
  local mode="${1:-on}"
  if [[ "$mode" == "on" ]]; then
    powerprofilesctl set performance 2>/dev/null && echo "Power profile: performance" \
      || echo "Could not set performance (run 'powerprofilesctl set performance' manually)"
  else
    powerprofilesctl set balanced 2>/dev/null && echo "Power profile: balanced" \
      || echo "Could not set balanced (run 'powerprofilesctl set balanced' manually)"
  fi
}

# Restart running servers with reasoning off (fast) or on (thinking).
do_reasoning() {
  local mode="$1" # off | on
  local ports=()
  # collect currently running ports
  for p in "$BASE_DIR/logs/"*.pid; do
    [[ -e "$p" ]] || continue
    local f="${p%.pid}"
    local port="${f##*-}"
    ports+=("$port")
  done
  if [[ ${#ports[@]} -eq 0 ]]; then
    echo "No servers running. Use: run.sh start <model> [port]"
    return 0
  fi
  local model
  for port in "${ports[@]}"; do
    model="$(cat "$BASE_DIR/logs/"*-"$port".model 2>/dev/null || grep -oE 'qwen3\.[0-9]+-[0-9a-z-]+' "$BASE_DIR/logs/"*-"$port".log 2>/dev/null | head -1)"
    echo "Restarting $model on port $port with reasoning=$mode ..."
    kill "$(cat "$BASE_DIR/logs/"*-"$port".pid)" 2>/dev/null || true
    rm -f "$BASE_DIR/logs/"*-"$port".pid
    REASONING="$mode" do_start "$model" "$port"
  done
}

download() {
  cd "$BASE_DIR"
  echo "Downloading Qwen3.6-35B-A3B (Q4_K_M, ~22 GB)..."
  mkdir -p models/qwen3.6-35b-a3b
  curl -L --retry 5 -C - -o models/qwen3.6-35b-a3b/Qwen3.6-35B-A3B-UD-Q4_K_M.gguf \
    "https://huggingface.co/unsloth/Qwen3.6-35B-A3B-GGUF/resolve/main/Qwen3.6-35B-A3B-UD-Q4_K_M.gguf"
  echo "Downloading Qwen3.8-27B (Q4_K_M, ~19 GB)..."
  mkdir -p models/qwen3.8-27b
  curl -L --retry 5 -C - -o models/qwen3.8-27b/Qwen3.8-27B-Q4_K_M.gguf \
    "https://huggingface.co/ggml-org/Qwen3.8-27B-GGUF/resolve/main/Qwen3.8-27B-Q4_K_M.gguf"
  echo "Done."
}

mkdir -p "$BASE_DIR/logs"

cmd="${1:-}"
shift || true
case "$cmd" in
  serve) do_start "$@" ;;
  start) do_start "$@" ;;
  stop) do_stop "$@" ;;
  guard) do_guard "$@" ;;
  chat) do_chat "$@" ;;
  show) do_show "$@" ;;
  aibox) do_aibox "$@" ;;
  download) download ;;
  perf) do_perf "$@" ;;
  fast) do_reasoning off ;;
  thinking) do_reasoning on ;;
  *) usage ;;
esac