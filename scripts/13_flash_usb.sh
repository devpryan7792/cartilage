#!/usr/bin/env bash
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    exec sudo bash "$0" "$@"
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
BUILD_DIR="${REPO_ROOT}/build"
BASE_ROOTFS="/var/lib/cartilage/rootfs"
KERNEL="${BASE_ROOTFS}/boot/vmlinuz-linux"
INITRD="${BASE_ROOTFS}/boot/initramfs-linux.img"
SYSTEMD_BOOT="${BASE_ROOTFS}/usr/lib/systemd/boot/efi/systemd-bootx64.efi"

DEFAULT_DILLO_IMG="${BUILD_DIR}/cartridge_dillo_arch.img"
if [[ ! -f "${DEFAULT_DILLO_IMG}" && -f "${BUILD_DIR}/cartridge_dillo.img" ]]; then
    DEFAULT_DILLO_IMG="${BUILD_DIR}/cartridge_dillo.img"
fi

DEFAULT_MOUSEPAD_IMG="${BUILD_DIR}/cartridge_mousepad_arch.img"
if [[ ! -f "${DEFAULT_MOUSEPAD_IMG}" && -f "${BUILD_DIR}/cartridge_mousepad.img" ]]; then
    DEFAULT_MOUSEPAD_IMG="${BUILD_DIR}/cartridge_mousepad.img"
fi


TARGET_DEV=""
FORCE_INTERNAL=0
ASSUME_YES=0
CART1_IMG="${DEFAULT_DILLO_IMG}"
CART2_IMG="${DEFAULT_MOUSEPAD_IMG}"


usage() {
    echo "Usage: $0 <block-device> [options]"
    echo ""
    echo "Arguments:"
    echo "  <block-device>        Target drive (e.g. /dev/sdb, /dev/sdc, /dev/loop0)"
    echo ""
    echo "Options:"
    echo "  --force-internal      Allow flashing fixed internal drives (SATA/NVMe)"
    echo "  -y, --yes             Non-interactive mode (assume yes to prompts)"
    echo "  --cart1 <path>        Path to Cartridge 1 image (default: build/cartridge_dillo.img)"
    echo "  --cart2 <path>        Path to Cartridge 2 image (default: build/cartridge_mousepad.img)"
    echo "  -h, --help            Show this help message"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --force-internal)
            FORCE_INTERNAL=1
            shift
            ;;
        -y|--yes)
            ASSUME_YES=1
            shift
            ;;
        --cart1)
            CART1_IMG="$2"
            shift 2
            ;;
        --cart2)
            CART2_IMG="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        -*)
            echo "Error: Unknown option '$1'" >&2
            usage
            exit 1
            ;;
        *)
            if [[ -z "${TARGET_DEV}" ]]; then
                TARGET_DEV="$1"
                shift
            else
                echo "Error: Unexpected argument '$1'" >&2
                usage
                exit 1
            fi
            ;;
    esac
done

if [[ -z "${TARGET_DEV}" ]]; then
    echo "Error: Target block device is required." >&2
    usage
    exit 1
fi

if [[ ! -b "${TARGET_DEV}" ]]; then
    echo "Error: '${TARGET_DEV}' is not a valid block device." >&2
    exit 1
fi

# Verify required Cartilage OS assets
for f in "${KERNEL}" "${INITRD}" "${SYSTEMD_BOOT}" "${CART1_IMG}" "${CART2_IMG}"; do
    if [[ ! -f "$f" ]]; then
        echo "Error: Required asset '$f' not found!" >&2
        exit 1
    fi
done

# --- Step 1: Block Device Safety Inspection ---
IS_RM=$(lsblk -n -d -o RM "${TARGET_DEV}" 2>/dev/null | tr -d ' ' || echo "0")
IS_RO=$(lsblk -n -d -o RO "${TARGET_DEV}" 2>/dev/null | tr -d ' ' || echo "0")
TRAN=$(lsblk -n -d -o TRAN "${TARGET_DEV}" 2>/dev/null | tr -d ' ' || echo "")
DEV_TYPE=$(lsblk -n -d -o TYPE "${TARGET_DEV}" 2>/dev/null | tr -d ' ' || echo "")
MODEL=$(lsblk -n -d -o MODEL "${TARGET_DEV}" 2>/dev/null || echo "Unknown")
SIZE_HUMAN=$(lsblk -n -d -o SIZE "${TARGET_DEV}" 2>/dev/null | tr -d ' ' || echo "Unknown")

