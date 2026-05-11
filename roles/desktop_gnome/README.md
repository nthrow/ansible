# desktop_gnome

GNOME-specific desktop role.  Pairs with `desktop_base` (which must run
first) and is gated on `desktop_environment == "gnome"` in the playbook.

## What it does

1. Installs GNOME Shell + Mutter + GDM + GNOME apps (`gnome` meta,
   `nautilus`, `gnome-terminal`, `gnome-text-editor`, `evince`, `eog`,
   `file-roller`, `gnome-calculator`, `gnome-disk-utility`,
   `gnome-keyring`, `gnome-screenshot`, `gnome-software`,
   `gnome-system-monitor`, `gnome-tweaks`).
2. Installs the GNOME polkit auth UI + portal backend
   (`polkit-gnome`, `xdg-desktop-portal-gnome`, `pinentry-gnome3`).
3. Renders `/etc/gdm/custom.conf` with `WaylandEnable` set per the
   `gdm_wayland_enable` var.
4. Enables `gdm` in the default runlevel.

## What it does NOT do

- Cross-DE setup (elogind, eudev, acpid, udisks2, tlp, fonts, mesa,
  vulkan, X11 server, fwupd, firefox, alacritty, mpv, gparted, dconf,
  portal core, polkit-elogind) — handled by `desktop_base`.
- Dev toolchains — `dev_stack` role.
- Flatpak setup — `flatpak` role.

## Variables

| Var | Default | Notes |
|-----|---------|-------|
| `gdm_wayland_enable` | `true` | If false, `[daemon] WaylandEnable=false` in custom.conf — forces the X11 greeter. Wayland user sessions remain selectable at the greeter regardless. |
| `gnome_packages` | (see defaults/main.yml) | The GNOME-specific package set. Edit here, not in inventory. |

## Greeter / display-server notes

GDM's Wayland greeter has historically been more robust than SDDM's
kwin_wayland greeter on Alpine — KDE's role hard-pins X11 due to a
real-hardware AMDGPU bug; we don't have an analogous known issue for
GDM at the moment, hence the `gdm_wayland_enable: true` default.  If a
specific host hits a greeter regression, override per-host:

```yaml
# inventory/host_vars/<host>.yml
gdm_wayland_enable: false
```

That switches just the greeter to X11; user sessions are unaffected.

## Switching between KDE and GNOME

Set `desktop_environment: gnome` in `inventory/group_vars/desktops.yml`
or per-host in `inventory/host_vars/<host>.yml`.  The install gate in
this role's `tasks/main.yml` keys on that var.

To cleanly tear down GNOME before switching back to KDE:

```sh
# 1. flip the var
$EDITOR inventory/host_vars/<host>.yml      # desktop_environment: kde

# 2. uninstall GNOME  (--tags uninstall_gnome fires regardless of the var)
ansible-playbook -i inventory/hosts.yml playbooks/desktop.yml \
    --tags uninstall_gnome --limit <host>

# 3. install KDE (default play, gated by desktop_environment)
ansible-playbook -i inventory/hosts.yml playbooks/desktop.yml \
    --limit <host>
```

Steps 2 and 3 can run in either order; running 2 first means you
don't briefly have both display managers fighting for seat0.

GNOME user config (`~/.config/gnome*`, `~/.local/share/gnome*`, the
dconf state) is NOT removed by the uninstall tag — it sits unused
if you ever come back to GNOME.  Wipe manually if you want a clean
slate.

If you instead want both DEs co-installed and just toggle the
greeter, you can skip the uninstall step entirely — set
`desktop_environment` to whichever you want active and run the
default play.  The user picks the session at the greeter regardless.

## Dependencies

- `desktop_base` must run first (provides elogind, eudev, fonts, the
  shared service stack).

## Ordering

In `playbooks/desktop.yml`:
```yaml
roles:
  - desktop_base
  - { role: desktop_gnome, when: desktop_environment == "gnome" }
```
