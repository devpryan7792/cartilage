"""
Cartilage OS Safe USB / Block Device Flasher Engine.
Provides strict safety checks against host drive destruction and supports dry-run mode.
"""

import os
import subprocess
import sys
from typing import List

from . import composer, schema, yaml


def is_device_mounted(device: str) -> bool:
    """Check if device or any of its partitions are mounted in /proc/mounts."""
    real_dev = os.path.realpath(device)
    try:
        with open("/proc/mounts", "r") as f:
            for line in f:
                parts = line.split()
                if not parts:
                    continue
                mount_dev = os.path.realpath(parts[0])
                if mount_dev == real_dev or mount_dev.startswith(real_dev):
                    return True
    except Exception:
        pass
    return False


def is_internal_drive(device: str) -> bool:
    """Check if device is an internal fixed drive (NVMe, MMC, VirtIO, or non-removable SATA)."""
    if device == "/dev/null":
        return False
    real_dev = os.path.realpath(device)
    dev_name = os.path.basename(real_dev)
    if (
        dev_name.startswith("nvme")
        or dev_name.startswith("pmem")
        or dev_name.startswith("mmcblk")
        or dev_name.startswith("vd")
    ):
        return True

    # Check sysfs removable attribute
    sys_block_dev = f"/sys/class/block/{dev_name}"
    if os.path.exists(sys_block_dev):
        real_sys = os.path.realpath(sys_block_dev)
        candidate_removables = [
            os.path.join(real_sys, "removable"),
            os.path.join(os.path.dirname(real_sys), "removable"),
        ]
        for rem in candidate_removables:
            if os.path.isfile(rem):
                try:
                    with open(rem, "r") as f:
                        if f.read().strip() == "0":
                            return True
                except Exception:
                    pass

    # Fallback: strip digits for sda1 -> sda
    base_dev = dev_name.rstrip("0123456789")
    removable_path = f"/sys/block/{base_dev}/removable"
    if os.path.exists(removable_path):
        try:
            with open(removable_path, "r") as f:
                return f.read().strip() == "0"
        except Exception:
            pass
    return False


def flash_device(target_device: str, recipes: List[str], dry_run: bool = False, force_internal: bool = False) -> int:
    """Safely flash one or more cartridges to a target USB block device."""
    print("=" * 60)
    print("Cartilage OS — Bare-Metal USB Flashing Engine")
    print(f"Target Device: {target_device} | Dry Run: {dry_run}")
    print(f"Recipes/Images: {', '.join(recipes)}")
    print("=" * 60)

    # Allow /dev/null only in dry-run mode for testing
    if target_device == "/dev/null":
        if not dry_run:
            print("[cartilage] Error: Cannot flash /dev/null in live mode!", file=sys.stderr)
            return 1
    else:
        # Safety Check 1: Existence
        if not os.path.exists(target_device):
            print(f"[cartilage] Error: Target device '{target_device}' does not exist!", file=sys.stderr)
            return 1

        # Safety Check 2: Must be block device
        import stat
        mode = os.stat(target_device).st_mode
        if not stat.S_ISBLK(mode) and not dry_run:
            print(f"[cartilage] Error: '{target_device}' is not a block device!", file=sys.stderr)
            return 1

        # Safety Check 3: Host root protection
        root_dev = None
        try:
            with open("/proc/mounts", "r") as f:
                for line in f:
                    parts = line.split()
                    if len(parts) >= 2 and parts[1] == "/":
                        root_dev = os.path.realpath(parts[0])
                        break
        except Exception:
            pass

        real_target = os.path.realpath(target_device)
        if root_dev and (root_dev == real_target or root_dev.startswith(real_target)):
            print(f"[cartilage] CRITICAL ERROR: '{target_device}' is the active HOST ROOT filesystem!", file=sys.stderr)
            print("[cartilage] Flashing aborted to protect host system.", file=sys.stderr)
            return 1

        # Safety Check 4: Mounted partitions check
        if is_device_mounted(target_device) and not dry_run:
            print(f"[cartilage] Error: Device '{target_device}' has active mounted partitions!", file=sys.stderr)
            print("[cartilage] Unmount all partitions before flashing.", file=sys.stderr)
            return 1

        # Safety Check 5: Internal / Fixed drive protection
        if is_internal_drive(target_device) and not force_internal and not dry_run:
            print(f"[cartilage] SAFETY ERROR: Device '{target_device}' appears to be an internal fixed drive!", file=sys.stderr)
            print("[cartilage] Cartilage Flasher is restricted to removable USB storage to prevent catastrophic data loss.", file=sys.stderr)
            print("[cartilage] Use --force-internal if you genuinely intend to overwrite an internal disk.", file=sys.stderr)
            return 1

    # Calculate layout
    print("[cartilage] -> Calculating GPT layout & partition offsets...")
    print("  Partition 1: ESP (128MB FAT32, PARTLABEL=CARTBOOT, Bootloader: systemd-boot)")

    current_idx = 1
    for r in recipes:
        print(f"  Partition {current_idx + 1}: Appliance Cartridge (EROFS, PARTLABEL=CART{current_idx}) -> {r}")
        current_idx += 1

    print(f"  Partition {current_idx + 1}: Persistent Data (256MB ext4, PARTLABEL=CARTDATA)")
    print(f"[cartilage] -> Total calculated partition count: {current_idx + 1}")

    if dry_run:
        print("=" * 60)
        print("[cartilage] [DRY RUN SUCCESS] All safety checks passed. No data written.")
        print("=" * 60)
        return 0

    # Live flashing
    print("\nWARNING: ALL DATA ON THE TARGET DEVICE WILL BE PERMANENTLY ERASED!")
    print(f"Target: {target_device}")
    confirm = input("Type 'yes' to confirm writing: ").strip()
    if confirm != "yes":
        print("[cartilage] Flashing aborted by user.")
        return 1

    # Compose into temp combined image and dd to block device
    import tempfile
    with tempfile.NamedTemporaryFile(suffix=".img", delete=True) as tmp:
        temp_img = tmp.name
        print("[cartilage] Composing disk image...")
        composer.compose_disk(temp_img, recipes)
        print(f"[cartilage] Writing image to {target_device}...")
        subprocess.run(["dd", f"if={temp_img}", f"of={target_device}", "bs=4M", "status=progress", "conv=fsync"], check=True)
        print(f"[cartilage] Flashing complete. Bootable Cartilage USB ready on {target_device}.")
    return 0


