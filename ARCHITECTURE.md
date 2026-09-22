# Cartilage OS — Architecture Specification (v2.0, LOCKED)

**Status: this file defines the authoritative systems architecture of Cartilage OS.** If a decision here conflicts with informal discussion or prior drafts, this file wins. If this file is silent on something, that thing is out of scope — do not invent it.

Cartilage OS is a **dual-mode appliance build and execution framework**. It compiles declarative appliance recipes into immutable, hardware-isolated EROFS cartridges that can be deployed either as **dedicated raw-partition kiosks** (Mode 1) or as **drag-and-drop file-based cartridges on a dynamic hub** (Mode 2).

---

## 1. Core Architectural Non-Negotiables

These architectural decisions were debated, benchmarked, and permanently closed:

1. **FUSE is Strictly Banned**: FUSE (Filesystem in Userspace) introduces context-switching overhead and CPU spikes. More critically, if a USB drive is removed while a FUSE daemon is active, the Linux kernel enters an unkillable uninterruptible sleep state (`D-state`), locking the hardware. All isolation, sandboxing, and persistence rely **exclusively on native Linux kernel bind mounts (`mount --bind`) and mount namespaces (`unshare -m`)**.
2. **Pure EROFS with LZ4-HC Compression**: EROFS (`mkfs.erofs -zlz4hc,12`) is used exclusively for cartridge filesystems. It provides direct, zero-copy kernel page-cache mapping without intermediate userspace bounce buffers, offering 3x faster random-read performance on flash media compared to SquashFS.
3. **Full Firmware Bundled Unconditionally**: `linux-firmware` is bundled in full on the ESP partition. Modern Wi-Fi, Ethernet, and GPU acceleration (Intel Iris, AMD Radeon, Realtek) must initialize deterministically on bare metal without missing firmware panics.
4. **The SIGBUS USB-Pull Rule**: Physical removal of a live USB drive mid-session will trigger `SIGBUS` if an un-cached page is requested. Cartilage explicitly does **not** attempt `mlock()` or `copytoram` (which would exhaust memory on 1GB–2GB targets). Instead, PID 1 traps compositor termination for *any* reason and executes an immediate hard reset (`reboot -f` or `poweroff -f`). PID 1 never falls through to an unauthenticated shell.
5. **No Systemd Userspace Daemons**: Systemd-boot is used on the ESP purely as a UEFI bootloader. Once the kernel boots, PID 1 is Cartilage's custom modular `/init` stage runner. There is no `systemd-logind`, no D-Bus session bus, no Polkit, and no NetworkManager running inside appliances.

---

## 2. The Dual-Deployment Engine

Cartilage OS produces a single compiled artifact: `cartridge_<app>_<engine>.img` (an immutable EROFS block payload). The framework supports two distinct deployment targets without changing the underlying cartridge binary:

```
                                  +------------------------------------+
                                  |  ./cartilage build recipes/*.yaml  |
                                  +------------------------------------+
                                                     |
                                                     v
                                  +------------------------------------+
                                  |    cartridge_<app>_<engine>.img    |
                                  |       (Immutable EROFS Payload)    |
                                  +------------------------------------+
                                          /                    \
                                         /                      \
                                        v                        v
            +----------------------------------+   +----------------------------------+
            |  DEPLOYMENT MODE 1: DEDICATED    |   |    DEPLOYMENT MODE 2: DYNAMIC    |
            |      (Raw Partition Kiosk)       |   |       (The "Ventoy" Hub)         |
            +----------------------------------+   +----------------------------------+
            | * Raw GPT partition per app      |   | * Static 2-partition USB (exFAT) |
            | * Hardcoded root=PARTLABEL=...   |   | * Drag-and-drop .img files       |
            | * Direct kernel block mapping    |   | * In-kernel exFAT loopback mount |
            | * Best for: Single-app kiosks,   |   | * Best for: Multi-tool drives,   |
            |   ATMs, embedded field rigs,     |   |   desktop hackers, sharing images|
            |   dedicated media stations       |   |   between Windows/Mac/Linux      |
            +----------------------------------+   +----------------------------------+
```

