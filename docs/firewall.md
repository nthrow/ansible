# Firewall DSL

Reference for the rule language used by `roles/firewall/`. Every host
in the fleet uses this same role; differences come from inventory
overrides.

## Goals

- Hardened by default: drop INVALID, drop XMAS/NULL, drop non-SYN NEW,
  drop fragments (v4), default-DROP INPUT and FORWARD.
- Per-tier rule layers expressed as YAML lists, *not* shell scripts.
- One template renders an `iptables-save` file; another renders the
  v6 equivalent. Both atomically restored via `iptables-restore`.
- Composable: a host's `firewall_allow_tcp` is often the concatenation
  of a base list and one or more per-feature additions.

## Rule kinds

There are five top-level rule lists (plus the policy and hardening
toggles).

### `firewall_allow_tcp` and `_udp`

INPUT-chain ACCEPT rules, narrowed by interface and/or source. Each
entry is one of:

```yaml
firewall_allow_tcp:
  # 1. Bare port — accept from any interface, any source.
  - 80

  # 2. Dict with `port`. Optional `in` (interface) and `source` (CIDR).
  - { port: 22, in: wg0 }
  - { port: 22, source: 10.0.0.0/8 }
  - { port: 80, in: eth0, source: 192.0.2.0/24 }

  # 3. Dict with `sources` — emits one rule per source CIDR.
  - port: 179
    sources: ["192.0.2.1", "192.0.2.2"]
  # Equivalent to:
  # - { port: 179, source: 192.0.2.1 }
  # - { port: 179, source: 192.0.2.2 }
```

The `sources:` form is what makes BGP-peer allowlists clean — see the
`cdn_edges` group_vars for an example using
`map(attribute='ip') | list`.

For IPv6, you can use `source_v6:`/`sources_v6:` which override
`source:`/`sources:` in the v6 template only:

```yaml
firewall_allow_tcp:
  # v4-only: emits in iptables, NOT ip6tables.
  - { port: 80, source: 10.0.0.0/8 }

  # v6-only: emits in ip6tables, NOT iptables.
  - { port: 80, source_v6: fd42::/64 }

  # Both families: pair them on the same entry.
  - { port: 22, source: 10.0.0.0/8, source_v6: fd42::/64 }

  # Interface-only (no source restriction) — emits in BOTH families.
  - { port: 22, in: wg0 }
```

Why no v4→v6 fallback? An ip4 address can't be a valid ip6tables
source; emitting it would crash `ip6tables-restore`. Keeping families
strictly separate prevents footguns.

### `firewall_forward_rules`

FORWARD-chain ACCEPT rules. Required for any host that routes traffic
between interfaces (wireguard hubs, NAT'd LAN gateways, docker hosts —
the last is handled by docker itself, not this DSL).

```yaml
firewall_forward_rules:
  # Hub-and-spoke: allow inter-VPN routing.
  - { in: wg0, out: wg0 }

  # Bidirectional bridge between two ifaces (write both rules).
  - { in: eth0, out: br0 }
  - { in: br0,  out: eth0 }

  # With CIDR scoping:
  - { in: wg0, out: eth0, source: 10.0.0.0/24 }
```

Available keys: `in`, `out`, `source` (v4), `dest` (v4), `source_v6`,
`dest_v6`. All optional; unset = no constraint.

### `firewall_nat_masquerade`

POSTROUTING NAT rules in the `*nat` table. Only emitted if the list
is non-empty; otherwise the `*nat` table block is omitted entirely.

```yaml
firewall_nat_masquerade:
  - { src: 10.0.0.0/24, out: eth0 }   # SNAT VPN clients to WAN
```

