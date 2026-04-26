# common

Baseline Alpine host config: apk repositories, hostname, timezone, a
small set of universally-useful CLI packages, and the console keymap.
Applied to every host as the first role in every play.

## What it does

1. Templates `/etc/hostname` from `hostname` (or falls back to
   `inventory_hostname`), and runs `hostname -F` so the kernel updates
   without a reboot.
2. Symlinks `/etc/localtime → /usr/share/zoneinfo/{{ timezone }}`.
3. Writes `/etc/apk/repositories` from `apk_repositories`. If the file
   changes, runs `apk update`.
4. `apk add`s `base_packages` (universal) and `kernel_packages`
   (bare-metal hosts only — empty by default).
5. Sets `KEYMAP=` in `/etc/conf.d/loadkmap` and enables `loadkmap` at
   the `boot` runlevel.

## Variables

| Var | Default | Notes |
|-----|---------|-------|
| `hostname` | `inventory_hostname` | Hosts/host_vars override per box. |
| `timezone` | `UTC` (`all.yml`) | E.g. `America/New_York`. |
| `keymap` | `us us` (`all.yml`) | Two whitespace-separated tokens; we use the second. |
| `apk_repositories` | edge main+community+testing | List of full URLs. |
| `base_packages` | minimal toolset | OS-agnostic only — no kernel/firmware. |
| `kernel_packages` | `[]` | Bare-metal hosts override (e.g. `[linux-lts, linux-firmware-other]`). |

## Why kernel_packages is separate

Bare-metal Alpine ships `linux-lts`. Cloud VPS Alpine ships
`linux-virt`. RPi ships `linux-rpi`. Pinning a kernel package in the
universal `base_packages` list would install a *second* kernel on
non-bare-metal hosts. So:

- `desktops.yml` sets `kernel_packages: [linux-lts, linux-firmware-other, kernel-hooks]`
- `wireguard_servers.yml` (cloud VPS) leaves it empty
- A bare-metal CDN node group could mirror `desktops.yml`'s kernel list

## Dependencies

None. This is the bootstrap-of-the-bootstrap.

## Example

```yaml
# group_vars/desktops.yml
kernel_packages:
  - linux-lts
  - linux-firmware-other
  - kernel-hooks
timezone: America/New_York
```

## Troubleshooting

- **`apk: package linux-lts is already installed (newer)`** — your VPS
  has `linux-virt` and you set `kernel_packages: [linux-lts]`. Either
  unset it for that group, or accept the dual-kernel state.
- **Hostname doesn't update without a reboot** — the handler runs
  `hostname -F /etc/hostname`. If you also have a stale entry in
  `/etc/hosts`, edit there too (we don't manage `/etc/hosts`).
- **Keymap not applied at the console** — `loadkmap` only runs at the
  `boot` runlevel. After a config change, restart the service or
  reboot.
