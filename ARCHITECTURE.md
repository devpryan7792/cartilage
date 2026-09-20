# Cartilage OS — Architecture (v1, LOCKED)

**Status: this file overrides any prior discussion, transcript, or chat.** If a
decision here conflicts with something discussed earlier, this file wins. If
this file is silent on something, that thing is out of scope for v1 — do not
invent it.

Cartilage OS is a **build framework**, not an ISO. Its output is
`build_cartridge.sh` producing bootable per-app cartridge images that live
alongside each other on one USB drive under a shared kernel/bootloader.

---

## 1. What v1 is

One USB drive containing:

- A shared bootloader (`systemd-boot` or GRUB — pick one in week 1, don't
  relitigate) that lists one boot entry per cartridge.
- A shared Linux kernel + `linux-firmware` (**bundled in full, always** —
  see §2).
- A `.img` (EROFS) file per app, each containing that app + `cage` (Wayland
  compositor) + `seatd` + the minimal userspace it needs.
- A small data partition (exFAT or ext4) for Persistent Mode and for storing
  the cartridge images themselves.

Boot flow: `firmware → bootloader menu → shared kernel → init script →
seatd → cage → target app`.

## 2. Firmware — no flag, no decision tree

`linux-firmware` is **always bundled**, full, unconditionally. This was
debated and closed: the user who needs the stripped-down variant is never the
user who knows to ask for it. ~400MB on a drive where 2GB total is "using
under 10% of a 32GB stick" is not a real cost. Revisit only after v1 ships
and someone actually complains about size.

## 3. The three modes (Module 3 — storage)

- **Ephemeral**: `tmpfs` upper layer via OverlayFS. Downloads capped hard
  (`size=` quota on the tmpfs, e.g. 10M for XDG_DOWNLOAD_DIR) — no dynamic
  password-escalation mid-session, no overflow partition. `zram` (zstd) is
  compiled into the init for old/low-RAM machines.
- **Persistent**: USB's own data partition kernel-bind-mounted into the
  app's `/data` or `~/Downloads`. Core OS image stays read-only.
- **Host Access**: internal drives mounted `ro` by default under a hidden
  root path invisible to the app. TTY passcode gate unlocks write access to
  a *specific user-chosen subdirectory* via `mount --bind` inside an
  `unshare -m` namespace. **No 15-minute timer, no background revocation
  daemon** — that was explored and explicitly dropped. Access lasts until
  reboot or explicit unmount.
  - **NTFS rule**: if the drive's dirty/hibernation bit is set, or it's
    BitLocker-encrypted, and the user requested write mode — **hard fail
    loud**, drop to read-only, print the exact fix (disable Windows Fast
    Startup) to the TTY. Never silently downgrade without telling the user.
  - FUSE is banned. Everything is kernel bind mounts + mount namespaces.

## 4. The cartridge (Module 2)

- Format: **EROFS**, not SquashFS (better random-read on flash, lower CPU
  decompression cost — matters on old hardware).
- Delivery: loop-mount directly off the USB. No `copytoram`, no internal
  drive pivot (assuming NVMe on old hardware was correctly identified as
  wrong). Rely on the Linux page cache; do not add `mlock()`/`vmtouch`.
- **Accepted risk**: if the USB is physically removed mid-session and an
  un-cached page is needed, the app gets `SIGBUS` and dies. This is
  accepted, not engineered around. The init script treats `cage` exiting
  for *any* reason (clean close or SIGBUS) identically: `reboot -f`. PID 1
  never falls through to a shell.
- `seatd` runs before `cage` so the compositor gets DRM/GPU permissions
  without `systemd-logind`.

## 5. The builder (Module 4)

CLI: `build_cartridge.sh --app <name> --runtime [arch|alpine]`

- `arch` runtime (glibc, via `pacstrap`): default for anything proprietary,
  Electron, or shipped as a generic `.deb`/AUR binary. Larger base (~100MB)
  but maximum compatibility.
- `alpine` runtime (musl, via `apk`): only for known-good tiny FOSS tools
  (text editors, simple utilities). Stretch goal — **ship Arch-only for the
  2-week deadline**, add Alpine after if time remains.
- Sanitization pass before packing: strip docs/locales, `strip
  --strip-unneeded` on binaries. Do **not** remove `/bin/bash` — see §6.

## 6. Debug access — the one thing that was previously self-contradictory

Earlier discussion twice built a "no shell, no `/bin/sh`, kernel `panic=10`,
hard reboot on any failure" design, then **separately and correctly
rejected it** for removing all debugging capability. This file resolves
that conflict permanently:

