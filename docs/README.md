# Developer Documentation

Index. Read [architecture.md](architecture.md) first.

| Doc | What it covers |
|-----|---------------|
| [architecture.md](architecture.md) | Why the codebase is shaped this way: two-stage install, role layering, group hierarchy, observability flow. |
| [inventory.md](inventory.md) | Group hierarchy, var cascade, per-host overrides, the `inventory/poc/` separation. |
| [conventions.md](conventions.md) | Role-writing conventions: naming, defaults vs vars, idempotency, handlers, validate steps. |
| [firewall.md](firewall.md) | The firewall rule DSL — every form `firewall_allow_tcp` accepts, plus forward + NAT. |
| [observability.md](observability.md) | How zero-conf scrape config works end-to-end. Adding a new exporter. |
| [bootstrap.md](bootstrap.md) | Walkthrough of `bootstrap.sh`: what each phase does, where the keyfiles live, recovery flow. |
| [secrets.md](secrets.md) | LUKS keyfiles, ZFS keys, Secure Boot CA, ansible-vault patterns. |
| [troubleshooting.md](troubleshooting.md) | Cross-cutting failure modes and their fixes. |
| [desktop-vm-validation.md](desktop-vm-validation.md) | VM-based runbook for end-to-end desktop build validation (bootstrap.sh + boot chain + KDE). |

For per-role usage, see each `roles/<name>/README.md`.
