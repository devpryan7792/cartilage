#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
BUILD_DIR="${REPO_ROOT}/build"
BASE_ROOTFS="/var/lib/cartilage/rootfs"

export PATH="${HOME}/.local/bin:${PATH}"

KERNEL=""
if [[ -f "${BASE_ROOTFS}/boot/vmlinuz-linux" ]]; then
    KERNEL="${BASE_ROOTFS}/boot/vmlinuz-linux"
elif [[ -f "/boot/vmlinuz-linux" ]]; then
    KERNEL="/boot/vmlinuz-linux"
fi

INITRD=""
if [[ -f "${BUILD_DIR}/initramfs-linux.img" ]]; then
    INITRD="${BUILD_DIR}/initramfs-linux.img"
elif [[ -f "${BASE_ROOTFS}/boot/initramfs-linux.img" ]]; then
    INITRD="${BASE_ROOTFS}/boot/initramfs-linux.img"
elif [[ -f "/boot/initramfs-linux.img" ]]; then
    INITRD="/boot/initramfs-linux.img"
fi

SYSTEMD_BOOT=""
if [[ -f "${BASE_ROOTFS}/usr/lib/systemd/boot/efi/systemd-bootx64.efi" ]]; then
    SYSTEMD_BOOT="${BASE_ROOTFS}/usr/lib/systemd/boot/efi/systemd-bootx64.efi"
elif [[ -f "/usr/lib/systemd/boot/efi/systemd-bootx64.efi" ]]; then
    SYSTEMD_BOOT="/usr/lib/systemd/boot/efi/systemd-bootx64.efi"
fi

DILLO_IMG="${BUILD_DIR}/cartridge_dillo_arch.img"
MOUSEPAD_IMG="${BUILD_DIR}/cartridge_mousepad_arch.img"
OUTPUT_COMBINED="${BUILD_DIR}/cartilage_combined.img"
TEMP_RAW="/tmp/cartilage_combined_$$.raw"
ESP_IMG="/tmp/cartilage_esp_$$.img"
DATA_IMG="/tmp/cartilage_data_$$.img"

BUILD_START=$SECONDS

echo "============================================================"
echo "Cartilage OS — Building Combined Multi-Cartridge USB Image"
echo "Kernel:      ${KERNEL}"
echo "Initrd:      ${INITRD}"
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

for tool in sfdisk mkfs.vfat mcopy mmd mkfs.ext4 dd; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "Error: Required tool '$tool' not found!" >&2
        exit 1
    fi
done

cleanup() {
    rm -f "${TEMP_RAW}" "${ESP_IMG}" "${DATA_IMG}"
}
trap cleanup EXIT INT TERM

# Step 1: Create ESP filesystem (128MB FAT32)
echo "==> Step 1: Formatting and populating ESP (128MB FAT32)..."
rm -f "${ESP_IMG}"
mkfs.vfat -F 32 -n CARTBOOT -C "${ESP_IMG}" 131072
mmd -i "${ESP_IMG}" ::EFI ::EFI/BOOT ::loader ::loader/entries
mcopy -i "${ESP_IMG}" "${SYSTEMD_BOOT}" ::EFI/BOOT/BOOTX64.EFI
mcopy -i "${ESP_IMG}" "${KERNEL}" ::vmlinuz-linux
mcopy -i "${ESP_IMG}" "${INITRD}" ::initramfs-linux.img

# Startup script
echo "\EFI\BOOT\BOOTX64.EFI" > /tmp/startup_$$.nsh
mcopy -i "${ESP_IMG}" /tmp/startup_$$.nsh ::startup.nsh
rm -f /tmp/startup_$$.nsh

# Loader config
cat << 'LOADER_EOF' > /tmp/loader_$$.conf
default dillo.conf
timeout 5
console-mode max
LOADER_EOF
mcopy -i "${ESP_IMG}" /tmp/loader_$$.conf ::loader/loader.conf
rm -f /tmp/loader_$$.conf

# Entry 1: Cartilage OS — Browser (Dillo)
cat << 'ENTRY1_EOF' > /tmp/dillo_$$.conf
title Cartilage OS — Browser (Dillo)
linux /vmlinuz-linux
initrd /initramfs-linux.img
options console=tty1 console=ttyS0 root=/dev/vda2 rootfstype=erofs init=/init
ENTRY1_EOF
mcopy -i "${ESP_IMG}" /tmp/dillo_$$.conf ::loader/entries/dillo.conf
rm -f /tmp/dillo_$$.conf

