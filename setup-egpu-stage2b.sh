#!/usr/bin/env bash
# Stage 2b: load nvidia on an AWAKE eGPU.
# Cold-boot sequence leaves the GPU in D3cold ("fallen off the bus" on probe).
# Strategy: pin power/control=on + d3cold_allowed=0 on the whole chain, try a
# plain late load; if that fails, bounce the device (remove/rescan -> D0) and
# retry. All sysfs writes -- works under Secure Boot lockdown (unlike setpci).
set -uo pipefail

D=/sys/bus/pci/devices/0000:03:00.0

echo "== power state =="
for d in 0000:01:00.0 0000:02:00.0 0000:03:00.0; do
  echo "$d control=$(cat /sys/bus/pci/devices/$d/power/control 2>/dev/null) status=$(cat /sys/bus/pci/devices/$d/power/runtime_status 2>/dev/null)"
done

modprobe -r nvidia_uvm nvidia 2>/dev/null || true

echo "== pin chain awake =="
for d in 0000:01:00.0 0000:02:00.0 0000:03:00.0; do
  echo on > "/sys/bus/pci/devices/$d/power/control" 2>/dev/null || true
  [ -f "/sys/bus/pci/devices/$d/power/d3cold_allowed" ] && echo 0 > "/sys/bus/pci/devices/$d/power/d3cold_allowed" 2>/dev/null || true
done

try_load() {
  local i
  for i in 1 2 3; do
    modprobe nvidia 2>/dev/null
    sleep 4
    if nvidia-smi >/dev/null 2>&1; then echo "load attempt $i: SUCCESS"; return 0; fi
    echo "load attempt $i: failed"
    modprobe -r nvidia 2>/dev/null || true
    sleep 4
  done
  return 1
}

echo "== try plain late load =="
if try_load; then
  nvidia-smi | head -20
  echo; echo "PASS: late load worked (device was already awake)."
  echo "Enable persistence: sudo systemctl start nvidia-persistenced && sudo nvidia-smi -pm 1"
  exit 0
fi

echo "== bounce device: remove + rescan =="
echo 1 > "$D/remove" 2>/dev/null || true
sleep 3
echo 1 > /sys/bus/pci/rescan
sleep 6
for d in 0000:01:00.0 0000:02:00.0 0000:03:00.0; do
  echo on > "/sys/bus/pci/devices/$d/power/control" 2>/dev/null || true
done
echo "device after rescan: $(cat $D/power/runtime_status 2>/dev/null)"

echo "== retry after bounce =="
if try_load; then
  nvidia-smi | head -20
  echo; echo "PASS: load worked after remove/rescan bounce."
  echo "Enable persistence: sudo systemctl start nvidia-persistenced && sudo nvidia-smi -pm 1"
else
  echo "FAIL: still not loading. Diagnostics:"
  echo "  journalctl -k -b 0 --no-pager | grep -iE 'nvidia|03:00' | tail -40"
fi
