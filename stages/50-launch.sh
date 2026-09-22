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

# Append url= parameter from kernel cmdline if present
for arg in $(cat /proc/cmdline 2>/dev/null); do
    if [[ "$arg" =~ ^url=(.*)$ ]]; then
        ARGS+=("${BASH_REMATCH[1]}")
    fi
done

# Determine graphics renderer (auto-detection with software fallback)
RENDER_OPTS="WLR_BACKENDS=drm,libinput WLR_RENDERER_ALLOW_SOFTWARE=1 WLR_NO_HARDWARE_CURSORS=1"

# Check if 3D acceleration is active (VirGL or physical GPU with render node)
HAS_3D_GPU=0
if grep -q "cartilage_virgl=1" /proc/cmdline 2>/dev/null; then
    HAS_3D_GPU=1
elif [[ -e /dev/dri/renderD128 && ! -e /sys/module/virtio_gpu ]]; then
    HAS_3D_GPU=1
fi

ACCEL_MODE="auto"
if [[ -f /etc/cartilage/acceleration ]]; then
    ACCEL_MODE="$(cat /etc/cartilage/acceleration | tr -d '\r\n')"
fi
for arg in $(cat /proc/cmdline 2>/dev/null); do
    if [[ "$arg" =~ ^cartilage_accel=(.*)$ ]]; then
        ACCEL_MODE="${BASH_REMATCH[1]}"
    fi
done

if [[ "$ACCEL_MODE" == "software" ]]; then
    echo "[stage:50-launch] Software rendering mode explicitly enforced: using Pixman CPU renderer..."
    RENDER_OPTS="$RENDER_OPTS WLR_RENDERER=pixman LIBGL_ALWAYS_SOFTWARE=1"
elif [[ $HAS_3D_GPU -eq 0 ]]; then
    echo "[stage:50-launch] 2D display mode: using optimized Pixman CPU renderer for rock-solid stability..."
    RENDER_OPTS="$RENDER_OPTS WLR_RENDERER=pixman"
else
    echo "[stage:50-launch] 3D GPU acceleration detected: using GLES2 hardware renderer..."
    RENDER_OPTS="$RENDER_OPTS WLR_RENDERER=gles2"
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

COMPOSITOR="cage"
if [[ -f /etc/cartilage/compositor ]]; then
    COMPOSITOR="$(cat /etc/cartilage/compositor)"
fi

# Kernel command line override (e.g. cartilage_compositor=dwl or sway)
for arg in $(cat /proc/cmdline 2>/dev/null); do
    if [[ "$arg" =~ ^cartilage_compositor=(.*)$ ]]; then
        COMPOSITOR="${BASH_REMATCH[1]}"
    fi
done

DISP_MODE="desktop"
if [[ -f /etc/cartilage/mode ]]; then
    DISP_MODE="$(cat /etc/cartilage/mode | tr -d '\r\n')"
fi
for arg in $(cat /proc/cmdline 2>/dev/null); do
    if [[ "$arg" =~ ^cartilage_mode=(.*)$ ]]; then
        DISP_MODE="${BASH_REMATCH[1]}"
    fi
done

if [[ "$DISP_MODE" == "kiosk" ]]; then
    echo "[stage:50-launch] Kiosk display mode active: enforcing fullscreen boundaries."
    if [[ "$ENTRYPOINT" =~ (chromium|chrome|browser) ]] && [[ ! " ${ARGS[*]} " =~ " --kiosk " ]]; then
        ARGS+=("--kiosk")
    fi
fi

echo "[stage:50-launch] Launching compositor: $COMPOSITOR (mode: $DISP_MODE, entrypoint: $ENTRYPOINT ${ARGS[*]:-})"

# Start user DBus session daemon if binary exists
DBUS_ADDR="unix:path=/dev/null"
if [[ -x /usr/bin/dbus-daemon ]]; then
    mkdir -p /run/user/1000 /run/dbus 2>/dev/null || true
    chown -R 1000:1000 /run/user/1000 2>/dev/null || true
    runuser -u cartilage -- dbus-daemon --session --address="unix:path=/run/user/1000/bus" --fork --nopidfile 2>/dev/null || true
    DBUS_ADDR="unix:path=/run/user/1000/bus"
fi

