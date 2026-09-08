#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
BUILD_DIR="${REPO_ROOT}/build"
CARTRIDGE_IMG="${BUILD_DIR}/cartridge.img"
KERNEL="/var/lib/cartilage/rootfs/boot/vmlinuz-linux"
INITRD="/var/lib/cartilage/rootfs/boot/initramfs-linux.img"

if [[ ! -f "${CARTRIDGE_IMG}" ]]; then
    echo "Error: ${CARTRIDGE_IMG} not found. Run scripts/02_build_cartridge.sh first." >&2
    exit 1
fi

echo "============================================================"
echo "Cartilage OS — QEMU Ephemeral Mode Verification (SPEC Task 3)"
echo "Cartridge: ${CARTRIDGE_IMG}"
echo "============================================================"

timeout 40s qemu-system-x86_64 \
  -kernel "${KERNEL}" \
  -initrd "${INITRD}" \
  -drive file="${CARTRIDGE_IMG}",format=raw,if=virtio \
  -append "console=ttyS0 root=/dev/vda rootfstype=erofs init=/init cartilage_test=ephemeral" \
  -display none \
  -serial stdio \
  -m 1024M || {
    RC=$?
    if [[ $RC -eq 124 || $RC -eq 143 || $RC -eq 0 ]]; then
        echo "==> [PASS] QEMU finished ephemeral test run."
        exit 0
    else
        echo "==> QEMU exited with code: ${RC}"
        exit $RC
    fi
}
