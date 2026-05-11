# upgrade

Run `apk upgrade` against a host with snapshot, diff capture, risky-
component flagging, post-upgrade health checks, and a markdown report.

Designed primarily for the **staging-VM-first workflow**: run this
against the desktop VM, eyeball the report, *then* run it against the
bare-metal Thinkpad/desktop.

## What it does

1. **Preflight** — refresh apk indexes, count pending updates, check
   disk space, ensure report dir exists.
2. **Snapshot** — `zfs snapshot {{ pool }}/ROOT/alpine@pre-upgrade-...`
   for rollback.  Skip with `upgrade_snapshot_zfs: false` if your
   underlying storage isn't ZFS or you snapshot upstream
   (libvirt / btrfs / etc.).
3. **Capture before** — `apk info -v | sort` saved as a fact.
4. **Upgrade** — `apk upgrade --no-progress` (or `--simulate` if
   `upgrade_dry_run: true`).
5. **Capture after** — same snapshot, post-upgrade.
6. **Restart services** — for any package in `upgrade_service_restart_map`
   that appears in the upgrade delta, restart the mapped services.
   Skipped in dry-run mode.
7. **Health checks** — running-kernel vs installed-kernel mismatch
   (=> reboot needed), critical service states, PAM-file integrity
   for display managers (catches the SDDM regression pattern).
8. **Report** — render markdown report on the host
   (`/var/log/alpine-upgrade/<timestamp>.md`) and fetch back to
   `~/bench/alpine/upgrade-reports/<host>-<timestamp>.md` on the controller.

## Variables

| Var | Default | Notes |
|-----|---------|-------|
| `upgrade_dry_run` | `false` | True → `apk upgrade --simulate` only.  Useful as a first pass when reviewing in staging. |
| `upgrade_snapshot_zfs` | `true` | False → skip the ZFS snapshot. |
| `upgrade_snapshot_dataset` | `{{ zfs_pool }}/ROOT/alpine` | Dataset to snapshot. |
| `upgrade_snapshot_tag` | `pre-upgrade-<UTC ISO compact>` | Snapshot suffix. |
| `upgrade_report_remote_dir` | `/var/log/alpine-upgrade` | Where the report lives on the host. |
| `upgrade_report_local_dir` | `~/bench/alpine/upgrade-reports` | Where the controller stashes copies for history. |
| `upgrade_service_restart_map` | (see defaults) | `pkg → [services]` map; touched packages bounce their services. |
| `upgrade_risky_packages` | (see defaults) | Categorized list of packages whose changes get flagged in the report.  Add to this when something new bites. |

## Risky-component categories

Each category renders as its own section in the report:

- `session` — elogind, polkit, dbus, PAM
- `display_manager` — sddm, gdm
- `compositor` — kwin, plasma-desktop, gnome-shell, mutter
- `graphics` — xorg, mesa, vulkan, libdrm, GPU firmware
- `udev` — eudev
- `kernel` — linux-lts, linux-firmware-*, mkinitfs
- `boot` — grub, kernel-hooks, sbsigntool, sbctl
- `core` — musl, busybox, openrc, openssl, openssh

## Usage

### Staging VM first pass (dry-run review)

```sh
ansible-playbook -i inventory/hosts.yml playbooks/upgrade.yml \
  -e upgrade_dry_run=true \
  --limit alpine-desktop-test
```

Read `~/bench/alpine/upgrade-reports/alpine-desktop-test-<timestamp>.md`,
look for `## ⚠ Risky-component changes` and decide whether to
proceed.

### Staging VM real upgrade

```sh
ansible-playbook -i inventory/hosts.yml playbooks/upgrade.yml \
  --limit alpine-desktop-test
```

Reboot the VM if the report says `needs-reboot`, then sanity-check
the desktop session manually (login, terminal, network, etc.).

### Bare-metal apply (after staging passes)

```sh
ansible-playbook -i inventory/hosts.yml playbooks/upgrade.yml \
  --limit thinkpad
```

Same flow.  The report path on the controller is keyed by hostname,
so staging and bare-metal don't clobber each other.

## Rollback

If the upgrade breaks a host:

1. Reboot to a working state if you can.  If not: LiveUSB → `zpool import`.
2. Find the snapshot:
   ```sh
   zfs list -t snapshot | grep pre-upgrade
   ```
3. Roll back:
   ```sh
   zfs rollback rpool/ROOT/alpine@pre-upgrade-<timestamp>
   ```
4. If the kernel was in the upgrade, regenerate initramfs:
   ```sh
   mkinitfs $(uname -r)
   ```
5. Reboot.

The report includes the exact rollback command pre-filled.

## Adding new risky packages

When something new breaks on edge, add the package to the appropriate
category in `defaults/main.yml`:

```yaml
upgrade_risky_packages:
  display_manager:
    - sddm
    - sddm-openrc
    - your-newly-broken-pkg     # add here
```

A package is matched if its name equals an entry exactly, or matches
an entry ending in `-*` (treated as prefix).

## Limitations

- **No package holds.**  This role doesn't pin specific package
  versions; if you need that, layer it with `apk add --no-upgrade`
  before running this.
- **Service restart map is heuristic.**  We bounce the obvious ones
  (`elogind`, `sddm`, `dbus`, etc.) when their packages change, but
  a `musl` upgrade really needs a reboot — the report flags reboot
  needs but doesn't auto-reboot.
- **PAM check is shallow.**  It catches missing-include errors
  (the regression that bit us last time) but won't catch logic bugs
  inside an existing PAM stack.
