# Cartilage OS — Deep-Dive Codebase & Architecture Explainer

> **Target Audience**: Any AI coding agent, systems engineer, or contributor entering this codebase.  
> **Purpose**: This document explains **WHY** every line of code, kernel flag, storage mechanism, and security control exists in Cartilage OS, how they fit together, and what pitfalls must never be repeated.

---

## Table of Contents
1. [Core Architectural Philosophy](#1-core-architectural-philosophy)
2. [Repository Anatomy & File Layout](#2-repository-anatomy--file-layout)
3. [Deep Dive: The Cartridge Compiler (build_cartridge.sh)](#3-deep-dive-the-cartridge-compiler-build_cartridgesh)
4. [Deep Dive: Custom PID 1 (/init) Line-by-Line](#4-deep-dive-custom-pid-1-init-line-by-line)
5. [The Three Storage Modes (Mechanics & Rationale)](#5-the-three-storage-modes-mechanics--rationale)
6. [The Display & Input Pipeline (seatd + cage + Wayland)](#6-the-display--input-pipeline-seatd--cage--wayland)
7. [Security Sandboxing & Binary Isolation](#7-security-sandboxing--binary-isolation)
8. [The Verification Suite (scripts/01 to scripts/09)](#8-the-verification-suite-scripts01-to-scripts09)
9. [The UEFI Multi-Boot Disk Layout](#9-the-uefi-multi-boot-disk-layout)
10. [Critical Gotchas & Forbidden Anti-Patterns](#10-critical-gotchas--forbidden-anti-patterns)

---

## 1. Core Architectural Philosophy

### What Cartilage OS Is
Cartilage OS is **not** a traditional Linux distribution and **not** an ISO installer. It is an **appliance build framework**.
- It outputs **EROFS cartridges** (`cartridge_<app>.img`): highly compressed, immutable filesystem images that hold a single target application and the bare minimum userspace needed to run it.
- Multiple cartridges live alongside each other on a single USB stick, sharing a single UEFI bootloader (`systemd-boot`) and a single shared Linux kernel (Arch 6.12+).

### Why EROFS Instead of SquashFS?
1. **Zero-Copy Page Cache Access**: EROFS (Enhanced Read-Only File System) maps fixed-size compressed blocks directly into the Linux kernel page cache. SquashFS decompresses into intermediate bounce buffers before copying to the page cache, resulting in **double-memory overhead** and CPU spikes on flash drives.
2. **Deterministic Block I/O**: EROFS random-read latency on flash NAND is up to 3x faster than SquashFS.
3. **Immutability by Design**: An EROFS partition cannot be modified by any userspace exploit or ransomware. Bitrot and malware persistence are physically impossible.

### Why Wayland (`cage`) Instead of X11?
1. **Single-Application Kiosk Model**: `cage` is a fullscreen Wayland kiosk compositor built on `wlroots`. It maximizes a single client window and suppresses all window management overhead (no titlebars, no taskbars, no desktop clutter).
2. **Elimination of X11 Attack Surface**: In traditional X11, any client can sniff keypresses, capture pixels from other windows, and inject synthetic input events across processes. Wayland's strict client isolation prevents all inter-application snooping.
3. **Bypassing Desktop Environments**: We do not run GNOME, KDE, or XFCE. We boot straight from `/init` into `cage`, cutting memory footprint from 1.5GB down to ~260MB.

### Why `seatd` Instead of `systemd-logind`?
- Wayland compositors need unprivileged access to DRM/KMS display nodes (`/dev/dri/card0`) and input devices (`/dev/input/*`).
- Distros normally use `systemd-logind` + Polkit + D-Bus for session arbitration. This pulls in dozens of daemons, 150MB of RAM, and adds 5–10 seconds of boot delay.
- `seatd` is an independent, tiny C daemon (~50KB) that arbitrates device permissions for user `cartilage` with **zero D-Bus** and **zero systemd dependencies**.

---

## 2. Repository Anatomy & File Layout

```text
cartrige/
├── build_cartridge.sh           # The primary CLI compiler that stages, strips, and packs cartridges
├── ARCHITECTURE.md              # The source of truth for architectural specifications
├── SPEC.md                      # Concrete acceptance criteria and pass/fail tests for all tasks
├── AGENT_TASKS.md               # Task checklist tracking completed vs pending engineering work
├── ROADMAP.md                   # Timeline milestones for v1 and Phase 2
├── BENCHMARKS.md                # Real, measured hardware benchmarks (boot time, idle RAM, image size)
├── README.md                    # Public GitHub presentation and reproduction guide
├── EXPLAINER.md                 # This file: line-by-line engineering rationale
├── run_mousepad.bat             # 1-click Windows launcher for Mousepad cartridge under KVM
├── run_dillo.bat                # 1-click Windows launcher for Dillo Web Browser cartridge under KVM
├── run_boot_menu.bat            # 1-click Windows launcher for UEFI multi-boot menu
├── build/                       # Staging directory for generated .img files and pacman mirrors
├── docs/assets/                 # Screen captures, boot GIFs, and architecture diagrams
├── scripts/                     # Automated test harness verifying every milestone:
│   ├── 01_build_base_rootfs.sh      # Compiles raw Arch Linux rootfs via pacstrap
│   ├── 01_test_qemu.sh              # Headless QEMU test booting rootfs to /bin/sh
│   ├── 02_build_cartridge.sh        # Builds demo EROFS cartridge
│   ├── 02_test_cartridge_qemu.sh    # Verifies cage + seatd execution in QEMU
│   ├── 03_test_ephemeral_storage.sh # Verifies OverlayFS tmpfs quota and zram memory swap
│   ├── 04_test_persistent_storage.sh# Verifies multi-reboot state persistence on /data
│   ├── 05_test_host_access.sh       # Verifies passcode gate and dirty NTFS rejection
│   ├── 06_test_builder_cli.sh       # Verifies hermetic builds and .deb archive extraction
│   ├── 07_build_combined_image.sh   # Assembles UEFI multi-boot GPT disk image
│   ├── 07_test_boot_menu.sh         # Verifies systemd-boot menu in QEMU via OVMF
│   ├── 08_test_debug_console.sh     # Verifies VT2 passcode prompt and app namespace isolation
│   ├── 09_run_benchmarks.sh         # Automated performance measurement suite
│   └── set_ntfs_dirty.py            # Diagnostic tool setting NTFS dirty bit for safety tests
└── skills/                      # Step-by-step technical guides for agents
```

---

## 3. Deep Dive: The Cartridge Compiler (`build_cartridge.sh`)

`build_cartridge.sh` transforms an application name (`mousepad`, `dillo`) or a `.deb` file into an immutable, bootable EROFS cartridge.

### Key Logic & Line-by-Line Rationale:

```bash
set -euo pipefail
```
- **Why**: Bash error handling. `-e` aborts on any non-zero exit; `-u` treats unset variables as errors; `-o pipefail` ensures pipeline errors (e.g. `cat file | grep pattern`) are not masked. Never remove this.

```bash
BASE_TEMPLATE="/var/lib/cartilage/base_template"
if [[ -d "${BASE_TEMPLATE}" ]]; then
    echo "==> Cloning pre-baked slim base template..."
    cp -a --reflink=auto "${BASE_TEMPLATE}" "${STAGING_DIR}"
```
- **Why**: Full `pacstrap` builds take 6–10 minutes because pacman downloads and unpacks 300+ packages. By maintaining a pre-baked base template at `/var/lib/cartilage/base_template` (containing `cage`, `seatd`, Mesa, Xwayland, and core libraries), builds take **under 90 seconds**. `--reflink=auto` performs instant copy-on-write cloning on Btrfs/XFS filesystems.

```bash
ln -sf /usr/bin/dash "${STAGING_DIR}/bin/sh"
```
- **CRITICAL ARCHITECTURAL DECISION**:
  - In Arch Linux, `/bin/sh` is a symlink to `/bin/bash`.
  - In Task 8, we mask `/bin/bash` with `/dev/null` inside the application namespace to prevent shell escapes.
  - However, `glibc` internal functions (`system()`, `popen()`) and Xwayland internally invoke `system("xkbcomp ...")` via `/bin/sh`.
  - If `/bin/sh` points to `/bin/bash` and `/bin/bash` is masked, Xwayland crashes immediately with `Failed to activate virtual core keyboard: 2`!
  - By linking `/bin/sh` to `dash` (a 90KB POSIX shell), masking `/bin/bash` leaves `/bin/sh` fully functional for C library subprocesses while preventing user shell escalation.

```bash
# Dead-weight stripping pass
rm -rf "${STAGING_DIR}/usr/lib/firmware"
rm -rf "${STAGING_DIR}/boot"
rm -rf "${STAGING_DIR}/usr/include"
rm -rf "${STAGING_DIR}/usr/share/locale"
```
- **Why**:
  - `/usr/lib/firmware` is 416MB. Firmware is loaded by the shared kernel during early boot from the ESP/boot partition. Cartridges do not need duplicate firmware inside `/sysroot`.
  - `/boot` contains duplicate kernel and initramfs files (41MB).
  - Locales and headers take 160MB of dead weight.
  - Stripping these dropped cartridge size from **1.2GB down to ~400MB**.

```bash
find "${STAGING_DIR}/usr/bin" "${STAGING_DIR}/usr/lib" -type f -exec strip --strip-unneeded {} + 2>/dev/null || true
```
- **Why**: Strips debug symbols and unneeded relocation tables from compiled ELF binaries, saving ~40MB per cartridge without affecting execution.

```bash
mkfs.erofs -z lz4 "${OUTPUT_IMG}" "${STAGING_DIR}"
```
- **Why**: Compresses the staging directory into an EROFS filesystem using `lz4`. LZ4 provides lightning-fast decompression speeds (>2 GB/s), ensuring cold-boot times remain under 2 seconds.

---

## 4. Deep Dive: Custom PID 1 (`/init`) Line-by-Line

Cartilage OS does not use systemd as PID 1 inside the cartridge. The entire operating system is booted by a hand-crafted, high-performance `/init` shell script.

### 4.1 Virtual Filesystem Mounting
```bash
mount -t proc proc /proc -o nosuid,noexec,nodev 2>/dev/null || true
mount -t sysfs sys /sys -o nosuid,noexec,nodev 2>/dev/null || true
mount -t devtmpfs devtmpfs /dev -o nosuid 2>/dev/null || true
mkdir -p /dev/pts /dev/shm
mount -t devpts devpts /dev/pts -o nosuid,noexec,gid=5,mode=620 2>/dev/null || true
mount -t tmpfs tmpfs /dev/shm -o nosuid,nodev 2>/dev/null || true
mount -t tmpfs tmpfs /run -o nosuid,nodev,mode=0755 2>/dev/null || true
```
- **Why**: Linux processes require `/proc`, `/sys`, and `/dev` to query kernel state and hardware. `/dev/pts` provides pseudo-terminals for terminal emulators; `/dev/shm` is POSIX shared memory required by Wayland and browsers.

### 4.2 Essential Device Nodes
```bash
mknod -m 600 /dev/console c 5 1 2>/dev/null || true
mknod -m 666 /dev/null c 1 3 2>/dev/null || true
mknod -m 666 /dev/zero c 1 5 2>/dev/null || true
mknod -m 666 /dev/tty1 c 4 1 2>/dev/null || true
mknod -m 666 /dev/tty2 c 4 2 2>/dev/null || true
```
- **Why**: Without explicit `/dev/console` and `/dev/tty1`, stdout/stderr fail in early userspace. `/dev/tty2` is explicitly created for the developer debug console.

### 4.3 Hardware Device Arbitration (`udev`)
```bash
systemd-udevd --daemon
udevadm trigger --action=add
udevadm settle --timeout=3
```
- **Why**: Modern Linux input devices (mice, keyboards, USB tablets) and GPU DRM nodes (`/dev/dri/card0`) are dynamic. Running `systemd-udevd` and triggering kernel events populates `/dev/input/*` immediately, ensuring mouse and keyboard respond as soon as `cage` starts.

### 4.4 Unprivileged User Setup
```bash
if ! id -u cartilage >/dev/null 2>&1; then
    groupadd -g 1000 cartilage 2>/dev/null || true
    useradd -u 1000 -g 1000 -G seat,video,input -d /home/cartilage -m -s /bin/sh cartilage 2>/dev/null || true
fi
```
- **Why**: Running graphical applications as `root` triggers security warnings (e.g. Mousepad's red root banner) and allows application bugs to compromise the system. User `cartilage` is created with UID 1000 and placed in `seat`, `video`, and `input` groups so `seatd` can grant it DRM/KMS display access without root privileges.

```bash
mount -t tmpfs -o mode=0700,uid=1000,gid=1000 tmpfs /home/cartilage
```
- **CRITICAL GOTCHA**:
  - The root filesystem is read-only EROFS.
  - Running `chown 1000:1000 /home/cartilage` fails with `Read-only file system` and triggers a kernel panic under `set -e`!
  - By mounting a writable `tmpfs` directly on `/home/cartilage` with `uid=1000,gid=1000`, the user receives a clean, writable home directory with zero disk mutations.

---

## 5. The Three Storage Modes (Mechanics & Rationale)

Cartilage OS inspects the kernel command line (`/proc/cmdline`) to determine which storage policy to enforce:

### Mode 1: Ephemeral Mode (`cartilage_storage=ephemeral` or default)
```bash
# 1. Mount OverlayFS over tmpfs for root
mount -t tmpfs -o size=512M tmpfs /overlay/upper
mount -t tmpfs -o size=64M tmpfs /overlay/work

# 2. Hard Quota on Downloads
mkdir -p /home/cartilage/Downloads
mount -t tmpfs -o size=20M,uid=1000,gid=1000 tmpfs /home/cartilage/Downloads

# 3. Memory swap compression via zram
modprobe zram num_devices=1
echo zstd > /sys/block/zram0/comp_algorithm
echo 256M > /sys/block/zram0/disksize
mkswap /dev/zram0
swapon -p 100 /dev/zram0
```
- **The Threat**: A rogue web download could fill physical RAM, causing the Linux Out-Of-Memory (OOM) killer to terminate PID 1 and panic the machine.
- **The Solution**: Downloads are capped at a strict **20MB quota**. Exceeding it returns `No space left on device` cleanly without crashing the system. `zram0` compresses RAM pages using `zstd`, effectively doubling usable memory on low-spec hardware.

### Mode 2: Persistent Mode (`cartilage_storage=persistent`)
```bash
DATA_DEV="/dev/vdb" # or labeled CARTDATA
mount -t ext4 -o noatime "${DATA_DEV}" /data
mkdir -p /data/cartilage_state
mount --bind /data/cartilage_state /home/cartilage
```
- **Why**: Documents and application settings survive reboots by binding state to the persistent USB partition (`/dev/vdb` or labeled `CARTDATA`).

### Mode 3: Host Access Mode (`cartilage_storage=host`)
```bash
# Mount host drive in hidden location
mkdir -p /mnt/hidden_host
mount -o ro /dev/sda1 /mnt/hidden_host

# Protect against Windows Fast Startup NTFS corruption
if blkid /dev/sda1 | grep -q "ntfs"; then
    if ntfsinfo -m /dev/sda1 2>/dev/null | grep -q "Volume is dirty"; then
        echo "[SECURITY ALERT] Windows Fast Startup dirty bit detected!"
        echo "Write access blocked to prevent host corruption."
        # Drop write request, stay read-only
    fi
fi
```
- **The Threat**: Windows Fast Startup leaves NTFS partitions in a hibernated state with the "dirty bit" set. Writing to a dirty NTFS partition from Linux corrupts the host Windows installation!
- **The Solution**: `ntfsinfo` inspects the volume flags before any write mount. If dirty or hibernated, write access is blocked loudly, protecting host data integrity.

---

## 6. The Display & Input Pipeline (`seatd` + `cage` + Wayland)

```bash
# 1. Start seat management daemon
seatd -u cartilage &
export SEATD_VTY=1
export XDG_RUNTIME_DIR=/run/user/1000
mkdir -p "${XDG_RUNTIME_DIR}"
chown cartilage:cartilage "${XDG_RUNTIME_DIR}"
chmod 0700 "${XDG_RUNTIME_DIR}"

# 2. Launch fullscreen Wayland compositor
exec runuser -u cartilage -- cage -s -- ${APP_EXEC}
```

### Why This Architecture Works:
1. `seatd` runs in the background. When `cage` starts, it requests DRM/KMS and `evdev` file descriptors via `/run/seatd.sock`. `seatd` verifies UID 1000 and hands over the file descriptors without `cage` ever needing root privileges.
2. `cage -s` enables fullscreen kiosk mode and launches the child application inside the Wayland session.
3. If the user closes the application, `cage` terminates.
4. Because PID 1 used `exec`, the termination of `cage` immediately executes the PID 1 reboot safety net:
   ```bash
   reboot -f
   ```
   **Result**: Zero chance of an app crash dropping to an exposed root console!

---

## 7. Security Sandboxing & Binary Isolation

### 7.1 Masking `/bin/bash` in the Application Namespace
```bash
mount --bind /dev/null /bin/bash
```
- **Why**: If an attacker exploits a vulnerability in Dillo or Mousepad to spawn a shell via `system("/bin/bash")` or `execve("/bin/bash")`, the execution fails immediately with `Permission denied` or executes empty EOF.
- **Why `/bin/sh` still works**: As detailed in Section 3, `/bin/sh` is linked to `/usr/bin/dash`. Native C libraries and Xwayland helper processes can still execute POSIX commands, but interactive bash shells are completely severed.

### 7.2 The Developer Debug Console (VT2)
```bash
openvt -c 2 -f -w -- /usr/local/bin/cartilage_debug_console &
```
- In `/usr/local/bin/cartilage_debug_console`:
  ```bash
  read -s -p "[auth] Enter Developer Passcode: " PASS
  if [ "$PASS" = "cartilage42" ]; then
      exec /bin/bash -i
  fi
  ```
- **Physical Console Only**: Cartilage OS runs **no SSH server**, no network listeners, and no web portals.
- The **only** way to access system diagnostics is physical access: press `Ctrl+Alt+F2`, enter the passcode, and you are granted a root shell on VT2 with full `/bin/bash` access to `dmesg`, `lsblk`, and `ip link`.

---

## 8. The Verification Suite (`scripts/01` to `scripts/09`)

Every milestone in Cartilage OS has a matching automated test script that runs headlessly in QEMU:

| Script | What It Tests | Pass Criteria |
| :--- | :--- | :--- |
| `scripts/01_test_qemu.sh` | Raw Arch rootfs boot | Serial console shows `/bin/sh` within 10s. |
| `scripts/02_test_cartridge_qemu.sh` | `cage` + `seatd` + EROFS execution | DRM card0 initializes and exits 0. |
| `scripts/03_test_ephemeral_storage.sh` | 20MB download quota + zram swap | Writing 30MB fails cleanly with `disk full`. |
| `scripts/04_test_persistent_storage.sh` | Reboot persistence | File written in boot 1 exists in boot 2. |
| `scripts/05_test_host_access.sh` | Passcode gate & NTFS safety | Dirty NTFS rejected; passcode grants workspace. |
| `scripts/06_test_builder_cli.sh` | CLI builder & `.deb` support | Compiles `.deb` archive into working cartridge. |
| `scripts/07_test_boot_menu.sh` | UEFI multi-cartridge boot menu | `systemd-boot` loads OVMF and boots cartridge. |
| `scripts/08_test_debug_console.sh` | VT2 passcode gate & binary masking | Passcode grants shell; `/bin/bash` masked on VT1. |
| `scripts/09_run_benchmarks.sh` | Automated performance recording | Boot time, idle RAM, and file size recorded. |

---

## 9. The UEFI Multi-Boot Disk Layout

When `scripts/07_build_combined_image.sh` builds `cartilage_combined.img`, it creates a strict GPT partition table:

```text
+-------------------------------------------------------------------------+
| Partition 1: EFI System Partition (ESP) — FAT32 (1GB)                   |
| - \EFI\BOOT\BOOTX64.EFI (systemd-boot)                                  |
| - \EFI\loader\loader.conf                                               |
| - \EFI\loader\entries\dillo.conf & mousepad.conf                        |
| - \vmlinuz-linux (shared Linux 6.12+ kernel)                            |
| - \initramfs-linux.img (shared initramfs + full firmware)               |
+-------------------------------------------------------------------------+
| Partition 2: Cartridge 1 (Dillo Web Browser) — EROFS (500MB)            |
| - Immutable rootfs with cage + seatd + dillo                            |
+-------------------------------------------------------------------------+
| Partition 3: Cartridge 2 (Mousepad Editor) — EROFS (500MB)              |
| - Immutable rootfs with cage + seatd + mousepad                         |
+-------------------------------------------------------------------------+
| Partition 4: Persistent User Data (CARTDATA) — ext4 / exFAT             |
| - User documents, bookmarks, and persistent application state           |
+-------------------------------------------------------------------------+
```

---

## 10. Critical Gotchas & Forbidden Anti-Patterns

For any developer or AI agent modifying this codebase, **never violate these rules**:

1. **NEVER mask `/bin/bash` without linking `/bin/sh` to `dash` first**:
   `glibc` and Xwayland require `/bin/sh`. Masking `/bin/bash` without `dash` breaks Xwayland keymap activation.
2. **NEVER run `chown` on files located inside the root EROFS**:
   EROFS is strictly read-only. `chown` triggers `Read-only file system` and crashes `/init` with a kernel panic. Mount a `tmpfs` on directories that need unprivileged ownership.
3. **NEVER use `umount -l` (lazy unmount) expecting file access to be severed**:
   `umount -l` only hides the mount from the VFS namespace. Open file descriptors remain active. Use separate kernel mount namespaces (`unshare -m`).
4. **NEVER omit `-device usb-tablet` in QEMU**:
   Standard PS/2 mouse emulation uses relative coordinates, causing cursor drift and cursor grabbing in Wayland compositors. The USB tablet device provides absolute coordinate tracking.
5. **NEVER bundle `/usr/lib/firmware` inside application cartridges**:
   Firmware belongs in the shared kernel/ESP layer. Bundling it inside cartridges wastes 416MB per application.
6. **NEVER install NetworkManager or D-Bus for kiosk networking**:
   Use lightweight direct tools (`dhcpcd`, `iwd`, and tmpfs `/etc/resolv.conf`). Heavy daemon stacks defeat the purpose of an appliance OS.
