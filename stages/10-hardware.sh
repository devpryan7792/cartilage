#!/bin/bash
# Stage 10: Hardware Discovery, Kernel Modules & DRM Pipeline
# Initializes graphics, input devices, and audio drivers.

echo "[stage:10-hardware] Loading kernel modules and initializing hardware..."

# Graphics & Display
modprobe drm 2>/dev/null || true
modprobe virtio_gpu 2>/dev/null || true
modprobe bochs 2>/dev/null || true
modprobe i915 2>/dev/null || true
modprobe amdgpu 2>/dev/null || true

# Storage & Filesystems
modprobe overlay 2>/dev/null || true
modprobe ext4 2>/dev/null || true
modprobe ntfs3 2>/dev/null || true
modprobe ntfs 2>/dev/null || true
modprobe zram num_devices=1 2>/dev/null || true

# Input Devices
modprobe evdev 2>/dev/null || true
modprobe virtio_input 2>/dev/null || true
modprobe psmouse 2>/dev/null || true
modprobe atkbd 2>/dev/null || true
modprobe usbhid 2>/dev/null || true
modprobe hid_generic 2>/dev/null || true

# Network & Audio
modprobe virtio_net 2>/dev/null || true
modprobe snd_hda_intel 2>/dev/null || true
modprobe snd_hda_codec_generic 2>/dev/null || true
modprobe virtio_snd 2>/dev/null || true

# Dynamic device node population
if [[ -x /sbin/udevd ]]; then
    /sbin/udevd --daemon 2>/dev/null || true
    udevadm trigger --action=add 2>/dev/null || true
    udevadm settle --timeout=3 2>/dev/null || true
elif [[ -x /usr/lib/systemd/systemd-udevd ]]; then
    /usr/lib/systemd/systemd-udevd --daemon 2>/dev/null || true
    udevadm trigger --action=add 2>/dev/null || true
    udevadm settle --timeout=3 2>/dev/null || true
elif command -v mdev >/dev/null 2>&1; then
    mdev -s 2>/dev/null || true
fi

# Ensure device nodes exist and have proper permissions
mkdir -p /dev/dri /dev/input /dev/snd
chmod 0755 /dev/dri /dev/input /dev/snd 2>/dev/null || true
chmod 0666 /dev/dri/* /dev/input/* 2>/dev/null || true
chmod -R 0660 /dev/snd/* 2>/dev/null || true

# Audio group configuration
groupadd -g 92 audio 2>/dev/null || addgroup -g 92 audio 2>/dev/null || true
chown -R root:audio /dev/snd 2>/dev/null || true

# Universal ALSA Audio Configuration (Direct plug to hardware DAC with format/rate conversion)
mkdir -p /run /var/cache/fontconfig
mount -t tmpfs tmpfs /var/cache/fontconfig -o mode=0777 2>/dev/null || true

CARD_NUM="0"
if [[ -f /proc/asound/cards ]]; then
    # Prefer analog/codec audio cards over HDMI/DisplayPort outputs
    DETECTED_CARD="$(grep -E '^[ 0-9]+ \[' /proc/asound/cards | grep -ivE 'hdmi|displayport' | head -n 1 | awk '{print $1}')"
    if [[ -z "$DETECTED_CARD" ]]; then
        DETECTED_CARD="$(grep -E '^[ 0-9]+ \[' /proc/asound/cards | head -n 1 | awk '{print $1}')"
    fi
    [[ -n "$DETECTED_CARD" ]] && CARD_NUM="$DETECTED_CARD"
fi

cat << ASOUND_EOF > /run/asound.conf
pcm.!default {
    type asym
    playback.pcm "playback_plug"
    capture.pcm "capture_plug"
}
pcm.playback_plug {
    type plug
    slave.pcm "hw:${CARD_NUM},0"
}
pcm.capture_plug {
    type plug
    slave.pcm "hw:${CARD_NUM},0"
}
pcm.dmixer {
    type dmix
    ipc_key 1024
    ipc_perm 0666
    slave {
        pcm "hw:${CARD_NUM},0"
        period_time 0
        period_size 1024
        buffer_size 4096
        rate 48000
    }
    bindings {
        0 0
        1 1
    }
}
pcm.dsnooper {
    type dsnoop
    ipc_key 2048
    ipc_perm 0666
    slave {
        pcm "hw:${CARD_NUM},0"
        rate 48000
    }
    bindings {
        0 0
        1 1
    }
}
ctl.!default {
    type hw
    card ${CARD_NUM}
}
ASOUND_EOF

chmod 0644 /run/asound.conf 2>/dev/null || true
mount --bind /run/asound.conf /etc/asound.conf 2>/dev/null || true

# Unmute all audio channels
amixer -c ${CARD_NUM} sset Master 100% unmute 2>/dev/null || true
amixer -c ${CARD_NUM} sset PCM 100% unmute 2>/dev/null || true
amixer sset Master 100% unmute 2>/dev/null || true
amixer sset PCM 100% unmute 2>/dev/null || true

echo "[stage:10-hardware] Hardware discovery completed."
echo "[stage:10-hardware] DRM devices: $(ls /dev/dri 2>/dev/null | tr '\n' ' ' || echo 'none')"
echo "[stage:10-hardware] Audio devices: $(ls /dev/snd 2>/dev/null | tr '\n' ' ' || echo 'none') (ALSA default card: ${CARD_NUM})"
