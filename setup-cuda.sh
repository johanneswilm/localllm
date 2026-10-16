#!/usr/bin/env bash
# Install NVIDIA CUDA toolkit 13.4 from NVIDIA's repo (Ubuntu's nvidia-cuda-toolkit
# is 12.4 -- too old for Blackwell/sm_120; >= 12.8 required to build llama.cpp CUDA).
# Safe to re-run. Does not touch the driver.
set -euo pipefail

cd /tmp
echo "== 1/4 CUDA keyring =="
if ! dpkg -l cuda-keyring 2>/dev/null | grep -q '^ii'; then
  curl -fSL -O https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2604/x86_64/cuda-keyring_1.1-1_all.deb
  dpkg -i cuda-keyring_1.1-1_all.deb
else
  echo "already installed"
fi

echo "== 2/4 apt update =="
apt update

echo "== 3/4 install toolkit (several GB download) =="
apt install -y cuda-toolkit-13-4

echo "== 4/4 verify =="
/usr/local/cuda/bin/nvcc --version | tail -2
echo
echo "Done. If nvcc printed 13.4, the llama.cpp CUDA build can proceed."