if [[ "${IS_RO}" == "1" ]]; then
    echo "Error: Block device ${TARGET_DEV} is read-only!" >&2
    exit 1
fi

# Guard against fixed internal drives (SATA / NVMe / Non-removable)
IS_INTERNAL=0
if [[ "${DEV_TYPE}" != "loop" && ( "${TRAN}" == "sata" || "${TRAN}" == "nvme" || "${TRAN}" == "ata" || "${IS_RM}" == "0" ) ]]; then
    IS_INTERNAL=1
fi

if [[ ${IS_INTERNAL} -eq 1 && ${FORCE_INTERNAL} -ne 1 ]]; then
    echo "============================================================" >&2
    echo "[SECURITY ALERT] Safety Guard Triggered!" >&2
    echo "Target device ${TARGET_DEV} (${MODEL}, ${SIZE_HUMAN}) is detected as a fixed internal disk (TRAN=${TRAN}, RM=${IS_RM})." >&2
    echo "Cartilage OS USB Flasher refuses to overwrite fixed internal storage." >&2
    echo "To override this protection for bare-metal appliance installation on internal SSD/NVMe," >&2
    echo "you must explicitly pass the --force-internal flag:" >&2
    echo "  $0 ${TARGET_DEV} --force-internal" >&2
    echo "============================================================" >&2
    exit 1
fi

DEV_SIZE_BYTES=$(blockdev --getsize64 "${TARGET_DEV}" 2>/dev/null || echo 0)
if [[ ${DEV_SIZE_BYTES} -lt 1200000000 ]]; then
    echo "Error: Target device ${TARGET_DEV} is smaller than 1.2GB (${DEV_SIZE_BYTES} bytes)." >&2
    exit 1
fi

echo "============================================================"
echo "Cartilage OS — Bare-Metal USB Appliance Flasher"
echo "Target Device: ${TARGET_DEV} (${MODEL}, ${SIZE_HUMAN})"
echo "Transport:     ${TRAN:-unknown}"
echo "Removable:     ${IS_RM}"
echo "Cartridge 1:   ${CART1_IMG}"
echo "Cartridge 2:   ${CART2_IMG}"
echo "============================================================"

if [[ ${ASSUME_YES} -ne 1 ]]; then
    echo "WARNING: ALL EXISTING DATA ON ${TARGET_DEV} WILL BE PERMANENTLY ERASED!"
    read -r -p "Type 'YES' to continue: " CONFIRM
    if [[ "${CONFIRM}" != "YES" ]]; then
        echo "Flashing cancelled by user."
        exit 1
    fi
fi

# --- Step 2: Unmount any active partitions on target ---
echo "==> Step 2: Unmounting existing partitions on ${TARGET_DEV}..."
for part in $(lsblk -n -l -o PATH "${TARGET_DEV}" 2>/dev/null || true); do
    if [[ "${part}" != "${TARGET_DEV}" ]]; then
        umount "${part}" 2>/dev/null || true
    fi
done

# Wipe old partition signatures
wipefs -a "${TARGET_DEV}" 2>/dev/null || true

# Dynamically calculate required partition sizes with 32MB safety margin
CART1_MB=$(( ( $(stat -c%s "${CART1_IMG}") + 1048575 ) / 1048576 + 32 ))
CART2_MB=$(( ( $(stat -c%s "${CART2_IMG}") + 1048575 ) / 1048576 + 32 ))

# --- Step 3: Write GPT Partition Table ---
echo "==> Step 3: Writing strict GPT partition layout via sfdisk (Cart1: ${CART1_MB}M, Cart2: ${CART2_MB}M)..."
sfdisk "${TARGET_DEV}" << EOF
label: gpt
size=128M, type=U, name="ESP"
size=${CART1_MB}M, type=L, name="CART_DILLO"
size=${CART2_MB}M, type=L, name="CART_MOUSEPAD"
name="CARTDATA", type=L
EOF


