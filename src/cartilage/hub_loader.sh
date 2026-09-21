#!/usr/bin/ash
# ==============================================================================
# Cartilage OS — Dynamic Hub Bootstrap Loader & Provisioner
# Scans exFAT CARTRIDGES partition, renders TTY text boot menu,
# loop-mounts chosen cartridge, attaches sparse ext4 data persistence,
# and hands off execution to the appliance /init.
# ==============================================================================

export PATH="/usr/bin:/bin:/usr/sbin:/sbin"

# ------------------------------------------------------------------------------
# Mode A: Automated Hub Provisioning / Population Mode
# ------------------------------------------------------------------------------
if grep -q "cartilage_populate=1" /proc/cmdline; then
    echo "[hub-populator] Initializing Dynamic Hub exFAT payload..."
    mkdir -p /proc /sys /dev /run /host /mnt/target
    mountpoint -q /proc || mount -t proc proc /proc
    mountpoint -q /sys || mount -t sysfs sys /sys
    mountpoint -q /dev || mount -t devtmpfs devtmpfs /dev

    modprobe exfat 2>/dev/null || true
    modprobe 9p 2>/dev/null || true
    modprobe 9pnet_virtio 2>/dev/null || true

    echo "[hub-populator] Mounting host filesystem..."
    mount -t 9p -o trans=virtio hosthub /host 2>/dev/null || \
    mount -t 9p -o trans=virtio,version=9p2000.L hosthub /host 2>/dev/null || true

    echo "[hub-populator] Mounting target exFAT device (/dev/vda)..."
    mount -t exfat /dev/vda /mnt/target 2>/dev/null || mount /dev/vda /mnt/target

    mkdir -p /mnt/target/cartridges /mnt/target/data
    if [ -d /host/cartridges ]; then
        echo "[hub-populator] Copying cartridges from host staging..."
        cp -a /host/cartridges/* /mnt/target/cartridges/ 2>/dev/null || true
    fi
    if [ -d /host/data ]; then
        echo "[hub-populator] Copying persistent data structures..."
        cp -a /host/data/* /mnt/target/data/ 2>/dev/null || true
    fi

    echo "[hub-populator] Payload sync complete. Powering off..."
    sync
    umount /mnt/target 2>/dev/null || true
    umount /host 2>/dev/null || true
    poweroff -f
fi

# ------------------------------------------------------------------------------
# Mode B: Runtime Hub Bootstrap & Interactive TTY Selection
# ------------------------------------------------------------------------------
TARGET_SYSROOT="${1:-/sysroot}"

# If running standalone (not via mkinitcpio mount_handler), set up virtual mounts
if [ -z "${CALLED_AS_HOOK:-}" ]; then
    mkdir -p /proc /sys /dev /run /sysroot
    mountpoint -q /proc || mount -t proc proc /proc
    mountpoint -q /sys || mount -t sysfs sys /sys
    mountpoint -q /dev || mount -t devtmpfs devtmpfs /dev
    mountpoint -q /run || mount -t tmpfs -o mode=0755,nodev,nosuid tmpfs /run
fi

echo "[hub-loader] Probing block devices for CARTRIDGES partition..."

# Give kernel and udev up to 5 seconds to settle and discover USB/virtio drives
CARTRIDGES_DEV=""
for i in $(seq 1 50); do
    # 1. Try blkid by label
    if command -v blkid >/dev/null 2>&1; then
        CARTRIDGES_DEV=$(blkid -L CARTRIDGES 2>/dev/null || true)
        if [ -n "$CARTRIDGES_DEV" ]; then
            break
        fi
    fi

    # 2. Check /dev/disk/by-label/CARTRIDGES
    if [ -b "/dev/disk/by-label/CARTRIDGES" ]; then
        CARTRIDGES_DEV="/dev/disk/by-label/CARTRIDGES"
        break
    fi

    # 3. Direct probe /dev/vd* /dev/sd* /dev/nvme*
    for d in /dev/vd*[0-9] /dev/sd*[0-9] /dev/nvme*n*p* /dev/vd* /dev/sd*; do
        if [ -b "$d" ]; then
            lbl=$(blkid -s LABEL -o value "$d" 2>/dev/null || true)
            if [ "$lbl" = "CARTRIDGES" ]; then
                CARTRIDGES_DEV="$d"
                break 2
            fi
        fi
    done

    sleep 0.1
done

if [ -z "$CARTRIDGES_DEV" ]; then
    echo "[hub-loader] ERROR: Could not locate partition labeled 'CARTRIDGES'!" >&2
    echo "[hub-loader] Available block devices:" >&2
    blkid 2>/dev/null || ls -l /dev/sd* /dev/vd* 2>/dev/null || true
    echo "[hub-loader] Dropping to emergency recovery shell..." >&2
    exec sh
fi

echo "[hub-loader] Found CARTRIDGES partition: ${CARTRIDGES_DEV}"

# Mount exFAT partition to /run/hub (read-write to allow updating sparse data.img)
HUB_MNT="/run/hub"
mkdir -p "$HUB_MNT"
modprobe exfat 2>/dev/null || true

if ! mount -t exfat "$CARTRIDGES_DEV" "$HUB_MNT" 2>/dev/null && \
   ! mount "$CARTRIDGES_DEV" "$HUB_MNT" 2>/dev/null; then
    echo "[hub-loader] ERROR: Failed to mount ${CARTRIDGES_DEV} as exFAT!" >&2
    exec sh
fi

# Discover cartridges in /run/hub/cartridges/
CARTRIDGE_DIR="${HUB_MNT}/cartridges"
if [ ! -d "$CARTRIDGE_DIR" ]; then
    echo "[hub-loader] ERROR: Cartridge directory ${CARTRIDGE_DIR} not found!" >&2
    exec sh
fi

# Collect list of images
set -- "$CARTRIDGE_DIR"/*.img
if [ ! -f "$1" ]; then
    echo "[hub-loader] ERROR: No cartridge images (*.img) found in ${CARTRIDGE_DIR}!" >&2
    echo "[hub-loader] Place at least one compiled cartridge into /cartridges/ on the exFAT drive." >&2
    exec sh
fi

TOTAL_CARTRIDGES=$#
CHOSEN_IMG=""

# Detect output console for TTY text menu
TTY_DEV="/dev/console"
if [ -w "/dev/tty1" ]; then
    TTY_DEV="/dev/tty1"
elif [ -w "/dev/ttyS0" ]; then
    TTY_DEV="/dev/ttyS0"
fi

if [ "$TOTAL_CARTRIDGES" -eq 1 ]; then
    CHOSEN_IMG="$1"
    echo "[hub-loader] Single cartridge detected: $(basename "$CHOSEN_IMG") (auto-booting)" > "$TTY_DEV"
else
    # Multiple cartridges: render instant TTY text menu
    {
        printf "\033[2J\033[H"
        printf "\033[1;36m============================================================\033[0m\n"
        printf "\033[1;37m                 CARTILAGE OS — DYNAMIC HUB                 \033[0m\n"
        printf "\033[1;34m        Ventoy-Style Instant Declarative Appliance Loader   \033[0m\n"
        printf "\033[1;36m============================================================\033[0m\n\n"
        printf "\033[1;33mAvailable Cartridges:\033[0m\n"

        idx=1
        for img in "$@"; do
            bname=$(basename "$img")
            # Format clean title
            appname=$(echo "$bname" | sed -e 's/cartridge_//' -e 's/\.img//' -e 's/_arch//' -e 's/_alpine//')
            printf "  \033[1;32m[%d]\033[0m %-22s (\033[0;37m%s\033[0m)\n" "$idx" "$appname" "$bname"
            idx=$((idx + 1))
        done

        printf "\n\033[1;36m------------------------------------------------------------\033[0m\n"
        printf "Select cartridge [1-%d] (default: 1 in 3s): " "$TOTAL_CARTRIDGES"
    } > "$TTY_DEV"

    # Read selection with 3-second timeout
    CHOICE=""
    if read -t 3 -r CHOICE < "$TTY_DEV" 2>/dev/null; then
        :
    else
        CHOICE=""
    fi

    # Validate choice, default to 1 if empty or invalid
    case "$CHOICE" in
        ''|*[!0-9]*) CHOICE=1 ;;
        *)
            if [ "$CHOICE" -lt 1 ] || [ "$CHOICE" -gt "$TOTAL_CARTRIDGES" ]; then
                CHOICE=1
            fi
            ;;
    esac

    # Resolve chosen image
    cur=1
    for img in "$@"; do
        if [ "$cur" -eq "$CHOICE" ]; then
            CHOSEN_IMG="$img"
            break
        fi
        cur=$((cur + 1))
    done

    printf "\n[hub-loader] Booting cartridge [%s]: %s\n\n" "$CHOICE" "$(basename "$CHOSEN_IMG")" > "$TTY_DEV"
fi

# Loopback mount chosen cartridge into /sysroot (EROFS)
mkdir -p "$TARGET_SYSROOT"
modprobe loop 2>/dev/null || true
modprobe erofs 2>/dev/null || true

echo "[hub-loader] Mounting $(basename "$CHOSEN_IMG") to ${TARGET_SYSROOT} (EROFS, ro)..."
if ! mount -t erofs -o loop,ro "$CHOSEN_IMG" "$TARGET_SYSROOT"; then
    echo "[hub-loader] ERROR: Failed to loop-mount ${CHOSEN_IMG} to ${TARGET_SYSROOT}!" >&2
    exec sh
fi

# Check for persistent sparse ext4 data image
PERSIST_IMG="${HUB_MNT}/data/data.img"
if [ -f "$PERSIST_IMG" ]; then
    echo "[hub-loader] Found persistent data loop file: ${PERSIST_IMG}"
    mkdir -p "${TARGET_SYSROOT}/data"
    modprobe ext4 2>/dev/null || true
    if mount -t ext4 -o loop,rw "$PERSIST_IMG" "${TARGET_SYSROOT}/data" 2>/dev/null; then
        echo "[hub-loader] Mounted persistent storage: ${TARGET_SYSROOT}/data (ext4, rw)"
    else
        echo "[hub-loader] WARNING: Failed to mount ${PERSIST_IMG} to ${TARGET_SYSROOT}/data!" >&2
    fi
fi

echo "[hub-loader] Appliance rootfs preparation complete."

# Standalone execution handoff
if [ -z "${CALLED_AS_HOOK:-}" ]; then
    echo "[hub-loader] Handing off PID 1 via switch_root..."
    exec switch_root "$TARGET_SYSROOT" /init
fi