- `bash`/`busybox` **stay in the Arch-runtime image**. They are not exposed
  to the running app (no `sh` reachable from the app's own sandbox/mount
  namespace), but they exist on a second virtual terminal.
- Switching to that TTY (e.g. `Ctrl+Alt+F2`) drops to a login gated by the
  **same Developer Passcode** already built for Host Access mode. One auth
  mechanism, reused, not two.
- No SSH, no network listener, no web dashboard, no `ttyd`/Cockpit for v1.
  Physical-console-only debug access is the goldilocks point — it solves
  real debugging pain for near-zero engineering cost.

## 7. Updates

No A/B atomic partitioning, no OTA, no signing pipeline for v1. Update =
rerun `build_cartridge.sh` for that one app and overwrite its `.img` file on
the shared data partition. This was already implied by the shared-kernel +
per-app-image layout — it just needed to be written down as *the* answer
instead of an open question.

## 8. Explicitly out of scope for v1 (do not build these)

- Disk encryption / LUKS on the USB. **Threat model note for the README**:
  this protects against a compromised app trying to escalate or touch host
  disk; it does **not** protect the USB's contents from someone with
  physical possession of the drive. That's a stated, accepted gap.
- Hypervisor / MicroVM isolation (Firecracker, Kata) between cartridges.
- Web dashboard, ttyd, Cockpit, any network-exposed management surface.
- 15-minute mount tokens / background revocation daemons.
- `--firmware=stripped` flag.
- eBPF/XDP network bypass.
- Plymouth or any graphical splash.

## 9. Definition of done for v1

Two cartridges (one browser via `arch` runtime, one lightweight text
editor) boot successfully in QEMU from a single simulated USB image, each
demonstrating all three storage modes working, with measured (not
estimated) boot time, idle RAM, and cartridge size numbers recorded in
`BENCHMARKS.md`.

---

## 10. Phase 2 Architecture (The Production Appliance)

Phase 2 transitions Cartilage OS from an emulated prototype into a daily-drivable,
production bare-metal appliance.

### 10.1 Milestone 1: Network & DNS Subsystem
- **Zero-daemon policy**: Do NOT install NetworkManager, Polkit, or D-Bus.
- **Ethernet**: Automatic interface link up (`ip link set <eth> up`) + background
  DHCP client (`dhcpcd -b -q` or `udhcpc`) with a 3-second non-blocking timeout.
- **Wi-Fi**: Intel Wireless Daemon (`iwd`) in standalone mode (`iwd -i <wlan>`),
  communicating directly via kernel `nl80211` without D-Bus.
- **Dynamic DNS**: `/etc/resolv.conf` is a symlink to `/run/resolv.conf` on `tmpfs`.
  Pre-seeded with anycast fallback DNS (`1.1.1.1`, `9.9.9.9`) during `/init`.

### 10.2 Milestone 2: Audio Subsystem
- **Zero-daemon software mixing**: Configure ALSA built-in `dmix` plugin in
  `/etc/asound.conf`. Enables multi-stream software mixing directly in the kernel
  ALSA layer with zero background daemons and zero CPU overhead.
- **Unprivileged user permissions**: User `cartilage` is a member of `audio`
  (`GID 92`); `udev` rules enforce `0660` on `/dev/snd/*`.

### 10.3 Milestone 3: Modern Web Kiosk Runtime (Chromium)
- **Native Wayland**: Launch Chromium natively via Ozone (`--ozone-platform=wayland
  --enable-features=UseOzonePlatform,VaapiVideoDecoder`).
- **Nested User Namespaces**: Enable `sysctl kernel.unprivileged_userns_clone=1`
  so Chromium's internal zygote sandbox functions seamlessly within the mount
  namespace.
- **IPC Shared Memory**: Mount a dedicated 512MB `tmpfs` on `/dev/shm`.
- **Pre-baked Fonts**: Run `fc-cache -fv` during image generation to eliminate
  cold-boot font scanning delays.

### 10.4 Milestone 4: Bare-Metal Physical USB Flasher
- **Target block device safety**: `flash_usb.sh` inspects `lsblk -d -o NAME,RM,SIZE,TRAN,MODEL`
  and rejects fixed drives (`TRAN=sata`, `TRAN=nvme`) unless `--force-internal` is given.
