# grub_efi

GRUB-EFI installation with `cryptodisk` (so it can prompt for the LUKS
`/boot` passphrase before loading the kernel) and the
firmware-fallback-path trick (`grubx64.efi` moved to
`/efi/EFI/boot/bootx64.efi`).

## What it does

1. `apk add grub grub-efi efibootmgr`.
2. Templates `/etc/default/grub` with `GRUB_ENABLE_CRYPTODISK=y` and
   `GRUB_DEVICE=ZFS={pool}/ROOT/alpine` (the zfs-as-grub-fs workaround).
3. Mounts `/boot` and `/efi` if not already mounted (boot/swap are
   `noauto` on bootstrap.sh hosts; mounted by `local.d`).
4. Runs `grub-install --target=x86_64-efi`.
5. Patches `SecureBoot` → `SecureB00t` in the GRUB binary (works around
   the [grub verification-requested issue](https://wejn.org/2021/09/fixing-grub-verification-requested-nobody-cares/)).
6. Moves `grubx64.efi` to the firmware fallback path so the box boots
   without relying on NVRAM entries.
7. Regenerates `grub.cfg` via the handler.

## Variables

| Var | Default | Notes |
|-----|---------|-------|
| `grub_timeout` | `2` | Seconds at the menu. |
| `grub_cmdline_default` | `" ro"` | Appended kernel cmdline. |
| `grub_efi_directory` | `/efi` | ESP mountpoint. |
| `grub_boot_directory` | `/boot` | LUKS-encrypted boot partition. |
| `grub_use_fallback_path` | `true` | Move grub to the firmware fallback path. |

## Dependencies

- `dmcrypt` role (so `/boot` is openable).
- `zfs` role (so `GRUB_DEVICE=ZFS=...` resolves).
- `bootstrap.sh` for the LUKS1 `/boot` (GRUB doesn't read LUKS2 with
  argon2id by default).

## Example

```yaml
# host_vars/<bare-metal-host>.yml
grub_cmdline_default: " ro quiet loglevel=3"
```

## Troubleshooting

- **GRUB drops to a `grub>` prompt** — usually the `cryptodisk`
  password was rejected. Type the passphrase exactly as set during
  bootstrap.sh's `cryptsetup luksAddKey` step.
- **"grub verification requested but nobody cares"** — the SecureBoot
  patch wasn't applied. The handler runs it on changes; force a re-run
  by `touch`ing `/etc/default/grub` and re-applying.
- **Firmware doesn't find the bootloader after motherboard swap** —
  the fallback path (`/EFI/boot/bootx64.efi`) is exactly what saves
  you here. If that's missing, run the role again or manually
  `mv /efi/EFI/alpine/grubx64.efi /efi/EFI/boot/bootx64.efi`.
