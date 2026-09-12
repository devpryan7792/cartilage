@echo off
echo ============================================================
echo Starting Cartilage OS -- Ultra-Lean Alpine Cartridge (Mousepad)
echo Image Size: 44.8 MB (96% smaller than Arch)
echo Cold Boot Latency: ~2 seconds (KVM Accelerated)
echo Memory Usage: ~57 MB Idle RAM
echo Mouse: USB Tablet Absolute Pointer
echo VT2 Console: Press Ctrl+Alt+F2 (Passcode: cartilage42)
echo ============================================================
wsl -d Ubuntu -u pryan bash -c "DISPLAY=:0 WAYLAND_DISPLAY=wayland-0 XDG_RUNTIME_DIR=/run/user/1000 qemu-system-x86_64 -enable-kvm -cpu host -kernel /var/lib/cartilage/rootfs/boot/vmlinuz-linux -initrd /var/lib/cartilage/rootfs/boot/initramfs-linux.img -drive file=/mnt/c/Users/pradyumn/Desktop/code/cartrige/build/cartridge_mousepad_alpine.img,format=raw,if=virtio -device virtio-gpu-pci -append 'console=ttyS0 root=/dev/vda rootfstype=erofs init=/init' -usb -device usb-tablet -m 1024M -display gtk -serial file:/tmp/cartilage-alpine.log -D /tmp/qemu-alpine-debug.log -d guest_errors"

echo.
echo Serial log: run  wsl -d Ubuntu cat /tmp/cartilage-alpine.log  to see boot output

