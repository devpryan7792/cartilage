#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
BUILD_DIR="${REPO_ROOT}/build"
BASE_ROOTFS="/var/lib/cartilage/rootfs"
KERNEL="${BASE_ROOTFS}/boot/vmlinuz-linux"
INITRD="${BASE_ROOTFS}/boot/initramfs-linux.img"
SYSTEMD_BOOT="${BASE_ROOTFS}/usr/lib/systemd/boot/efi/systemd-bootx64.efi"

DILLO_IMG="${BUILD_DIR}/cartridge_dillo_arch.img"
MOUSEPAD_IMG="${BUILD_DIR}/cartridge_mousepad_arch.img"
OUTPUT_COMBINED="${BUILD_DIR}/cartilage_combined.img"
TEMP_RAW="/var/lib/cartilage/cartilage_combined.raw"

BUILD_START=$SECONDS

echo "============================================================"
echo "Cartilage OS — Building Combined Multi-Cartridge USB Image"
echo "Kernel:      ${KERNEL}"
echo "Bootloader:  systemd-boot (UEFI)"
echo "Cartridge 1: ${DILLO_IMG}"
echo "Cartridge 2: ${MOUSEPAD_IMG}"
echo "Output:      ${OUTPUT_COMBINED}"
echo "============================================================"

# Verify prerequisites
for f in "${KERNEL}" "${INITRD}" "${SYSTEMD_BOOT}" "${DILLO_IMG}" "${MOUSEPAD_IMG}"; do
    if [[ ! -f "$f" ]]; then
        echo "Error: Required component '$f' not found!" >&2
        exit 1
    fi
done

# Calculate required partition sizes with safety margin
DILLO_MB=$(( ( $(stat -c%s "${DILLO_IMG}") + 1048575 ) / 1048576 + 32 ))
MOUSEPAD_MB=$(( ( $(stat -c%s "${MOUSEPAD_IMG}") + 1048575 ) / 1048576 + 32 ))
TOTAL_MB=$(( 128 + DILLO_MB + MOUSEPAD_MB + 64 + 64 ))

echo "==> Step 1: Allocating raw disk image (${TOTAL_MB}M) on native ext4..."
rm -f "${TEMP_RAW}" "${OUTPUT_COMBINED}"
truncate -s "${TOTAL_MB}M" "${TEMP_RAW}"

echo "==> Step 2: Formatting GPT partition table via sfdisk..."
sfdisk "${TEMP_RAW}" << EOF
label: gpt
size=128M, type=U, name="ESP"
size=${DILLO_MB}M, type=L, name="CART_DILLO"
size=${MOUSEPAD_MB}M, type=L, name="CART_MOUSEPAD"
size=64M,  type=L, name="CARTDATA"
EOF

echo "==> Step 3: Attaching loop device with partition scanning..."
LOOP_DEV=$(losetup -Pf --show "${TEMP_RAW}")
trap 'echo "Detaching loop device ${LOOP_DEV}..."; losetup -d "${LOOP_DEV}" 2>/dev/null || true' EXIT INT TERM

echo "Loop device attached: ${LOOP_DEV}"
ls -la ${LOOP_DEV}*

echo "==> Step 4: Formatting and populating Partition 1 (ESP, FAT32)..."
mkfs.vfat -F 32 -n CARTBOOT "${LOOP_DEV}p1"

ESP_MNT="/mnt/cartilage_esp_mnt"
mkdir -p "${ESP_MNT}"
mount "${LOOP_DEV}p1" "${ESP_MNT}"

mkdir -p "${ESP_MNT}/EFI/BOOT"
mkdir -p "${ESP_MNT}/loader/entries"

# Copy systemd-boot as default UEFI fallback loader
cp "${SYSTEMD_BOOT}" "${ESP_MNT}/EFI/BOOT/BOOTX64.EFI"

# Copy shared kernel and initramfs
cp "${KERNEL}" "${ESP_MNT}/vmlinuz-linux"
cp "${INITRD}" "${ESP_MNT}/initramfs-linux.img"

# Write systemd-boot loader configuration
cat << 'LOADER_EOF' > "${ESP_MNT}/loader/loader.conf"
default dillo.conf
timeout 3
console-mode max
LOADER_EOF

# Entry 1: Cartilage OS — Browser (Dillo)
cat << 'ENTRY1_EOF' > "${ESP_MNT}/loader/entries/dillo.conf"
title Cartilage OS — Browser (Dillo)
linux /vmlinuz-linux
initrd /initramfs-linux.img
options console=ttyS0 root=/dev/vda2 rootfstype=erofs init=/init cartilage_test=verify_app
ENTRY1_EOF

# Entry 2: Cartilage OS — Text Editor (Mousepad)
cat << 'ENTRY2_EOF' > "${ESP_MNT}/loader/entries/mousepad.conf"
title Cartilage OS — Text Editor (Mousepad)
linux /vmlinuz-linux
initrd /initramfs-linux.img
options console=ttyS0 root=/dev/vda3 rootfstype=erofs init=/init cartilage_test=verify_app
ENTRY2_EOF

sync
umount "${ESP_MNT}"
rmdir "${ESP_MNT}"
echo "Partition 1 (ESP) successfully populated with systemd-boot and entries."

echo "==> Step 5: Writing Partition 2 (Dillo Cartridge EROFS)..."
dd if="${DILLO_IMG}" of="${LOOP_DEV}p2" bs=4M status=none conv=fsync

echo "==> Step 6: Writing Partition 3 (Mousepad Cartridge EROFS)..."
dd if="${MOUSEPAD_IMG}" of="${LOOP_DEV}p3" bs=4M status=none conv=fsync

echo "==> Step 7: Formatting Partition 4 (Persistent Data, ext4)..."
mkfs.ext4 -F -L CARTDATA "${LOOP_DEV}p4"

# Detach loop device
losetup -d "${LOOP_DEV}"
trap - EXIT INT TERM

echo "==> Step 8: Finalizing combined disk image and creating symlink in build directory..."
COMBINED_STORAGE="/var/lib/cartilage/cartilage_combined.img"
mv -f "${TEMP_RAW}" "${COMBINED_STORAGE}"
ln -sf "${COMBINED_STORAGE}" "${OUTPUT_COMBINED}"

BUILD_ELAPSED=$(( SECONDS - BUILD_START ))
echo "============================================================"
echo "Combined image successfully generated in ${BUILD_ELAPSED}s!"
echo "Image:  $(ls -lh "${OUTPUT_COMBINED}")"
echo "Layout: GPT 4 Partitions (ESP, Dillo, Mousepad, Cartdata)"
echo "============================================================"
