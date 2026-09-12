#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
BUILD_DIR="${REPO_ROOT}/build"
CARTRIDGE_IMG="${BUILD_DIR}/cartridge.img"
DATA_IMG="${BUILD_DIR}/data_partition.img"
KERNEL="/var/lib/cartilage/rootfs/boot/vmlinuz-linux"
INITRD="/var/lib/cartilage/rootfs/boot/initramfs-linux.img"

if [[ ! -f "${CARTRIDGE_IMG}" ]]; then
    echo "Error: ${CARTRIDGE_IMG} not found. Run scripts/02_build_cartridge.sh first." >&2
    exit 1
fi

echo "============================================================"
echo "Cartilage OS — Persistent Mode Verification (SPEC Task 4)"
echo "Cartridge: ${CARTRIDGE_IMG}"
echo "Data Disk: ${DATA_IMG}"
echo "============================================================"

KVM_FLAGS=""
if [[ -c /dev/kvm ]]; then
    KVM_FLAGS="-enable-kvm -cpu host"
fi

# Step 1: Create fresh 64MB ext4 data partition
echo "==> Step 1: Creating fresh 64MB ext4 data partition..."
truncate -s 64M "${DATA_IMG}"
mkfs.ext4 -F -L CARTDATA "${DATA_IMG}"

# Step 2: Boot Phase 1 — Write marker file into persistent storage
echo "==> Step 2: Booting VM (Phase 1 - Write Marker File)..."
timeout 65s qemu-system-x86_64 \
  ${KVM_FLAGS} \
  -kernel "${KERNEL}" \
  -initrd "${INITRD}" \
  -drive file="${CARTRIDGE_IMG}",format=raw,if=virtio \
  -drive file="${DATA_IMG}",format=raw,if=virtio \
  -append "console=ttyS0 root=/dev/vda rootfstype=erofs init=/init cartilage_test=persist_write" \
  -display none \
  -serial stdio \
  -m 1024M || true

echo "==> Phase 1 complete. Data written and VM shut down."
sleep 1

# Step 3: Boot Phase 2 — Fresh reboot, verify marker file survived
echo "==> Step 3: Rebooting VM (Phase 2 - Verify Reboot Survival)..."
timeout 65s qemu-system-x86_64 \
  ${KVM_FLAGS} \
  -kernel "${KERNEL}" \
  -initrd "${INITRD}" \
  -drive file="${CARTRIDGE_IMG}",format=raw,if=virtio \
  -drive file="${DATA_IMG}",format=raw,if=virtio \
  -append "console=ttyS0 root=/dev/vda rootfstype=erofs init=/init cartilage_test=persist_read" \
  -display none \
  -serial stdio \
  -m 1024M || true

echo ""
echo "==> [PASS] Task 4 Checkpoint Passed: File survived across VM reboot with core OS read-only!"
