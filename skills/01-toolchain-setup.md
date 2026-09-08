# Skill: Toolchain Setup

Load before: Part 1 (base rootfs).

## Required tools on the build host
- `arch-install-scripts` (provides `pacstrap`, `arch-chroot`)
- `erofs-utils` (provides `mkfs.erofs`)
- `qemu-full` or equivalent (`qemu-system-x86_64` minimum)
- `grub` or `systemd-boot` tooling — pick ONE at the start of Part 1 and do
  not switch later. Default to `systemd-boot` if the build host is
  UEFI-capable in QEMU (`OVMF` firmware); it's less config surface than
  GRUB for a single-purpose menu.
- `dosfstools`/`e2fsprogs` for partitioning the test USB image

## Ground rules
- Do not install a display manager, `systemd` targets beyond the bare
  minimum, or any daemon not explicitly named in ARCHITECTURE.md.
- The base rootfs from `pacstrap` should include `base`, `linux`,
  `linux-firmware`, and nothing else at this stage. Everything else
  (cage, seatd, the app) gets added in Part 2.
- Verify at every step by booting in QEMU, not by inspecting the rootfs
  tree and assuming it will boot. Assumptions about boot behavior are
  wrong more often than not — always check with `-serial stdio` on the
  QEMU invocation so kernel/init output is visible.
