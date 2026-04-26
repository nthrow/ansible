# zfs

Idempotent management of ZFS datasets and properties on top of an
already-created pool. **Does not create the pool** — that's the job
of `bootstrap.sh`. Run only on hosts where ZFS is the root.

## What it does

1. `apk add zfs` (userland — kernel module is built into Alpine's
   kernels).
2. Enables `zfs-import` and `zfs-mount` at the `sysinit` runlevel.
3. Sets the pool's `keylocation` to `file:///crypto_keyfile.bin` so
   the initramfs can unlock it without a passphrase prompt.
4. Iterates over `zfs_datasets`, ensuring each exists with the
   declared `mountpoint` and `canmount` properties.

## Variables

| Var | Default | Notes |
|-----|---------|-------|
| `zfs_pool` | `rpool` (`all.yml`) | Pool name created by bootstrap.sh. |
| `zfs_datasets` | `[ROOT, ROOT/alpine]` | Per-group adds. Desktops add `ROOT/home`. |

Each dataset entry: `{ name, mountpoint, canmount }`.

## Dependencies

`bootstrap.sh` must have already created the pool with the right
encryption properties (aes-256-gcm, keylocation pointing at
`/etc/fstab.zfs_keyfile`). The role re-asserts the keylocation but
does not initialize crypto.

## Example

```yaml
# group_vars/desktops.yml
zfs_datasets: "{{ zfs_datasets_base + zfs_datasets_desktop }}"
zfs_datasets_base:
  - { name: "{{ zfs_pool }}/ROOT",        mountpoint: none,   canmount: off }
  - { name: "{{ zfs_pool }}/ROOT/alpine", mountpoint: legacy, canmount: off }
zfs_datasets_desktop:
  - { name: "{{ zfs_pool }}/ROOT/home",   mountpoint: legacy, canmount: on  }
```

## Troubleshooting

- **`cannot open 'rpool': no such pool`** — the role was applied to
  a host where bootstrap.sh wasn't run. Don't include `zfs` role in
  cloud-VPS playbooks.
- **`keylocation` reverts after reboot** — make sure the keyfile path
  in the symlink (`/crypto_keyfile.bin → /etc/fstab.zfs_keyfile`) is
  intact in the new system. The symlink is created by bootstrap.sh.
- **Pool imports but doesn't auto-unlock at boot** — `keystatus` should
  be `available` shortly after boot. If not, the cryptkey feature in
  `mkinitfs.conf` may be missing. Check
  `cat /etc/mkinitfs/mkinitfs.conf` for the `cryptkey` feature.
