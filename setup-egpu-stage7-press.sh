#!/usr/bin/env bash
# Stage 7: full-court press on kernel 7.3.0 -- every remaining load strategy in
# one run, each labeled. Stops at the first success and says which step won.
# Requires Secure Boot OFF. Run: sudo bash setup-egpu-stage7-press.sh
set -uo pipefail

detect() {
  D=$(lspci -nn | awk '/10de:2d04/ {print $1; exit}')
  DD="0000:$D"
  BUS=${D%%:*}
  BR_MID=$(printf "0000:%02x:00.0" $((BUS - 1)))
  BR_TOP=$(printf "0000:%02x:00.0" $((BUS - 2)))
}

pin_awake() {
  detect
  for d in "$BR_TOP" "$BR_MID" "$DD"; do
    [ -d "/sys/bus/pci/devices/$d" ] && echo on > "/sys/bus/pci/devices/$d/power/control" 2>/dev/null
  done
}

try_load() {
  local tag="$1" i
  for i in 1 2; do
    modprobe nvidia 2>/dev/null
    sleep 4
    if nvidia-smi >/dev/null 2>&1; then
      echo ">>> SUCCESS at: $tag"
      nvidia-smi | head -20
      echo
      echo "WINNER: $tag -- tell me which step passed so I bake it into the boot service."
      exit 0
    fi
    echo ">>> $tag attempt $i: failed"
    modprobe -r nvidia 2>/dev/null || true
    sleep 4
  done
  return 1
}

modprobe -r nvidia_uvm nvidia 2>/dev/null || true
pin_awake

echo "== step 1: plain late load (device is awake right now) =="
try_load "plain late load" && exit 0

echo "== step 2: Gen3 pin on all chain links + retrain =="
detect
for d in "$BR_TOP" "$BR_MID" "$DD"; do
  [ -d "/sys/bus/pci/devices/$d" ] && setpci -s "$d" CAP_EXP+10.w=0000 2>/dev/null
  [ -d "/sys/bus/pci/devices/$d" ] && setpci -s "$d" CAP_EXP+30.w=0x0003:0x000f 2>/dev/null
done
sleep 1
for d in "$BR_MID" "$DD"; do
  setpci -s "$d" CAP_EXP+10.w=0x0020:0x0020 2>/dev/null
done
sleep 6
echo "link after pin attempt: $(cat /sys/bus/pci/devices/$DD/current_link_speed 2>/dev/null) (8.0 = pin worked, 16.0 = tunnel controls speed)"
try_load "Gen3 pin" && exit 0

echo "== step 3: remove/rescan bounce =="
detect
echo 1 > "/sys/bus/pci/devices/$DD/remove" 2>/dev/null || true
sleep 3
echo 1 > /sys/bus/pci/rescan
sleep 6
pin_awake
detect
echo "device back at: ${D:-GONE} status=$(cat /sys/bus/pci/devices/$DD/power/runtime_status 2>/dev/null)"
try_load "remove/rescan bounce" && exit 0

echo "== step 4: hot-add (physical) =="
echo ">>> UNPLUG the Thunderbolt cable from the laptop now."
echo ">>> Wait 10 seconds. REPLUG it (same port is fine)."
echo ">>> Then press Enter here."
read -r _
sleep 6
if ! lspci -nn | grep -q 10de:2d04; then
  echo "not enumerated after replug, triggering rescan"
  echo 1 > /sys/bus/pci/rescan
  sleep 6
fi
pin_awake
detect
echo "device at: ${D:-GONE}"
[ -n "$D" ] && try_load "hot-add"

echo
echo "ALL STEPS FAILED. Capture:"
echo "  journalctl -k -b 0 --no-pager | grep -iE 'nvidia|03:00|aer' | tail -40"
