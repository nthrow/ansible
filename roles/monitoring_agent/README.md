# monitoring_agent

Universal observability agent: Prometheus `node_exporter` + Loki
`promtail`, both bound to the host's wireguard IP. Included by every
per-tier playbook.

## What it does

1. `apk add prometheus-node-exporter loki-promtail`.
2. Templates `/etc/conf.d/node-exporter` so the daemon listens on
   `<wg0-ip>:9100`. Restarts on change.
3. Renders `/etc/loki/promtail-config.yml` with scrape configs for
   `/var/log/messages`, `/var/log/nginx/*.log`, `/var/log/varnish/*.log`,
   etc., labeled with hostname + group_names.
4. Enables both services at the `default` runlevel.

Promtail config (and the service) is **only enabled when
`loki_push_url` is non-empty** — i.e. once the observability host is
provisioned and the URL is auto-derived in `group_vars/all.yml`.

## Variables

| Var | Default | Notes |
|-----|---------|-------|
| `monitoring_bind_iface` | `wg0` | Which interface to bind on. |
| `monitoring_bind_addr` | `ansible_facts[<iface>].ipv4.address`, fallback `127.0.0.1` | |
| `node_exporter_port` | `9100` | |
| `node_exporter_flags` | `--collector.systemd --collector.processes` | wireguard hosts add `--collector.wireguard` via group_vars. |
| `promtail_port` | `9080` | |
| `promtail_log_paths` | system + nginx + varnish + dmesg | Used in default scrape configs. |
| `loki_push_url` | derived in `all.yml` | Empty disables promtail entirely. |

## Dependencies

- The fleet expects the observability host to be at
  `groups['observability'][0]`. The Loki push URL is derived from its
  `ansible_host` in `group_vars/all.yml`.
- Hosts must be on the wireguard network to reach Loki — or override
  `monitoring_bind_iface`/`loki_push_url` per group.

## Example

```yaml
# group_vars/wireguard_servers.yml
node_exporter_flags: >-
  --collector.systemd --collector.processes --collector.wireguard
```

## Troubleshooting

- **`apk: package loki-promtail not found`** — Alpine occasionally
  renames packages. Check `apk search promtail`; the binary may be in
  a `loki-promtail` or `promtail` package depending on the snapshot.
- **Promtail not running** — verify `loki_push_url` is non-empty on
  this host: `ansible -i inventory/hosts.yml <host> -m debug -a "var=loki_push_url"`.
  If empty, the observability host isn't in inventory yet.
- **Prometheus scrape returns "context deadline exceeded"** — node_exporter
  is bound to wg0 IP, but you're scraping from outside the tunnel. Check
  the scrape target in `prometheus.yml` matches the wg-side address.
- **`unknown collector wireguard`** — your `prometheus-node-exporter`
  package is too old. Alpine edge has a recent enough build.
