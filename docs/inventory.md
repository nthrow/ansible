# Inventory

Group hierarchy, var cascade, and the inventory/poc separation.

## The hierarchy

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

Defined in `inventory/hosts.yml` via Ansible's `children:` syntax. Each
host belongs to exactly one leaf group and inherits all parents'
variables.

## Var cascade

Ansible merges variables in a defined precedence order. The relevant
ones for this repo:

```
role defaults                       (lowest)
inventory group_vars/all.yml
inventory group_vars/<parent>.yml
inventory group_vars/<leaf>.yml
inventory host_vars/<host>.yml
play vars
extra-vars (-e)                     (highest)
```

So a host in `cdn_edges` gets vars from:

1. Each role's `defaults/main.yml` it ends up applying.
2. `group_vars/all.yml`.
3. `group_vars/alpine.yml` (if present — none today).
4. `group_vars/servers.yml`.
5. `group_vars/cdn.yml`.
6. `group_vars/cdn_edges.yml`.
7. `host_vars/<edge1>.yml` (if present).

Variables of the same name later in the chain win.

## Where to put a config value

| Where | Use it for |
|-------|-----------|
| `roles/<role>/defaults/main.yml` | The role's *defaults*. The "if you don't set anything, this is what you get." |
| `inventory/group_vars/all.yml` | Truly fleet-wide constants (apk repos, base packages, loki_push_url derivation). |
| `inventory/group_vars/<group>.yml` | Anything specific to a *class* of host. Most config lives here. |
| `inventory/host_vars/<host>.yml` | Per-host overrides only. ASN, BGP router-id, hostname-specific cert paths. |
| `playbooks/<x>.yml` `vars:` | Avoid. Use group_vars. The only legitimate use is play-scoped vars not visible to roles. |

Never put non-trivial config in role `defaults/main.yml` — those are
*defaults*, meant to make a role usable with empty group_vars. The
real config is inventory-side.

## Helper-vars convention

Lists that are concatenated together (e.g. firewall rule chains)
sometimes need a private intermediate var. We prefix those with `_`:

```yaml
# group_vars/cdn_edges.yml
firewall_allow_tcp: "{{ _cdn_edge_base_tcp + _cdn_edge_bgp_tcp }}"
_cdn_edge_base_tcp:
  - { port: 22, in: wg0 }
  - 80
  - 443
_cdn_edge_bgp_tcp:
  - port: 179
    sources: "{{ cdn_edge_bgp_peers | map(attribute='ip') | list }}"
```

The `_`-prefix communicates "internal scaffolding, don't override
directly." Ansible doesn't enforce it; convention only.

## host_vars usage

Use `host_vars/<host>.yml` for things that genuinely vary per box:

- `hostname` (when it differs from inventory_hostname)
- `cdn_edge_router_id` (one per edge, must be unique)
- `cdn_edge_bgp_peers` (different switch peer per edge in a multi-rack
  topology)
- TLS cert paths (per-host certs)
- `wireguard_peers` lists (if managed per-hub rather than fleet-wide)

Don't put config there that's identical across a group — it belongs
in group_vars.

## The `inventory/poc/` separation

The CDN PoC has its own *inventory*, not just its own group_vars:

```
inventory/poc/
├── hosts.yml
└── group_vars/
    ├── all.yml             ← lean PoC overrides
    ├── cdn_edges.yml
    ├── cdn_varnish.yml
    └── cdn_origins.yml
```

Run with `-i inventory/poc/`. Vars there are completely independent
from `inventory/group_vars/*`. This is intentional: the PoC runs with
firewall off, no wireguard, no observability — sharing inventory with
prod would mean every PoC override has to also disable a prod feature.

When in doubt, prefer a separate inventory directory over piling
"poc-mode flags" into the main one.

## Adding a new host

1. Decide which leaf group it belongs to.
2. Add it to `inventory/hosts.yml` under that group:
   ```yaml
   docker_workers:
     hosts:
       pi-wk-4:
         ansible_host: 10.0.0.74
   ```
3. (If unique config) drop a `host_vars/pi-wk-4.yml`.
4. Run the relevant playbook (`playbooks/docker.yml`).
5. The host shows up in Prometheus on the next `observability.yml`
   apply (because `prometheus.yml.j2` iterates inventory groups).

## Adding a new group

Less common. Reasons you might:

- New host class (e.g. NAS with NFS exports). Make a leaf group under
  `servers:`, write a role, add a playbook.
- Splitting an existing group (e.g. `docker_managers` into
  `docker_managers_primary` / `_secondary`). Usually solved by
  host_vars instead.

When you do add a group, also add `group_vars/<group>.yml` even if
just empty — it documents that the group is real.

## Inspection commands

```sh
# What groups does a host belong to?
ansible-inventory --host <host>

# What hosts are in a group?
ansible-inventory --graph

# What vars resolve for a host?
ansible <host> -m debug -a "var=hostvars[inventory_hostname]"

# Just one var:
ansible <host> -m debug -a "var=firewall_allow_tcp"
```
