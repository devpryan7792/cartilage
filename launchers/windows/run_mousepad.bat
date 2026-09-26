@echo off
echo ============================================================
echo Starting Cartilage OS -- Text Editor (Mousepad)
echo Acceleration: Hardware KVM enabled
echo Mouse: USB Tablet absolute pointer integration
echo ============================================================
wsl bash -c "cd \"$(wslpath '%~dp0/../..')\" && ./cartilage run recipes/editor-mousepad.yaml"
