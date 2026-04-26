# firewall

Hardened iptables/ip6tables, modeled after the a hardened iptables ruleset
scripts. Fully data-driven: rule lists in vars produce
`iptables-save`-format rules, atomically restored via the OpenRC
service.

For the rule-language reference, see [docs/firewall.md](../../docs/firewall.md).

## What it does

1. Installs `iptables` + `ip6tables`.
2. Sets `SAVE_ON_STOP="no"` in `/etc/conf.d/{ip,ip6}tables` (otherwise
   `rc-service stop` would clobber our rendered rules with whatever's
   live in the kernel).
3. Renders `/etc/iptables/rules-save` and `/etc/iptables/rules6-save`
   from inventory variables.
4. Enables both services at the `default` runlevel; reload handlers
   re-`iptables-restore` on rule changes.

## Variables

The role's `defaults/main.yml` defines hardening toggles + empty
allow-lists. Hosts override allow-lists per group/host.

### Default policies

| Var | Default | Effect |
|-----|---------|--------|
| `firewall_input_default` | `DROP` | Default policy on INPUT. |
| `firewall_forward_default` | `DROP` | Default policy on FORWARD. |
| `firewall_output_default` | `ACCEPT` | Default policy on OUTPUT (loosened so apk works). |

### Hardening (INPUT)

| Var | Default | Effect |
|-----|---------|--------|
| `firewall_drop_invalid` | `true` | Log+drop INVALID conntrack states. |
| `firewall_drop_nonsyn_new` | `true` | Drop new TCP that isn't SYN. |
| `firewall_drop_xmas_null` | `true` | Drop XMAS + NULL TCP packets. |
| `firewall_drop_fragments_v4` | `true` | Drop IP fragments (v4). |
| `firewall_drop_fragments_v6` | `false` | Don't drop fragments on v6. |
| `firewall_loopback_protect` | `true` | Allow lo, REJECT spoofed-loopback from non-lo. |
| `firewall_allow_icmp` | `true` | Echo (v4) / full ICMPv6. |

### Allow-lists

`firewall_allow_tcp` and `firewall_allow_udp` accept three forms:

```yaml
firewall_allow_tcp:
  - 22                                   # bare port — open from anywhere
  - { port: 22, in: wg0 }                # only on iface wg0
  - { port: 22, source: 10.0.0.0/8 }     # only from one CIDR
  - { port: 179, sources: ["10.0.0.1", "10.0.0.2"] }   # one rule per source
```

### Forward + NAT

```yaml
firewall_forward_rules:
  - { in: wg0, out: wg0 }                # inter-VPN routing
firewall_nat_masquerade:
  - { src: 10.0.0.0/24, out: eth0 }
```

### Logging

| Var | Default | |
|-----|---------|--|
| `firewall_log_drops` | `true` | Rate-limited log line at end of INPUT/FORWARD. |
| `firewall_log_rate` | `3/min` | iptables `--limit` value. |

## Dependencies

None for the role itself. **Plays that include both `firewall` and
`docker_host` need them in the same play** so the docker-restart
handler fires after the iptables-restore handler — otherwise docker's
FORWARD-chain insertions get wiped on rule changes.

## Example

```yaml
# group_vars/cdn_edges.yml
firewall_allow_tcp: "{{ _base + _bgp }}"
_base:
  - { port: 22, in: wg0 }
  - 80
  - 443
_bgp:
  - port: 179
    sources: "{{ cdn_edge_bgp_peers | map(attribute='ip') | list }}"
firewall_forward_rules: []
firewall_nat_masquerade: []
```

## Troubleshooting

- **`iptables-restore: line N failed`** — `cat /etc/iptables/rules-save`
  on the host and look at line N. Usually a syntactically odd entry
  from a typo'd `firewall_allow_tcp` item.
- **Rules disappear after `rc-service iptables stop`** — confirm
  `SAVE_ON_STOP="no"` is in `/etc/conf.d/iptables` (the role sets it).
- **Docker containers can't reach the network after a firewall reload**
  — the `iptables-restore` wiped docker's chain. Fix:
  `service docker restart` (or re-run `docker.yml`, which restarts
  docker as a notify handler).
- **Want to see what'll be applied before applying it** — run with
  `--check --diff`; the template diff prints. Or render manually:
  `ansible-playbook ... --start-at-task="Render iptables rules" --check`.
