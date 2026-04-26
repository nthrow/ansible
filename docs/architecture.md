# Architecture

This doc explains *why* the codebase is shaped the way it is. Per-role
specifics live in each role's `README.md`; cross-cutting decisions are
here.

## The two-stage install

Ansible is built around the idempotent-config model: connect to a
running host via SSH, converge it. That model breaks the moment you're
at *bare metal* with no OS — there's no SSH endpoint, no python, no
network identity. So we don't try to do bare-metal install with
Ansible. We split:

1. **`bootstrap.sh`** — POSIX `ash` shell script for the Alpine
   *Extended* LiveUSB. Does the destructive work that doesn't fit
   Ansible's model:
   - Wipe the disk with `/dev/urandom`
   - Partition with `sfdisk` (ESP / `/boot` / swap / ZFS)
   - Format LUKS containers, generate keyfiles, build the ZFS pool
   - Run `setup-disk` to install Alpine
   - Carry the keyfiles into the new system, configure mkinitfs
   - Install minimal GRUB so it boots
   - Install sshd + python3, drop root's authorized_keys
   - Reboot

2. **Ansible** — connects to the now-rebooted host via SSH and runs
   the per-tier playbook. Everything from here on is idempotent: rerun
   safely, re-converge to the declared state.

For cloud VPS hosts (wireguard hub, possibly future CDN nodes),
bootstrap.sh is skipped entirely — the cloud provider's image already
has Alpine installed and SSH reachable. Ansible takes over directly.

This split is the single most load-bearing design choice in the repo.
It's why `bootstrap.sh` is the only shell script in the install path;
why everything else is yaml; why some roles (zfs, dmcrypt, grub_efi)
only apply to bootstrap.sh hosts.

## Role layering

Roles compose. A given host runs a stack of roles in order, with each
later role assuming the earlier ones have completed.

The standard server stack:

```
common              # apk repos, hostname, base pkgs
sshd                # OpenSSH hardened
firewall            # iptables hardening
<tier-role>         # wireguard_hub | cdn_edge | docker_host | ...
monitoring_agent    # node_exporter + promtail (last so daemons it talks to are up)
```

Bare-metal additions (in `desktop.yml`, theoretical bare-metal CDN):

```
common
zfs                 # dataset/property idempotency on top of bootstrap.sh's pool
dmcrypt             # /etc/conf.d/dmcrypt + local.d unlock helpers
sshd
firewall
grub_efi            # GRUB w/ cryptodisk
secureboot          # self-signed CA + kernel signing
users               # account + doas + (desktop) fstab
<tier-role>
monitoring_agent
```

The ordering matters in only a few specific places:

- `firewall` before any tier role that adds its own iptables-aware
  service (notably `docker_host`, whose chain insertion gets clobbered
  by an iptables-restore unless the docker restart fires after).
- `grub_efi` before `secureboot` (signs the bootloader produced by
  grub-install).
- `dmcrypt` before `grub_efi` (needs `/boot` openable to install grub
  there).

Everywhere else, role order is for readability.

## The "shared role with toggles" pattern

When the same role can serve multiple host classes, we prefer toggles
over forking the role. Examples:

- **`cdn_edge` has `cdn_edge_anycast_enabled`.** True for prod
  (BIRD + VIPs); false for the PoC (single edge, plain HTTP). Same
  `tasks/main.yml`, gated.
- **`docker_host` has `docker_swarm_role`.** `none`/`manager`/`worker`.
  Standalone and swarm modes are the same role.
- **`cdn_varnish` has `cdn_varnish_nfs_role`.** `none`/`server`/`client`.
- **`users` has `users_manage_fstab`.** Defaults false; bare-metal-bootstrap
  hosts flip true.

The win: less code to maintain. The cost: each role's tasks file has
some `when:` gating. Worth it.

## Inventory hierarchy = scrape-target hierarchy

Inventory groups aren't just for "what plays where" — they're also
the source of truth for observability. The `prometheus.yml` template
iterates `groups['cdn_varnish']` to populate the `varnish` scrape job.
Adding a host to `cdn_varnish` group ⇒ next observability run picks
it up automatically.

This is why we don't bury hosts under flat lists. Group membership
*is* documentation.

## Firewall as a small DSL

