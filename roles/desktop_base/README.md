# desktop_base

Shared desktop infrastructure used by both `desktop_kde` and
`desktop_gnome`.  Always run before the per-DE role.

## What it does

1. Installs cross-DE packages: elogind, eudev, polkit-elogind, acpid,
   power-profiles-provider, tlp, udisks2, mesa/vulkan, X11 server,
   fwupd, alacritty, firefox, mpv, xdg-desktop-portal core, etc.
2. Installs fonts (one canonical set; per-DE roles do NOT install fonts).
3. Removes `mdev` from sysinit and enables `udev` / `udev-trigger` /
   `udev-settle`.  Required for DRM devices to be tagged
   `master-of-seat`, which is what makes elogind report
   `CanGraphical=true` — both SDDM and GDM check this before showing
   a greeter.
4. Enables the shared default-runlevel services: `elogind`, `acpid`,
   `udisks2`, `cgroups` (if present).
5. Enables `tlp` in the boot runlevel.
6. Drops `/etc/udev/rules.d/99-pulse-ignore-hdmi-dp.rules`, which
   tags the GPU's HDA function (HDMI / DisplayPort audio) with
   `PULSE_IGNORE=1` so PulseAudio never enumerates it.  Keeps
   the audio applet uncluttered and prevents auto-switch-on-BT-
   disconnect from selecting an HDMI sink.  The rule matches by
   PCI bus address (`KERNELS=="0000:c4:00.1"`), which is the
   ThinkPad P14s Gen5 AMD's GPU — see the rule file itself for
   portability notes if applying to other hardware.

   The handlers in `handlers/main.yml` reload udev rules and
   re-trigger the sound subsystem so the rule takes effect on
   apply.  (BT auto-switch and unmute behaviour work out-of-the-
   box on this stack with no .pa drop-ins.)

## What it deliberately does NOT do

- No display manager.  `desktop_kde` enables `sddm`; `desktop_gnome`
  enables `gdm`.
- No DE-specific Polkit agent or portal backend (`polkit-kde-agent-1`
  vs. `polkit-gnome`; `xdg-desktop-portal-kde` vs. `-gnome`) — those
  live in the per-DE roles.
- No browser-specific or mailclient-specific packages — base ships
  Firefox; if a DE wants a different browser as default, add it in the
  DE role.

## Variables

| Var | Default | Notes |
|-----|---------|-------|
| `desktop_base_packages` | (see defaults/main.yml) | Cross-DE packages. |
| `desktop_base_font_packages` | (see defaults/main.yml) | Fonts. |

## Dependencies

None — but the per-DE roles depend on this one and assume it ran.

## Ordering

In `playbooks/desktop.yml`:
```yaml
roles:
  - desktop_base
  - { role: desktop_kde,   when: desktop_environment == "kde" }
  - { role: desktop_gnome, when: desktop_environment == "gnome" }
```
