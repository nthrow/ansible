# desktop_kde

KDE Plasma desktop + SDDM display manager.  Pairs with `desktop_base`
(which must run first) and is gated on `desktop_environment == "kde"`
in the playbook.

## What it does

1. Installs the KDE Plasma package set from `defaults/main.yml`:
   plasma-desktop + plasma-* widgets, dolphin / kate / konsole / kwrite
   / okular / spectacle, KDE network/disk/firewall integration,
   powerdevil, breeze theme + icons, sddm + sddm-breeze.
2. Installs the KDE polkit auth UI + portal backend
   (`polkit-kde-agent-1`, `xdg-desktop-portal-kde`, `pinentry-qt`).
3. Templates `/etc/sddm.conf` with the configured theme.
4. Enables `sddm` in the default runlevel.

## What it does NOT do

- Cross-DE setup (elogind, eudev, acpid, udisks2, tlp, fonts, mesa,
  vulkan, X11 server, fwupd, firefox, alacritty, mpv, gparted, dconf,
  portal core, polkit-elogind) — handled by `desktop_base`.
- Dev toolchains — `dev_stack` role.
- Flatpak setup — `flatpak` role.

## Variables

| Var | Default | Notes |
|-----|---------|-------|
| `sddm_theme` | `breeze` | |
| `sddm_cursor_theme` | `breeze_cursors` | |
| `kde_packages` | (see defaults/main.yml) | KDE-specific set. |

## Greeter notes

`templates/sddm.conf.j2` historically pinned `DisplayServer=x11` for the
greeter as a workaround for kwin_wayland (the wayland greeter) dying
fast on Alpine + real GPUs (validated broken on AMDGPU; was previously
fine on virtio-gpu in VMs).  As of 2026-05-10 the bandaid is dropped
pending a fresh test against a newer Alpine Edge package set — the
hypothesis is that the regression has been upstream-fixed since the
bandaid was added.  If the wayland greeter fails on a recently-upgraded
host, restore the `DisplayServer=x11` line and reapply.

## Switching between KDE and GNOME

Set `desktop_environment: kde` (default) or `gnome` in
`inventory/group_vars/desktops.yml` or per-host in
`inventory/host_vars/<host>.yml`.

To cleanly tear down KDE before switching to GNOME (recommended for
validation runs; avoids leaving both DEs co-installed):

```sh
# 1. flip the var
$EDITOR inventory/host_vars/<host>.yml      # desktop_environment: gnome

# 2. uninstall KDE  (--tags uninstall_kde fires regardless of the var)
ansible-playbook -i inventory/hosts.yml playbooks/desktop.yml \
    --tags uninstall_kde --limit <host>

# 3. install GNOME (default play, gated by desktop_environment)
ansible-playbook -i inventory/hosts.yml playbooks/desktop.yml \
    --limit <host>
```

Steps 2 and 3 can run in either order; running 2 first means you
don't briefly have both display managers fighting for seat0.

Plasma user config (`~/.config/plasma*`, `~/.local/share/plasma*`,
`~/.kde`) is NOT removed by the uninstall tag — it sits unused if
you ever come back to KDE.  Wipe manually if you want a clean slate.

## Dependencies

- `desktop_base` must run first.
- `users` role with `desktop_user` set (for sddm autologin etc.).
- `networking_desktop` role (NetworkManager + bluetooth).

## Troubleshooting

- **SDDM doesn't start** — check `service sddm status` and
  `/var/log/sddm.log`.  Most often: missing X11/wayland session due
  to a partial Plasma install.
- **No login screen, just a blinking cursor** — `elogind` not running.
  `rc-status default | grep elogind` should show `started`.  That's
  desktop_base's responsibility; if elogind is missing, desktop_base
  did not run successfully.
- **Suspend doesn't wake** — `tlp` may have masked a runtime PM hook.
  Bisect by stopping `tlp` and re-testing.  `tlp` is also enabled by
  desktop_base.
