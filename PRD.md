# Cartilage OS — Product Requirements Document (PRD)
## Phase 3: The Cartilage Appliance Framework ("The Bigger Shift")

---

## 1. Executive Summary & Product Vision

### 1.1 The Vision
**Cartilage OS** is an open-source, bare-metal appliance engine that compiles applications into immutable, hardware-isolated, sub-2-second bootable operating systems. 

Traditional operating systems (Ubuntu, Windows, Fedora) are general-purpose behemoths carrying gigabytes of background daemons, systemd services, login managers, analytics telemetry, and desktop environment overhead. Even minimal container solutions (Docker, Podman) require a running host kernel, userland daemon, and host desktop to project graphics.

Cartilage OS eliminates the middleman: **your application *is* the operating system**. 

A single USB drive or NVMe partition boots directly from UEFI in under 2 seconds into a dedicated, hardware-accelerated Wayland application session (such as a secure Chromium web browser, a focused code editor, or an isolated Bitcoin cold-vault) with zero desktop bloat, zero background services, and strict storage isolation.

### 1.2 Evolution: From Prototype ("Boat of Bandages") to Engineered Engine
* **Phase 1 (Proof of Concept)**: Proved the physics. Demonstrated that an EROFS filesystem running on a minimal Linux kernel with `cage` and `seatd` can boot in 1.08 seconds without systemd.
* **Phase 2 (Stabilization - v2.0.0)**: Proved multi-runtime versatility. Added an ultra-lean 44.8 MB Alpine musl runtime, full Chromium desktop browser mode (tabs, omnibox, Anycast DNS), and rootless UEFI GPT multi-boot disks.
* **Phase 3 (The Bigger Shift - Active)**: **Engineering the Real Ship**. Moving away from imperative 1,000-line shell scripts, duplicated launchers, and fragile ad-hoc flags into a **declarative, unified appliance compiler and runtime framework**.

---

## 2. Target Users & Core Personas

| Persona | Motivation | Key Requirement |
| :--- | :--- | :--- |
| **The Focused Developer** | Wants an instant, distraction-free coding terminal or air-gapped dev environment that boots in 2 seconds on any machine without touching the host OS. | Fast boot, persistent local project storage, USB plug-and-play. |
| **The Privacy / Security Researcher** | Needs an ephemeral, tamper-proof browsing station where every reboot leaves zero cryptographic or forensic footprint on the device. | 100% read-only EROFS root, tmpfs OverlayFS, zero host disk leakage. |
| **The Homelab / Appliance Builder** | Wants to turn spare x86_64 PCs into single-purpose appliances (digital signage, dashboard display, media workstation, diagnostic kiosk). | Declarative YAML specification, low RAM usage (< 256MB idle), automatic hardware detection. |
| **The Public Kiosk Operator** | Deploys public terminals (libraries, clinics, schools) where users must not be able to break out of the target application or access system settings. | Locked-down kiosk mode, binary masking (`/dev/null` bound over shells), automated crash restart. |

---

## 3. Product Principles (The Ground Reality)

1. **Zero Bandages**: No brittle sed/awk hacks, no monolithic 1,000-line shell scripts. Every component must be modular, deterministic, and self-contained.
2. **Declarative Over Imperative**: Users describe *what* the appliance needs (`cartilage.yaml`), not *how* to mount partitions or configure QEMU flags.
3. **Sub-2-Second Boot-to-App**: From UEFI handoff to the first graphical frame of the application must take less than 2 seconds on physical NVMe/USB 3.2.
4. **Immutable by Default**: The root filesystem is always read-only EROFS. State is explicitly opted into via declared storage policies.
5. **Universal Silicon Compatibility**: Must boot on real-world bare metal (Intel Core/Xeon, AMD Ryzen, Intel Iris/UHD, AMD Radeon, standard Realtek/Intel Ethernet and Wi-Fi) with graceful software fallback if hardware DRM is missing.
6. **Zero-Sudo Development**: Compiling cartridges, building multi-boot images, and running local virtual tests must run entirely in unprivileged userspace.

---

## 4. Architectural Pillars of Phase 3

### 4.1 Pillar 1: Declarative Appliance Manifest (`cartilage.yaml`)
A single, validated configuration file defines the complete appliance profile.

```yaml
appliance:
  name: web-station
  version: "1.0.0"
  description: "Secure, immutable web browser workstation"

runtime:
  engine: arch          # alpine (lean musl) or arch (glibc)
  packages:
    - chromium
    - cage
    - seatd
    - ttf-dejavu

display:
  compositor: cage      # Wayland kiosk compositor
  mode: desktop         # desktop (tabs + omnibox) or kiosk (fullscreen locked)
  entrypoint: /usr/bin/chromium
  args:
    - "--start-maximized"
    - "https://duckduckgo.com"

storage:
  mode: persistent      # ephemeral | persistent | host-access
  partition_label: CARTDATA
  download_quota: 256M

hardware:
  network: true         # Automatic DHCP + Anycast DNS
  audio: true           # ALSA dmix multi-stream mixing
  acceleration: auto    # Auto-detects DRM/KMS, fallback to software rendering
```

