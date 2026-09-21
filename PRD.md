# Cartilage OS — Product Requirements Document (PRD)
## Phase 4: The Dual-Mode Appliance Platform & Developer Workstation

---

## 1. Executive Summary & Product Vision

### 1.1 The Vision
**Cartilage OS** is an open-source, bare-metal appliance engine that compiles declarative software recipes into immutable, hardware-isolated, sub-2-second bootable operating systems.

Traditional operating systems (Windows 11, Ubuntu, macOS) are monolithic, 20-gigabyte mutable state machines. They thrash spinning hard drives for minutes, run over 80 background surveillance and telemetry daemons, consume 3GB to 4GB of RAM at idle, and turn capable 2GB–4GB computers into electronic landfill.

Cartilage OS operates on a different thesis: **an operating system should be an appliance**. Like inserting a Game Boy cartridge into handheld hardware, a computer should boot instantly into a single dedicated task or a razor-focused workstation, run at native bare-metal speeds, and remain completely immune to malware, state decay, or user error.

### 1.2 Evolution: From Prototype to Enterprise-Grade Engine
* **Phase 1 (Proof of Concept)**: Demonstrated that an EROFS filesystem with a minimal Linux kernel, `cage`, and `seatd` can cold boot in 1.08s without systemd.
* **Phase 2 (Dual Runtimes & Stabilization)**: Added ultra-compact Alpine Linux (`musl`, 44.6 MB) alongside Arch Linux (`glibc`), full Chromium desktop kiosk mode, and early multi-boot disks.
* **Phase 3 (Unified Appliance Platform)**: Engineered the zero-dependency Python CLI (`./cartilage`), pure-Python rootless compiler (`builder.py`), modular `/init.d/` stage sequencing (`00-vfs` through `50-launch`), and universal ALSA `dmix` hardware audio multiplexing.
* **Phase 4 (The Dual-Mode Platform - Active)**: **Bridging Kiosks and Daily Computing**. Upgrading Cartilage from a rigid, partition-per-app model into a flexible dual-engine framework:
  1. **Mode 1 (Dedicated Appliance Kiosk)**: Single-app raw partition boot for ATMs, digital signage, single-purpose retro consoles, and medical field hardware.
  2. **Mode 2 (Dynamic Cartridge Hub — The "Ventoy" Model)**: Format USB once with exFAT, drag-and-drop `.img` cartridges into `/cartridges/`, loopback mounting with zero re-partitioning, and cross-platform curation on Windows, macOS, and Linux.
  3. **The Developer Workstation Duo**: Simultaneous execution of terminal + web browser in a shared lightweight Wayland compositor (`sway`/`dwl`) under 800 MB total RAM on 2GB silicon without rebooting.

---

## 2. Target Personas & Use Cases

| Persona | Primary Goal | Critical Requirement | Deployment Mode |
| :--- | :--- | :--- | :--- |
| **The Distraction-Free Developer** | Wants a blazing-fast, air-gapped coding terminal and documentation browser that boots in 2 seconds on a 2GB garage-sale laptop. | Sub-2s boot, simultaneous Terminal + Browser, persistent Git repos/dotfiles. | **Mode 2 (Hub) / Workstation** |
| **The Public Kiosk / POS Operator** | Deploys public kiosks (libraries, ticketing, self-checkout, digital signage) where users must never escape to a desktop or corrupt storage. | Single-app locked canvas, disabled hotkeys, shell masking (`/dev/null`), automatic restart on exit. | **Mode 1 (Dedicated Kiosk)** |
| **The Privacy / Security Researcher** | Needs an ephemeral, tamper-proof browsing environment where every session leaves zero cryptographic or forensic trace. | 100% read-only EROFS root, in-memory `tmpfs` OverlayFS, `zram` memory swap, state vaporizes on power-off. | **Mode 1 or 2 (Ephemeral)** |
| **The Offline Educator / Field Worker** | Carries a library of 10+ standalone educational tools, offline Wikipedia, and coding spaces on a single flash drive. | Plug-and-play USB management: add/remove appliances via Windows/macOS file managers without Linux tools. | **Mode 2 (Dynamic Hub)** |

