@echo off
echo ============================================================
echo Starting Cartilage OS -- Web Browser (Dillo)
echo Acceleration: Hardware KVM enabled (cold boot ~2 seconds)
echo Mouse: USB Tablet absolute pointer integration
echo Console: VT2 Debug Console (Ctrl+Alt+F2)
echo ============================================================
wsl -d Ubuntu -u root qemu-system-x86_64 -enable-kvm -cpu host -kernel /var/lib/cartilage/rootfs/boot/vmlinuz-linux -initrd /var/lib/cartilage/rootfs/boot/initramfs-linux.img -drive file=/mnt/c/Users/pradyumn/Desktop/code/cartrige/build/cartridge_dillo.img,format=raw,if=virtio -append "console=ttyS0 root=/dev/vda rootfstype=erofs init=/init" -vga virtio -usb -device usb-tablet -m 1024M -display gtk
