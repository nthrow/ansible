# desktop_kde

KDE Plasma desktop environment + SDDM display manager + fonts +
X11 input. Desktop-only; do not include in server playbooks.

## What it does

1. `apk add` the (large) KDE Plasma package set defined in
   `defaults/main.yml`: dolphin, konsole, plasma-desktop, plasma-nm,
   sddm, breeze, X11, mesa, …
2. `apk add` the font set (noto, ubuntu, terminus, …).
3. Templates `/etc/sddm.conf` with the configured theme.
4. Enables `sddm`, `elogind`, `acpid`, `udisks2`, `cgroups` at the
   `default` runlevel.
5. Enables `tlp` at the `boot` runlevel.

## Variables

| Var | Default | Notes |
|-----|---------|-------|
| `sddm_theme` | `breeze` | |
| `sddm_cursor_theme` | `breeze_cursors` | |
| `kde_packages` | (large list) | Override to trim. |
| `font_packages` | (full font set) | |

## Dependencies

- `users` role with `desktop_user` set (for SDDM auto-login etc.).
- `networking_desktop` role (NetworkManager + bluetooth).

## Example

```yaml
# host_vars/laptop.yml
sddm_theme: breeze-dark
```

## Troubleshooting

- **SDDM doesn't start** — check `service sddm status` and the
  `~sddm/.local/share/sddm/sddm.log`. Most often: missing
  X11/wayland session due to a partial Plasma install.
- **No login screen, just a blinking cursor** — `elogind` not running.
  `rc-status default | grep elogind` should show `started`.
- **Suspend doesn't wake** — `tlp` may have masked a runtime PM hook.
  Bisect by stopping `tlp` and re-testing.
