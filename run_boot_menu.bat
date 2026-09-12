@echo off
echo ============================================================
echo Starting Cartilage OS -- Unified Multi-Boot UEFI Menu
echo Select Dillo or Mousepad using arrow keys and press Enter.
echo ============================================================
wsl -d Ubuntu -u pryan bash -c "DISPLAY=:0 WAYLAND_DISPLAY=wayland-0 XDG_RUNTIME_DIR=/run/user/1000 qemu-system-x86_64 -enable-kvm -cpu host -drive file=/mnt/c/Users/pradyumn/Desktop/code/cartrige/build/cartilage_combined.img,format=raw,if=virtio -vga virtio -net none -usb -device usb-tablet -m 1024M -bios /usr/share/ovmf/OVMF.fd -display gtk -serial file:/tmp/cartilage-bootmenu.log -D /tmp/qemu-bootmenu-debug.log -d guest_errors"

echo.
echo Serial log: run  wsl -d Ubuntu cat /tmp/cartilage-bootmenu.log  to see boot output
