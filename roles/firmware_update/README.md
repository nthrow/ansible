# firmware_update

UEFI / device firmware update management via fwupd + LVFS. Designed
for safe expansion to fleet management without rework.

## What it does (v1)

1. `apk add fwupd fwupd-openrc fwupd-efi fwupd-grub`.
2. Enables and starts the fwupd service.
3. Ensures the standard LVFS remote (`lvfs`) is enabled.
4. Drops a periodic refresh+report script in `/etc/periodic/<cadence>/`
   that:
   - Refreshes LVFS metadata via `fwupdmgr refresh --force`.
   - Captures device inventory + pending updates as JSON.
   - Atomically writes the result to `firmware_update_report_path`.

It **does not apply updates.** v1 is "install fwupd, surface what's
available, leave the apply decision to the operator." See [Operator
workflow](#operator-workflow) below.

## Variables

| Var | Default | Notes |
|-----|---------|-------|
| `firmware_update_enable` | `true` | Set false on VMs / hosts without firmware to manage. |
| `firmware_update_refresh_cron` | `weekly` | `off`, `15min`, `hourly`, `daily`, `weekly`, or `monthly`. Maps to `/etc/periodic/<value>/`. |
| `firmware_update_report_path` | `/var/lib/firmware-updates-pending.json` | Where the periodic script writes status JSON. |

## Status JSON shape

```json
{
  "generated_at": "2026-04-30T12:00:00Z",
  "host": "thinkpad",
  "devices": { ... },          // fwupdmgr get-devices --json
  "pending_updates": { ... }   // fwupdmgr get-updates --json
}
```

The file is intended for monitoring scrape:

- **Prometheus textfile collector**: a tiny companion script can
  convert `pending_updates.Devices | length` into a metric.
- **Loki / Promtail**: tail the file (each `mv` updates mtime) for a
  per-host pending-updates event stream.
- **Ad-hoc**: `jq '.pending_updates.Devices[].Name' <path>` for a
  one-line CLI check across the fleet.

## Operator workflow

For now, applying updates is a manual, per-host action:

```sh
ssh root@<host>
fwupdmgr get-updates       # confirm what's pending (also in the report JSON)
fwupdmgr update            # apply; will prompt for reboot for capsule updates
reboot                     # capsules apply during the next firmware boot
fwupdmgr get-updates       # post-reboot, should report "No updates available"
```

For Lenovo and most x86 OEMs, the capsule is staged to the ESP, the
firmware notices it on the next boot, applies it before launching the
OS, then reboots one more time. Total ~2-3 reboots per capsule.

## Expansion paths (v2 and beyond)

The v1 design leaves these as additive changes, not rewrites:

### Self-hosted LVFS mirror (offline / staged rollout)

Add a `firmware_update_lvfs_remote` variable that accepts a URL and
templates a `/etc/fwupd/remotes.d/<custom>.conf` file pointing at the
mirror, then disable the upstream `lvfs` remote. Useful for:

- Air-gapped networks
- Curating which firmware versions reach the fleet (gate at the mirror
  by symlinking specific `.cab` versions)
- Reducing LVFS bandwidth when running many hosts

### Scheduled auto-apply (`apply_mode: scheduled`)

Reserved for v2. Plan: a maintenance-window cron entry runs
`fwupdmgr update --no-reboot-check`, sets `/var/lib/firmware-updates-
needs-reboot` if a capsule landed, and existing reboot orchestration
(out of scope for this role) handles the reboot.

The reason this isn't in v1: capsule application is an irreversible
firmware-write operation, and a wrong update can brick a board. We
want operator confidence before removing the human from the loop.

### Approval workflow

Once you have many hosts:

1. Each host's report JSON shows up in your monitoring backend.
2. An out-of-band review process (Linear ticket, dashboard, gh issue)
   decides what to apply where.
3. Apply happens via ansible with `--limit <hosts>` and a v2
   `firmware_update_apply_now: true` variable that triggers a one-shot
   `fwupdmgr update` task.

This keeps fwupd "always installed and reporting" while keeping
"actually apply" as an explicit, audited action with a paper trail.

### Custom remotes (testing / vendor-specific)

`fwupd-testing` (LVFS bleeding-edge) and vendor-specific remotes
(some OEMs publish their own LVFS mirrors with earlier access to
fixes) are easy to add as additional `enable-remote` calls. Out of
scope for v1 because they introduce a "which channel is this host
on" axis we don't need yet.

## Dependencies

- ESP large enough for capsules. `bootstrap.sh` defaults `EFI_MB=512`,
  sized exactly for this.
- Internet access to the LVFS CDN (or a self-hosted mirror; see
  expansion paths).
- AC power for some EC firmware updates — fwupd will refuse and
  prompt if the host is on battery.

## Security caveats

- **The `secureboot` role's self-signed CA does NOT extend to capsule
  signing.** Firmware capsules are signed by the OEM (Lenovo, Dell,
  HP) with a key baked into the firmware itself, separate from the
  PK/KEK/db chain you control. fwupd validates against the OEM chain,
  not yours.
- This is a hardware/firmware constraint, not a fwupd one. The only
  way to sign capsules with your own key is replacing the firmware
  itself (coreboot etc.), which is out of scope for any role here.

## Hardware coverage notes

- **NVMe firmware**: fwupd routes via the nvme plugin; vendor support
  varies. Most consumer-grade NVMe (Samsung, Western Digital) work.
- **Dock firmware** (Lenovo USB-C, Dell WD19, etc.): supported via
  vendor-specific plugins.
- **EC / BIOS firmware**: best support on Lenovo, Dell, HP business
  lines. Consumer-grade hardware is hit-or-miss.
- **Run `fwupdmgr get-devices` to see what fwupd actually thinks it
  can manage on a given host before assuming.**
