# Skill: Debug Console

Load before: Part 8.

## Context — why this exists
Earlier design iterations removed all shell access from the image
entirely (no `/bin/sh`, kernel `panic=10` on any failure, hard reboot with
no fallback). That was correctly identified as a dead end: it makes the
system undebuggable for any user other than the original builder. This
skill defines the resolved, permanent answer — do not remove the shell
again.

## Fixed decisions
- `bash`/`busybox` remain installed in the Arch-runtime cartridge image
  (see skill 02). They are reachable only via a second virtual terminal,
  never from within the running app's own process/mount namespace.
- Switching VT (e.g. `Ctrl+Alt+F2`) presents a login prompt gated by the
  **same Developer Passcode** used for Host Access mode (skill 03). Do
  not build a second, separate credential — one auth codepath, reused.
- No SSH daemon, no network-exposed shell, no `ttyd`/Cockpit/web
  dashboard for v1. Physical-console-only.

## Checkpoint definition
From within a booted cartridge in QEMU: switch VT, authenticate with the
passcode, confirm a working shell with `dmesg` and `ip link` available.
Separately confirm the app's own sandbox/namespace has no path to reach
this shell or its binaries.
