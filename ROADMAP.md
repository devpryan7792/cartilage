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

## Phase 4: The Dynamic Hub & Developer Workstation [COMPLETED]
*Goal: Transform Cartilage into a complete daily development and utility platform via the Ventoy-style drag-and-drop Hub and simultaneous Terminal + Browser execution.*

### Milestone 4.1: Dynamic Hub Bootstrap Loader (`initramfs-hub.img`)
- [x] Implemented early userspace bootstrap script (`src/cartilage/hub_loader.sh`):
  - Detects partition labeled `CARTRIDGES` (exFAT).
  - Mounts exFAT in-kernel via `exfat.ko`.
  - Discovers `/cartridges/*.img` payloads.
  - Automatically boots single cartridge or renders an instant (<100ms) TTY text boot selector with 3s timeout.
  - Mounts selected cartridge via loopback: `mount -t erofs -o loop,ro /mnt/hub/cartridges/<app>.img /sysroot`.
  - Mounts persistent ext4 loop file: `mount -t ext4 -o loop,rw /mnt/hub/data/data.img /sysroot/data`.
  - Performs `switch_root /sysroot /init` (verified 1.005s boot latency).

### Milestone 4.2: Dynamic Hub Disk Formatting CLI (`cartilage init-hub`)
- [x] Added `cartilage init-hub --target /dev/sdX` subcommand to `flasher.py`:
  - Strict block device safety verification (refuses internal SATA/NVMe without `--force-internal`).
  - Creates 2-partition GPT layout: 256 MB FAT32 ESP (`CARTBOOT`) + remainder exFAT (`CARTRIDGES`).
  - Pre-creates `/cartridges/` directory for drag-and-drop image placement.
  - Generates sparse 512 MB ext4 image at `/data/data.img` for POSIX user persistence.
  - Installs `vmlinuz-linux` and `initramfs-hub.img` onto the ESP.
  - Added headless 0.8s QEMU micro-VM populator for rootless exFAT formatting without `sudo`.

### Milestone 4.3: Developer Workstation Appliance (`recipes/workstation-dev.yaml`)
- [x] Created unified developer workstation recipe:
  - Compositor: C-based dynamic tiling Wayland compositor (`dwl` v0.9, <15 MB RAM).
  - Packages: `dwl`, `foot`, `dillo`, `seatd`.
  - Configures Workspace 1 (Terminal) and Workspace 2 (Browser) with instant keybinding toggle (`Alt+1` / `Alt+2`).
  - Measured idle RAM at **264 MB** total active memory on 1GB virtual machine, leaving >680 MB free memory.

### Milestone 4.4: Automated Test Suite & Bare-Metal Matrix
- [x] Updated `scripts/15_test_cartilage_cli.sh` to include Hub formatting dry-run (Test 9), Workstation Duo boot (Test 10), and Dynamic Hub UEFI boot (Test 11).
- [x] Benchmarked cold boot latency: Mode 1 (1.8s) vs. Mode 2 (1.005s to loop-mount).
- [x] All 11 tests passing cleanly (13/13 test assertions).

---

## Phase 5: Multi-Compositor Choice & Workstation Ergonomics [COMPLETED]
*Goal: Provide users with granular compositor choice across single-app kiosks and multi-window workstations, supporting cage, dwl, and sway (i3).*

### Milestone 5.1: Three-Tier Compositor Architecture
- [x] Enforce compositor behavioral semantics:
  - **`cage`**: Locked single-application kiosk mode (strictly 1 window/app, shell masked to `/dev/null`, ~5 MB RAM).
  - **`dwl`**: Ultra-lean C-based dynamic tiling (dwm for Wayland; <15 MB RAM, tags 1–9, unmasked `/bin/bash` for interactive developer shells).
  - **`sway`**: Full i3-compatible tiling window manager (~35–45 MB RAM, workspaces 1–10, split containers, floating windows, i3-ipc, unmasked `/bin/bash`).
- [x] Implement validator constraint: warn or reject if `cage` is assigned to multi-application sessions or workstation recipes.

### Milestone 5.2: Declarative & CLI Compositor Selection
- [x] Schema validation update for `display.compositor`: enum `["cage", "dwl", "sway", "none"]`.
- [x] Add CLI flag `--compositor` to `cartilage build` and `cartilage run` to allow on-the-fly compositor switching.
- [x] Implement rootless `sway` packaging and minimal Cartilage i3 configuration (`/etc/cartilage/sway.conf`).

### Milestone 5.3: Workstation Recipe Suite
- [x] Maintain `recipes/workstation-dev.yaml` with `dwl` default for low-memory appliances (<300 MB RAM).
- [x] Create `recipes/workstation-i3.yaml` with `sway` for full i3-compatible developer workflows.

### Milestone 5.4: Test Suite & Matrix Expansion
- [x] Extend `scripts/15_test_cartilage_cli.sh` to verify `cage`, `dwl`, and `sway` builds and launches (14/14 tests passing).
- [x] Record benchmark memory and latency matrix comparing all three compositor targets.

---

## Phase 6: Ecosystem, OCI Container Import & Appliance Distribution [PLANNED]
*Goal: Expand Cartilage OS from local builds into a frictionless ecosystem with OCI image translation and remote cartridge distribution.*

### Milestone 6.1: OCI Container to Cartridge Importer (`cartilage import-docker`)
- [ ] Parse Docker/OCI rootfs layers and convert directly into immutable EROFS cartridges.
- [ ] Automatically synthesize declarative recipe manifests from container metadata (`CMD`, `ENV`, `EXPOSE`).

### Milestone 6.2: Remote Cartridge Hub & Package Distribution (`cartilage pull`)
- [ ] Implement zero-dependency HTTP/HTTPS download engine with sha256 checksum verification.
- [ ] Enable 1-command appliance fetching: `./cartilage pull devpryan7792/workstation-i3`.

### Milestone 6.3: Interactive TUI Hub Configurator
- [ ] Early-userspace dialog/curses configuration menu for Mode 2 Dynamic Hub.
- [ ] Wi-Fi network selection and persistent credential storage in `/data`.

