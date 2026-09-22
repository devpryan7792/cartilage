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
        else
            echo "[stage:30-storage] [WARN] $PERSIST_DEV mounted read-only, falling back to OverlayFS..."
            umount /run/persistent_data 2>/dev/null || true
        fi
    else
        echo "[stage:30-storage] [WARN] Mount failed on $PERSIST_DEV, falling back to OverlayFS..."
    fi
fi

if [[ $MOUNTED_PERSISTENT -eq 0 ]]; then
    echo "[stage:30-storage] Ephemeral Mode active: setting up writable OverlayFS on tmpfs..."
    mkdir -p /run/overlay_fs
    mount -t tmpfs -o size=512M tmpfs /run/overlay_fs 2>/dev/null || true
    mkdir -p /run/overlay_fs/upper /run/overlay_fs/work
    if ! mount -t overlay overlay -o lowerdir=/data,upperdir=/run/overlay_fs/upper,workdir=/run/overlay_fs/work /data 2>/dev/null; then
        echo "[stage:30-storage] [WARN] OverlayFS mount failed, mounting tmpfs directly on /data..."
        mount -t tmpfs -o size=512M tmpfs /data 2>/dev/null || true
    fi
    echo "[stage:30-storage] Ephemeral storage mounted on /data."
fi

# Downloads directory
mkdir -p /data/downloads 2>/dev/null || true
mount -t tmpfs -o size=32M,mode=0777 tmpfs /data/downloads 2>/dev/null || true
export XDG_DOWNLOAD_DIR=/data/downloads

# Configure zram swap (zstd) if available
if command -v zramctl >/dev/null 2>&1 && [[ -e /dev/zram0 ]]; then
    zramctl -f -s 512M -a zstd 2>/dev/null || zramctl /dev/zram0 -s 512M -a zstd 2>/dev/null || true
    mkswap /dev/zram0 2>/dev/null || true
    swapon -p 32767 /dev/zram0 2>/dev/null || true
fi

# Auto-mount writable system overlays for live session package installation & configuration
for sys_dir in var usr etc; do
    if [[ -d "/${sys_dir}" ]]; then
        mkdir -p "/run/overlay_${sys_dir}/upper" "/run/overlay_${sys_dir}/work"
        if mount -t overlay overlay -o lowerdir=/${sys_dir},upperdir=/run/overlay_${sys_dir}/upper,workdir=/run/overlay_${sys_dir}/work /${sys_dir} 2>/dev/null; then
            echo "[stage:30-storage] Writable RAM overlay active on /${sys_dir}"
        fi
    fi
done

# Re-affirm core system runtime symlinks/binds over overlaid /etc
mount --bind /run/resolv.conf /etc/resolv.conf 2>/dev/null || true
mount --bind /run/asound.conf /etc/asound.conf 2>/dev/null || true

echo "[stage:30-storage] Storage configuration completed."
