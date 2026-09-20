# Cartilage OS — 14-Day Roadmap

Goal at day 14: a public repo with a working `build_cartridge.sh`, two
demo cartridges booting in QEMU, a benchmark table with real numbers, and a
README that reads like an infra project, not a tutorial.

Rule for every day: **if a decision isn't in ARCHITECTURE.md, don't make a
new one — stop and flag it, don't improvise.**

---

### Day 1–2: Toolchain + base rootfs
- Confirm build host has: `arch-install-scripts`, `erofs-utils`,
  `qemu-full`, `grub` (or `systemd-boot` tooling), `debootstrap`/`pacstrap`.
- Load skill: `skills/01-toolchain-setup.md`.
- Script a minimal `pacstrap` call producing a bare Arch rootfs with no
  extra packages. Verify you can `arch-chroot` into it.
- **Checkpoint**: bare rootfs boots to a shell in QEMU with `init=/bin/sh`.

### Day 3–4: Module 2 — the cartridge
- Load skill: `skills/02-cartridge-builder.md`.
- Add `cage` + `seatd` + Mesa to the rootfs. Write the custom `/init`
  that starts `seatd`, then `cage -- <app>`.
- Pack with `mkfs.erofs`. Loop-mount and boot it in QEMU with a KMS/virtio
  GPU device.
- **Checkpoint**: QEMU boots straight into a full-screen test app (start
  with something trivial like `foot` or `alacritty` before attempting
  Chromium — de-risk the display pipeline before adding weight).

### Day 5–6: Module 3 — storage
- Load skill: `skills/03-storage-isolation.md`.
- Implement Ephemeral mode (tmpfs + OverlayFS + `zram`).
- Implement Persistent mode (bind mount of a second QEMU virtual disk
  standing in for the USB data partition).
- Implement Host Access mode: hidden `ro` global mount, TTY passcode gate,
  `unshare -m` + `mount --bind` for the requested subdirectory. Test the
  NTFS dirty-bit hard-fail path with a deliberately "dirty" test image.
- **Checkpoint**: all three modes demonstrably work against a virtual
  second disk in QEMU.

### Day 7–8: Module 4 — the builder CLI
- Load skill: `skills/02-cartridge-builder.md` (same skill, now the CLI
  wrapper, not the manual steps).
