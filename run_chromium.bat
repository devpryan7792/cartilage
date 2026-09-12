@echo off
echo ============================================================
echo Starting Cartilage OS -- Chromium Modern Web Kiosk
echo Runtime: Chromium Ozone Wayland on Cage Compositor
echo Network: virtio-net with automatic DHCP
echo Audio: Intel HDA Sound Card with ALSA dmix
echo Memory: 2048 MB allocated
echo Mouse: USB Tablet Absolute Pointer
echo VT2 Console: Press Ctrl+Alt+F2 (Passcode: cartilage42)
echo ============================================================
wsl -d Ubuntu -u pryan bash -c "DISPLAY=:0 WAYLAND_DISPLAY=wayland-0 XDG_RUNTIME_DIR=/run/user/1000 qemu-system-x86_64 -enable-kvm -cpu host -kernel /var/lib/cartilage/rootfs/boot/vmlinuz-linux -initrd /var/lib/cartilage/rootfs/boot/initramfs-linux.img -drive file=/mnt/c/Users/pradyumn/Desktop/code/cartrige/build/cartridge_chromium_arch.img,format=raw,if=virtio -vga virtio -netdev user,id=net0 -device virtio-net-pci,netdev=net0 -audiodev id=snd0,driver=none -device intel-hda -device hda-duplex,audiodev=snd0 -append 'console=tty1 console=ttyS0 root=/dev/vda rootfstype=erofs init=/init' -usb -device usb-tablet -m 2048M -display gtk -serial file:/tmp/chromium.log -D /tmp/qemu-chromium-debug.log -d guest_errors"