Rather than per-role iptables snippets glued together, every tier
expresses its firewall needs through one schema:
`firewall_allow_tcp` / `_udp` / `forward_rules` / `nat_masquerade`.
Each entry is either a bare port (universal allow) or a dict with
`in`/`source`/`sources` filters. The template renders the same
hardened skeleton for every host and inserts these.

This means:

- Reading a host's `group_vars/<group>.yml` tells you exactly what's
  open.
- Composing rules across roles is pure variable concatenation
  (`firewall_allow_tcp: "{{ a + b }}"`).
- There's one place to look for "what changed in the firewall" across
  reruns.

See [firewall.md](firewall.md) for the full DSL.

## Zero-conf observability

The whole obs tier (Prometheus + Loki + Grafana) is designed so that
joining a host to the right inventory group is *all* the config
needed to start scraping it. Achieved via:

1. Every role that runs a service also installs that service's
   exporter (varnish_exporter on cdn_varnish hosts, nginx_exporter
   on edges, etc.). No manual exporter ansible-management.
2. `monitoring_agent` (universal) installs node_exporter + promtail,
   bound to the host's wg0 IP.
3. `prometheus.yml` is templated by iterating inventory groups —
   `cdn_varnish` group ⇒ varnish scrape job, `docker_hosts` group ⇒
   docker scrape job.
4. Loki push URL is auto-derived in `group_vars/all.yml` from
   `groups['observability'][0]`'s wg0 IP. No per-host config.

See [observability.md](observability.md) for the data flow.

## Wireguard as the management plane

Every server is on the wireguard mesh. SSH is open *only* on `wg0` —
no port 22 on any public iface. Same for swarm gossip, prometheus
scrapes, log shipping, and inter-tier CDN traffic where applicable.

This means:

- Public attack surface = whatever the host's actual *job* requires
  (UDP/51820 on the hub, 80/443 on edges, nothing on varnish/docker).
- Compromise of a single internet-facing host doesn't pivot via a
  flatly-trusted internal network.
- `ansible_host` for most hosts is their wg-IP, not their public IP.

The exception is the wireguard hub itself, where `ansible_host`
points at its public IP for the first run (you can flip it to
`10.0.0.1` once you're peered in).

## Group_vars composition tricks

A few patterns recur:

- **Concatenated lists** for additive config:
  ```yaml
  firewall_allow_tcp: "{{ _base + _bgp_peers }}"
  _base: [{port: 22, in: wg0}, 80, 443]
  _bgp_peers: [{port: 179, sources: "{{ cdn_edge_bgp_peers | map(attribute='ip') | list }}"}]
  ```
  The leading underscore is a convention for "internal helper var,
  don't override directly."

- **Conditional blocks** built from list comprehensions:
  ```yaml
  firewall_nat_masquerade: >-
    {{ [{'src': wg_subnet, 'out': iface}]
       if wireguard_enable_exit else [] }}
  ```

- **Auto-derived values from `ansible_facts`**:
  ```yaml
  monitoring_bind_addr: "{{ ansible_facts[monitoring_bind_iface].ipv4.address
                            | default('127.0.0.1') }}"
  ```
  Never hardcode wg-IPs in inventory; let facts resolve them.

## What's *not* in this repo

Deliberately out of scope:

- **TLS cert provisioning** for the CDN edges. Drop them at the
  configured paths via your own role/cron/whatever. The `cdn_edge`
  role just consumes `tls_cert`/`tls_key` paths.
- **DNS**. Hostnames are inventory-side; we don't run a DNS server.
- **Container orchestration beyond docker swarm.** No k8s, no nomad.
- **HA load balancers** in front of the wireguard hub or obs host.
  These are single-points-of-failure on purpose for a homelab; if
  you need HA, fork.
- **Backup**. ZFS makes snapshotting trivial; do it via cron or your
  preferred tool. Out of scope here because every fleet's backup
  destination is different.

## Reading order if you're new

1. This doc (you are here).
2. [inventory.md](inventory.md) — how the group hierarchy works.
3. [bootstrap.md](bootstrap.md) — how bare-metal hosts become Ansible-
   manageable.
4. [conventions.md](conventions.md) — how to add a role without
   breaking the patterns above.
5. The README of the role you're trying to use or extend.
