#!/bin/bash
# Stage 30: Storage Subsystem & Persistence Policy
# Mounts /data with fault-tolerant error boundaries and OverlayFS fallback.

echo "[stage:30-storage] Configuring storage subsystem..."

mkdir -p /data

# Check kernel cmdline for storage override (e.g., storage=ephemeral or storage=persistent)
CMD_STORAGE=""
for arg in $(cat /proc/cmdline 2>/dev/null); do
    if [[ "$arg" =~ ^storage=(.*)$ ]]; then
        CMD_STORAGE="${BASH_REMATCH[1]}"
    fi
done

PERSIST_DEV=""
if [[ "$CMD_STORAGE" != "ephemeral" ]]; then
    if [[ -b /dev/disk/by-partlabel/CARTDATA ]]; then
        PERSIST_DEV="/dev/disk/by-partlabel/CARTDATA"
    elif [[ -b /dev/disk/by-label/CARTDATA ]]; then
        PERSIST_DEV="/dev/disk/by-label/CARTDATA"
    elif [[ -b /dev/vdb ]]; then
        PERSIST_DEV="/dev/vdb"
    fi
fi

MOUNTED_PERSISTENT=0
if [[ -n "$PERSIST_DEV" ]]; then
    echo "[stage:30-storage] Persistent block device detected: $PERSIST_DEV"
    mkdir -p /run/persistent_data
    if mount -t ext4 -o rw "$PERSIST_DEV" /run/persistent_data; then
        # Check if the mount is actually writable
        if touch /run/persistent_data/.probe_rw 2>/dev/null; then
            rm -f /run/persistent_data/.probe_rw
            mount --bind /run/persistent_data /data
            echo "[stage:30-storage] Persistent Mode active: $PERSIST_DEV bound to /data"
            MOUNTED_PERSISTENT=1
            touch /run/cartilage_persistent_active
        else
            echo "[stage:30-storage] [WARN] $PERSIST_DEV mounted read-only, falling back to OverlayFS..."
            umount /run/persistent_data 2>/dev/null || true
        fi
    else
        echo "[stage:30-storage] [WARN] Mount failed on $PERSIST_DEV, falling back to OverlayFS..."
    fi
fi

if [[ $MOUNTED_PERSISTENT -eq 0 ]]; then
    QUOTA="256M"
    if [[ -f /etc/cartilage/quota ]]; then
        QUOTA="$(cat /etc/cartilage/quota | tr -d '\r\n')"
    fi
    echo "[stage:30-storage] Ephemeral Mode active (quota: $QUOTA): setting up writable OverlayFS on tmpfs..."
    mkdir -p /run/overlay_fs
    mount -t tmpfs -o size="$QUOTA" tmpfs /run/overlay_fs 2>/dev/null || true
    mkdir -p /run/overlay_fs/upper /run/overlay_fs/work
    if ! mount -t overlay overlay -o lowerdir=/data,upperdir=/run/overlay_fs/upper,workdir=/run/overlay_fs/work /data 2>/dev/null; then
        echo "[stage:30-storage] [WARN] OverlayFS mount failed, mounting tmpfs directly on /data..."
        mount -t tmpfs -o size="$QUOTA" tmpfs /data 2>/dev/null || true
    fi
    echo "[stage:30-storage] Ephemeral storage mounted on /data."
fi

# Downloads directory (persistent on CARTDATA, tmpfs in ephemeral mode)
mkdir -p /data/downloads 2>/dev/null || true
if [[ $MOUNTED_PERSISTENT -eq 0 ]]; then
    mount -t tmpfs -o size=64M,mode=0777 tmpfs /data/downloads 2>/dev/null || true
fi
export XDG_DOWNLOAD_DIR=/data/downloads

