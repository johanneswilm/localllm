#!/usr/bin/env bash
# Stage 2: recover the NVIDIA driver on a settled Thunderbolt link.
# The boot-time probe of the eGPU fails (GSP firmware init while link/retimers
# settle). This unloads the module, pins ASPM off via setpci, lets the link
# settle, then loads the driver once -- the pattern from stable AORUS-box setups.
set -uo pipefail

echo "== link state before =="
for d in 0000:01:00.0 0000:02:00.0 0000:03:00.0; do
  [ -d "/sys/bus/pci/devices/$d" ] && echo "$d: $(cat /sys/bus/pci/devices/$d/current_link_speed 2>/dev/null) x$(cat /sys/bus/pci/devices/$d/current_link_width 2>/dev/null)"
done

echo "== unloading nvidia (ignore errors) =="
modprobe -r nvidia_uvm nvidia 2>/dev/null
sleep 1

echo "== ASPM off via setpci (GPU + upstream bridges) =="
for d in 0000:01:00.0 0000:02:00.0 0000:03:00.0; do
  if [ -d "/sys/bus/pci/devices/$d" ]; then
    setpci -s "$d" CAP_EXP+10.w=0000 && echo "$d ASPM off"
  fi
done
sleep 2

echo "== loading nvidia (up to 3 attempts, 5s between) =="
ok=0
for i in 1 2 3; do
  modprobe nvidia 2>/dev/null
  sleep 3
  if [ -c /dev/nvidiactl ] && nvidia-smi >/dev/null 2>&1; then
    echo "attempt $i: SUCCESS"
    ok=1
    break
  else
    echo "attempt $i: probe failed"
    modprobe -r nvidia 2>/dev/null
    sleep 5
  fi
done

echo "== result =="
if [ "$ok" = 1 ]; then
  nvidia-smi | head -20
  echo
  echo "PASS: driver is up. Now enable persistence:"
  echo "  sudo systemctl start nvidia-persistenced"
  echo "  sudo nvidia-smi -pm 1 -pl 180"
else
  echo "FAIL: probe still failing. Get diagnostics with:"
  echo "  journalctl -k -b 0 --no-pager | grep -iE 'nvidia|xid' | tail -30"
fi
