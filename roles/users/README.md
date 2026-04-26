# users

User accounts + `doas` (Alpine's sudo replacement) + optional
desktop-only fstab management.

## What it does

Universal:

1. `apk add doas` (and the user's shell, if `desktop_user_shell` is set).
2. Ensures auxiliary groups exist.
3. Creates `desktop_user` (if defined) with the configured shell + groups.
4. Writes `/etc/doas.d/doas.conf` with `permit persist :wheel`, mode 0400.
5. Adds `include "/etc/doas.d/*.conf"` to `/etc/doas.conf` (Alpine's
   default doesn't, unlike sudo's drop-in dir).

Desktop-only (gated on `users_manage_fstab: true`):

6. Creates `/opt/<user>/{bin,projects,.cargo,…}` backing dirs for the
   noexec-`/home` bind mounts.
7. Renders `/etc/fstab` with the bare-metal-bootstrap layout (ZFS root,
   `/efi` UUID, `/dev/mapper/boot`, tmpfs, plus the bind mounts).

## Why fstab is gated

The fstab template assumes `bootstrap.sh`'s disk layout: ZFS root,
LUKS `/boot`, vfat `/efi`, plus `/opt/<user>` bind-mounts. None of this
applies to a cloud VPS. Setting `users_manage_fstab: false` (the
default) skips the fstab + `/opt/<user>` tasks — the role then does
just user/doas, which is portable to any host.

## Variables

| Var | Default | Notes |
|-----|---------|-------|
| `desktop_user` | unset | If unset, no user is created. |
| `desktop_user_shell` | unset | Shell pkg name is auto-installed if set. |
| `desktop_user_groups` | `[]` | Groups created if missing. |
| `users_manage_fstab` | `false` | Flip on bare-metal-bootstrap hosts. |
| `home_bind_mounts` | unset | Subpaths under `/home/<user>` to bind from `/opt/<user>`. |

## Dependencies

For the fstab path: ZFS pool created (by bootstrap.sh), `/efi`
discoverable in `ansible_mounts` (so the UUID lookup works).

## Example

```yaml
# group_vars/desktops.yml
users_manage_fstab: true
desktop_user: alice
desktop_user_shell: /usr/bin/fish
desktop_user_groups: [wheel, audio, video, docker]
home_bind_mounts: [bin, .cargo, .rustup]
```

## Troubleshooting

- **`/etc/fstab` rendered with `UUID=CHANGE-ME`** — the `ansible_mounts`
  fact didn't find a `/efi` mountpoint. On bootstrap.sh-installed hosts
  /efi is mounted at boot via `local.d/boot.start` *or* fstab itself.
  Run `mount /efi` and re-gather facts:
  `ansible <host> -m setup --become`.
- **User can't run `doas` even though they're in `wheel`** — verify
  `/etc/doas.conf` has the `include "/etc/doas.d/*.conf"` line; Alpine's
  default doesn't, and the role adds it.
- **Setting `users_manage_fstab: true` on a non-bootstrap host
  destroyed its `/etc/fstab`** — that's the bug we explicitly guard
  against. Don't set the toggle on cloud VPS hosts.
