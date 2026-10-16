#!/usr/bin/env bash
# Stage 6: patch the NVIDIA 615.71.09 DKMS source for the kernel 7.3
# dmem_cgroup API change, rebuild for 7.3.0-9 (and 7.0.0-38), and clear the
# half-configured kernel headers package.
#   - The only 7.3 breakage: dmem_cgroup_register_region(size, name) became
#     dmem_cgroup_register_region(&init, "%s", name) with struct dmem_cgroup_init.
#   - virtualbox-dkms cannot build on 7.3 (vbox lags kernels); it is purged so
#     dkms autoinstall / dpkg --configure can succeed. Reinstall it later if
#     needed (it keeps working on 7.0).
# Idempotent: safe to re-run.
set -euo pipefail

SRC=/usr/src/nvidia-615.71.09/nvidia/os-interface.c

echo "== 1/4 patch os-interface.c =="
if grep -q 'struct dmem_cgroup_init init' "$SRC"; then
  echo "already patched, skipping"
else
python3 - <<'PYEOF'
path = "/usr/src/nvidia-615.71.09/nvidia/os-interface.c"
old = "    void *region = dmem_cgroup_register_region(size, name);"
new = """#if LINUX_VERSION_CODE >= KERNEL_VERSION(7, 3, 0)
    struct dmem_cgroup_init init = { 0 };
    void *region;
    init.size = size;
    region = dmem_cgroup_register_region(&init, "%s", name);
#else
    void *region = dmem_cgroup_register_region(size, name);
#endif"""
s = open(path).read()
assert s.count(old) == 1, "expected exactly one call site"
open(path, "w").write(s.replace(old, new))
print("patched")
PYEOF
fi

echo "== 2/4 purge virtualbox-dkms (cannot build on 7.3) =="
dpkg -l virtualbox-dkms 2>/dev/null | grep -q '^ii' && apt purge -y virtualbox-dkms || echo "not installed"

echo "== 3/4 rebuild nvidia for 7.3.0-9 and 7.0.0-38 =="
dkms build nvidia/615.71.09 -k 7.3.0-9-generic
dkms install nvidia/615.71.09 -k 7.3.0-9-generic
dkms build nvidia/615.71.09 -k 7.0.0-38-generic
dkms install nvidia/615.71.09 -k 7.0.0-38-generic

echo "== 4/4 finish configuring packages =="
dpkg --configure -a

echo
echo "== status =="
dkms status | grep nvidia
echo
echo "Done. Reboot (GRUB defaults to 7.3.0-9), then:"
echo "  nvidia-smi | head -20"
echo "  journalctl -k -b 0 --no-pager | grep -iE 'nvidia|fallen' | tail -15"
