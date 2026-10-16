#!/usr/bin/env bash
# egpu-bringup.sh - careful, step-verified bring-up of the AORUS eGPU.
#
# Unlike stage 9 (which poked registers blind and modprobed regardless), this
# script reads PCI config space via sysfs, verifies the device is alive before
# every step, strips ASPM/L1 substates on EVERY link of the Thunderbolt chain
# (host root port + both JHL9480 bridges + the GPU, a la Damian's
# blackwell-egpu-manager), pins the GPU link speed, checks the BARs for the
# "garbage BAR" wedge facet, and only then loads the NVIDIA driver. If
# anything looks dead it stops WITHOUT modprobe, so the console can never be
# flooded with probe errors again and nvidia-persistenced cannot restart-storm.
#
# Usage: sudo bash egpu-bringup.sh [--gen3|--gen4] [--pin-only] [--status]
#   --gen4      target Gen4 16 GT/s (default; nikomiiller recipe)
#   --gen3      target Gen3 8 GT/s  (damian recipe variant)
#   --pin-only  pin the link, do not modprobe nvidia
#   --status    read-only dump of the chain (no writes, no driver load)
set -uo pipefail

GEN=4
PIN_ONLY=0
STATUS=0
for a in "$@"; do
  case "$a" in
    --gen3) GEN=3 ;;
    --gen4) GEN=4 ;;
    --pin-only) PIN_ONLY=1 ;;
    --status) STATUS=1 ;;
  esac
done

# the Thunderbolt chain on this host: root port -> JHL9480 -> JHL9480 -> GPU
# (03:00.1 is the GPU's audio function; it shares the GPU's physical link)
CHAIN="00:01.1 01:00.0 02:00.0 03:00.0 03:00.1"
GPU=03:00.0
BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG="$BASE_DIR/logs/egpu-bringup.log"
mkdir -p "$(dirname "$LOG")"
exec > >(tee -a "$LOG") 2>&1
echo "===== $(date) bring-up gen$GEN pin_only=$PIN_ONLY status=$STATUS ====="

if [ "$(id -u)" != 0 ]; then
  if [ "$STATUS" = 1 ]; then
    echo "NOTE: without sudo the kernel gates config reads to the 64-byte"
    echo "standard header (drivers/pci/pci-sysfs.c caps unprivileged reads),"
    echo "so link/ASPM/L1PM info below will be missing. A 64-byte 'wc -c' is"
    echo "NOT a wedge indicator. Re-run with sudo for the full chain dump."
    echo
  else
    echo "this script writes PCI config space and loads the driver: run it with sudo"
    exit 1
  fi
fi

if [ "$STATUS" = 1 ]; then
  echo "--- chain status (read-only) ---"
else
  # keep devices awake; without a bound driver the GPU can sit in D3 and its
  # config space then refuses write access
  for d in $CHAIN; do
    [ -e /sys/bus/pci/devices/0000:$d/power/control ] && echo on > /sys/bus/pci/devices/0000:$d/power/control 2>/dev/null
  done
fi

python3 - "$STATUS" "$GPU" "$GEN" <<'PYEOF'
import sys, time

status = sys.argv[1] == "1"
gpu, gen = sys.argv[2], int(sys.argv[3])
chain = ["00:01.1", "01:00.0", "02:00.0", "03:00.0", "03:00.1"]

def cfg(bdf):
    return f"/sys/bus/pci/devices/0000:{bdf}/config"

def rw(bdf, off, size, val=None):
    mode = "r+b" if val is not None else "rb"
    with open(cfg(bdf), mode, buffering=0) as f:
        f.seek(off)
        if val is None:
            return int.from_bytes(f.read(size), "little")
        f.write(val.to_bytes(size, "little"))

def find_cap(bdf, base, cid):
    off = rw(bdf, base, 1)
    while off:
        if rw(bdf, off, 1) == cid:
            return off
        off = rw(bdf, off + 1, 1)
    return 0

