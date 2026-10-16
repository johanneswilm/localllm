#!/usr/bin/env bash
# Stage 10: safety fixes after the stage-9 console-spam incident.
#  - disable egpu-up.service (blind auto-bring-up; replaced by manual
#    egpu-bringup.sh run AFTER the cable is connected)
#  - hide kernel error spam from the console (journald still records all)
#  - try to stop the box wedging on reboot: detach the GPU during shutdown
# Run as root: sudo bash setup-egpu-stage10.sh
set -euo pipefail
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "== 1/4 disable auto bring-up service =="
systemctl disable egpu-up.service 2>/dev/null || true

echo "== 2/4 keep kernel errors off the console =="
sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT="quiet splash /GRUB_CMDLINE_LINUX_DEFAULT="quiet splash loglevel=2 /' /etc/default/grub
grep '^GRUB_CMDLINE_LINUX_DEFAULT' /etc/default/grub

echo "== 3/4 shutdown disarm: detach GPU before PCI teardown =="
cat > /etc/systemd/system/egpu-down.service <<'EOF'
[Unit]
Description=Detach AORUS eGPU before shutdown
DefaultDependencies=no
Before=shutdown.target umount.target final.target

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'for d in 03:00.0 03:00.1; do [ -e /sys/bus/pci/devices/0000:$d ] && echo 1 > /sys/bus/pci/devices/0000:$d/remove; done; true'
TimeoutStartSec=10

[Install]
WantedBy=shutdown.target
EOF
systemctl daemon-reload
systemctl enable egpu-down.service

echo "== 4/4 update grub =="
update-grub

cat <<EOF

Done. New workflow per attempt:
  1. power-cycle the AI box (PSU off 30s, back on)
  2. boot / log in as usual (multi-user text console is fine)
  3. connect the Thunderbolt cable AFTER login
  4. sudo bash "$REPO_DIR/egpu-bringup.sh" --gen4
     (add --pin-only to stop after the link pin)
  5. show me the output; if OK I run the CUDA load test
EOF
