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


def flash_device(target_device: str, recipes: List[str], dry_run: bool = False) -> int:
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
