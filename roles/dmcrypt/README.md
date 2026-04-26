# dmcrypt

Manages `/etc/conf.d/dmcrypt` and the `/etc/local.d` unlock helpers
that mount `/boot` and turn on swap *after* the encrypted ZFS root has
mounted. Used only on bootstrap.sh-installed bare-metal hosts.

## What it does

1. `apk add cryptsetup device-mapper`.
2. Reads the existing `/etc/conf.d/dmcrypt` to detect the target disk
   (`source='/dev/nvme0n1pX'` → `dmcrypt_disk = /dev/nvme0n1`,
   `dmcrypt_part_prefix = /dev/nvme0n1p`). This avoids re-encoding the
   disk path in inventory.
3. Re-renders `/etc/conf.d/dmcrypt` from `dmcrypt_containers`.
4. Drops `/etc/local.d/{boot,swap}.{start,stop}` (when
   `dmcrypt_use_localdotdee: true`) — `mount /boot` and
   `swapon /dev/mapper/swap` after ZFS finishes mounting.
5. Adds `dmcrypt` to `boot` runlevel, `local` to `default`.

## Why local.d?

The `/boot` and swap LUKS keyfiles live on the ZFS root
(`/etc/fstab.{boot,swap}_keyfile`). They can't be opened until ZFS is
mounted. OpenRC's `dmcrypt` service runs at `boot` runlevel — *after*
`zfs-mount` (sysinit) — so it can technically open them, but the
matching fstab entries are also at `boot` and may race. Using
`local.d` (default runlevel, late in boot) sidesteps the race.

## Variables

| Var | Default | Notes |
|-----|---------|-------|
| `dmcrypt_containers` | `[swap, boot]` (`all.yml`) | List of `{target, source_part, key}` entries. |
| `dmcrypt_use_localdotdee` | `true` (`all.yml`) | Drop the `local.d` helpers. |
| `dmcrypt_target_disk` | (auto-detected) | Override if the auto-detect goes wrong. |

## Dependencies

`bootstrap.sh` must have written an initial `/etc/conf.d/dmcrypt` —
the role reads it to discover the disk. If you've never run
bootstrap.sh, set `dmcrypt_target_disk` explicitly.

## Example

```yaml
# group_vars/all.yml (already shipped)
dmcrypt_containers:
  - { target: swap, source_part: 3, key: /etc/fstab.swap_keyfile }
  - { target: boot, source_part: 2, key: /etc/fstab.boot_keyfile }
```

## Troubleshooting

- **`/boot` empty after a reboot** — confirm
  `/etc/local.d/boot.start` is executable and `local` is in the
  `default` runlevel: `rc-status default | grep local`.
- **`swapon` fails with "device busy"** — leftover from a partial
  unmount; check `swapon --show` and `cryptsetup status swap`.
- **Disk auto-detect wrong (e.g. partitioned a second disk)** — set
  `dmcrypt_target_disk: /dev/nvme0n1` explicitly in host_vars.
