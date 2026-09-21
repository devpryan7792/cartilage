# Cartilage OS — Strategic Roadmap

This document outlines the evolutionary phases of Cartilage OS, tracking completed engineering milestones and defining active architecture deliverables.

---

## Phase 1: Proof of Concept & Minimal Physics [COMPLETED]
*Goal: Prove that a bare Linux kernel and EROFS can boot an interactive Wayland session in ~1 second without systemd.*
- [x] Scripted minimal `pacstrap` base rootfs build (`base`, `linux`, `linux-firmware`).
- [x] Verified `arch-chroot` environment and unprivileged user setup.
- [x] Implemented minimal `/init` script driving `seatd` and `cage` compositor over kernel DRM/KMS.
- [x] Packed rootfs into immutable EROFS image with `mkfs.erofs`.
- [x] Verified sub-1.5s cold boot in QEMU with direct KMS rendering.

---

## Phase 2: Dual Runtimes & Stabilization (v2.0) [COMPLETED]
*Goal: Expand beyond a single demo into lightweight runtimes, storage modes, and modern web capabilities.*
- [x] Implemented Alpine Linux runtime (`musl` libc, `apk` package manager), dropping base appliance size to **44.6 MB** and cold boot latency to **2.1s**.
- [x] Implemented Ephemeral Mode: OverlayFS with memory-quota `tmpfs` upperdir and `zram` (zstd) compressed memory swap.
- [x] Implemented Persistent Mode: Secondary ext4 data disk bound to `/data`.
- [x] Implemented Host Access Mode: Hidden read-only host mount with TTY Developer Passcode gate (`cartilage42`) and loud rejection of dirty Windows NTFS partitions.
- [x] Verified Chromium Modern Web Kiosk: Ozone Wayland rendering and nested unprivileged user namespaces.

---

## Phase 3: Universal Appliance Platform [COMPLETED]
*Goal: Replace procedural shell scripts with an engineered, declarative appliance engine and unified CLI.*
- [x] **Unified CLI Engine (`./cartilage`)**: Zero-dependency Python CLI (`validate`, `build`, `run`, `compose`, `flash`) with standard JSON Schema validation.
- [x] **Modular `/init.d/` Stage Runner**: Sequential, fault-tolerant stage dispatcher (`00-vfs`, `10-hardware`, `20-network`, `30-storage`, `40-security`, `50-launch`) with automatic memory OverlayFS fallback on storage errors.
- [x] **Pure-Python Rootless Compiler (`builder.py`)**: Rootless base extraction via `fsck.erofs`, unprivileged package ingestion, account baking (`cartilage:1000:1000`), and `mkfs.erofs --all-root -zlz4hc,12` compilation.
- [x] **Universal ALSA `dmix` Multiplexer**: In-kernel multi-client audio mixing in `stages/10-hardware.sh`, eliminating background PulseAudio/PipeWire daemons.
- [x] **Appliance Fleet Expansion**: Built and physically verified 6 appliances:
  - `terminal-foot`: Minimalist Wayland terminal (85 MB idle RAM, 1.8s boot)
  - `media-vlc`: Universal Qt5 media player with GUI controls & ALSA audio (340 MB RAM, 2.8s boot)
  - `media-mpv`: Minimalist video playback engine (120 MB RAM, 2.5s boot)
  - `editor-mousepad`: Focused text editor (44.6 MB Alpine image, 57.6 MB RAM)
  - `browser-dillo`: Ultra-compact web browser (528 MB image, 285 MB RAM)
  - `browser-chromium`: Modern web kiosk (844 MB image, 552 MB RAM)
- [x] **Mode 1 Multi-Boot UEFI GPT Composer**: Composed all appliances into a unified 3.6 GiB UEFI GPT disk image with `systemd-boot`.

---

## Phase 4: The Dynamic Hub & Developer Workstation [ACTIVE]
*Goal: Transform Cartilage into a complete daily development and utility platform via the Ventoy-style drag-and-drop Hub and simultaneous Terminal + Browser execution.*

### Milestone 4.1: Dynamic Hub Bootstrap Loader (`initramfs-hub.img`)
- [ ] Implement early userspace bootstrap script:
  - Detects partition labeled `CARTRIDGES` (exFAT).
  - Mounts exFAT in-kernel via `exfat.ko`.
  - Discovers `/cartridges/*.img` payloads.
  - Automatically boots single cartridge or renders an instant (<100ms) TTY text boot selector.
  - Mounts selected cartridge via loopback: `mount -t erofs -o loop,ro /mnt/hub/cartridges/<app>.img /sysroot`.
  - Mounts persistent ext4 loop file: `mount -t ext4 -o loop,rw /mnt/hub/data/data.img /sysroot/data`.
  - Performs `switch_root /sysroot /init`.

### Milestone 4.2: Dynamic Hub Disk Formatting CLI (`cartilage init-hub`)
- [ ] Add `cartilage init-hub --target /dev/sdX` subcommand to `flasher.py`:
  - Strict block device safety verification (refuses internal SATA/NVMe).
  - Creates 2-partition GPT layout: 256 MB FAT32 ESP (`CARTBOOT`) + remainder exFAT (`CARTRIDGES`).
  - Pre-creates `/cartridges/` directory for drag-and-drop image placement.
  - Generates sparse 512 MB ext4 image at `/data/data.img` for POSIX user persistence.
  - Installs `vmlinuz-linux` and `initramfs-hub.img` onto the ESP.

### Milestone 4.3: Developer Workstation Appliance (`recipes/workstation-dev.yaml`)
- [ ] Create unified developer workstation recipe:
  - Compositor: Lightweight Wayland tiling compositor (`sway` or `dwl`).
  - Packages: `sway`, `foot`, `chromium` (or `dillo`), `seatd`.
  - Configures Workspace 1 (Terminal) and Workspace 2 (Browser) with keybinding toggle (`Mod+1` / `Mod+2`).
  - Measures idle RAM under 800 MB on 2GB virtual machine, leaving >1.2 GB free memory.

### Milestone 4.4: Automated Test Suite & Bare-Metal Matrix
- [ ] Update `scripts/15_test_cartilage_cli.sh` to include Hub formatting dry-run and bootstrap loader tests.
- [ ] Benchmark cold boot latency and I/O throughput: Raw Partition (Mode 1) vs. Loopback on exFAT (Mode 2).
- [ ] Validate hardware compatibility on real x86_64 machines (Intel UHD, AMD Radeon, USB 2.0/3.0).
