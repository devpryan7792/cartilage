@echo off
echo ============================================================
echo Starting Cartilage OS -- Unified Multi-Boot UEFI Menu
echo Select Dillo or Mousepad using arrow keys and press Enter.
echo ============================================================
wsl -d Ubuntu -u root qemu-system-x86_64 -enable-kvm -cpu host -drive file=/mnt/c/Users/pradyumn/Desktop/code/cartrige/build/cartilage_combined.img,format=raw -vga virtio -usb -device usb-tablet -m 1024M -bios /usr/share/OVMF/OVMF_CODE.fd -display gtk