- Turn days 1–6's manual steps into `build_cartridge.sh --app <name>
  --runtime arch`. Input: an app name or a path to a `.deb`. Output: a
  bootable `.img`.
- **Checkpoint**: running the script twice for two different apps (e.g. a
  browser and a text editor) produces two independent, correctly-sized
  `.img` files with no manual intervention.

### Day 9–10: Boot menu + full integration
- Load skill: `skills/04-boot-pipeline.md`.
- Wire up the bootloader menu listing both cartridges from a single
  simulated USB image (one shared kernel/firmware partition + two `.img`
  files).
- **Checkpoint**: boot the combined image in QEMU, pick each cartridge
  from the menu, confirm both launch correctly.

### Day 11: Debug console
- Load skill: `skills/05-debug-console.md`.
- Wire the second-TTY passcode-gated shell. Confirm the running app cannot
  reach that shell from inside its own mount namespace.
- **Checkpoint**: `Ctrl+Alt+F2` from within a booted cartridge in QEMU
  drops to the passcode prompt, then a working shell with `dmesg`/`ip
  link` available.

### Day 12: Benchmarks
- Measure, don't estimate: boot-to-app time, idle RAM, cartridge file
  size, for both demo cartridges.
- Write `BENCHMARKS.md` with the raw numbers and the command used to
  measure each one (so it's reproducible, not just asserted).

### Day 13: README + demo capture
- Record a short terminal/QEMU screen capture (GIF or short video) of
  boot-to-app for both cartridges.
- Write the README: what it is, the architecture diagram (ASCII is fine),
  the three storage modes, the FUSE-vs-bind-mount and EROFS-vs-SquashFS
  decisions with one-paragraph justifications each, the stated threat
  model and its explicit limits (§8 of ARCHITECTURE.md), benchmark table,
  and how to run it yourself in QEMU.

### Day 14: Buffer + publish
- Use this day for whatever slipped, not new scope. If everything above
  landed on time, spend it polishing the README and the demo capture —
  that's what a reviewer actually looks at in the first 90 seconds.
- Publish the repo public.

---

# Phase 2 — Production Appliance Roadmap

### Day 15: Milestone 1 — Network & DNS Subsystem
- Hook network device settling (`udevadm settle`) into `/init`.
- Implement non-blocking DHCP client (`dhcpcd` or `udhcpc`) on primary interface.
- Route `/etc/resolv.conf` to `/run/resolv.conf` on tmpfs with fallback DNS (`1.1.1.1`).
- Write and run `scripts/10_test_networking.sh`.

### Day 16: Milestone 2 — Audio Subsystem
- Configure `/etc/asound.conf` with ALSA `dmix` multi-stream mixing.
- Grant `audio` group permissions to user `cartilage` (`UID 1000`).
- Verify sound playback without background daemons via `scripts/11_test_audio.sh`.

### Day 17–18: Milestone 3 — Modern Web Kiosk Runtime (Chromium)
- Configure Ozone Wayland flags and GPU hardware acceleration parameters.
- Verify nested user namespace sandbox (`sysctl kernel.unprivileged_userns_clone=1`).
- Mount 512MB `/dev/shm` tmpfs and pre-bake font caches (`fc-cache -fv`).
- Build Chromium cartridge and verify kiosk operation in QEMU.

### Day 19: Milestone 4 — Bare-Metal Physical USB Flasher
- Write `scripts/13_flash_usb.sh` with target safety verification.
- Write GPT layout (ESP, Cartridges, `CARTDATA`) and install UEFI fallback binary.
- Migrate bootloader entries to `PARTLABEL` root parameters.
- Test booting flashed image with `scripts/13_test_flasher.sh`.

### Day 20–21: Milestone 5 — Alpine Lightweight Runtime
- Implement `--runtime alpine` in `build_cartridge.sh` using `apk.static` and `musl`.
- Build an ultra-lean GUI cartridge (<50MB) and benchmark boot latency and RAM.
- Update `BENCHMARKS.md` and `README.md` with Phase 2 capabilities.

---

# Phase 3 — The Cartilage Appliance Framework ("The Bigger Shift")

### Day 22: Milestone 6 — Manifest Specification (`cartilage.yaml`) & Schema Engine
- Create `spec/cartilage.schema.json` defining the declarative appliance specification.
- Implement manifest validator checking required sections: `appliance`, `runtime`, `display`, `storage`, `hardware`.
- Establish standard recipe directory structure under `recipes/`.

### Day 23–24: Milestone 7 — Unified `cartilage` CLI Engine
- Implement the core CLI tool `cartilage` in standard Python 3 (zero external dependencies).
- Support subcommands: `validate`, `build`, `run`, `compose`, `flash`.
- Automatically map hardware and display flags from manifest to QEMU runner, replacing legacy shell/batch launchers.

### Day 25–26: Milestone 8 — Modular Stage-Based Init Pipeline (`/init.d/`)
- Break the monolithic 600-line `/init` heredoc into modular, testable stage scripts (`/init.d/00-vfs.sh` through `50-launch.sh`).
- Add robust error boundaries: graceful fallback to in-memory OverlayFS if persistent storage is read-only, and software rasterizer fallback (`pixman`) if hardware DRM is absent.

### Day 27: Milestone 9 — Standard Recipe Hub
- Migrate appliances into declarative recipes:
  - `recipes/browser-chromium.yaml` (Desktop Wayland browser)
  - `recipes/browser-dillo.yaml` (Ultra-fast lightweight browser)
  - `recipes/editor-mousepad.yaml` (Lean text editor)
  - `recipes/terminal-foot.yaml` (Minimalist terminal station)
- Verify end-to-end compilation with `cartilage build`.

### Day 28: Milestone 10 — Bare-Metal Hardware Compatibility & Final Release
- Verify universal GPU driver probing (Intel `i915`, AMD `amdgpu`, VirtIO) with software fallback.
- Run `cartilage flash` to burn bootable multi-appliance USB media.
- Document real hardware boot performance and tag release `v3.0.0`.


