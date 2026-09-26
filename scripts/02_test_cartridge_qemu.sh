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
echo "Cartilage OS — QEMU Cartridge Boot Verification (Task 2)"
echo "Cartridge: ${CARTRIDGE_IMG}"
echo "============================================================"

KVM_FLAGS=""
if [[ -c /dev/kvm ]]; then
    KVM_FLAGS="-enable-kvm -cpu host"
fi

LOG_FILE="${BUILD_DIR}/02_test_cartridge_qemu.log"

timeout 30s qemu-system-x86_64 \
  ${KVM_FLAGS} \
  -kernel "${KERNEL}" \
  -initrd "${INITRD}" \
  -drive file="${CARTRIDGE_IMG}",format=raw,if=virtio \
  -append "console=ttyS0 root=/dev/vda rootfstype=erofs init=/init" \
  -vga virtio \
  -display none \
  -serial stdio \
  -m 1024M 2>&1 | tee "${LOG_FILE}" || true

if grep -q "Running stage: 50-launch.sh" "${LOG_FILE}"; then
    echo ""
    echo "==> [PASS] Cartridge booted successfully and reached launch stage."
    exit 0
else
    echo "==> [FAIL] Cartridge did not boot properly."
    exit 1
fi
