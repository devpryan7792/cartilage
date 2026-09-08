# Cartilage OS — SPEC.md

This is the acceptance-criteria document. `ARCHITECTURE.md` says *what* to
build and *why*. `AGENT_TASKS.md` says *what order*. This file says
**how you know each task is actually done** — a concrete output, a
concrete test, or a concrete command whose result you check, not a
judgment call. If a task doesn't have a clear pass/fail here, don't mark
it complete — flag it and ask, don't guess.

Where useful, each task lists a real open-source repo to read for pattern
inspiration. These are references for *how something is structured*, not
dependencies to pull in wholesale — don't vendor code from them, read them
to understand the shape of a correct solution, then write your own.

---

## Task 1 — Base rootfs

**Done when:**
- `pacstrap -c rootfs/ base linux linux-firmware` completes with exit
  code 0 and `rootfs/` contains a standard Arch filesystem tree.
- `arch-chroot rootfs/ /bin/true` exits 0.
- Booting `rootfs/` in QEMU with `-append "init=/bin/sh"` and
  `-serial stdio` produces a visible `sh` prompt on the serial console
  within 10 seconds, with no kernel panic in the log.

**Test command:**
```bash
qemu-system-x86_64 -kernel rootfs/boot/vmlinuz-linux \
  -append "console=ttyS0 init=/bin/sh" -serial stdio -nographic \
  -m 512M
```
Pass = you see a shell prompt. Fail = panic, hang past 30s, or no output.

