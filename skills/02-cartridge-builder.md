# Skill: Cartridge Builder (Module 2 + Module 4)

Load before: Part 2 (packaging), Part 6 (CLI wrapper).

## Fixed decisions — do not re-derive these
- Package format is **EROFS**, not SquashFS. Use `mkfs.erofs`.
- Delivery is **loop-mount off the USB directly**. No `copytoram`, no
  pivoting to an internal drive. Rely on the Linux page cache.
- `SIGBUS` on drive removal is an **accepted risk**, not a bug to fix. Do
  not add `mlock()`, `vmtouch`, or any page-pinning mechanism.
- `seatd` must start before `cage`. `cage` needs seat permissions to touch
  `/dev/dri/*` without `systemd-logind`.
- **`/bin/bash` and `/bin/busybox` stay in the image.** Do not strip them
  out. They are used by the debug console (Part 8 / skill 05), not
  exposed to the app itself.
- PID 1 behavior: if `cage` exits for any reason (clean exit or crash),
  the init script runs `reboot -f`. No fallback shell on PID 1 death.

## Sanitization pass (safe to do)
- Delete `/usr/share/man`, `/usr/share/doc`, non-essential
  `/usr/share/locale` entries.
- `strip --strip-unneeded` on binaries and shared libraries.

## Builder CLI contract (Part 6)
```
build_cartridge.sh --app <name|path-to-deb> --runtime arch
```
- `--runtime arch` is the only supported value for v1. `alpine` is a
  stretch goal outside the 14-day scope — do not build it unless
  everything in ROADMAP.md through Day 13 is already done.
- Input can be a repo/AUR package name or a path to a `.deb`. For `.deb`
  inputs, extract into the chroot and resolve `.so` dependencies via
  `pacman`/`ldd`, don't hand-roll a dependency resolver.
- Output: one `.img` file per invocation. Running it twice for two
  different apps must not interfere with each other's build state — use a
  fresh temp chroot per invocation, don't reuse a dirty staging directory.
