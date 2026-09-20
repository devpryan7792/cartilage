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

echo "[stage:10-hardware] Hardware discovery completed."
echo "[stage:10-hardware] DRM devices: $(ls /dev/dri 2>/dev/null | tr '\n' ' ' || echo 'none')"
echo "[stage:10-hardware] Audio devices: $(ls /dev/snd 2>/dev/null | tr '\n' ' ' || echo 'none')"
