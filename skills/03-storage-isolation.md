# Skill: Storage Isolation (Module 3)

Load before: Parts 3, 4, 5 (Ephemeral, Persistent, Host Access modes).

## Fixed decisions — do not re-derive these
- **FUSE is banned everywhere in this module.** Use kernel bind mounts
  (`mount --bind`) inside mount namespaces (`unshare -m`) exclusively.
- **No 15-minute token, no background revocation daemon, no dynamic
  mid-session privilege escalation.** Access granted at boot/auth time
  persists until reboot or explicit unmount. This was explored and
  explicitly dropped — do not re-add it.
- NTFS handling uses the in-kernel `ntfs3` driver, not `ntfs-3g` in
  userspace, unless `ntfs3` proves genuinely broken for a specific test
  case — if so, flag it, don't silently swap drivers.

## Ephemeral mode
- OverlayFS: `lowerdir` = the read-only EROFS cartridge, `upperdir`/
  `workdir` = tmpfs.
- Enforce a hard `size=` quota on the tmpfs used for downloads. On quota
  hit, the correct behavior is the kernel rejecting the write syscall
  ("disk full") — **not** a password prompt, **not** overflow storage.
  If the app crashes instead of showing a clean error, that's acceptable
  for v1; do not build custom error-handling UI for it.
- `zram` (zstd) should be active for swap/compressed-memory purposes on
  low-RAM targets. Confirm with `zramctl`, don't just assume the module
  loaded.

## Persistent mode
- Bind-mount the USB's own data partition into the app's `/data` (or
  equivalent). Core OS image stays untouched/read-only.

## Host Access mode
- Internal/host drives mount `ro` by default, globally, under a path
  **not visible to the app** (e.g. outside its future mount namespace).
- TTY passcode gate (shared with the debug console auth — see skill 05)
  triggers: pick a specific subdirectory, `unshare -m` for the app, then
  `mount --bind <chosen subdir> /app/workspace` inside that namespace.
- **NTFS dirty-bit / BitLocker rule**: if write access is requested
  against a volume with the hibernation/dirty bit set, or that's
  BitLocker-encrypted, **hard-fail loud**. Print the exact corrective
  instruction (disable Windows Fast Startup) to the TTY and drop to `ro`.
  Never silently downgrade without telling the user why.
