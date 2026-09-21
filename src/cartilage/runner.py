"""
Cartilage OS QEMU Appliance Runner.
Inspects appliance recipes or cartridge images and launches QEMU with matched flags.
"""

import os
import shutil
import subprocess
import sys
from pathlib import Path
from typing import Any, Dict, List, Optional

from . import schema, yaml


def find_kernel_and_initramfs() -> Tuple[str, str]:
    """Locate host kernel and initramfs."""
    kernel_candidates = [
        "/boot/vmlinuz-linux",
        "/boot/vmlinuz-linux-lts",
        "/boot/vmlinuz-linux-zen",
    ]
    kernel = None
    for c in kernel_candidates:
        if os.path.isfile(c):
            kernel = c
            break
    if not kernel:
        raise FileNotFoundError("Could not locate Linux kernel image in /boot (vmlinuz-linux)")

    initrd_candidates = [
        "build/initramfs-linux.img",
        "/boot/initramfs-linux.img",
        "/boot/initramfs-linux-fallback.img",
    ]
    initrd = None
    for c in initrd_candidates:
        if os.path.isfile(c):
            initrd = c
            break
    if not initrd:
        raise FileNotFoundError("Could not locate initramfs image in build/ or /boot")

    return os.path.abspath(kernel), os.path.abspath(initrd)


def ensure_cartdata_image(path: str = "build/cartdata.img", size_mb: int = 256) -> str:
    """Create a persistent ext4 CARTDATA image if it does not exist."""
    path = os.path.abspath(path)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    if not os.path.exists(path) or os.path.getsize(path) == 0:
        print(f"[cartilage] Initializing persistent CARTDATA disk: {path} ({size_mb}MB)...")
        subprocess.run(["truncate", "-s", f"{size_mb}M", path], check=True)
        # Format ext4 with label CARTDATA
        subprocess.run(["mkfs.ext4", "-F", "-L", "CARTDATA", path], check=True, stdout=subprocess.DEVNULL)
    return path


