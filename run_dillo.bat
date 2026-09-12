@echo off
echo ============================================================
echo Starting Cartilage OS -- Web Browser (Dillo)
echo Acceleration: Hardware KVM enabled (cold boot ~2 seconds)
echo Mouse: USB Tablet absolute pointer integration
echo Console: VT2 Debug Console (Ctrl+Alt+F2)
echo ============================================================
wsl -d Ubuntu -u pryan bash -c "DISPLAY=:0 WAYLAND_DISPLAY=wayland-0 XDG_RUNTIME_DIR=/run/user/1000 qemu-system-x86_64 -enable-kvm -cpu host -kernel /var/lib/cartilage/rootfs/boot/vmlinuz-linux -initrd /var/lib/cartilage/rootfs/boot/initramfs-linux.img -drive file=/mnt/c/Users/pradyumn/Desktop/code/cartrige/build/cartridge_dillo.img,format=raw,if=virtio -vga virtio -append 'console=tty1 console=ttyS0 root=/dev/vda rootfstype=erofs init=/init' -usb -device usb-tablet -m 1024M -display gtk -serial file:/tmp/cartilage-dillo.log -D /tmp/qemu-dillo-debug.log -d guest_errors"

echo.
echo Serial log: run  wsl -d Ubuntu cat /tmp/cartilage-dillo.log  to see boot output
