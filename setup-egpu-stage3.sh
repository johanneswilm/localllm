#!/usr/bin/env bash
# Stage 3: (a) upgrade driver 595 -> 615-open, (b) install a boot-time service that
# loads the NVIDIA driver only after pinning the eGPU chain awake (fix for the
# D3cold "fallen off the bus" boot-time probe failure). Reboot with the box
# attached afterwards. Idempotent -- safe to re-run.
set -euo pipefail

echo "== 1/3 driver upgrade 595 -> 615-open =="
apt install -y nvidia-driver-615-open

echo "== 2/3 boot-time awake-first loader =="
cat > /usr/local/sbin/egpu-load.sh <<'EOF'
#!/usr/bin/env bash
# Load nvidia.ko only after the eGPU is awake. Invoked by egpu-load.service.
set -u
exec >>/var/log/egpu-load.log 2>&1
echo "=== $(date) egpu-load start ==="
D=/sys/bus/pci/devices/0000:03:00.0
for i in $(seq 1 90); do
  [ -d "$D" ] && break
  sleep 1
done
if [ ! -d "$D" ]; then
  echo "eGPU not present, nothing to do"
  exit 0
fi
modprobe -r nvidia_uvm nvidia 2>/dev/null || true
for d in 0000:01:00.0 0000:02:00.0 0000:03:00.0; do
  [ -d "/sys/bus/pci/devices/$d" ] || continue
  echo on > "/sys/bus/pci/devices/$d/power/control" 2>/dev/null || true
  [ -f "/sys/bus/pci/devices/$d/power/d3cold_allowed" ] && echo 0 > "/sys/bus/pci/devices/$d/power/d3cold_allowed" 2>/dev/null || true
done
sleep 2
ok=0
for i in 1 2 3; do
  modprobe nvidia 2>/dev/null
  sleep 4
  if nvidia-smi >/dev/null 2>&1; then ok=1; echo "nvidia loaded on attempt $i"; break; fi
  echo "attempt $i failed"
  modprobe -r nvidia 2>/dev/null || true
  sleep 4
done
if [ "$ok" != 1 ]; then
  echo "bouncing device (remove/rescan)"
  echo 1 > "$D/remove" 2>/dev/null || true
  sleep 3
  echo 1 > /sys/bus/pci/rescan
  sleep 6
  for d in 0000:01:00.0 0000:02:00.0 0000:03:00.0; do
    echo on > "/sys/bus/pci/devices/$d/power/control" 2>/dev/null || true
  done
  for i in 1 2 3; do
    modprobe nvidia 2>/dev/null
    sleep 4
    if nvidia-smi >/dev/null 2>&1; then ok=1; echo "nvidia loaded after bounce, attempt $i"; break; fi
    modprobe -r nvidia 2>/dev/null || true
    sleep 6
  done
fi
if [ "$ok" = 1 ]; then
  nvidia-smi -pm 1 || true
  systemctl start nvidia-persistenced || true
else
  echo "FAILED to load nvidia"
fi
echo "=== $(date) egpu-load end ==="
EOF
chmod +x /usr/local/sbin/egpu-load.sh

cat > /etc/systemd/system/egpu-load.service <<'EOF'
[Unit]
Description=Load NVIDIA driver once Thunderbolt eGPU is awake
ConditionPathExists=/sys/bus/pci/devices/0000:03:00.0
After=multi-user.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/egpu-load.sh

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable egpu-load.service

echo "== 3/3 done =="
echo "Reboot with the AI BOX attached. Afterwards verify:"
echo "  systemctl status egpu-load.service --no-pager"
echo "  nvidia-smi | head -20"
echo "  tail -30 /var/log/egpu-load.log"
