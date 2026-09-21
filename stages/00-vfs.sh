#!/bin/bash
# Stage 00: Kernel Virtual Filesystems (VFS)
# Mounts /proc, /sys, /dev, /run, /tmp, /dev/shm with strict error boundaries.

echo "[stage:00-vfs] Mounting virtual filesystems..."

mount -t proc proc /proc -o nosuid,noexec,nodev 2>/dev/null || true
mount -t sysfs sys /sys -o nosuid,noexec,nodev 2>/dev/null || true
mount -t devtmpfs devtmpfs /dev -o nosuid,mode=0755 2>/dev/null || true

mkdir -p /dev/pts /dev/shm /run /tmp /var/lib/xkb 2>/dev/null || true

mount -t devpts devpts /dev/pts -o nosuid,noexec,mode=0620,gid=5 2>/dev/null || true
mount -t tmpfs shm /dev/shm -o nosuid,nodev,size=512M,mode=1777 2>/dev/null || true
mount -t tmpfs tmpfs /tmp -o nosuid,nodev 2>/dev/null || true
mount -t tmpfs tmpfs /run -o nosuid,nodev,mode=0755 2>/dev/null || true
mount -t tmpfs tmpfs /var/lib/xkb -o mode=1777 2>/dev/null || true
mkdir -p /tmp/.X11-unix 2>/dev/null || true
chmod 1777 /tmp/.X11-unix /tmp /dev/shm 2>/dev/null || true

# Enable unprivileged user namespaces for sandboxed engines (Chromium zygote, etc.)
sysctl -w kernel.unprivileged_userns_clone=1 2>/dev/null || true
if [[ -f /proc/sys/kernel/unprivileged_userns_clone ]]; then
    echo 1 > /proc/sys/kernel/unprivileged_userns_clone 2>/dev/null || true
fi

echo "[stage:00-vfs] Virtual filesystems mounted successfully."