---

## 3. Product Principles

1. **Dual-Mode Flexibility**: Support single-app hard-wired kiosks AND multi-app drag-and-drop flash drives using identical `.img` cartridge binaries.
2. **Zero Bandages**: No brittle sed/awk scripts, no unmanaged background daemons, no messy wrapper hacks. Every layer is deterministic.
3. **Sub-2-Second Boot Latency**: Cold UEFI power-on to active GUI must take under 2.5 seconds on physical media.
4. **Immutable by Default**: The operating system root is always read-only EROFS. Pulling the USB power plug can never corrupt the OS.
5. **No FUSE Allowed**: Native Linux kernel bind mounts (`mount --bind`) and mount namespaces (`unshare -m`) exclusively. Zero runtime memory overhead, native I/O speed, zero unkillable D-state lockups on USB removal.
6. **Zero-Sudo Development**: Compiling cartridges and testing locally in QEMU runs 100% in unprivileged userspace without `sudo` or Docker daemons.

---

## 4. The Two Deployment Paradigms

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

### 4.1 Mode 1: Dedicated Appliance Kiosk (Raw Block Deployment)
- **Target Hardware**: Single-purpose terminals, ATMs, digital advertising displays, dedicated media consoles.
- **Mechanism**: The target storage device contains a dedicated GPT partition for the specific appliance (`PARTLABEL=cartilage_<app>`).
- **Boot Flow**: UEFI -> `systemd-boot` -> Shared Kernel -> direct rootfs mount (`root=PARTLABEL=cartilage_<app> rootfstype=erofs`) -> `stages/init` -> fullscreen `cage` compositor.
- **Advantages**: Absolute minimum overhead, zero intermediate filesystem drivers, raw NAND I/O speeds.

### 4.2 Mode 2: Dynamic Cartridge Hub (File-Based Deployment)
- **Target Hardware**: Multi-purpose flash drives, hacker toolkits, student development stations.
- **Drive Partition Layout**:
  - **Partition 1 (ESP)**: 256 MB FAT32 containing UEFI bootloader, shared Linux kernel (`vmlinuz-linux`), and dynamic bootstrap loader (`initramfs-hub.img`).
  - **Partition 2 (CARTRIDGES)**: exFAT filesystem taking up the remainder of the disk. Readable and writeable natively on Windows, macOS, and Linux.
- **Folder Structure**:
  - `/cartridges/`: Users drop any number of `.img` files here via normal file manager copy.
  - `/data/`: Contains a sparse ext4 disk image (`data.img`) providing full POSIX filesystem semantics on top of exFAT.
- **Boot Flow**:
  1. Kernel boots into lightweight bootstrap `initramfs`.
  2. Scans block devices for `CARTRIDGES` exFAT partition and mounts at `/mnt/hub`.
  3. Discovers all `.img` files in `/mnt/hub/cartridges/`.
  4. If 1 cartridge: boots immediately. If multiple: renders an instantaneous (<100ms) TTY boot menu.
  5. Mounts selected cartridge via in-kernel loopback: `mount -t erofs -o loop,ro /mnt/hub/cartridges/<app>.img /sysroot`.
  6. Mounts persistent ext4 loop: `mount -t ext4 -o loop,rw /mnt/hub/data/data.img /sysroot/data`.
  7. Executes `switch_root /sysroot /init`.

---

## 5. The Flagship Hero Experience: Developer Workstation Duo

To resolve the workflow friction of rebooting between single-app cartridges, Cartilage introduces the **Developer Workstation Appliance** (`recipes/workstation-dev.yaml`):

