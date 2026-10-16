#!/usr/bin/env bash
# Stage 5: install mainline kernel 7.2.10.
# Mainline kernels are UNSIGNED -> requires Secure Boot OFF to boot.
# DKMS (nvidia, virtualbox) is rebuilt for the new kernel during install.
set -euo pipefail
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

V=7.2.6
URL="https://kernel.ubuntu.com/mainline/v${V}/amd64"

echo "== /boot space =="
df -h /boot | tail -1

echo "== package list =="
pkgs=$(curl -fsSL "$URL/" | grep -oE "linux-(headers|image-unsigned|modules)-${V}[^\"<]*_amd64\.deb" | sort -u)
echo "$pkgs"
[ -n "$pkgs" ] || { echo "ERROR: no packages found at $URL (version may not exist)"; exit 1; }

echo "== downloading =="
cd /tmp
rm -f linux-*"${V}"*.deb
for p in $pkgs; do curl -fSL -O "$URL/$p"; done

echo "== installing (this triggers DKMS rebuilds) =="
dpkg -i /tmp/linux-*"${V}"*.deb

echo "== DKMS status =="
dkms status | grep -iE 'nvidia|virtualbox' || true

echo
echo "Done. Reboot and GRUB will start $V by default."
echo "Then: nvidia-smi | head -20"
echo "If 'fallen off the bus' persists on $V: sudo bash \"$REPO_DIR/setup-egpu-stage4.sh\""
