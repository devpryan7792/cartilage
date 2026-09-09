#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
BUILD_DIR="${REPO_ROOT}/build"
BUILDER="${REPO_ROOT}/build_cartridge.sh"
CARTRIDGE_IMG="${BUILD_DIR}/cartridge_mousepad_alpine.img"
KERNEL="/var/lib/cartilage/rootfs/boot/vmlinuz-linux"
INITRD="/var/lib/cartilage/rootfs/boot/initramfs-linux.img"
LOG_FILE="${BUILD_DIR}/14_test_alpine_cartridge.log"

TOTAL_START=$SECONDS

echo "============================================================"
echo "Cartilage OS — Alpine Lightweight Runtime Verification (Task 15)"
echo "Target Cartridge: ${CARTRIDGE_IMG}"
echo "Kernel:           ${KERNEL}"
echo "============================================================"

# Step 1: Build Alpine Cartridge with Mousepad
echo "==> Step 1: Building Alpine cartridge (mousepad)..."
T_BUILD_START=$SECONDS
"${BUILDER}" --app mousepad --runtime alpine --output "${CARTRIDGE_IMG}"
T_BUILD_ELAPSED=$(( SECONDS - T_BUILD_START ))
echo "==> Step 1 completed in ${T_BUILD_ELAPSED}s."

# Step 2: Assert Image Size < 50MB (52,428,800 bytes)
echo ""
echo "============================================================"
echo "==> Step 2: Verifying Alpine cartridge size constraint (< 50MB)..."
echo "============================================================"
if [[ ! -f "${CARTRIDGE_IMG}" ]]; then
    echo "Error: Output cartridge image not found at ${CARTRIDGE_IMG}!" >&2
    exit 1
fi

IMG_SIZE=$(stat -c %s "${CARTRIDGE_IMG}")
HUMAN_SIZE=$(ls -lh "${CARTRIDGE_IMG}" | awk '{print $5}')
echo "Alpine Cartridge File Size: ${IMG_SIZE} bytes (${HUMAN_SIZE})"

MAX_SIZE=52428800 # 50MB
if [[ ${IMG_SIZE} -ge ${MAX_SIZE} ]]; then
    echo "==> [FAIL] Cartridge size ${IMG_SIZE} bytes exceeds 50MB threshold (${MAX_SIZE} bytes)!" >&2
    exit 1
fi
echo "==> [PASS] Size threshold met: ${IMG_SIZE} bytes < ${MAX_SIZE} bytes."

# Step 3: Boot QEMU with virtio-gpu and verify app verification hook
echo ""
echo "============================================================"
echo "==> Step 3: Booting QEMU with Alpine Cartridge..."
echo "============================================================"
mkdir -p "${BUILD_DIR}"
T_QEMU_START=$SECONDS

KVM_FLAGS=""
if [[ -c /dev/kvm ]]; then
    KVM_FLAGS="-enable-kvm -cpu host"
fi

timeout 60s qemu-system-x86_64 \
  ${KVM_FLAGS} \
  -kernel "${KERNEL}" \
  -initrd "${INITRD}" \
  -drive file="${CARTRIDGE_IMG}",format=raw,if=virtio \
  -device virtio-gpu-pci \
  -append "console=ttyS0 root=/dev/vda rootfstype=erofs init=/init cartilage_test=verify_app" \
  -display none \
  -serial stdio \
  -m 1024M 2>&1 | tee "${LOG_FILE}" || true

T_QEMU_ELAPSED=$(( SECONDS - T_QEMU_START ))
echo "==> QEMU execution finished in ${T_QEMU_ELAPSED}s."

# Step 4: Assert verification results
echo ""
echo "============================================================"
echo "Cartilage OS — Task 15 Verification Assertions"
echo "============================================================"
if grep -q "\[TEST\] CARTRIDGE VERIFICATION FOR mousepad SUCCEEDED" "${LOG_FILE}"; then
    TOTAL_ELAPSED=$(( SECONDS - TOTAL_START ))
    echo "  [PASS] Alpine Cartridge Build:            ${T_BUILD_ELAPSED}s"
    echo "  [PASS] Cartridge Image Size:              ${IMG_SIZE} bytes (${HUMAN_SIZE}) < 50MB"
    echo "  [PASS] QEMU Alpine Boot & App Verify:     ${T_QEMU_ELAPSED}s"
    echo "  TOTAL EXECUTION TIME:                     ${TOTAL_ELAPSED}s"
    echo "============================================================"
    echo "==> [PASS] Task 15 Checkpoint Passed: Alpine Lightweight Runtime verified successfully!"
    exit 0
else
    echo "==> [FAIL] Expected '[TEST] CARTRIDGE VERIFICATION FOR mousepad SUCCEEDED' not found in test log." >&2
    echo "--- Log output ---" >&2
    cat "${LOG_FILE}" >&2
    exit 1
fi
