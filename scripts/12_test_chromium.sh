#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
BUILD_DIR="${REPO_ROOT}/build"
BUILDER="${REPO_ROOT}/build_cartridge.sh"
CARTRIDGE_IMG="${BUILD_DIR}/cartridge_chromium_arch.img"
KERNEL="/var/lib/cartilage/rootfs/boot/vmlinuz-linux"
INITRD="/var/lib/cartilage/rootfs/boot/initramfs-linux.img"
LOG_FILE="${BUILD_DIR}/12_test_chromium.log"

TOTAL_START=$SECONDS

echo "============================================================"
echo "Cartilage OS — Chromium Kiosk Verification Suite (Task 13)"
echo "Target Cartridge: ${CARTRIDGE_IMG}"
echo "Kernel:           ${KERNEL}"
echo "============================================================"

# Step 1: Ensure cartridge is built with Chromium and Wayland Ozone
echo "==> Step 1: Building Chromium cartridge..."
T_BUILD_START=$SECONDS
"${BUILDER}" --app chromium --runtime arch
T_BUILD_ELAPSED=$(( SECONDS - T_BUILD_START ))
echo "==> Step 1 completed in ${T_BUILD_ELAPSED}s."

# Step 2: Boot QEMU with virtio-gpu, virtio-net, intel-hda and run test hook
echo ""
echo "============================================================"
echo "==> Step 2: Booting QEMU with Chromium Wayland Kiosk runtime..."
echo "============================================================"
mkdir -p "${BUILD_DIR}"
T_QEMU_START=$SECONDS

KVM_FLAGS=""
if [[ -c /dev/kvm ]]; then
    KVM_FLAGS="-enable-kvm -cpu host"
fi

timeout 120s qemu-system-x86_64 \
  ${KVM_FLAGS} \
  -kernel "${KERNEL}" \
  -initrd "${INITRD}" \
  -drive file="${CARTRIDGE_IMG}",format=raw,if=virtio \
  -device virtio-gpu-pci \
  -netdev user,id=net0 \
  -device virtio-net-pci,netdev=net0 \
  -audiodev id=snd0,driver=none \
  -device intel-hda \
  -device hda-duplex,audiodev=snd0 \
  -append "console=ttyS0 root=/dev/vda rootfstype=erofs init=/init cartilage_test_chromium=1" \
  -display none \
  -serial stdio \
  -m 2048M 2>&1 | tee "${LOG_FILE}" || true

T_QEMU_ELAPSED=$(( SECONDS - T_QEMU_START ))
echo "==> QEMU execution finished in ${T_QEMU_ELAPSED}s."

# Step 3: Assert verification results
echo ""
echo "============================================================"
echo "Cartilage OS — Task 13 Verification Assertions"
echo "============================================================"
if grep -q "\[PASS\] Chromium Ozone Wayland verification successful" "${LOG_FILE}"; then
    TOTAL_ELAPSED=$(( SECONDS - TOTAL_START ))
    echo "  [PASS] Cartridge Build:                   ${T_BUILD_ELAPSED}s"
    echo "  [PASS] QEMU Chromium Test:                ${T_QEMU_ELAPSED}s"
    echo "  TOTAL EXECUTION TIME:                     ${TOTAL_ELAPSED}s"
    echo "============================================================"
    echo "==> [PASS] Task 13 Checkpoint Passed: Modern Web Kiosk Runtime (Chromium) verified!"
    exit 0
else
    echo "==> [FAIL] Expected '[PASS] Chromium Ozone Wayland verification successful' not found in test log." >&2
    echo "--- Log output ---" >&2
    cat "${LOG_FILE}" >&2
    exit 1
fi
