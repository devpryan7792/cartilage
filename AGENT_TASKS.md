# Cartilage OS — Agent Task Breakdown

Feed this task breakdown to Antigravity alongside `ARCHITECTURE.md` and `SPEC.md`. Work sequentially top to bottom.
Each task must end with a verifiable test command whose output is objectively validated.

---

## Part 1 — Base Rootfs Construction [`skills/01-toolchain-setup.md`]
- [x] Script `pacstrap`-based minimal rootfs build (base + linux + firmware)
- [x] Verify `arch-chroot` access into the built rootfs
- [x] Boot the raw rootfs in QEMU with `init=/bin/sh`, confirm a shell

## Part 2 — Cartridge Packaging [`skills/02-cartridge-builder.md`]
- [x] Install `seatd`, `cage`, Mesa into the rootfs
- [x] Write `/init`: mount proc/sys/dev, start `seatd`, exec `cage -- <app>`
- [x] Remove docs/locales, strip binaries — do NOT remove `/bin/bash`
- [x] Pack rootfs into EROFS with `mkfs.erofs`
- [x] Loop-mount the `.img`, boot in QEMU with virtio-gpu, confirm full-screen GUI

## Part 3 — Storage: Ephemeral Mode [`skills/03-storage-isolation.md`]
- [x] OverlayFS: lowerdir = EROFS cartridge, upperdir/workdir = tmpfs
- [x] Enforce `size=` cap on tmpfs; point XDG_DOWNLOAD_DIR at quota'd sub-mount
- [x] Compile/enable `zram` with zstd, confirm it's active (`zramctl`)
- [x] Checkpoint: fill download quota, confirm clean `ENOSPC` failure without OOM panic

## Part 4 — Storage: Persistent Mode [`skills/03-storage-isolation.md`]
- [x] Add second virtual disk in QEMU representing USB data partition
- [x] `mount --bind` that partition into the app's `/data`
- [x] Checkpoint: write file inside app, reboot VM, confirm file survived

## Part 5 — Storage: Host Access Mode [`skills/03-storage-isolation.md`]
- [x] Global hidden `ro` mount of host virtual disk on boot
- [x] TTY passcode prompt (`cartilage42`)
- [x] On successful auth: `unshare -m` + `mount --bind /mnt/hidden_host/<dir> /app/workspace`
- [x] NTFS dirty-bit / BitLocker detection: on write request against dirty volume, hard-fail with clear remediation message
- [x] Checkpoint: demonstrate happy path (clean NTFS) and failure path (dirty NTFS)

## Part 6 — Builder CLI & Modular Pipeline [`skills/02-cartridge-builder.md`]
- [x] Pure-Python rootless builder (`src/cartilage/builder.py`) with zero pip dependencies
- [x] Modular `/init.d/` stage sequencer (`00-vfs`, `10-hardware`, `20-network`, `30-storage`, `40-security`, `50-launch`)
- [x] Checkpoint: run `cartilage build` rootlessly without `sudo`

## Part 7 — Audio Subsystem & Hardware Platform [`skills/04-boot-pipeline.md`]
- [x] Universal ALSA `dmix` hardware software mixing in `stages/10-hardware.sh`
- [x] Pre-baked fontconfig cache on writable tmpfs to eliminate font scanning delays
- [x] VirtIO sound auto-detection and unprivileged audio group permissions
- [x] Checkpoint: multi-client audio verified concurrently in guest

## Part 8 — Appliance Fleet Expansion
- [x] `recipes/terminal-foot.yaml`: Minimalist Wayland terminal (85 MB RAM, 1.8s boot)
- [x] `recipes/media-vlc.yaml`: Universal Qt5 media player with GUI controls & ALSA audio
- [x] `recipes/media-mpv.yaml`: Minimalist video playback engine
- [x] `recipes/browser-chromium.yaml`: Modern Chromium web kiosk
- [x] `recipes/browser-dillo.yaml`: Ultra-compact FLTK browser
- [x] `recipes/editor-mousepad.yaml`: Focused text editor (44.6 MB Alpine musl runtime)

## Part 9 — Mode 1 UEFI GPT Multi-Boot Composer [`skills/04-boot-pipeline.md`]
- [x] Assembles multiple cartridges into unified 3.6 GiB UEFI GPT disk image
- [x] Formats ESP (128 MB FAT32) with `systemd-boot`, kernel, and initramfs
- [x] Checkpoint: boots in QEMU via OVMF, presents interactive 5-appliance menu

## Part 10 — Legal Compliance & Licensing
- [x] Official OSI/SPDX MIT `LICENSE` with statutory "AS IS" limitation of liability
- [x] Comprehensive `ATTRIBUTION.md` covering all 15 upstream open-source components
- [x] Nominative Fair Use trademark disclaimers (Nintendo, Game Boy, VideoLAN, Google, Microsoft)

---

## Part 11 — Mode 2 Dynamic Hub Disk Formatter (Completed)
- [x] Add `cartilage init-hub --target <device>` to `src/cartilage/flasher.py`
- [x] Implement safety check: reject internal SATA/NVMe drives unless `--force-internal`
- [x] Format 2-partition GPT layout:
  - Part 1: `CARTBOOT` (256 MB FAT32 ESP, Type `EF00`)
  - Part 2: `CARTRIDGES` (exFAT, Type `0700`, remainder of drive)
- [x] Create initial exFAT directory structure: `/cartridges/` and `/data/`
- [x] Generate sparse 512 MB ext4 image at `/data/data.img`
- [x] Checkpoint: `./cartilage init-hub --dry-run /dev/null` outputs verified partition offsets

## Part 12 — Mode 2 Dynamic Bootstrap Loader (`initramfs-hub.img`) (Completed)
- [x] Create early userspace bootstrap script (`src/cartilage/hub_loader.sh`)
- [x] Mount block device labeled `CARTRIDGES` via in-kernel `exfat.ko`
- [x] Scan `/mnt/hub/cartridges/*.img`:
  - 1 cartridge: boot immediately
  - Multiple: render lightweight TTY text menu
- [x] Mount chosen cartridge via loopback: `mount -t erofs -o loop,ro <path> /sysroot`
- [x] Mount persistent data loop file: `mount -t ext4 -o loop,rw /mnt/hub/data/data.img /sysroot/data`
- [x] Execute `switch_root /sysroot /init`
- [x] Checkpoint: QEMU boots `cartilage_hub.img`, discovers cartridges from exFAT, launches app

## Part 13 — Developer Workstation Appliance (`workstation-dev.yaml`) (Completed)
- [x] Create `recipes/workstation-dev.yaml`
- [x] Configure lightweight tiling Wayland compositor (`dwl` v0.9)
- [x] Bind Workspace 1 to `foot` and Workspace 2 to `chromium`/`dillo`
- [x] Verify hotkey workspace toggle (`Alt+1` <-> `Alt+2`) with zero reboot delay
- [x] Checkpoint: verify active memory usage remains under 800 MB on 2GB virtual machine (Measured: 264 MB)

## Part 14 — End-to-End Verification & Documentation Update (Completed)
- [x] Update `scripts/15_test_cartilage_cli.sh` with Hub dry-run and loader tests (Tests 9, 10, 11)
- [x] Run benchmark suite comparing Mode 1 (raw block) vs. Mode 2 (exFAT loopback)
- [x] Update `README.md` and `walkthrough.md` with Mode 2 instructions and workstation demo