For v6, use `firewall_nat_masquerade_v6:` (separate var, since v6
NAT is unusual and you usually don't want it).

### Default policies

```yaml
firewall_input_default:   DROP    # default
firewall_forward_default: DROP    # default
firewall_output_default:  ACCEPT  # default — loosened so apk works
```

Set `firewall_output_default: DROP` for very-locked-down hosts. You
will need `firewall_allow_output_*` rules (which the current template
doesn't define — extend if you need it).

### Hardening toggles

```yaml
firewall_drop_invalid:        true   # log+drop INVALID conntrack
firewall_drop_nonsyn_new:     true   # drop new TCP that isn't SYN
firewall_drop_xmas_null:      true   # drop XMAS+NULL TCP
firewall_drop_fragments_v4:   true   # drop IP fragments (v4 only by default)
firewall_drop_fragments_v6:   false
firewall_loopback_protect:    true   # allow lo, REJECT spoofed-lo from non-lo
firewall_allow_icmp:          true
```

### Logging

```yaml
firewall_log_drops: true   # rate-limited LOG line at end of INPUT/FORWARD
firewall_log_rate:  3/min  # iptables --limit value
```

Logged drops show up in `dmesg` / syslog with prefixes `DROP `,
`DROP INVALID `, `FWD `, `FWD INVALID `.

## How rules compose across roles

Each tier's `group_vars/<group>.yml` typically builds the allow-list
from a base + tier-specific additions:

```yaml
# group_vars/cdn_edges.yml
firewall_allow_tcp: "{{ _cdn_edge_base_tcp + _cdn_edge_bgp_tcp }}"

_cdn_edge_base_tcp:
  - { port: 22, in: wg0 }    # ssh via wg only
  - 80
  - 443

_cdn_edge_bgp_tcp:
  - port: 179
    sources: "{{ cdn_edge_bgp_peers | map(attribute='ip') | list }}"
```

Underscored vars are convention for "internal scaffolding."

## Reading the rendered output

Rendered files are at:
- `/etc/iptables/rules-save`
- `/etc/iptables/rules6-save`

These are consumed by `iptables-restore` / `ip6tables-restore` on
service start.

To preview without applying:

```sh
ansible-playbook -i inventory/hosts.yml playbooks/<x>.yml \
    --check --diff --start-at-task="Render iptables rules"
```

To inspect the actual live rules:

```sh
iptables -L -nv --line-numbers
iptables -L FORWARD -nv
iptables -t nat -L POSTROUTING -nv
```

## Coexistence with docker

Docker manipulates iptables itself: at daemon start, it inserts rules
in FORWARD (the `DOCKER` chain) so containers can route. Our
`iptables-restore` wipes those.

The fix lives in `playbooks/docker.yml`: the `docker_host` role's
`restart docker` handler fires after `firewall`'s
`restore iptables` handler in the same play, so docker re-inserts
its rules. **Steady-state is fine; the moment of churn happens only
on actual rule changes.**

If you flush iptables manually (`iptables -F`), you'll need to
`service docker restart` afterward.

## Coexistence with kubernetes / other CNI

We don't run k8s here, but the same pattern applies for any CNI that
manages its own iptables: include their daemon's restart handler
after the firewall's restore handler in the same play, or accept
that firewall changes require a manual restart.

## Common patterns

### "Open this port only on the wireguard interface"

```yaml
firewall_allow_tcp:
  - { port: 9100, in: wg0 }   # node_exporter
```

### "Allow traffic from a list of hosts"

```yaml
firewall_allow_tcp:
  - port: 5432
    sources: "{{ groups['db_clients'] | map('extract', hostvars, 'ansible_host') | list }}"
```

### "Allow forwarding from a tunnel to the internet"

```yaml
firewall_forward_rules:
  - { in: wg0, out: eth0 }
  - { in: eth0, out: wg0 }   # for return traffic on long-lived sessions
firewall_nat_masquerade:
  - { src: 10.0.0.0/24, out: eth0 }
```

For new (state) traffic, you only need `wg0 → eth0`; the
`ESTABLISHED,RELATED` allow at the top of FORWARD handles the
return path. The `eth0 → wg0` example above is wrong for most cases
— don't add it without thinking.

### "Restrict ssh to a known admin network"

```yaml
firewall_allow_tcp:
  - { port: 22, in: wg0 }
  - { port: 22, source: 198.51.100.0/24 }   # office IPs as fallback
```

## Limitations

- **No `mark` or `mangle` table support** — extend the templates if
  you need it.
- **No support for ipset-backed allow-lists** — if your peer list is
  >100 entries, generating one rule per peer gets unwieldy. Add an
  `ipset:` form to the templates.
- **`firewall_allow_output_*` doesn't exist yet** — OUTPUT default is
  ACCEPT; lock it down per-host requires extending the template.