# Entry 2: Cartilage OS — Text Editor (Mousepad)
cat << 'ENTRY2_EOF' > /tmp/mousepad_$$.conf
title Cartilage OS — Text Editor (Mousepad)
linux /vmlinuz-linux
initrd /initramfs-linux.img
options console=tty1 console=ttyS0 root=/dev/vda3 rootfstype=erofs init=/init
ENTRY2_EOF
mcopy -i "${ESP_IMG}" /tmp/mousepad_$$.conf ::loader/entries/mousepad.conf
rm -f /tmp/mousepad_$$.conf

echo "==> ESP partition image prepared successfully."

# Step 2: Create CARTDATA partition (64MB ext4)
echo "==> Step 2: Formatting persistent data partition (64MB ext4)..."
rm -f "${DATA_IMG}"
mkfs.ext4 -F -L CARTDATA "${DATA_IMG}" 64M

# Step 3: Calculate partition sizes and layout GPT disk
echo "==> Step 3: Creating GPT partition table..."
ESP_SECTORS=262144 # 128MB
DILLO_BYTES=$(stat -c%s "${DILLO_IMG}")
MOUSEPAD_BYTES=$(stat -c%s "${MOUSEPAD_IMG}")
# Align each partition to 2048-sector (1MB) boundary
DILLO_SECTORS=$(( ((DILLO_BYTES + 1048575) / 1048576) * 2048 ))
MOUSEPAD_SECTORS=$(( ((MOUSEPAD_BYTES + 1048575) / 1048576) * 2048 ))
DATA_SECTORS=131072 # 64MB

TOTAL_SECTORS=$(( 2048 + ESP_SECTORS + DILLO_SECTORS + MOUSEPAD_SECTORS + DATA_SECTORS + 2048 ))
TOTAL_MB=$(( (TOTAL_SECTORS * 512 + 1048575) / 1048576 ))

rm -f "${TEMP_RAW}"
truncate -s "${TOTAL_MB}M" "${TEMP_RAW}"

sfdisk --no-reread "${TEMP_RAW}" << EOF
label: gpt
size=${ESP_SECTORS}, type=U, name="ESP"
size=${DILLO_SECTORS}, type=L, name="CART_DILLO"
size=${MOUSEPAD_SECTORS}, type=L, name="CART_MOUSEPAD"
size=${DATA_SECTORS}, type=L, name="CARTDATA"
EOF

# Parse exact partition start sectors
P1_START=$(sfdisk -d "${TEMP_RAW}" | grep "${TEMP_RAW}1 " | awk -F'start=' '{print $2}' | awk '{print $1}' | tr -d ',')
P2_START=$(sfdisk -d "${TEMP_RAW}" | grep "${TEMP_RAW}2 " | awk -F'start=' '{print $2}' | awk '{print $1}' | tr -d ',')
P3_START=$(sfdisk -d "${TEMP_RAW}" | grep "${TEMP_RAW}3 " | awk -F'start=' '{print $2}' | awk '{print $1}' | tr -d ',')
P4_START=$(sfdisk -d "${TEMP_RAW}" | grep "${TEMP_RAW}4 " | awk -F'start=' '{print $2}' | awk '{print $1}' | tr -d ',')

echo "==> Step 4: Writing partitions into disk image..."
echo "    P1 (ESP):      sector ${P1_START}"
dd if="${ESP_IMG}" of="${TEMP_RAW}" bs=512 seek="${P1_START}" conv=notrunc status=none
echo "    P2 (Dillo):    sector ${P2_START}"
dd if="${DILLO_IMG}" of="${TEMP_RAW}" bs=512 seek="${P2_START}" conv=notrunc status=none
echo "    P3 (Mousepad): sector ${P3_START}"
dd if="${MOUSEPAD_IMG}" of="${TEMP_RAW}" bs=512 seek="${P3_START}" conv=notrunc status=none
echo "    P4 (Cartdata): sector ${P4_START}"
dd if="${DATA_IMG}" of="${TEMP_RAW}" bs=512 seek="${P4_START}" conv=notrunc status=none

echo "==> Step 5: Finalizing image in build directory..."
mkdir -p "${BUILD_DIR}"
mv -f "${TEMP_RAW}" "${OUTPUT_COMBINED}"

BUILD_ELAPSED=$(( SECONDS - BUILD_START ))
echo "============================================================"
echo "Combined image successfully generated in ${BUILD_ELAPSED}s!"
echo "Image:  $(ls -lh "${OUTPUT_COMBINED}")"
echo "Layout: GPT 4 Partitions (ESP, Dillo, Mousepad, Cartdata)"
echo "============================================================"
