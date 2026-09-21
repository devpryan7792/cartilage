"""
Cartilage OS Image Composer.
Assembles multiple cartridges into a unified rootless multi-boot UEFI GPT disk image.
"""

import os
import shutil
import subprocess
import sys
import tempfile
from typing import List, Tuple

from . import schema, yaml


def compose_disk(output_img: str, targets: List[str]) -> str:
    """Compose a multi-boot UEFI disk image containing the specified cartridges."""
    repo_root = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
    build_dir = os.path.join(repo_root, "build")

    cartridge_entries: List[Tuple[str, str, str]] = []  # (app_name, title, img_path)

    for target in targets:
        if target.endswith(".yaml") or target.endswith(".yml") or target.endswith(".json"):
            data = yaml.load(target)
            manifest = schema.validate_manifest(data)
            app_name = manifest["appliance"]["name"]
            title = f"Cartilage OS — {manifest['appliance'].get('description', app_name.capitalize())}"
            engine = manifest["runtime"]["engine"]
            candidates = [
                os.path.join(build_dir, f"cartridge_{app_name}_{engine}.img"),
                os.path.join(build_dir, f"cartridge_{app_name}.img"),
                os.path.join(build_dir, f"cartridge_{app_name}_arch.img"),
                os.path.join(build_dir, f"cartridge_{app_name}_alpine.img"),
            ]
            img_path = None
            for c in candidates:
                if os.path.isfile(c) and os.path.getsize(c) > 0:
                    img_path = c
                    break
            if not img_path:
                raise FileNotFoundError(f"Cartridge image for recipe {target} not found. Run 'cartilage build {target}' first.")
            cartridge_entries.append((app_name, title, img_path))
        else:
            img_path = os.path.abspath(target)
            if not os.path.isfile(img_path):
                raise FileNotFoundError(f"Cartridge image {target} not found.")
            base = os.path.basename(img_path)
            app_name = base.replace("cartridge_", "").replace(".img", "").split("_")[0]
            title = f"Cartilage OS — {app_name.capitalize()}"
            cartridge_entries.append((app_name, title, img_path))

    if not cartridge_entries:
        raise ValueError("At least one cartridge image or recipe is required to compose a disk.")

    # Locate kernel, initramfs, systemd-boot
    kernel = None
    for k in ["/var/lib/cartilage/rootfs/boot/vmlinuz-linux", "/boot/vmlinuz-linux"]:
        if os.path.isfile(k):
            kernel = k
            break
    if not kernel:
        raise FileNotFoundError("vmlinuz-linux not found in /boot")

    initrd = None
    for i in [os.path.join(build_dir, "initramfs-linux.img"), "/boot/initramfs-linux.img"]:
        if os.path.isfile(i):
            initrd = i
            break
    if not initrd:
        raise FileNotFoundError("initramfs-linux.img not found in build/ or /boot")

    bootloader = None
    for b in [
        "/var/lib/cartilage/rootfs/usr/lib/systemd/boot/efi/systemd-bootx64.efi",
        "/usr/lib/systemd/boot/efi/systemd-bootx64.efi",
    ]:
        if os.path.isfile(b):
            bootloader = b
            break
    if not bootloader:
        raise FileNotFoundError("systemd-bootx64.efi not found")

    print("=" * 60)
    print(f"[cartilage] Composing Multi-Boot UEFI Disk: {output_img}")
    print(f"[cartilage] Kernel: {kernel} | Initrd: {initrd}")
    for idx, (name, title, path) in enumerate(cartridge_entries, 1):
        print(f"[cartilage] Cartridge {idx} (PARTLABEL=CART{idx}): {title} -> {os.path.basename(path)}")
    print("=" * 60)

    # Temporary directory for intermediate files on the repository build filesystem
    temp_dir = tempfile.mkdtemp(prefix="cartilage_compose_", dir=build_dir)
    try:
        esp_img = os.path.join(temp_dir, "esp.img")
        data_img = os.path.join(temp_dir, "data.img")
        raw_disk = os.path.join(temp_dir, "disk.raw")

        # Step 1: Create ESP (128MB FAT32)
        print("[cartilage] -> Formatting ESP (128MB FAT32)...")
        subprocess.run(["mkfs.vfat", "-F", "32", "-n", "CARTBOOT", "-C", esp_img, "131072"], check=True, stdout=subprocess.DEVNULL)
        subprocess.run(["mmd", "-i", esp_img, "::EFI", "::EFI/BOOT", "::loader", "::loader/entries"], check=True)
        subprocess.run(["mcopy", "-i", esp_img, bootloader, "::EFI/BOOT/BOOTX64.EFI"], check=True)
        subprocess.run(["mcopy", "-i", esp_img, kernel, "::vmlinuz-linux"], check=True)
        subprocess.run(["mcopy", "-i", esp_img, initrd, "::initramfs-linux.img"], check=True)

        startup_nsh = os.path.join(temp_dir, "startup.nsh")
        with open(startup_nsh, "w") as f:
            f.write("\\EFI\\BOOT\\BOOTX64.EFI\n")
        subprocess.run(["mcopy", "-i", esp_img, startup_nsh, "::startup.nsh"], check=True)

        loader_conf = os.path.join(temp_dir, "loader.conf")
        default_entry = f"{cartridge_entries[0][0]}.conf"
        with open(loader_conf, "w") as f:
            f.write(f"default {default_entry}\ntimeout 5\nconsole-mode max\n")
        subprocess.run(["mcopy", "-i", esp_img, loader_conf, "::loader/loader.conf"], check=True)

        for idx, (name, title, _) in enumerate(cartridge_entries, 1):
            entry_file = os.path.join(temp_dir, f"{name}.conf")
            with open(entry_file, "w") as f:
                f.write(
                    f"title {title}\n"
                    f"linux /vmlinuz-linux\n"
                    f"initrd /initramfs-linux.img\n"
                    f"options root=PARTLABEL=CART{idx} rootfstype=erofs ro quiet loglevel=3 console=tty1 console=ttyS0 host_passcode=cartilage42\n"
                )
            subprocess.run(["mcopy", "-i", esp_img, entry_file, f"::loader/entries/{name}.conf"], check=True)

        # Step 2: Create CARTDATA (256MB ext4)
        print("[cartilage] -> Formatting CARTDATA partition (256MB ext4)...")
        subprocess.run(["truncate", "-s", "256M", data_img], check=True)
        subprocess.run(["mkfs.ext4", "-F", "-L", "CARTDATA", data_img], check=True, stdout=subprocess.DEVNULL)

        # Step 3: Compute sectors and partitions
        SECTOR_SIZE = 512
        SECTORS_PER_MIB = 2048
        current_sector = 2048  # 1 MiB alignment

        esp_sectors = os.path.getsize(esp_img) // SECTOR_SIZE
        # Round up to 1 MiB boundary
        esp_sectors = ((esp_sectors + SECTORS_PER_MIB - 1) // SECTORS_PER_MIB) * SECTORS_PER_MIB
        esp_start = current_sector
        current_sector += esp_sectors

        cart_partitions = []
        for idx, (_, _, path) in enumerate(cartridge_entries, 1):
            cart_sectors = os.path.getsize(path) // SECTOR_SIZE
            cart_sectors = ((cart_sectors + SECTORS_PER_MIB - 1) // SECTORS_PER_MIB) * SECTORS_PER_MIB
            cart_partitions.append((f"CART{idx}", current_sector, cart_sectors, path))
            current_sector += cart_sectors

        data_sectors = os.path.getsize(data_img) // SECTOR_SIZE
        data_sectors = ((data_sectors + SECTORS_PER_MIB - 1) // SECTORS_PER_MIB) * SECTORS_PER_MIB
        data_start = current_sector
        current_sector += data_sectors

        total_sectors = current_sector + 2048
        total_size_bytes = total_sectors * SECTOR_SIZE

        print(f"[cartilage] -> Creating raw disk image ({total_size_bytes // (1024*1024)} MiB)...")
        subprocess.run(["truncate", "-s", str(total_size_bytes), raw_disk], check=True)

        # Write GPT partition table using sfdisk
        sfdisk_script = (
            "label: gpt\n"
            f"label-id: {os.urandom(16).hex().upper()[:8]}-0000-4000-8000-000000000001\n\n"
            f"start={esp_start}, size={esp_sectors}, type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B, name=\"CARTBOOT\"\n"
        )
        for label, start, size, _ in cart_partitions:
            sfdisk_script += f"start={start}, size={size}, type=0FC63DAF-8483-4772-8E79-3D69D8477DE4, name=\"{label}\"\n"
        sfdisk_script += f"start={data_start}, size={data_sectors}, type=0FC63DAF-8483-4772-8E79-3D69D8477DE4, name=\"CARTDATA\"\n"

        subprocess.run(["sfdisk", "--no-reread", raw_disk], input=sfdisk_script.encode(), check=True, stdout=subprocess.DEVNULL)

        # Copy data blocks into raw disk
        print("[cartilage] -> Writing partition blocks into disk...")
        subprocess.run(["dd", f"if={esp_img}", f"of={raw_disk}", f"seek={esp_start}", "bs=512", "conv=notrunc", "status=none"], check=True)
        for _, start, _, path in cart_partitions:
            subprocess.run(["dd", f"if={path}", f"of={raw_disk}", f"seek={start}", "bs=512", "conv=notrunc", "status=none"], check=True)
        subprocess.run(["dd", f"if={data_img}", f"of={raw_disk}", f"seek={data_start}", "bs=512", "conv=notrunc", "status=none"], check=True)

        # Move to output path
        os.makedirs(os.path.dirname(os.path.abspath(output_img)), exist_ok=True)
        shutil.move(raw_disk, output_img)
        print(f"[cartilage] Multi-boot image composed successfully: {output_img} ({os.path.getsize(output_img) // (1024*1024)} MiB)")
        return output_img

    finally:
        shutil.rmtree(temp_dir, ignore_errors=True)