- **Strict GPT layout**:
  - Partition 1 (1GB, FAT32, ESP, Type `EF00`): Bootloader at `\EFI\BOOT\BOOTX64.EFI`,
    `vmlinuz-linux`, `initramfs-linux.img`.
  - Partition 2 (Raw EROFS, Type `8300`): Cartridge image 1.
  - Partition 3 (Raw EROFS, Type `8300`): Cartridge image 2.
  - Partition 4 (Remaining capacity, ext4/exFAT, Labeled `CARTDATA`): Persistent data.
- **PARTLABEL / PARTUUID routing**: Kernel cmdline targets `root=PARTLABEL=CART_<APP>`
  instead of hardcoded `/dev/vdX` nodes.

### 10.5 Milestone 5: Alpine Lightweight Runtime (`--runtime alpine`)
- **Dual-engine build pipeline**:
  - `--runtime arch`: For glibc, `.deb` packages, and proprietary apps (Chromium, VS Code).
  - `--runtime alpine`: For FOSS packages built with `apk` and `musl`, reducing GUI
    cartridges to **under 40MB**.

---

## 11. Phase 3: The Cartilage Appliance Framework Architecture

### 11.1 The Declarative Manifest Standard (`cartilage.yaml`)
Cartilage OS transitions from procedural bash scripting to a declarative specification model. An appliance is defined by a single manifest describing:
- **`appliance`**: Metadata (name, version, description, author).
- **`runtime`**: Base userspace engine (`alpine` for lean musl, `arch` for full glibc) and package list.
- **`display`**: Window composition (`cage` Wayland kiosk or direct DRM/KMS), display mode (`desktop` with tabs and omnibox vs. `kiosk` locked canvas), entrypoint binary, and launch arguments.
- **`storage`**: Storage isolation policy (`ephemeral` tmpfs OverlayFS, `persistent` partition binding, or `host-access` read-only mount) with quota constraints.
- **`hardware`**: Device requirements (audio multi-stream mixing, network DHCP/DNS, hardware GPU acceleration vs. software fallback).

### 11.2 The Unified `cartilage` CLI Engine
Replaces all legacy bash build scripts and duplicated launcher scripts (`run_*.sh`, `run_*.bat`) with a single, cross-platform CLI tool implemented in standard Python 3 (standard library only, zero pip dependencies):
- `cartilage validate <manifest.yaml>` — Validates schema and dependency constraints.
- `cartilage build <manifest.yaml>` — Hermetically compiles rootfs and packs into immutable EROFS.
- `cartilage run <manifest.yaml|image.img>` — Automatically constructs optimal QEMU hardware flags from the manifest and boots the appliance.
- `cartilage compose -o <combined.img> <manifest1.yaml> ...` — Generates a rootless GPT multi-boot UEFI image with `systemd-boot` and multiple cartridges.
- `cartilage flash --target <device> <manifest.yaml> ...` — Safely writes bootable media directly to physical USB drives.

### 11.3 Modular Stage-Based Init Pipeline (`/init.d/`)
The monolithic 600-line `/init` heredoc is modularized into sequential, independent stage scripts:
1. `00-vfs.sh`: Virtual kernel filesystems (`/proc`, `/sys`, `/dev`, `/dev/pts`, `/dev/shm`, `/run`, `/tmp`).
2. `10-hardware.sh`: Device hotplugging (`udevadm`/`mdev`), GPU DRM nodes, input devices, kernel module autoloading.
3. `20-network.sh`: Ethernet/Wi-Fi link detection, background DHCP client, Anycast DNS writing.
4. `30-storage.sh`: Storage policy execution with automatic error boundaries (graceful fallback to memory OverlayFS if physical media is read-only).
5. `40-security.sh`: Namespace isolation (`unshare -m`), binary masking (`/dev/null` bind mount over shells), dropping privileges to UID 1000 (`cartilage`).
6. `50-launch.sh`: `seatd` daemon activation, Wayland kiosk compositor (`cage`), and target application execution.

### 11.4 Fault-Tolerant Error Boundaries & Hardware Abstraction
- **Read-Only Media Protection**: Physical USB drives or storage partitions with write-locks, read-only mounts, or filesystem errors will never trigger a kernel panic. `/init` automatically falls back to an in-memory `tmpfs` OverlayFS.
- **Graphics Fallback**: If GPU hardware DRM nodes (`/dev/dri/card*`) fail to initialize or lack kernel acceleration (e.g. legacy hardware or safe-mode), the display pipeline automatically activates Mesa software rasterization (`WLR_RENDERER=pixman`, `LIBGL_ALWAYS_SOFTWARE=1`) to ensure GUI applications always render without black screens.


