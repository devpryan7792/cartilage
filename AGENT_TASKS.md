# Cartilage OS — Agent Task Breakdown

Feed this to Antigravity alongside `ARCHITECTURE.md`. Work top to bottom.
Each task should end with a verifiable checkpoint (boots in QEMU, produces
a file, passes a check) — not "looks right."

Before starting **any** task, the agent should load the matching skill file
from `skills/` referenced in brackets.

## Part 1 — Base rootfs [`skills/01-toolchain-setup.md`]
- [x] Script `pacstrap`-based minimal rootfs build (base + linux + firmware)
- [x] Verify `arch-chroot` access into the built rootfs
- [x] Boot the raw rootfs in QEMU with `init=/bin/sh`, confirm a shell

## Part 2 — Cartridge packaging [`skills/02-cartridge-builder.md`]
- [x] Install `seatd`, `cage`, Mesa into the rootfs
- [x] Write `/init`: mount proc/sys/dev, start `seatd`, exec `cage -- <app>`
- [x] Remove docs/locales, strip binaries — do NOT remove `/bin/bash`
- [x] Pack rootfs into EROFS with `mkfs.erofs`
- [x] Loop-mount the `.img`, boot in QEMU with virtio-gpu, confirm one
      trivial GUI app renders full-screen

## Part 3 — Storage: Ephemeral mode [`skills/03-storage-isolation.md`]
- [x] OverlayFS: lowerdir = EROFS cartridge, upperdir/workdir = tmpfs
- [x] Enforce `size=` cap on tmpfs; point XDG_DOWNLOAD_DIR at a
      hard-quota'd sub-mount
- [x] Compile/enable `zram` with zstd, confirm it's active (`zramctl`)
- [x] Checkpoint: fill the download quota inside the booted cartridge,
      confirm a clean "disk full" failure, not an OOM/kernel panic

## Part 4 — Storage: Persistent mode [`skills/03-storage-isolation.md`]
- [x] Add a second virtual disk in QEMU representing the USB data
      partition
- [x] `mount --bind` that partition into the app's `/data`
- [x] Checkpoint: write a file from inside the app, reboot the VM, confirm
      the file survived

## Part 5 — Storage: Host Access mode [`skills/03-storage-isolation.md`]
- [x] Global hidden `ro` mount of the "host" virtual disk on boot
- [x] TTY passcode prompt (reuse across Parts 5 and 7 — one auth codepath)
- [x] On successful auth: `unshare -m` + `mount --bind
      /mnt/hidden_host/<chosen dir> /app/workspace`
- [x] NTFS dirty-bit / BitLocker detection: on write request against a
      dirty/encrypted volume, hard-fail with the documented error message,
      drop to `ro`
- [x] Checkpoint: demonstrate both the happy path (clean NTFS, write
      succeeds) and the failure path (dirty NTFS, loud correct error)

## Part 6 — Builder CLI [`skills/02-cartridge-builder.md`]
- [x] Wrap Parts 1–2 into `build_cartridge.sh --app <name> --runtime arch`
- [x] Accept either a package name (repo/AUR) or a path to a `.deb`
- [x] Checkpoint: run it twice for two different apps, get two correctly
      distinct `.img` outputs with no manual steps in between

## Part 7 — Boot menu integration [`skills/04-boot-pipeline.md`]
- [x] Build one combined USB image: shared kernel/firmware partition +
      bootloader config listing both cartridges + data partition
- [x] Checkpoint: boot combined image in QEMU, select each cartridge from
      the menu, confirm correct app launches for each

## Part 8 — Debug console [`skills/05-debug-console.md`]
- [x] Configure second VT, gate its login behind the same passcode as
      Part 5
- [x] Checkpoint: switch VT from within a running cartridge, authenticate,
      confirm `dmesg`/`ip link` work; confirm the app's own mount
      namespace cannot see or reach this shell

## Part 9 — Benchmarks
- [x] Record boot-to-app time (method: timestamp at power-on vs first
      frame) for both cartridges
- [x] Record idle RAM (`free -h` inside the VM after app is idle)
- [x] Record final `.img` file size for both cartridges
- [x] Write `BENCHMARKS.md` with numbers + exact commands used

## Part 10 — README + demo
- [x] Architecture diagram (ASCII acceptable)
- [x] Screen capture of boot-to-app for both cartridges
- [x] Design-decision write-ups: FUSE vs bind mounts, EROFS vs SquashFS,
      SIGBUS-accepted tradeoff, threat model statement (from
      ARCHITECTURE.md §8)
