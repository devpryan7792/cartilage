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