def l1pm_cap(bdf):
    off = 0x100
    while off:
        d = rw(bdf, off, 4)
        if (d & 0xFFF) == 0x1E:
            return off
        off = (d >> 20) & 0xFFC
    return 0

def alive(bdf):
    try:
        ven, dev = rw(bdf, 0, 2), rw(bdf, 2, 2)
    except OSError:
        return None, None
    return ven, dev

def show(bdf):
    ven, dev = alive(bdf)
    if ven is None:
        print(f"{bdf}: not present")
        return
    if ven == 0xFFFF or dev == 0xFFFF:
        print(f"{bdf}: DEAD (config space 0xFFFF)")
        return
    pcie = find_cap(bdf, 0x34, 0x10)
    line = f"{bdf}: {ven:04x}:{dev:04x}"
    if pcie:
        lnkctl, lnksta = rw(bdf, pcie + 0x10, 2), rw(bdf, pcie + 0x12, 2)
        spd, width = lnksta & 0xF, (lnksta >> 4) & 0x3F
        line += f" Gen{spd} x{width} LnkCtl={lnkctl:04x}(ASPM={lnkctl & 3})"
    l1pm = l1pm_cap(bdf)
    if l1pm:
        ctl1 = rw(bdf, l1pm + 0x08, 4)
        line += f" L1PM@0x{l1pm:03x} ctl1={ctl1:08x}(en={ctl1 & 0xF})"
    if bdf == gpu:
        bars = [rw(bdf, 0x10 + 4 * i, 4) for i in range(6)]
        line += " BARs=" + " ".join(f"{b:08x}" for b in bars)
    print(line)

if status:
    for d in chain:
        show(d)
    sys.exit(0)

dead = []
for d in chain:
    ven, dev = alive(d)
    if ven is None:
        if d == "03:00.1":
            print(f"{d}: audio function absent, skipping")
            chain.remove(d)
            continue
        dead.append(f"{d} (no config space)")
    elif ven == 0xFFFF or dev == 0xFFFF:
        dead.append(f"{d} (0xFFFF)")
if dead:
    print("DEAD: " + "; ".join(dead) + " - power-cycle the box (PSU cord out 2-3 min)")
    sys.exit(1)

for d in chain:
    pcie = find_cap(d, 0x34, 0x10)
    if not pcie:
        print(f"{d}: no PCIe capability, skipping")
        continue
    lnkctl = rw(d, pcie + 0x10, 2)
    # ASPM off (clear bits 0-1), preserve everything else; no retrain yet
    rw(d, pcie + 0x10, 2, lnkctl & ~0x3)
    l1pm = l1pm_cap(d)
    if l1pm:
        ctl1 = rw(d, l1pm + 0x08, 4)
        rw(d, l1pm + 0x08, 4, ctl1 & ~0x3)
        ctl2 = rw(d, l1pm + 0x0C, 4)
        rw(d, l1pm + 0x0C, 4, ctl2 & ~0x3)
    print(f"{d}: ASPM+L1SS off (LnkCtl was {lnkctl:04x})")

# target speed + retrain on the GPU last, after every upstream link is clean
pcie = find_cap(gpu, 0x34, 0x10)
if not pcie:
    print("GPU has no reachable PCIe capability. As root this means the")
    print("device is genuinely dead (wedged box: config reads 0xFFFF/short).")
    print("NOTE: without root the kernel caps config reads at the 64-byte")
    print("header (pci-sysfs.c), which looks identical - run with sudo to be")
    print("sure. If truly wedged: power-cycle the box (PSU cord out 2-3 min);")
    print("driver NOT loaded.")
    sys.exit(4)
lnkctl, lnksta, lnkctl2 = rw(gpu, pcie + 0x10, 2), rw(gpu, pcie + 0x12, 2), rw(gpu, pcie + 0x30, 2)
print(f"{gpu} before: LnkSta={lnksta:04x} LnkCtl2={lnkctl2:04x}")
rw(gpu, pcie + 0x30, 2, (lnkctl2 & ~0xF) | gen)
rw(gpu, pcie + 0x10, 2, (lnkctl & ~0x3) | 0x20)