- [x] Instructions to reproduce in QEMU from a clean checkout

---

# Phase 2 — Production Bare-Metal Appliance

## Part 11 — Network & DNS Subsystem
- [x] Add network initialization hook to `/init` (udevadm settle + interface link up)
- [x] Add lightweight DHCP background client (`dhcpcd` or `udhcpc`) with 3s non-blocking fallback
- [x] Symlink `/etc/resolv.conf` to `/run/resolv.conf` (tmpfs) and seed with fallback anycast DNS
- [x] Checkpoint: `bash scripts/10_test_networking.sh` passes (DNS lookup + HTTP GET)

## Part 12 — Audio Subsystem
- [x] Configure ALSA `dmix` multi-stream plugin in `/etc/asound.conf`
- [x] Ensure user `cartilage` is in group `audio` with proper device permissions (`0660`)
- [x] Checkpoint: `bash scripts/11_test_audio.sh` passes (ALSA PCM open and sound test)


## Part 13 — Modern Web Kiosk Runtime (Chromium)
- [x] Configure Chromium Ozone Wayland launch flags in `build_cartridge.sh`
- [x] Enable `sysctl kernel.unprivileged_userns_clone=1` for Chromium zygote sandbox
- [x] Mount 512MB tmpfs on `/dev/shm`
- [x] Pre-bake fontconfig cache during build
- [x] Checkpoint: `bash scripts/12_test_chromium.sh` passes (Wayland kiosk renders page)

## Part 14 — Bare-Metal USB Flasher Script
- [x] Write `scripts/13_flash_usb.sh` with block device safety inspection
- [x] Create GPT layout: ESP (FAT32), EROFS Cartridges, and `CARTDATA` partition
- [x] Install UEFI fallback bootloader `\EFI\BOOT\BOOTX64.EFI`
- [x] Update bootloader configs to use PARTLABEL routing
- [x] Checkpoint: `bash scripts/13_test_flasher.sh` passes (booting flashed disk image)

## Part 15 — Alpine Lightweight Runtime
- [x] Integrate static `apk` toolchain into `build_cartridge.sh` (`--runtime alpine`)
- [x] Construct ultra-lean rootfs template with `musl`, `cage`, `seatd`
- [x] Checkpoint: `bash scripts/14_test_alpine_cartridge.sh` passes (output .img < 50MB)

---

# Phase 3 — The Cartilage Appliance Framework ("The Bigger Shift")

## Part 16 — Declarative Appliance Specification
- [ ] Author `spec/cartilage.schema.json` with strict validation rules
- [ ] Implement schema validation for runtime, display, storage, hardware blocks
- [ ] Checkpoint: Schema validates valid manifests and rejects invalid syntax

## Part 17 — The Unified `cartilage` CLI Engine
- [ ] Create `src/cartilage/` Python package (zero external dependencies)
- [ ] Implement commands: `validate`, `build`, `run`, `compose`, `flash`
- [ ] Auto-map QEMU flags directly from manifest (eliminate duplicate shell/bat scripts)
- [ ] Checkpoint: `python3 -m cartilage --help` and command dispatch pass

## Part 18 — Modular `/init.d/` Stage Runner
- [ ] Extract monolithic 600-line `/init` heredoc into modular stage scripts (`/init.d/00-vfs.sh` through `50-launch.sh`)
- [ ] Add fault-tolerant error boundaries (OverlayFS fallback on ro media, software rasterizer fallback)
- [ ] Checkpoint: EROFS image boots through all 6 stages sequentially with zero kernel panic points

## Part 19 — Standard Recipe Hub
- [ ] Author `recipes/browser-chromium.yaml`
- [ ] Author `recipes/browser-dillo.yaml`
- [ ] Author `recipes/editor-mousepad.yaml`
- [ ] Author `recipes/terminal-foot.yaml`
- [ ] Checkpoint: `cartilage validate recipes/*.yaml` passes

## Part 20 — Universal Bare-Metal Portability & USB Flash Engine
- [ ] Add universal GPU auto-detection (Intel `i915`, AMD `amdgpu`, VirtIO) with software fallback
- [ ] Implement safe, interactive block device flashing in `cartilage flash`
- [ ] Checkpoint: `cartilage flash --dry-run /dev/null recipes/browser-dillo.yaml` succeeds


