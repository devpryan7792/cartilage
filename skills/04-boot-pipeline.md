# Skill: Boot Pipeline (multi-cartridge menu)

Load before: Part 7.

## Fixed decisions
- One shared kernel + `linux-firmware` partition on the drive. Firmware is
  always bundled in full — no size-optimization flag for v1.
- Bootloader (decided once in skill 01, likely `systemd-boot`) presents a
  menu with one entry per cartridge `.img`. Selecting an entry passes an
  identifying kernel parameter (e.g. `cartridge=browser`) so the shared
  init script knows which `.img` to loop-mount.
- Do not build a custom graphical boot menu, Plymouth, or any splash
  screen. The bootloader's native text menu is sufficient and correct for
  v1 — this was explicitly decided against adding polish here.

## Layout of the combined test image
```
[ EFI/bootloader partition ]
[ shared kernel + initramfs + linux-firmware ]
[ cartridge-a.img ]
[ cartridge-b.img ]
[ data partition (persistent mode + host-access staging) ]
```

## Checkpoint definition
Boot the combined image in QEMU, confirm the menu lists both cartridges by
name, confirm selecting each one loop-mounts the correct `.img` and
launches the correct app — not just that the menu renders.