def run_appliance(
    target: str,
    test_mode: bool = False,
    url: Optional[str] = None,
    extra_cmdline: Optional[str] = None,
    data_image: Optional[str] = None,
    efi_mode: bool = False,
    verbose: bool = False,
) -> int:

    """Launch an appliance in QEMU based on recipe or image."""
    manifest: Optional[Dict[str, Any]] = None
    cartridge_img = None

    if target.endswith(".yaml") or target.endswith(".yml") or target.endswith(".json"):
        manifest_data = yaml.load(target)
        manifest = schema.validate_manifest(manifest_data)
        app_name = manifest["appliance"]["name"]
        engine = manifest["runtime"]["engine"]

        # Look for existing cartridge image
        candidates = [
            f"build/cartridge_{app_name}_{engine}.img",
            f"build/cartridge_{app_name}.img",
            f"build/cartridge_{app_name}_arch.img",
            f"build/cartridge_{app_name}_alpine.img",
        ]
        for c in candidates:
            if os.path.isfile(c) and os.path.getsize(c) > 0:
                cartridge_img = os.path.abspath(c)
                break
        if not cartridge_img:
            print(f"[cartilage] Cartridge image not found for recipe '{target}'.")
            print(f"[cartilage] Run: cartilage build {target}")
            return 1
    else:
        # Direct image specified
        cartridge_img = os.path.abspath(target)
        if not os.path.isfile(cartridge_img):
            print(f"[cartilage] Error: Image not found at {cartridge_img}", file=sys.stderr)
            return 1

    # In combined disk image mode, run UEFI boot
    is_combined = "combined" in os.path.basename(cartridge_img) or efi_mode

    qemu_cmd = ["qemu-system-x86_64"]

    # KVM hardware acceleration
    if os.path.exists("/dev/kvm") and os.access("/dev/kvm", os.R_OK | os.W_OK):
        qemu_cmd.extend(["-enable-kvm", "-cpu", "host"])
    else:
        qemu_cmd.extend(["-cpu", "qemu64"])

    # Memory and cores
    ram = "1024M"
    cores = 2
    network_enabled = True
    audio_enabled = True
    storage_mode = "persistent"

    if manifest:
        ram = manifest["hardware"].get("memory", "1024M")
        cores = manifest["hardware"].get("cores", 2)
        network_enabled = manifest["hardware"].get("network", False)
        audio_enabled = manifest["hardware"].get("audio", False)
        storage_mode = manifest["storage"].get("mode", "persistent")
    elif "chromium" in os.path.basename(cartridge_img).lower():
        ram = "2048M"
        cores = 2
        network_enabled = True
        audio_enabled = True

    qemu_cmd.extend(["-m", ram, "-smp", str(cores)])

    # Display & Graphics
    qemu_cmd.extend(["-device", "virtio-gpu-pci"])
    if test_mode:
        qemu_cmd.extend(["-display", "none", "-serial", "stdio"])
    elif verbose:
        qemu_cmd.extend(["-display", "gtk", "-serial", "stdio"])
    else:
        qemu_cmd.extend(["-display", "gtk", "-serial", "file:/tmp/cartilage_last_run.log"])

    # Input devices (virtio tablet + keyboard)
    qemu_cmd.extend(["-device", "virtio-tablet-pci", "-device", "virtio-keyboard-pci"])


    # Audio Subsystem
    if audio_enabled and not test_mode:
        qemu_cmd.extend([
            "-audiodev", "id=snd0,driver=pa",
            "-device", "intel-hda",
            "-device", "hda-duplex,audiodev=snd0"
        ])

    # Network Subsystem
    if network_enabled or not manifest:
        qemu_cmd.extend([
            "-netdev", "user,id=net0",
            "-device", "virtio-net-pci,netdev=net0"
        ])
    else:
        qemu_cmd.extend(["-net", "none"])

    # Storage & Drives
    if is_combined:
        # UEFI combined disk
        ovmf_code = "/usr/share/edk2-ovmf/x64/OVMF_CODE.fd"
        if not os.path.exists(ovmf_code):
            ovmf_code = "/usr/share/ovmf/x64/OVMF_CODE.fd"
        if os.path.exists(ovmf_code):
            qemu_cmd.extend(["-drive", f"if=pflash,format=raw,readonly=on,file={ovmf_code}"])
        qemu_cmd.extend(["-drive", f"file={cartridge_img},format=raw,if=virtio"])
    else:
        # Kernel + Initrd Direct Boot
        kernel, initrd = find_kernel_and_initramfs()
        qemu_cmd.extend(["-kernel", kernel, "-initrd", initrd])

        # Cartridge Drive (vda)
        qemu_cmd.extend(["-drive", f"file={cartridge_img},format=raw,if=virtio,readonly=on"])

        # Persistent Data Drive (vdb)
        if storage_mode == "persistent":
            cartdata = data_image or ensure_cartdata_image()
            qemu_cmd.extend(["-drive", f"file={cartdata},format=raw,if=virtio"])

        # Kernel commandline
        cmdline_parts = [
            "root=/dev/vda",
            "rootfstype=erofs",
            "init=/init",
            "ro",
            "quiet",
            "loglevel=3",
            "console=tty1",
            "console=ttyS0",
            "host_passcode=cartilage42",
        ]

        if storage_mode == "ephemeral":
            cmdline_parts.append("storage=ephemeral")
        if url:
            cmdline_parts.append(f"url={url}")
        if test_mode:
            cmdline_parts.append("cartilage_test=verify_app")
        if extra_cmdline:
            cmdline_parts.append(extra_cmdline)

        qemu_cmd.extend(["-append", " ".join(cmdline_parts)])

    print("=" * 60)
    print(f"[cartilage] Launching appliance: {os.path.basename(cartridge_img)}")
    print(f"[cartilage] RAM: {ram} | Cores: {cores} | Network: {network_enabled} | Audio: {audio_enabled}")
    print("=" * 60)

    try:
        proc = subprocess.run(qemu_cmd)
        return proc.returncode
    except KeyboardInterrupt:
        print("\n[cartilage] QEMU terminated by user.")
        return 0
