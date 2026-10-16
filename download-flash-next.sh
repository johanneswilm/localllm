#!/usr/bin/env bash
# One-off download for Qwen3.8-Flash-Next (AtomicChat AD-4.27bpw) + MTP drafts.
# Resumable: safe to re-run; completed files are skipped, partials resumed.
set -uo pipefail

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FN_DIR="$BASE_DIR/models/qwen3.8-flash-next"
D27_DIR="$BASE_DIR/models/qwen3.8-27b"
mkdir -p "$FN_DIR"

dl() { # dl <url> <dest>
  local url="$1" dest="$2"
  curl -L --fail --retry 10 --retry-all-errors --http1.1 -C - --connect-timeout 30 -o "$dest" "$url"
}

echo "== small files =="
dl "https://huggingface.co/ggml-org/Qwen3.8-27B-GGUF/resolve/main/mtp-Qwen3.8-27B-Q4_0.gguf" \
   "$D27_DIR/mtp-Qwen3.8-27B-Q4_0.gguf"
dl "https://huggingface.co/unsloth/Qwen3.8-Flash-Next-GGUF/resolve/main/MTP/mtp-Qwen3.8-Flash-Next-Q4_K_M.gguf" \
   "$FN_DIR/mtp-Qwen3.8-Flash-Next-Q4_K_M.gguf"
dl "https://huggingface.co/AtomicChat/Qwen3.8-Flash-Next-GGUF/resolve/main/mmproj-Qwen3.8-Flash-Next-F16.gguf" \
   "$FN_DIR/mmproj-Qwen3.8-Flash-Next-F16.gguf"

echo "== AD-4.27bpw shards (33, ~88 GiB), 6 at a time =="
HUB="https://huggingface.co/AtomicChat/Qwen3.8-Flash-Next-GGUF/resolve/main/Qwen3.8-Flash-Next-AD-4.27bpw-Q4_K_M-M64"
printf '%s\n' $(seq -w 1 33) | xargs -P 6 -I{} bash -c '
  f="Qwen3.8-Flash-Next-AD-4.27bpw-Q4_K_M-M64-000{}-of-00033.gguf"
  curl -sS -L --fail --retry 10 --retry-all-errors --http1.1 -C - --connect-timeout 30 -o "'"$FN_DIR"'/$f" "'"$HUB"'/$f" \
    && echo "done: $f" || { echo "FAILED: $f"; exit 1; }
' || exit 1
echo "== all downloads complete =="
