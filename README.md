# alpine ansible

Provisioning for an Alpine Linux fleet: a desktop workstation, a
WireGuard hub, a CDN edge+varnish stack, homelab Docker hosts (with
optional swarm), and a Prometheus/Loki/Grafana observability tier — all
configurable from one inventory.

Two-stage install model:

- **`bootstrap.sh`** runs from the Alpine *Extended* LiveUSB and does
  the destructive work (wipe, partition, LUKS, ZFS, base install). Used
  for bare-metal hosts (desktops, on-prem CDN). Cloud/VPS hosts skip it.
- **Ansible** takes over via SSH for everything idempotent: services,
  configs, firewall, observability, etc.

## Layout

```
ansible/
├── ansible.cfg
├── bootstrap.sh                    # LiveUSB-side bare-metal installer
├── README.md                       # this file
├── docs/                           # developer docs (start with architecture.md)
├── tests/                          # end-to-end docker-based validation harness
├── inventory/
│   ├── hosts.yml                   # group hierarchy
│   ├── group_vars/                 # per-group config
│   ├── host_vars/                  # per-host overrides
│   └── poc/                        # separate inventory for the CDN PoC
├── playbooks/                      # one per host class + site.yml
└── roles/                          # see roles/<name>/README.md for each
```

## Prerequisites

```sh
ansible-galaxy collection install \
    community.general \
    community.crypto \
    community.docker \
    ansible.posix
```

Each managed host needs SSH reachable as root with key auth, and
`python3` installed (bootstrap.sh installs it; cloud Alpine images
ship with `apk add python3` available).

## Quickstart

For a homelab with a single desktop, a wireguard VPS, and a couple of
docker hosts:

```sh
# 1. bring up bare-metal hosts via the LiveUSB
./bootstrap.sh                                     # on each LiveUSB

# 2. fill in inventory/hosts.yml + group_vars

# 3. provision in this order
ansible-playbook -i inventory/hosts.yml playbooks/wireguard.yml
ansible-playbook -i inventory/hosts.yml playbooks/desktop.yml
ansible-playbook -i inventory/hosts.yml playbooks/docker.yml
ansible-playbook -i inventory/hosts.yml playbooks/observability.yml

# 4. (one-time) re-run per-tier plays so each host's monitoring agent
#    picks up the now-resolved Loki push URL
ansible-playbook -i inventory/hosts.yml playbooks/site.yml
```

## Group hierarchy

```
all
└── alpine
    ├── desktops
    └── servers
        ├── observability
        ├── wireguard_servers
        ├── cdn
        │   ├── cdn_edges
        │   └── cdn_varnish
        └── docker_hosts
            ├── docker_standalone
            └── docker_swarm
                ├── docker_managers
                └── docker_workers
```

Vars cascade `all → alpine → servers/desktops → leaf-group → host`.
See [docs/inventory.md](docs/inventory.md) for details.

## Playbooks

| Playbook | Targets | What it does |
|----------|---------|--------------|
| `desktop.yml` | `desktops` | Plasma + dev stack + flatpak + everything baked into bootstrap.sh |
| `wireguard.yml` | `wireguard_servers` | Hub-and-spoke WireGuard server |
| `cdn.yml` | `cdn_edges` + `cdn_varnish` | nginx-edge + bird + varnish + L7 routing |
| `cdn-poc.yml` | inventory/poc/ | 3-VM local-bridge demo (no anycast, no TLS) |
| `docker.yml` | `docker_hosts` | Single-box or swarm |
| `observability.yml` | `observability` | Prometheus + Loki + Grafana |
| `site.yml` | everything | Imports all of the above |

## Roles

Each role has its own `README.md` with variable reference and
troubleshooting. Cross-tier-shared first, then host-class-specific:

**Shared (any host)**
- [`common`](roles/common/README.md) — apk repos, hostname, timezone, base pkgs
- [`sshd`](roles/sshd/README.md) — sshd hardening
- [`firewall`](roles/firewall/README.md) — hardened iptables DSL
- [`monitoring_agent`](roles/monitoring_agent/README.md) — node_exporter + promtail
- [`users`](roles/users/README.md) — user accounts + doas

**Bare-metal-bootstrap-only**
- [`zfs`](roles/zfs/README.md) — ZFS dataset/property idempotency
- [`dmcrypt`](roles/dmcrypt/README.md) — LUKS unlock helpers
- [`grub_efi`](roles/grub_efi/README.md) — GRUB w/ cryptodisk
- [`secureboot`](roles/secureboot/README.md) — self-signed CA + kernel signing

**Server-tier-specific**
- [`wireguard_hub`](roles/wireguard_hub/README.md) — hub-and-spoke WG server
- [`cdn_edge`](roles/cdn_edge/README.md) — nginx + BIRD edge
- [`cdn_varnish`](roles/cdn_varnish/README.md) — varnish + local nginx + NFS
- [`cdn_origin_static`](roles/cdn_origin_static/README.md) — PoC-only origin
- [`docker_host`](roles/docker_host/README.md) — docker daemon + optional swarm
- [`observability`](roles/observability/README.md) — prom + loki + grafana

**Desktop-only**
- [`desktop_kde`](roles/desktop_kde/README.md) — Plasma + SDDM + fonts
- [`networking_desktop`](roles/networking_desktop/README.md) — NetworkManager + BT
- [`dev_stack`](roles/dev_stack/README.md) — toolchain, qemu, containers
- [`flatpak`](roles/flatpak/README.md) — system + per-user remotes

## Documentation

- [docs/architecture.md](docs/architecture.md) — overall design philosophy
- [docs/inventory.md](docs/inventory.md) — group hierarchy + var cascade
- [docs/conventions.md](docs/conventions.md) — role conventions, naming, style
- [docs/firewall.md](docs/firewall.md) — firewall rule DSL reference
- [docs/observability.md](docs/observability.md) — zero-conf monitoring deep dive
- [docs/bootstrap.md](docs/bootstrap.md) — LiveUSB install walkthrough
- [docs/secrets.md](docs/secrets.md) — keyfiles, vault, rotation
- [docs/troubleshooting.md](docs/troubleshooting.md) — common breakages