### 4.2 Pillar 2: The Unified `cartilage` CLI
A single, clean CLI tool written in standard Python (zero external pip dependencies) that replaces all 15 legacy scripts and 10 launcher files:

```bash
# Compile an appliance from manifest to EROFS cartridge
cartilage build recipes/web-station.yaml

# Test an appliance in QEMU with automatically matched hardware arguments
cartilage run recipes/web-station.yaml

# Create a multi-boot UEFI GPT drive containing multiple recipes
cartilage compose -o build/cartilage_combined.img recipes/web-station.yaml recipes/coder-station.yaml

# Flash a bootable appliance directly to physical USB storage
cartilage flash --target /dev/sdX recipes/web-station.yaml
```

### 4.3 Pillar 3: Modular Stage-Based Init Runner (`/init.d/`)
The single 600-line bash `/init` heredoc is replaced by a structured, deterministic stage pipeline:

```text
/init (PID 1 Master Dispatcher)
  ├── 00-vfs.sh        # Mounts /proc, /sys, /dev, /dev/pts, /dev/shm, /run, /tmp
  ├── 10-hardware.sh   # Coldplug udevadm/mdev, loads GPU/DRM, input, storage modules
  ├── 20-network.sh    # Detects interfaces, triggers background DHCP, configures DNS
  ├── 30-storage.sh    # Evaluates storage policy (ephemeral tmpfs vs persistent ext4)
  ├── 40-security.sh   # Sets up namespaces, drops capabilities, masks shells if needed
  └── 50-launch.sh     # Starts seatd, launches Wayland compositor, execs app
```
* **Fault-Tolerant Error Boundaries**: If persistent storage is read-only or corrupted, `/init` does not panic; it logs a warning and cleanly falls back to an in-memory OverlayFS.

### 4.4 Pillar 4: Real Bare-Metal Portability
* **Graphics**: Probes `/dev/dri/card*` for Intel (`i915`), AMD (`amdgpu`), and VirtIO. If missing or unsupported, automatically exports `WLR_RENDERER=pixman` and `LIBGL_ALWAYS_SOFTWARE=1` to ensure the display server never crashes.
* **Input**: Configures `seatd` and `libinput` to dynamically handle USB keyboards, mice, trackpads, and touchscreens.
* **Firmware**: Integrates compressed `linux-firmware` blobs required for modern Wi-Fi, Ethernet, and GPU initialization.

---

## 5. Functional Requirements (FR)

* **FR-1: Manifest Validation**: CLI validates `cartilage.yaml` against a strict JSON Schema before performing any build or run operation.
* **FR-2: Hermetic Cartridge Building**: Builds immutable EROFS images using `mkfs.erofs` with LZ4 compression, stripping unneeded documentation, manual pages, and debug symbols.
* **FR-3: Multi-Runtime Engines**: Supports both Alpine Linux (musl libc, APK package manager, <50MB footprint) and Arch Linux (glibc, Pacman package manager, broad library compatibility).
* **FR-4: Display Mode Control**: Supports `desktop` mode (full browser controls, omnibox, tabs) and `kiosk` mode (locked canvas, fullscreen, no address bar).
* **FR-5: Rootless UEFI Composition**: Generates GPT multi-boot disk images with `systemd-boot`, UEFI fallback loaders (`BOOTX64.EFI`), and multiple cartridge partitions without requiring `sudo`.
* **FR-6: Hardware-Isolated Sandboxing**: Masks shells (`/bin/bash`, `/bin/sh`) inside app namespaces when configured, isolating apps from the host file system.

---

## 6. Non-Functional Requirements (NFR)

* **NFR-1: Performance**: Cold boot time from bootloader selection to application render must be under **2.5 seconds** on physical hardware.
* **NFR-2: Resource Efficiency**: Base system idle memory consumption must not exceed **80 MB** for Alpine runtimes and **280 MB** for Arch glibc runtimes.
* **NFR-3: Developer Ergonomics**: A developer must be able to define, compile, and run a new appliance in under **3 terminal commands**.
* **NFR-4: Zero Host Contamination**: Cartilage builds must never leave dangling loop mounts, temporary rootfs directories in `/tmp`, or unmanaged disk files.

---

## 7. Success Criteria & Phase 3 Milestones

1. **Milestone 1 (Manifest & CLI Core)**: Complete specification schema and working `cartilage` CLI tool able to parse, validate, and launch appliances.
2. **Milestone 2 (Modular Stage Runner)**: Refactor `/init` into deterministic `/init.d/` stage scripts with full error boundaries and zero kernel panic points.
3. **Milestone 3 (Standard Recipe Hub)**: Provide production-ready recipes for `recipes/browser-chromium.yaml`, `recipes/browser-dillo.yaml`, `recipes/editor-mousepad.yaml`, and `recipes/terminal-foot.yaml`.
4. **Milestone 4 (Bare-Metal Verification)**: Flash a combined USB image to physical hardware, boot on real silicon, and document hardware compatibility.