```
+-----------------------------------------------------------------------------+
|               Unified Developer Workstation (2GB RAM Target)               |
+-----------------------------------------------------------------------------+
|                                                                             |
|  Workspace 1: Hacker Terminal (foot)        Workspace 2: Web Kiosk (chrome) |
|  +---------------------------------------+  +-----------------------------+ |
|  | $ git status                          |  | Documentation / Web Apps   | |
|  | $ vim src/main.rs                     |  | Local dev server inspection | |
|  | $ cargo build --release               |  | API testing                 | |
|  +---------------------------------------+  +-----------------------------+ |
|                                                                             |
|  Compositor: Lightweight Wayland Tiling (sway / dwl)                        |
|  Memory Budget: ~775 MB active / ~1.2 GB available for compilation         |
|  Switching: Mod+1 (Terminal) <---> Mod+2 (Browser) with zero reboot delay   |
+-----------------------------------------------------------------------------+
```

### Memory Budget on 2GB Silicon:
- **Shared Kernel & Page Tables**: ~120 MB
- **Wayland Tiling Compositor (`sway`/`dwl`)**: ~35 MB
- **Terminal (`foot`)**: ~25 MB
- **Browser (`chromium` / `dillo`)**: ~550 MB
- **Total Active Footprint**: **~730 MB**, leaving **over 1.2 GB of free RAM** for compilation, buffer caches, and user applications without touching swap.

---

## 6. Functional Requirements (FR)

### FR-1: Declarative Manifest Validation
The CLI must validate all appliance recipes against [`spec/cartilage.schema.json`](spec/cartilage.schema.json) before compilation or execution, returning line-numbered errors on invalid keys or types.

### FR-2: Pure-Python Rootless Cartridge Compiler
`cartilage build` must compile hermetic EROFS images using `fsck.erofs` and `mkfs.erofs -zlz4hc,12` without requiring `sudo`, `fakeroot` daemon escalation, or Docker.

### FR-3: Dynamic Hub Preparation & Boot
- `cartilage init-hub /dev/sdX` must format target media into the standard 2-partition ESP + exFAT layout with safety checks refusing fixed internal NVMe/SATA drives.
- The bootstrap `initramfs` must dynamically scan, discover, loop-mount, and `switch_root` into any valid EROFS cartridge in `/cartridges/`.

### FR-4: Workstation Multi-Window Compositor Support
The display subsystem must support both single-window kiosk compositing (`cage`) and multi-window tiling compositing (`sway`/`dwl`) configured via `display.compositor`.

### FR-5: Three Storage Paradigms
1. **Ephemeral Mode**: OverlayFS with memory-quota `tmpfs` upperdir backed by `zram` compressed memory swap.
2. **Persistent Mode**: Loop-mounted ext4 sparse image (`data.img`) or dedicated ext4 partition bound to `/data`.
3. **Host Access Mode**: Controlled read-only mount of internal host drives with TTY Developer Passcode gate (`cartilage42`) and loud rejection of hibernated/dirty Windows NTFS partitions.

### FR-6: Universal Audio Multiplexing
All appliances must output multi-client audio concurrently via kernel-level ALSA `dmix` without requiring background PulseAudio or PipeWire daemons.

---

## 7. Non-Functional Requirements (NFR)

* **NFR-1: Cold Boot Latency**: Cold boot from UEFI handoff to interactive GUI must complete in **< 2.0s** for Mode 1 (Dedicated) and **< 2.2s** for Mode 2 (Hub loopback).
* **NFR-2: Memory Efficiency**: Idle system RAM consumption must not exceed **90 MB** for terminal workstations, **350 MB** for media players, and **800 MB** for dual-app developer workstations.
* **NFR-3: Zero Host Storage Contamination**: Build and test workflows must never leave dangling loop devices, rootfs leakage in `/tmp`, or unmanaged temporary files.
* **NFR-4: Physical Removal Fault Tolerance**: Mid-session USB removal must trigger an immediate kernel-level clean reboot (`reboot -f`), never exposing an unauthenticated shell or dropping to broken systemd rescue prompts.
