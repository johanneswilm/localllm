#!/usr/bin/env bash
# iGPU (Radeon 890M) Vulkan benchmark for llama.cpp -- the deferred TODO.md
# experiment, run while the eGPU is blocked. Builds a separate Vulkan tree
# (CPU build stays untouched) and benches the three existing models.
# Requires: glslc (sudo apt install -y glslc) -- run this script as your user,
# it only needs sudo for the apt line if glslc is missing.
set -euo pipefail

cd "$(dirname "$0")"
LL=runtime/llama.cpp

if ! command -v glslc >/dev/null 2>&1; then
  echo "glslc missing -- install it first: sudo apt install -y glslc"
  exit 1
fi
if ! dpkg -l libvulkan-dev 2>/dev/null | grep -q '^ii'; then
  echo "libvulkan-dev missing -- install it first: sudo apt install -y libvulkan-dev"
  exit 1
fi

echo "== configure Vulkan build =="
cmake -S "$LL" -B "$LL/build-vulkan" -DGGML_VULKAN=ON -DCMAKE_BUILD_TYPE=Release

echo "== build (this takes several minutes) =="
cmake --build "$LL/build-vulkan" -j"$(nproc)" --target llama-server llama-cli llama-bench

echo "== devices =="
"$LL/build-vulkan/bin/llama-bench" --list-devices 2>/dev/null | head -8 || true

echo "== bench: qwen3.6-35b-a3b =="
"$LL/build-vulkan/bin/llama-bench" --model models/qwen3.6-35b-a3b/Qwen3.6-35B-A3B-UD-Q4_K_M.gguf -ngl 99 -n 64 -r 2 2>&1 | tail -5

echo "== bench: qwen3.8-27b =="
"$LL/build-vulkan/bin/llama-bench" --model models/qwen3.8-27b/Qwen3.8-27B-Q4_K_M.gguf -ngl 99 -n 64 -r 2 2>&1 | tail -5

echo "== done =="
echo "Compare against CPU baselines in TODO.md (17.5 / 3.5 t/s)."