**Reference repo:** [archiso](https://gitlab.archlinux.org/archlinux/archiso)
— read `configs/releng/` to see how Arch structures its own
`pacstrap`-based profile. You're building a much smaller version of the
same idea (a profile that produces a bootable rootfs), not using archiso
itself.

---

## Task 2 — Cartridge packaging (Module 2)

**Done when:**
- `mkfs.erofs cartridge.img rootfs/` produces a file, and
  `file cartridge.img` reports EROFS filesystem data.
- Loop-mounting it read-only succeeds: `mount -o loop,ro cartridge.img
  /mnt/test && ls /mnt/test/init` shows the init script present and
  executable.
- Booting the `.img` in QEMU with a virtio-gpu device shows a trivial
  test app (start with `foot` or a plain colored `cage` background before
  attempting a real app) rendered full-screen, with `seatd` confirmed
  running via the serial log before `cage` starts.
- `/bin/bash` and `/bin/busybox` are present in the image
  (`ls rootfs/bin/bash` before packaging) — confirming you did NOT strip
  them, per ARCHITECTURE.md §6.

**Test command:**
```bash
qemu-system-x86_64 -drive file=cartridge.img,format=raw,if=virtio \
  -vga virtio -serial stdio -m 1024M
```
Pass = full-screen test app visible, serial log shows `seatd` start line
before `cage` start line, no `SIGSEGV`/`SIGBUS` in the log during normal
launch.

**Reference repos:**
- [cage](https://github.com/cage-kiosk/cage) — read the README and
  `main.c` to understand exactly what cage expects at launch (env vars,
  seat handoff). This is the actual compositor you're bundling, not just
  inspiration — but read it before treating it as a black box.
- [seatd](https://git.sr.ht/~kennylevinsen/seatd) — read `docs/` for how
  the seat handoff protocol works; this explains *why* seatd must start
  first, not just that it must.
- [postmarketOS `pmbootstrap`](https://gitlab.com/postmarketOS/pmbootstrap)
  — good reference for a minimal custom `/init` script structure on a
  stripped rootfs, similar spirit to what you're writing.

---

## Task 3 — Ephemeral mode

**Done when:**
- Inside a booted cartridge, `mount | grep overlay` shows the app's
  writable layer is an OverlayFS with `upperdir` on `tmpfs`.
- `mount | grep tmpfs` shows the download-target tmpfs has a `size=`
  option set (not unbounded).
- Attempting to write a file larger than the quota fails with `ENOSPC`
  (visible as "No space left on device" from a simple `dd` test), and the
  system does **not** panic or OOM-kill unrelated processes.
- `zramctl` (run from the debug console once Task 8 exists, or via serial
  log at boot) shows at least one active zram device using `zstd`.

**Test command (inside the booted VM):**
```bash
dd if=/dev/zero of=/data/downloads/test.bin bs=1M count=999999
```
Pass = clean `dd: error writing ... No space left on device`, system
stays responsive. Fail = kernel OOM message, panic, or silent truncation
with no error.

**Reference repo:** [OverlayFS kernel docs](https://www.kernel.org/doc/html/latest/filesystems/overlayfs.html)
— not a project repo, but read this directly rather than a tutorial; it's
short and it's the actual spec for the mount options you're using.

---

## Task 4 — Persistent mode

**Done when:**
- A second QEMU virtual disk is attached, formatted, and bind-mounted
  into the app's `/data` at boot.
- Writing a file, then rebooting the VM (not just restarting the app),
  results in the file still being present.

**Test command:**
```bash
# inside VM
echo "persisted" > /data/marker.txt
reboot
# after reboot, inside VM again
cat /data/marker.txt
```
Pass = `persisted` printed after reboot. Fail = file missing or the
reboot doesn't cleanly re-mount the data partition.

---

## Task 5 — Host Access mode

**Done when:**
- A third virtual disk simulating "the host's internal drive" is
  attached, mounted `ro` globally under a hidden path at boot, and is
  **not** visible from inside the app's own mount namespace by default
  (`ls /` from the app's context should not reveal it).
- Entering the correct passcode at the TTY prompt and selecting a
  subdirectory results in that subdirectory becoming visible and
  writable at `/app/workspace` inside the app's namespace.
- A second virtual disk deliberately formatted/flagged as "dirty" NTFS
  (or simulated via a marker file/flag your script checks for, if a real
  dirty-bit test image is impractical in QEMU) triggers the documented
  hard-fail: a clear error message on the TTY, and the mount stays `ro`.

**Test commands:**
```bash
# happy path: from app namespace, before auth
ls /mnt/hidden_host        # should fail — not visible

# after TTY passcode + directory selection
ls /app/workspace          # should show the chosen subdirectory's contents
touch /app/workspace/test.txt   # should succeed on a clean volume

# dirty-volume path
# (simulate however is practical) — write attempt should fail loud with
# the documented message, not silently downgrade
```
Pass = all three behaviors match exactly. Fail = any silent failure, any
success where a failure was expected, or vice versa.

**Reference repo:** [bubblewrap (bwrap)](https://github.com/containers/bubblewrap)
— read `bubblewrap.c` for a real, battle-tested example of building a
restricted mount namespace with selective bind mounts. You are not using
bwrap itself (it's a general sandboxing tool, heavier than you need), but
its approach to "namespace, then bind mount only what's explicitly
allowed" is exactly the pattern this task implements by hand with
`unshare`/`mount --bind`.

---

## Task 6 — Builder CLI

**Done when:**
- `./build_cartridge.sh --app firefox --runtime arch` and
  `./build_cartridge.sh --app leafpad --runtime arch` can be run back to
  back (or in parallel in separate temp dirs) and produce two distinct,
  correctly-named `.img` files without manual cleanup between runs.
- Re-running the script for the same app a second time produces a
  functionally equivalent image (idempotent — not bit-identical
  necessarily, but not broken or partial).
- Passing a `.deb` file path instead of a package name successfully
  extracts and packages that binary.

**Test command:**
```bash
./build_cartridge.sh --app leafpad --runtime arch
./build_cartridge.sh --app ./downloads/google-chrome-stable.deb --runtime arch
ls -la *.img   # both should exist, non-zero size, different sizes
```

**Reference repo:** [mkosi](https://github.com/systemd/mkosi) — this is
the closest real-world analog to what you're building: a CLI that takes a
declarative target and outputs a bootable OS image. Read its `resources/`
and how it structures build steps; don't adopt its config format
wholesale, but the separation between "define what goes in" and "produce
the image" is the right shape to copy.

---

## Task 7 — Boot menu integration

**Done when:**
- One combined disk image contains the shared kernel/firmware partition,
  both cartridge `.img` files, and the data partition.
- Booting it in QEMU shows a bootloader menu listing both cartridges by
  name (not by raw filename/UUID — actual readable labels).
- Selecting each entry boots into the correct app, confirmed visually or
  via a distinguishing marker in the serial log.

**Test command:**
```bash
qemu-system-x86_64 -drive file=cartilage-combined.img,format=raw \
  -vga virtio -serial stdio -m 1024M -bios /usr/share/OVMF/OVMF_CODE.fd
```
Pass = menu visible, both entries selectable, both boot correctly across
two separate QEMU runs (test both entries, not just the first one).

**Reference repo:** [Ventoy](https://github.com/ventoy/Ventoy) — not for
its actual multi-ISO mechanism (that's a different problem, booting
foreign ISOs), but its documentation on GRUB menu generation from a
directory of images is a useful pattern reference for building your
`systemd-boot`/GRUB entries programmatically rather than hand-writing
each one.

---

## Task 8 — Debug console

**Done when:**
- Switching VT (`Ctrl+Alt+F2` equivalent in QEMU: usually
  `Ctrl+Alt+F2` works if `-vga virtio` and a Linux VT are both present;
  otherwise use `sendkey` via the QEMU monitor) presents a login prompt.
- Entering the correct Developer Passcode drops to a working shell with
  `dmesg` and `ip link` both producing real output.
- From inside the running app's context (its own mount namespace/PID
  namespace if used), there is no path to reach this shell or its
  binaries — verify by confirming the app's namespace doesn't expose
  `/bin/bash` at any visible path.

**Test commands:**
```
(qemu) sendkey ctrl-alt-f2
# enter passcode at prompt
dmesg | tail -5
ip link show
```
Pass = shell reachable only via this path, both diagnostic commands work.

---

## Task 9 — Benchmarks

**Done when:** `BENCHMARKS.md` exists with, for each of the two demo
cartridges:
- Boot-to-app time in seconds, with the measurement method stated
  (e.g. "timestamp at QEMU process start vs. timestamp of first rendered
  frame, averaged over 3 runs").
- Idle RAM usage (`free -h` output pasted, taken 10 seconds after app
  launch with no user interaction).
- Final `.img` file size (`ls -la` output).

No estimates, no "should be around X" — every number in this file must
have been actually measured on an actual run, and the command used to
measure it must be shown next to the number.

---

## Task 10 — README + demo

**Done when:**
- A screen recording (GIF or short video, both cartridges) is embedded or
  linked.
- The README contains, at minimum: what the project is (one paragraph),
  the architecture diagram, the three storage modes explained briefly,
  short justification paragraphs for the FUSE-vs-bind-mount and
  EROFS-vs-SquashFS decisions, the benchmark table from Task 9, the
  explicit threat-model limitation statement from `ARCHITECTURE.md` §8,
  and exact reproduction steps (clone, install deps, run
  `build_cartridge.sh`, boot in QEMU) that someone with zero prior context
  could follow.
- **Test this literally**: have the agent (or you) follow the README's
  own reproduction steps on a clean checkout / clean directory, with no
  assumed leftover state. If it doesn't work from scratch, the README
  isn't done, regardless of how the prose reads.

**Reference repo:** any of [Bazzite](https://github.com/ublue-os/bazzite),
[archiso](https://gitlab.archlinux.org/archlinux/archiso), or
[mkosi](https://github.com/systemd/mkosi) — not for content, but for
README *structure*: they all lead with what it is and a visual before any
deep technical explanation. Copy that ordering, not their words.

---

## General rule across all tasks

A task is marked complete in `AGENT_TASKS.md` only when its "Done when"
criteria above are met and the listed test command has actually been run
and its output checked — not when the code "should" work. If a test can't
be run for some reason (missing hardware, QEMU limitation), say so
explicitly next to the checkbox instead of marking it done.
