#!/usr/bin/env bash
# Stage 5b (v2): install the Ubuntu 'stonking' (26.10) kernel 7.3.0 on 26.04,
# letting apt resolve cross-release deps (libssl4, linux-main-modules-*) from the
# stonking pocket.
#
# Rabbit-hole safeguards:
#   - stonking is pinned to priority 100: only packages resolute does NOT have
#     are ever taken from it; no mass-upgrade.
#   - the temp source + pin are REMOVED after install, so future apt runs never
#     see stonking again. The installed kernel packages keep working; your
#     do-release-upgrade to 26.10 supersedes them cleanly.
# Requires Secure Boot OFF (unsigned image). Idempotent.
set -euo pipefail
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

LIST=/etc/apt/sources.list.d/zz-stonking-kernel.list
PIN=/etc/apt/preferences.d/zz-stonking-kernel
KVER=7.3.0-9

echo "== 1/5 add stonking source (pinned to 100 = only-if-missing) =="
if [ ! -f "$LIST" ]; then
  echo "deb http://archive.ubuntu.com/ubuntu stonking main" > "$LIST"
fi
if [ ! -f "$PIN" ]; then
  cat > "$PIN" <<'EOF'
Package: *
Pin: release a=stonking
Pin-Priority: 100
EOF
fi

echo "== 2/5 apt update (downloads stonking indexes, ~100 MB) =="
apt update

echo "== 3/5 install kernel $KVER (deps auto-resolve from stonking) =="
apt install -y "linux-image-unsigned-${KVER}-generic" "linux-modules-${KVER}-generic" "linux-headers-${KVER}-generic"

echo "== 4/5 remove temp source + pin (installed packages stay) =="
rm -f "$LIST" "$PIN"
rm -f /var/lib/apt/lists/*stonking* 2>/dev/null || true
apt update

echo "== 5/5 DKMS status (nvidia must list 7.3.0) =="
dkms status | grep -i nvidia || true

echo
echo "Done. Reboot -> GRUB defaults to 7.3.0. Then:"
echo "  nvidia-smi | head -20"
echo "  journalctl -k -b 0 --no-pager | grep -iE 'nvidia|fallen' | tail -15"
echo "If 'fallen off the bus' persists: sudo bash \"$REPO_DIR/setup-egpu-stage4.sh\""
echo "(7.0.0-38 stays installed; GRUB -> Advanced options to go back)"