partprobe "${TARGET_DEV}" 2>/dev/null || true
udevadm settle --timeout=5 2>/dev/null || true
sleep 1

# Detect partition naming convention
if [[ "${TARGET_DEV}" =~ [0-9]$ ]]; then
    P1="${TARGET_DEV}p1"
    P2="${TARGET_DEV}p2"
    P3="${TARGET_DEV}p3"
    P4="${TARGET_DEV}p4"
else
    P1="${TARGET_DEV}1"
    P2="${TARGET_DEV}2"
    P3="${TARGET_DEV}3"
    P4="${TARGET_DEV}4"
fi

for p in "${P1}" "${P2}" "${P3}" "${P4}"; do
    if [[ ! -b "$p" ]]; then
        echo "Error: Expected partition device node '$p' not found after partitioning!" >&2
        exit 1
    fi
done

# --- Step 4: Populate Partition 1 (ESP, FAT32) ---
echo "==> Step 4: Formatting and populating Partition 1 (ESP, FAT32)..."
mkfs.vfat -F 32 -n CARTBOOT "${P1}"

ESP_MNT=$(mktemp -d /tmp/cartilage_esp_XXXXXX)
trap 'umount "${ESP_MNT}" 2>/dev/null || true; rmdir "${ESP_MNT}" 2>/dev/null || true' EXIT INT TERM

mount "${P1}" "${ESP_MNT}"
mkdir -p "${ESP_MNT}/EFI/BOOT" "${ESP_MNT}/loader/entries"

# Install systemd-boot as UEFI fallback loader
cp "${SYSTEMD_BOOT}" "${ESP_MNT}/EFI/BOOT/BOOTX64.EFI"

# Copy kernel and initramfs
cp "${KERNEL}" "${ESP_MNT}/vmlinuz-linux"
cp "${INITRD}" "${ESP_MNT}/initramfs-linux.img"

# Write systemd-boot configuration
cat << 'LOADER_EOF' > "${ESP_MNT}/loader/loader.conf"
default dillo.conf
timeout 3
console-mode max
LOADER_EOF

# Write Entry 1: Dillo with PARTLABEL routing
cat << 'ENTRY1_EOF' > "${ESP_MNT}/loader/entries/dillo.conf"
title Cartilage OS — Browser (Dillo)
linux /vmlinuz-linux
initrd /initramfs-linux.img
options console=ttyS0 root=PARTLABEL=CART_DILLO rootfstype=erofs init=/init cartilage_test=verify_app
ENTRY1_EOF

# Write Entry 2: Mousepad with PARTLABEL routing
cat << 'ENTRY2_EOF' > "${ESP_MNT}/loader/entries/mousepad.conf"
title Cartilage OS — Text Editor (Mousepad)
linux /vmlinuz-linux
initrd /initramfs-linux.img
options console=ttyS0 root=PARTLABEL=CART_MOUSEPAD rootfstype=erofs init=/init cartilage_test=verify_app
ENTRY2_EOF

sync
umount "${ESP_MNT}"
rmdir "${ESP_MNT}"
trap - EXIT INT TERM

# --- Step 5: Write Cartridge 1 (Raw EROFS) ---
echo "==> Step 5: Writing Cartridge 1 (${CART1_IMG}) to ${P2} (PARTLABEL=CART_DILLO)..."
dd if="${CART1_IMG}" of="${P2}" bs=4M status=none conv=fsync

# --- Step 6: Write Cartridge 2 (Raw EROFS) ---
echo "==> Step 6: Writing Cartridge 2 (${CART2_IMG}) to ${P3} (PARTLABEL=CART_MOUSEPAD)..."
dd if="${CART2_IMG}" of="${P3}" bs=4M status=none conv=fsync

# --- Step 7: Format Partition 4 (CARTDATA, ext4) ---
echo "==> Step 7: Formatting Partition 4 (${P4}) as ext4 (LABEL=CARTDATA)..."
mkfs.ext4 -F -L CARTDATA "${P4}"

echo "============================================================"
echo "Cartilage OS Appliance successfully flashed to ${TARGET_DEV}!"
echo "Partition Layout:"
lsblk -o NAME,SIZE,TYPE,PARTLABEL,FSTYPE,LABEL "${TARGET_DEV}"
echo "============================================================"
exit 0
