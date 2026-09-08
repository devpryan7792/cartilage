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