### 2.1 Mode 1: Dedicated Appliance Kiosk (Raw Block Deployment)
- **Use Cases**: Public kiosks, ATMs, digital signage, medical diagnostic displays, single-purpose retro consoles.
- **Partition Layout**:
  - Partition 1 (`CARTBOOT`): 128 MB FAT32 ESP (`systemd-boot`, `vmlinuz-linux`, `initramfs-linux.img`).
  - Partition 2 (`CART1`): Raw EROFS image (`cartridge_foot_arch.img`).
  - Partition 3 (`CART2`): Raw EROFS image (`cartridge_vlc_arch.img`).
  - Partition N (`CARTDATA`): ext4 persistent user storage.
- **Kernel Command Line**: `root=PARTLABEL=CART1 rootfstype=erofs init=/init ro quiet console=tty1`.
- **Performance**: Zero intermediate layers. Direct block I/O to physical NAND flash. Cold boot in **2.1s to 4.3s** (Alpine) / **4.5s to 6.5s** (Arch).

### 2.2 Mode 2: Dynamic Cartridge Hub (File-Based "Ventoy" Deployment)
- **Use Cases**: Multi-app flash drives, student developer kits, offline repair drives, cross-platform USBs curated on Windows/macOS.
- **Partition Layout (Format Once)**:
  - **Partition 1 (`CARTBOOT`)**: 256 MB FAT32 ESP containing `systemd-boot`, shared kernel (`vmlinuz-linux`), and dynamic bootstrap loader (`initramfs-hub.img`).
  - **Partition 2 (`CARTRIDGES`)**: exFAT filesystem taking up the remainder of the USB drive. Formatted once via `./cartilage init-hub /dev/sdX`.
- **Directory Structure on exFAT**:
  - `/cartridges/`: Directory where users drop `.img` files via standard file manager copy.
  - `/data/`: Directory containing `data.img` (a sparse ext4 loopback image).
- **The exFAT POSIX Solution**: exFAT does not support Linux permissions, UIDs, or symlinks. Cartilage solves this elegantly:
  - EROFS cartridges sit as plain files on exFAT. When loop-mounted, EROFS enforces POSIX permissions and UIDs internally.
  - Persistent `/data` is stored inside `data.img` (an ext4 filesystem inside a file on exFAT), preserving full POSIX permissions for Git, SSH, and scripts.
- **Bootstrap Loader Execution Sequence**:
  1. UEFI boots `vmlinuz-linux` with `initramfs-hub.img`.
  2. Bootstrap script probes block devices for partition labeled `CARTRIDGES`.
  3. Mounts exFAT filesystem to `/mnt/hub` via in-kernel `exfat.ko`.
  4. Scans `/mnt/hub/cartridges/*.img`:
     - If exactly 1 cartridge exists: immediately boots it.
     - If multiple cartridges exist: presents a fast (<100ms) TTY text boot menu.
  5. In-kernel loop mount: `mount -t erofs -o loop,ro /mnt/hub/cartridges/<chosen>.img /sysroot`.
  6. Persistent data loop mount: `mount -t ext4 -o loop,rw /mnt/hub/data/data.img /sysroot/data` (if present).
  7. Handoff: `exec switch_root /sysroot /init`.
- **Performance Impact**: In-kernel loop mapping over sequential exFAT clusters adds only **~30ms to 60ms** to cold boot latency. Foot boots in ~1.85s.

---

## 3. The Three Storage Modes

Cartilage OS strictly isolates application state into three mutually exclusive storage policies:

1. **Ephemeral Mode**:
   - The immutable EROFS root is combined with an in-memory `tmpfs` upperdir via `OverlayFS`.
   - Temporary file writes and browser caches are bounded by strict memory quotas.
   - Kernel `zram` with `zstd` compression actively swaps compressed memory, preventing out-of-memory panics on low-RAM (1GB) targets.
   - On power-off or USB removal, all scratch state instantly evaporates.
2. **Persistent Mode**:
   - In Mode 1: Physical ext4 partition labeled `CARTDATA` is kernel-bind-mounted to `/data`.
   - In Mode 2: Sparse ext4 loop file `/mnt/hub/data/data.img` is mounted to `/data`.
   - The appliance rootfs remains 100% read-only; user code, dotfiles, and downloads persist safely across reboots without risking OS corruption.
