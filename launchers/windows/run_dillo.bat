@echo off
echo ============================================================
echo Starting Cartilage OS -- Web Browser (Dillo)
echo Acceleration: Hardware KVM enabled
echo Mouse: USB Tablet absolute pointer integration
echo ============================================================
wsl bash -c "cd \"$(wslpath '%~dp0/../..')\" && ./cartilage run recipes/browser-dillo.yaml"
