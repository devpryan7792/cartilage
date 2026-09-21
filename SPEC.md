# Cartilage OS — Acceptance Specification (SPEC.md)

This document defines the **concrete acceptance criteria and verification commands** for Cartilage OS.
- `ARCHITECTURE.md` defines *what* to build and *why*.
- `ROADMAP.md` and `AGENT_TASKS.md` define *what order*.
- **This file defines how you know each task is objectively done.**

Every task ends with a verifiable test command whose output you check. There are no judgment calls or "looks right" approvals.

---

## Part 1: Core Foundation & Runtimes (Completed & Verified)

### Task 1 — Base Rootfs Construction
**Done when:**
- Unprivileged base rootfs extraction succeeds with exit code 0.
- Rootfs contains valid Linux directory tree (`/usr`, `/bin`, `/lib`).
- Booting raw rootfs in QEMU produces visible console output with no kernel panic.

### Task 2 — Cartridge Packaging (Module 2)
**Done when:**
- `mkfs.erofs -zlz4hc,12` compiles an immutable EROFS image without `sudo`.
- Loop-mounting read-only succeeds: `fsck.erofs` validates filesystem structure.
- Booting in QEMU launches `cage` and target application full-screen.

### Task 3 — Ephemeral Storage Mode
**Done when:**
- OverlayFS combines EROFS lowerdir with `tmpfs` upperdir.
- `size=` quota on tmpfs limits download capacity; `zram` compressed memory swap is active (`zramctl`).
- Filling quota results in clean `ENOSPC` (disk full) error, never kernel OOM panic.

### Task 4 — Persistent Storage Mode
**Done when:**
- Second virtual disk (or loop file) formatted as ext4 is bound to `/data`.
- Files written to `/data` survive VM reboot and remain intact.

### Task 5 — Host Access Mode & NTFS Dirty-Bit Gate
**Done when:**
- Internal host partitions are mounted read-only under hidden path (`/mnt/hidden_host`).
- Physical entry of Passcode (`cartilage42`) unlocks write access to chosen folder via `unshare -m`.
- If an NTFS partition has its dirty/hibernation bit set, write mount is loudly rejected on TTY with remediation steps.

---

## Part 2: Appliance Framework & Platform Layer (Completed & Verified)

### Task 6 — Unified CLI Engine (`./cartilage`)
**Done when:**
- `./cartilage --help` executes cleanly using standard Python (zero external pip dependencies).
- `cartilage validate recipes/*.yaml` verifies manifests against `spec/cartilage.schema.json`.

### Task 7 — Pure-Python Rootless Builder (`cartilage build`)
**Done when:**
- Running `./cartilage build recipes/<recipe>.yaml` extracts base image via `fsck.erofs`, resolves packages rootlessly, injects stages, and compiles with `mkfs.erofs --all-root -zlz4hc,12`.
- Operates 100% in unprivileged userspace (zero `sudo`).

### Task 8 — Modular `/init.d/` Stage Sequencing
**Done when:**
- Root filesystem uses modular stages: `00-vfs.sh`, `10-hardware.sh`, `20-network.sh`, `30-storage.sh`, `40-security.sh`, `50-launch.sh`.
- PID 1 executes stages sequentially and logs progress cleanly.
- Corrupted or missing storage triggers graceful fallback to memory OverlayFS without kernel panic.

### Task 9 — Universal ALSA `dmix` Audio
**Done when:**
- `/run/asound.conf` configures `type dmix` on default audio card.
- Two audio processes can output sound simultaneously without PulseAudio or PipeWire daemons.
- Verified with `speaker-test` or MPV live audio playback.

### Task 10 — Mode 1 Multi-Boot UEFI Disk Composition (`cartilage compose`)
**Done when:**
- `./cartilage compose -o build/cartilage_combined.img recipes/*.yaml` generates a 7-partition GPT image with `systemd-boot`.
- QEMU with OVMF firmware displays the interactive bootloader menu listing all appliances.
- Selecting any appliance boots directly into that appliance's Wayland session.

---

## Part 3: Phase 4 Evolution — The Dynamic Hub & Workstation Duo (Active)

### Task 11 — Mode 2 Dynamic Hub Disk Initialization (`cartilage init-hub`)
**Done when:**
- Running `./cartilage init-hub --target /dev/sdX` safely inspects block device:
  - Rejects internal SATA/NVMe drives automatically unless forced.
  - Writes GPT partition table with 2 partitions:
    - Partition 1: `CARTBOOT` (256 MB FAT32 ESP, Type `EF00`).
    - Partition 2: `CARTRIDGES` (exFAT, Type `0700`, occupying rest of drive).
  - Creates directories on exFAT: `/cartridges/` and `/data/`.
  - Creates sparse 512 MB ext4 image at `/data/data.img`.
- Disk is immediately mountable and readable natively on Windows, macOS, and Linux.

**Test command:**
```bash
./cartilage init-hub --dry-run /dev/null
```
Pass = Partition offsets calculated, exFAT payload structure defined, zero errors.

---

### Task 12 — Mode 2 Dynamic Bootstrap Loader (`initramfs-hub.img`)
**Done when:**
- Bootstrap initramfs detects block device with label `CARTRIDGES`.
- Mounts exFAT partition in-kernel via `exfat.ko`.
- Dynamically discovers all `*.img` files in `/cartridges/`:
  - If 1 cartridge: boots immediately.
  - If multiple cartridges: renders instant TTY text menu.
- Successfully mounts chosen cartridge via loopback:
  ```bash
  mount -t erofs -o loop,ro /mnt/hub/cartridges/<chosen>.img /sysroot
  ```
- Loop-mounts `/mnt/hub/data/data.img` (ext4) to `/sysroot/data`.
- Executes `switch_root /sysroot /init` into the target appliance without errors.

**Test command:**
```bash
qemu-system-x86_64 -enable-kvm -cpu host -m 1024M -smp 2 \
  -drive file=build/cartilage_hub.img,format=raw,if=virtio \
  -device virtio-vga -display none -serial stdio
```
Pass = Discovers cartridges from exFAT, loop-mounts, launches Wayland appliance.

---

### Task 13 — Developer Workstation Appliance (`workstation-dev.yaml`)
**Done when:**
- `recipes/workstation-dev.yaml` declares a multi-window tiling Wayland compositor (`sway` or `dwl`).
- Launches `foot` terminal on Workspace 1 and web browser (`chromium` or `dillo`) on Workspace 2.
- User can toggle between Terminal and Browser (`Mod+1` / `Mod+2`) with zero reboot delay.
- **Physical Memory Benchmark on 2GB Target**:
  - Total active system memory under 800 MB RAM.
  - Leaves >1.2 GB free memory for developer compilation and buffer cache.

**Test command:**
```bash
./cartilage run recipes/workstation-dev.yaml --append "cartilage_benchmark=1" -v
```
Pass = Idle RAM measured under 800 MB, both Foot and Browser operational.