3. **Host Access Mode**:
   - Internal host drives (SATA/NVMe) are detected and mounted read-only under a hidden system directory (`/mnt/hidden_host`) invisible to the application namespace.
   - Physical entry of the **Developer Passcode** (`cartilage42`) at the console unlocks write access to a specific user-chosen directory via `mount --bind` within an isolated `unshare -m` namespace.
   - **NTFS Fast Startup Protection**: If an internal Windows partition has its hibernation/dirty bit set (caused by Windows Fast Startup), Cartilage actively rejects write requests, drops to read-only, and prints the exact remediation instructions to TTY. FUSE is banned; all mounting is in-kernel.

---

## 4. Compositor & Display Architecture

Cartilage OS implements a **Flexible Compositor Choice Architecture** allowing developers to declare the exact display environment suited to the workload:

```
+-----------------------------------------------------------------------------------+
|                           Compositor Architecture Matrix                          |
+-----------------------------------------------------------------------------------+
|  1. Kiosk Mode (`cage`)                                                           |
|     - Single fullscreen application canvas (strictly 1 primary window).           |
|     - Zero window borders, zero desktop chrome, disabled windowing keybindings.   |
|     - Security: Hard mask of `/bin/bash` to `/dev/null` in application namespace.  |
|     - Used by: Dedicated Terminals, Media Stations, Single-App Kiosks, POS, ATMs. |
|     - Memory Footprint: ~15-20 MB.                                                |
|                                                                                   |
|  2. Stacking Desktop (`labwc`) [Default for Workstations]                         |
|     - Lightweight Openbox-style stacking Wayland compositor (wlroots).           |
|     - Familiar multi-window floating paradigm with titlebars, minimize, maximize. |
|     - Built-in root-menu window management and anti-void guardian.                |
|     - Used by: Multi-window Workstations, Desktop Appliances.                     |
|     - Memory Footprint: ~25-35 MB.                                                |
|                                                                                   |
|  3. Ultra-Lean Dynamic Tiling (`dwl`)                                             |
|     - dwm for Wayland written in minimal, hackable C (<300 KB binary).            |
|     - Master-and-stack dynamic tiling layout with Tags 1–9.                       |
|     - Hotkeys: Alt+1 (Terminal) <-> Alt+2 (Browser), Alt+Enter (Spawn Terminal).  |
|     - Security: Retains unmasked `/bin/bash` for interactive developer shells.    |
|     - Used by: Low-memory Developer Workstations (512MB–1GB RAM targets).         |
|     - Memory Footprint: <15 MB (<265 MB active memory with dual apps).            |
|                                                                                   |
|  4. i3-Compatible Tiling Window Manager (`sway`)                                  |
|     - Drop-in replacement for the i3 window manager on Wayland.                   |
|     - Dynamic workspaces 1–10, vertical/horizontal splits, floating containers.   |
|     - Native i3-ipc support for external status bars and scripting (`swaymsg`).   |
|     - Hotkeys: Mod4/Mod1+Return (Terminal), Mod+1..10 (Workspaces), Mod+Shift+q.  |
|     - Security: Retains unmasked `/bin/bash` for developer tools and workflows.   |
|     - Used by: Power-user workstations, multi-window engineering rigs.             |
|     - Memory Footprint: ~35-45 MB.                                                |
+-----------------------------------------------------------------------------------+
```

### Hardware Direct Rendering & Fallback:
- `seatd` runs before the compositor, providing unprivileged DRM/KMS device access to user `cartilage` (UID 1000) without `systemd-logind`.
- If hardware GPU DRM nodes (`/dev/dri/card*`) are present, cage, labwc, dwl, and sway render via OpenGL ES over kernel DRM/KMS.
- If hardware DRM is absent or running under virtual emulation without acceleration, `/init.d/50-launch.sh` automatically falls back to software rasterization (`WLR_RENDERER=pixman`, `LIBGL_ALWAYS_SOFTWARE=1`) to prevent black screens.

---

## 5. Universal Audio Subsystem (ALSA `dmix`)