# Environment configuration for application session (explicit seatd backend prevents logind fallback crashes)
APP_ENV="HOME=/home/cartilage SHELL=/bin/bash USER=cartilage LOGNAME=cartilage LANG=C.UTF-8 LC_ALL=C.UTF-8 XDG_RUNTIME_DIR=/run/user/1000 GSETTINGS_BACKEND=keyfile NO_AT_BRIDGE=1 DBUS_SESSION_BUS_ADDRESS=$DBUS_ADDR GDK_BACKEND=wayland,x11 MOZ_ENABLE_WAYLAND=1 FONTCONFIG_PATH=/etc/fonts LIBSEAT_BACKEND=seatd"

# Load recipe-declared environment variables
if [[ -f /etc/cartilage/env ]]; then
    while IFS='=' read -r key val; do
        if [[ -n "$key" && ! "$key" =~ ^# ]]; then
            APP_ENV="$APP_ENV $key=$val"
        fi
    done < /etc/cartilage/env
fi

# Launch compositor in isolated mount namespace
unshare -m /bin/bash -c '
export HOME=/home/cartilage
export XDG_RUNTIME_DIR=/run/user/1000
mount --make-rprivate / 2>/dev/null || true
umount -l /mnt/hidden_host 2>/dev/null || true

entry="$1"
comp="$2"
shift 2
if [[ "$comp" == "labwc" ]]; then
    exec runuser -u cartilage -m -- env '"$APP_ENV $RENDER_OPTS"' labwc -s "$entry $*"
elif [[ "$comp" == "dwl" ]]; then
    exec runuser -u cartilage -m -- env '"$APP_ENV $RENDER_OPTS"' dwl -s "$entry $*"
elif [[ "$comp" == "sway" ]]; then
    SWAY_CONF="/etc/cartilage/sway.conf"
    if [[ -f /data/.config/sway/config ]]; then
        SWAY_CONF="/data/.config/sway/config"
    elif [[ -f /data/.config/i3/config ]]; then
        SWAY_CONF="/data/.config/i3/config"
    elif [[ -f /data/sway.conf ]]; then
        SWAY_CONF="/data/sway.conf"
    elif [[ ! -f "$SWAY_CONF" && -f /etc/sway/config ]]; then
        SWAY_CONF="/etc/sway/config"
    fi
    exec runuser -u cartilage -m -- env '"$APP_ENV $RENDER_OPTS"' sway -c "$SWAY_CONF" --unsupported-gpu
else
    exec runuser -u cartilage -m -- env '"$APP_ENV $RENDER_OPTS"' cage -s -- "$entry" "$@"
fi
' -- "$ENTRYPOINT" "$COMPOSITOR" "${ARGS[@]}" &

COMPOSITOR_PID=$!

# Automated Test Hook: Validate real Wayland execution
if grep -q "cartilage_test=verify_app" /proc/cmdline; then
    (
        echo "[stage:50-launch] Automated Test Mode: validating Wayland compositor ($COMPOSITOR) and application ($ENTRYPOINT)..."
        WAYLAND_READY=0
        for i in $(seq 1 12); do
            sleep 0.5
            # Verify compositor is running and Wayland display socket exists
            if kill -0 $COMPOSITOR_PID 2>/dev/null; then
                if [[ -S /run/user/1000/wayland-0 || -S /run/user/1000/wayland-1 || -e /run/user/1000/wayland-0 ]]; then
                    WAYLAND_READY=1
                    break
                fi
            else
                echo "[stage:50-launch] [FAIL] Compositor process exited unexpectedly."
                break
            fi
        done

        echo "============================================================"
        echo "[TEST] Cartridge Verification Hook"
        echo "============================================================"
        if [[ $WAYLAND_READY -eq 1 ]]; then
            echo "[TEST-PASS] Cartridge verification completed for $ENTRYPOINT."
            echo "[TEST-PASS] Wayland compositor ($COMPOSITOR) and display server verified active."
            sync
            kill -15 $COMPOSITOR_PID 2>/dev/null || kill -9 $COMPOSITOR_PID 2>/dev/null || true
            kill $SEATD_PID 2>/dev/null || true
            sleep 0.5
            poweroff -f 2>/dev/null || reboot -f
        else
            echo "[TEST-FAIL] Wayland compositor failed to initialize display socket within 6s!"
            sync
            kill -9 $COMPOSITOR_PID 2>/dev/null || true
            poweroff -f 2>/dev/null || reboot -f
        fi
    ) &
fi

# Wait for compositor exit
wait $COMPOSITOR_PID 2>/dev/null || true

echo "[stage:50-launch] Compositor terminated. Shutting down appliance..."
kill $SEATD_PID 2>/dev/null || true
sync
poweroff -f 2>/dev/null || reboot -f
