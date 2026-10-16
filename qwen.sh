#!/usr/bin/env bash
# Launch Qwen Code against the local llama-server (OpenAI-compatible).
# Usage:
#   ./qwen.sh                      - start server if needed, then interactive Qwen Code
#   ./qwen.sh "your prompt"        - non-interactive single shot
#   ./qwen.sh --model qwen3.8-27b  - pick which local model to load (default qwen3.6-35b-a3b)
set -euo pipefail

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PORT="${QWEN_LOCAL_PORT:-18035}"
MODEL_KEY="${QWEN_LOCAL_MODEL:-qwen3.6-35b-a3b}"

case "$MODEL_KEY" in
  qwen3.6-35b-a3b) ;;
  qwen3.8-27b) ;;
  qwen3.8-flash-next) ;;
  *) echo "Unknown model: $MODEL_KEY (use qwen3.6-35b-a3b, qwen3.8-27b or qwen3.8-flash-next)" >&2; exit 1 ;;
esac

# Make sure the local server is running on the target port.
if ! curl -s "http://localhost:$PORT/health" >/dev/null 2>&1; then
  echo "Starting local model ($MODEL_KEY) on port $PORT ..."
  "$BASE_DIR/run.sh" perf on >/dev/null 2>&1 || true
  "$BASE_DIR/run.sh" start "$MODEL_KEY" "$PORT" >/dev/null
  printf "Waiting for server"
  for i in $(seq 1 60); do
    if curl -s "http://localhost:$PORT/health" >/dev/null 2>&1; then echo " ready."; break; fi
    printf "."
    sleep 5
  done
  if ! curl -s "http://localhost:$PORT/health" >/dev/null 2>&1; then
    echo "Server did not become ready. Check logs in $BASE_DIR/logs/" >&2
    exit 1
  fi
fi

export OPENAI_API_KEY="local"
export OPENAI_BASE_URL="http://localhost:$PORT/v1"
# Use a recognized Qwen model id so Qwen Code can resolve token limits,
# while the actual serving happens on our local llama-server.
export OPENAI_MODEL="${QWEN_UPSTREAM_MODEL:-qwen3-coder}"

exec qwen --model "$OPENAI_MODEL" "$@"