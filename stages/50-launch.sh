#!/bin/bash
# Stage 50: Appliance Compositor Launch & Execution
# Starts seatd, initializes Wayland compositor (cage), and launches target application.

echo "[stage:50-launch] Starting seatd and Wayland compositor..."

export XDG_RUNTIME_DIR=/run/user/1000
export HOME=/home/cartilage
export SEATD_LOGLEVEL=info

# Start seatd daemon for user cartilage
seatd -u cartilage &
SEATD_PID=$!
sleep 0.5
chmod 0777 /run/seatd.sock 2>/dev/null || true

# Determine entrypoint and arguments
ENTRYPOINT="/usr/bin/dillo"
if [[ -f /etc/cartilage/entrypoint ]]; then
    ENTRYPOINT="$(cat /etc/cartilage/entrypoint)"
fi

ARGS=()
if [[ -f /etc/cartilage/args ]]; then
    while IFS= read -r line; do
        [[ -n "$line" ]] && ARGS+=("$line")
    done < /etc/cartilage/args
fi

# Determine graphics renderer (auto-detection with software fallback)
RENDER_OPTS="WLR_BACKENDS=drm,libinput WLR_LIBINPUT_NO_DEVICES=1 WLR_RENDERER_ALLOW_SOFTWARE=1"
if [[ ! -e /dev/dri/card0 && ! -e /dev/dri/card1 ]]; then
    echo "[stage:50-launch] [WARN] No hardware DRM card detected, falling back to pixman software rasterizer..."
    RENDER_OPTS="$RENDER_OPTS WLR_RENDERER=pixman"
fi

# Check for Alpine vs Arch specific options
if grep -qi "alpine" /etc/os-release 2>/dev/null; then
    RENDER_OPTS="$RENDER_OPTS WLR_RENDERER=pixman"
fi

# Optional: Benchmark Hook
if grep -q "cartilage_benchmark=1" /proc/cmdline; then
    (
        echo "[benchmark] Waiting 10s post-launch to measure idle RAM..."
        sleep 10
        echo "============================================================"
        echo "[BENCHMARK] Idle RAM usage (10s post-launch):"
        echo "============================================================"
        free -h
        echo "============================================================"
        echo "[BENCHMARK] Monotonic uptime: $(cat /proc/uptime 2>/dev/null | cut -d' ' -f1)s"
        echo "============================================================"
        sync; poweroff -f || reboot -f
    ) &
fi

# Optional: Screenshot Hook
if grep -q "cartilage_screenshot=1" /proc/cmdline; then
    (
        sleep 4
        mkdir -p /mnt/screendisk
        mount /dev/vdb /mnt/screendisk 2>/dev/null || mount /dev/sdb /mnt/screendisk 2>/dev/null || true
        export XDG_RUNTIME_DIR=/run/user/0
        export WAYLAND_DISPLAY=wayland-0
        echo "[screenshot] Capturing frame with grim..."
        grim /mnt/screendisk/shot.png 2>&1 || true
        sync; poweroff -f || reboot -f
    ) &
fi

echo "[stage:50-launch] Launching compositor: cage -s -- $ENTRYPOINT ${ARGS[*]:-}"

# Launch cage in isolated mount namespace
unshare -m /bin/bash << CAGE_LAUNCH_EOF &
export HOME=/home/cartilage
export XDG_RUNTIME_DIR=/run/user/1000
mount --make-rprivate / 2>/dev/null || true
umount -l /mnt/hidden_host 2>/dev/null || true
mount --bind /dev/null /bin/bash 2>/dev/null || true

exec runuser -u cartilage -m -- env HOME=/home/cartilage XDG_RUNTIME_DIR=/run/user/1000 $RENDER_OPTS cage -s -- "$ENTRYPOINT" "${ARGS[@]}"
CAGE_LAUNCH_EOF

CAGE_PID=$!

# Wait for compositor exit
wait $CAGE_PID 2>/dev/null || true

echo "[stage:50-launch] Compositor terminated. Shutting down appliance..."
kill $SEATD_PID 2>/dev/null || true
sync
poweroff -f 2>/dev/null || reboot -f
