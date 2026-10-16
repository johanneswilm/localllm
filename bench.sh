#!/usr/bin/env bash
set -euo pipefail

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODELS_DIR="$BASE_DIR/models"

if [[ -x "$BASE_DIR/runtime/llama.cpp/build-cuda/bin/llama-bench" ]] && nvidia-smi >/dev/null 2>&1; then
  BENCH="$BASE_DIR/runtime/llama.cpp/build-cuda/bin/llama-bench"
else
  BENCH="$BASE_DIR/runtime/llama.cpp/build/bin/llama-bench"
fi

model="${1:-qwen3.6-35b-a3b}"
shift || true

case "$model" in
  qwen3.6-35b-a3b)     file="$MODELS_DIR/qwen3.6-35b-a3b/Qwen3.6-35B-A3B-UD-Q4_K_M.gguf" ;;
  qwen3.8-27b)         file="$MODELS_DIR/qwen3.8-27b/Qwen3.8-27B-Q4_K_M.gguf" ;;
  qwen3.8-flash-next)  file="$MODELS_DIR/qwen3.8-flash-next/Qwen3.8-Flash-Next-AD-4.27bpw-Q4_K_M-M64-00001-of-00033.gguf" ;;
  *) echo "Usage: bench.sh {qwen3.6-35b-a3b|qwen3.8-27b|qwen3.8-flash-next}" >&2; exit 1 ;;
esac

if [[ ! -f "$file" ]]; then
  echo "Model not found: $file" >&2
  exit 1
fi

echo "Benchmarking $model ..."
echo "Using $BENCH"
tpc="$(lscpu | awk '/^Thread\(s\) per core:/ {print $4}')"
phys="$(nproc)"
if [[ -n "$tpc" && "$tpc" -gt 0 && "$phys" -gt "$tpc" ]]; then threads=$((phys / tpc)); else threads=12; fi
echo "Using $threads physical threads"
echo "Extra args: $*"
exec "$BENCH" --model "$file" --threads "$threads" -n 64 -r 2 "$@"