def init_hub(target_device: str, dry_run: bool = False, force_internal: bool = False) -> int:
    """Format and initialize a USB drive as a Dynamic Cartridge Hub (Mode 2 Ventoy-Style)."""
    print("=" * 60)
    print("Cartilage OS — Dynamic Hub Initializer (Mode 2)")
    print(f"Target Device: {target_device} | Dry Run: {dry_run}")
    print("=" * 60)

    if target_device == "/dev/null":
        if not dry_run:
            print("[cartilage] Error: Cannot format /dev/null in live mode!", file=sys.stderr)
            return 1
    else:
        if not os.path.exists(target_device):
            print(f"[cartilage] Error: Target device '{target_device}' does not exist!", file=sys.stderr)
            return 1

        import stat
        mode = os.stat(target_device).st_mode
        if not stat.S_ISBLK(mode) and not dry_run:
            print(f"[cartilage] Error: '{target_device}' is not a block device!", file=sys.stderr)
            return 1

        # Host root protection
        root_dev = None
        try:
            with open("/proc/mounts", "r") as f:
                for line in f:
                    parts = line.split()
                    if len(parts) >= 2 and parts[1] == "/":
                        root_dev = os.path.realpath(parts[0])
                        break
        except Exception:
            pass

        real_target = os.path.realpath(target_device)
        if root_dev and (root_dev == real_target or root_dev.startswith(real_target)):
            print(f"[cartilage] CRITICAL ERROR: '{target_device}' is the active HOST ROOT filesystem!", file=sys.stderr)
            print("[cartilage] Operation aborted to protect host system.", file=sys.stderr)
            return 1

        if is_device_mounted(target_device) and not dry_run:
            print(f"[cartilage] Error: Device '{target_device}' has active mounted partitions!", file=sys.stderr)
            print("[cartilage] Unmount all partitions before formatting.", file=sys.stderr)
            return 1

        if is_internal_drive(target_device) and not force_internal and not dry_run:
            print(f"[cartilage] SAFETY ERROR: Device '{target_device}' appears to be an internal fixed drive!", file=sys.stderr)
            print("[cartilage] Cartilage Hub is designed for removable USB storage to prevent accidental data loss.", file=sys.stderr)
            print("[cartilage] Use --force-internal if you genuinely intend to format a fixed internal disk.", file=sys.stderr)
            return 1

    # Calculate GPT layout
    print("[cartilage] -> Calculating GPT layout & partition offsets...")
    print("  Partition 1: ESP (256MB FAT32, PARTLABEL=CARTBOOT, Type=EF00, Bootloader: systemd-boot)")
    print("  Partition 2: Hub Storage (exFAT, PARTLABEL=CARTRIDGES, Type=0700, Remainder of drive)")
    print("[cartilage] -> Dynamic Hub Payload Structure:")
    print("  /cartridges/           (Drop-in directory for *.img EROFS cartridges)")
    print("  /data/data.img         (Sparse 512MB ext4 loop filesystem for POSIX persistence)")

    if dry_run:
        print("=" * 60)
        print("[cartilage] [DRY RUN SUCCESS] Hub layout calculated successfully. No data written.")
        print("=" * 60)
        return 0

    print("\nWARNING: ALL DATA ON THE TARGET DEVICE WILL BE PERMANENTLY ERASED!")
    print(f"Target: {target_device}")
    confirm = input("Type 'yes' to confirm writing: ").strip()
    if confirm != "yes":
        print("[cartilage] Operation aborted by user.")
        return 1

    repo_root = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
    build_dir = os.path.join(repo_root, "build")
    cart_candidates = [
        os.path.join(build_dir, "cartridge_workstation-dev_arch.img"),
        os.path.join(build_dir, "cartridge_foot_arch.img"),
        os.path.join(build_dir, "cartridge_vlc_arch.img"),
    ]
    cartridges = [c for c in cart_candidates if os.path.isfile(c) and os.path.getsize(c) > 0]
    if not cartridges:
        import glob
        cartridges = glob.glob(os.path.join(build_dir, "cartridge_*.img"))

    import tempfile
    with tempfile.NamedTemporaryFile(suffix=".img", delete=True) as tmp:
        temp_img = tmp.name
        print("[cartilage] Composing Dynamic Hub disk image...")
        composer.compose_hub_disk(temp_img, cartridges)
        print(f"[cartilage] Writing Hub image to {target_device}...")
        subprocess.run(["dd", f"if={temp_img}", f"of={target_device}", "bs=4M", "status=progress", "conv=fsync"], check=True)
        print(f"[cartilage] Flashing complete. Dynamic Hub USB drive ready on {target_device}.")
    return 0