Traditional desktop Linux requires PulseAudio or PipeWire daemons running in userspace, consuming 50–150 MB of RAM and introducing inter-process communication latency.

Cartilage OS implements a **zero-daemon audio architecture**:
- Stage `10-hardware.sh` configures `/run/asound.conf` with an ALSA `type dmix` software mixer bound to `/dev/snd/pcmC0D0p` (and symlinked from `/etc/asound.conf`).
- Multiple independent processes (e.g., MPV, VLC, browser audio) can output sound simultaneously.
- Zero background audio processes are executed. Audio latency is sub-millisecond at direct kernel level.

---

## 6. The Modular `/init.d/` Stage Pipeline

PID 1 is not a monolithic binary. It is a deterministic shell dispatcher executing sequential, isolated stages within an error boundary:

```
/init (PID 1 Dispatcher)
  ├── 00-vfs.sh        # Mounts /proc, /sys, /dev, /dev/pts, /dev/shm, /run, /tmp
  ├── 10-hardware.sh   # Coldplug udevadm/mdev, loads GPU/DRM, input, storage modules
  ├── 20-network.sh    # Detects interfaces, triggers background DHCP, configures DNS
  ├── 30-storage.sh    # Evaluates storage policy (ephemeral tmpfs vs persistent ext4)
  ├── 40-security.sh   # Sets up namespaces, drops capabilities, masks shells if needed
  └── 50-launch.sh     # Starts seatd, launches Wayland compositor, execs app
```

### Error Boundaries & Fault Tolerance:
- If persistent storage is corrupted or read-only, `30-storage.sh` does not crash; it logs a warning and transparently activates an in-memory `tmpfs` OverlayFS.
- If the application exits or crashes, PID 1 immediately traps the exit and executes `poweroff -f` or `reboot -f`. No root shell is ever exposed.

---

## 7. Threat Model & Security Boundaries

Cartilage OS operates on an **Appliance Isolation and Unbrickable Integrity** model:

1. **Root-in-Guest by Design**:
   - The appliance environment compiles a setuid `/usr/bin/sudo` helper so unprivileged user `cartilage` (UID 1000) has full administrative agency inside their own session (e.g. running live package installations with `pacman`, hardware inspection, developer tools).
   - **System Integrity via EROFS**: The entire operating system rootfs is stored as a compressed, read-only EROFS block filesystem. Even if `cartilage` escalates to root inside the guest, the base system cannot be modified, corrupted, or bricked. All live modifications evaporate on reboot (or stay safely isolated to `/data`).
2. **Appliance-to-Appliance & Guest-to-Host Isolation**:
   - Each appliance executes inside isolated Linux mount namespaces (`unshare -m`) and user namespaces (`unshare -U`).
   - Virtual machine appliances run under QEMU hardware virtualization, preventing execution outside the guest.
   - Host storage drives (SATA/NVMe) are protected: `flasher` refuses internal disks unless `--force-internal` is set, and in-guest host access requires explicit mount isolation.
3. **Kiosk Hardening**:
   - For single-purpose kiosk appliances, shell binaries (`/bin/bash`, `/bin/sh`) are masked to `/dev/null` in the application namespace to prevent shell injection escapes.
4. **Explicit Limits (Out-of-Scope)**:
   - Does **not** protect against an attacker with physical possession of the USB drive (no LUKS encryption in v2.0).
   - Relies on physical USB hardware integrity.

---

## 8. Bootstrap & Build Pipeline

1. **Bootstrap Phase (One-Time)**:
   - Compiles the base Arch rootfs and initramfs via `sudo ./scripts/01_build_base_rootfs.sh`. This step requires root/pacstrap to populate the shared base `build/cartridge_base_arch.img`.
2. **Declarative Cartridge Builds (Rootless)**:
   - Once `build/cartridge_base_arch.img` is present, compiling recipes into standalone cartridges via `./cartilage build recipes/*.yaml` is **100% rootless** (zero sudo, zero Docker required) by utilizing user namespaces and pure-Python schema packaging.
3. **Composition & Flashing**:
   - `./cartilage compose` packages cartridges and UEFI bootloaders into a GPT disk image.
   - `./cartilage flash` safely writes GPT images to verified removable USB media with host drive safeguards.