for _ in range(50):
    time.sleep(0.1)
    lnksta = rw(gpu, pcie + 0x12, 2)
    if (lnksta & 0x3FFF) != 0 and (lnksta & 0x2000):
        break
lnksta = rw(gpu, pcie + 0x12, 2)
spd, width = lnksta & 0xF, (lnksta >> 4) & 0x3F
print(f"{gpu} after: LnkSta speed=Gen{spd} width=x{width}")
if spd != gen:
    print(f"MISMATCH: wanted Gen{gen}, link at Gen{spd} - not loading driver")
    sys.exit(2)

# the third wedge facet: link healthy but BAR registers garbage/zero, which
# makes modprobe fail with "PCI I/O region ... is invalid" and sends
# nvidia-persistenced into a restart storm - check BEFORE the driver
bars = [rw(gpu, 0x10 + 4 * i, 4) for i in range(6)]
print(f"{gpu} BARs: " + " ".join(f"{b:08x}" for b in bars))
if bars[0] in (0x00000000, 0xFFFFFFFF) or bars[0] == bars[1] == bars[2] == bars[3] == 0:
    print("BAR GARBAGE: link is up but the device returns no BARs - the box is wedged")
    print("in the third facet; power-cycle it (PSU cord out 2-3 min). Driver NOT loaded.")
    sys.exit(3)
print("LINK PINNED OK")
PYEOF
rc=$?

if [ "$STATUS" = 1 ]; then
  echo "RESULT: status done"
  exit 0
fi

if [ $rc -ne 0 ]; then
  echo "RESULT: pin phase failed (rc=$rc), driver NOT loaded"
  exit $rc
fi

[ "$PIN_ONLY" = 1 ] && { echo "RESULT: pin-only done"; exit 0; }

# the boot-attached box can need settle time after the retrain, and the first
# probe occasionally races the link - retry, then bounce (remove/rescan) once
sleep 3
load_ok=0
for round in 1 2 3; do
  # --ignore-install: zz-egpu.conf no-ops nvidia/nvidia_uvm via install
  # lines (stops the udev nvidia-uvm dependency loop, EGPU.md); the only
  # legitimate loads are explicit, from this script.
  if modprobe --ignore-install nvidia && modprobe --ignore-install nvidia_uvm; then
    load_ok=1
    break
  fi
  echo "modprobe round $round failed; device state:"
  python3 - <<'PYEOF' || true
def rd(off, size):
    with open("/sys/bus/pci/devices/0000:03:00.0/config", "rb", buffering=0) as f:
        f.seek(off)
        return int.from_bytes(f.read(size), "little")
print(f"vendor={rd(0,2):04x} dev={rd(2,2):04x}")
PYEOF
  if [ $round -lt 3 ]; then
    echo "bouncing device (remove + rescan) ..."
    echo 1 > /sys/bus/pci/devices/0000:03:00.1/remove 2>/dev/null || true
    echo 1 > /sys/bus/pci/devices/0000:03:00.0/remove 2>/dev/null || true
    sleep 2
    echo 1 > /sys/bus/pci/rescan
    sleep 5
    for d in $CHAIN; do
      [ -e /sys/bus/pci/devices/0000:$d/power/control ] && echo on > /sys/bus/pci/devices/0000:$d/power/control
    done
    sleep 2
  fi
done

if [ $load_ok -ne 1 ]; then
  echo "RESULT: modprobe failed after retries - box likely wedged; power-cycle it"
  exit 1
fi
sleep 2
if lsmod | grep -qE '^nvidia_(drm|modeset)'; then
  echo "WARN: nvidia_drm/nvidia_modeset loaded - the desktop stack can see the GPU."
  echo "      Run setup-egpu-stage11.sh (install /bin/true block) and reboot."
fi
nvidia-smi -pm 1 || true
nvidia-smi --query-gpu=name,pstate,pcie.link.gen.current,pcie.link.width.current --format=csv || true
echo "RESULT: bring-up complete"