# Configure zram swap (zstd) if available
if command -v zramctl >/dev/null 2>&1 && [[ -e /dev/zram0 ]]; then
    zramctl -f -s 512M -a zstd 2>/dev/null || zramctl /dev/zram0 -s 512M -a zstd 2>/dev/null || true
    mkswap /dev/zram0 2>/dev/null || true
    swapon -p 32767 /dev/zram0 2>/dev/null || true
fi

# Auto-mount writable system overlays for live session configuration (/var, /usr, /etc)
for sys_dir in var usr etc; do
    if [[ -d "/${sys_dir}" ]]; then
        mkdir -p "/run/overlay_${sys_dir}/upper" "/run/overlay_${sys_dir}/work"
        if mount -t overlay overlay -o lowerdir=/${sys_dir},upperdir=/run/overlay_${sys_dir}/upper,workdir=/run/overlay_${sys_dir}/work /${sys_dir} 2>/dev/null; then
            echo "[stage:30-storage] Writable RAM overlay active on /${sys_dir}"
        fi
    fi
done

# Cartilage Appliance Package Guard: Enforces "Bake, Don't Mutate" principle
ELF_HEADER=$(head -c 4 /usr/bin/pacman 2>/dev/null)
if [[ "$ELF_HEADER" == $'\x7fELF' && ! -e /usr/bin/pacman.real ]]; then
    cp -p /usr/bin/pacman /usr/bin/pacman.real
    cat << 'PACMAN_GUARD' > /usr/bin/pacman
#!/bin/bash
# Cartilage OS - Appliance Package Guard
# Enforces the "Bake, Don't Mutate" immutable appliance principle.

REAL_PACMAN="/usr/bin/pacman.real"

# Allow non-mutating queries / version checks
if [[ "$1" =~ ^-[QVh] || "$1" == "--version" || "$1" == "--help" ]]; then
    if [[ -x "$REAL_PACMAN" ]]; then
        exec "$REAL_PACMAN" "$@"
    fi
fi

# Check for explicit ephemeral testing override
FORCE_EPHEMERAL=0
FILTERED_ARGS=()
for arg in "$@"; do
    if [[ "$arg" == "--force-ephemeral" ]]; then
        FORCE_EPHEMERAL=1
    else
        FILTERED_ARGS+=("$arg")
    fi
done

if [[ $FORCE_EPHEMERAL -eq 1 && -x "$REAL_PACMAN" ]]; then
    echo "[cartilage] WARNING: Running pacman in temporary RAM OverlayFS. Changes will disappear on reboot." >&2
    exec "$REAL_PACMAN" --overwrite '*' "${FILTERED_ARGS[@]}"
fi

cat << 'NOTICE'
======================================================================
                 CARTILAGE OS — IMMUTABLE APPLIANCE
======================================================================
 This cartridge is an immutable read-only appliance.
 Direct runtime package installation is intentionally disabled:
   * Files installed to /usr vanish completely upon reboot.
   * Downloading packages into RAM tmpfs exhausts system memory.

 [HOW TO ADD PACKAGES PERMANENTLY]
 1. Add desired packages to your recipe YAML on your host:
      runtime:
        packages:
          - <package-name>
 2. Rebuild the immutable cartridge:
      ./cartilage build recipes/<recipe>.yaml

 [PERSISTENT USER STORAGE]
 User code, dotfiles, Git repos, and notes persist safely in:
      /data  (or ~ when persistent CARTDATA drive is attached)

 (To bypass for temporary live debugging: pacman --force-ephemeral ...)
======================================================================
NOTICE
exit 1
PACMAN_GUARD
    chmod 0755 /usr/bin/pacman
    mkdir -p /usr/local/bin
    cp -p /usr/bin/pacman /usr/local/bin/pacman
fi

# Re-affirm core system runtime symlinks/binds over overlaid /etc
mount --bind /run/resolv.conf /etc/resolv.conf 2>/dev/null || true
mount --bind /run/asound.conf /etc/asound.conf 2>/dev/null || true

echo "[stage:30-storage] Storage configuration completed."
