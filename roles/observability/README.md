# observability

Central Prometheus + Loki + Grafana stack on a dedicated host. Native
apk installs — no docker required, no extra dependencies.

For the zero-conf flow that gets metrics from every other host into
this stack, see [docs/observability.md](../../docs/observability.md).

## What it does

1. `apk add prometheus loki grafana`.
2. Templates `/etc/prometheus/prometheus.yml` from inventory groups.
   Each scrape job is a Jinja loop over `groups[<group>]` — adding a
   host to a group makes it a scrape target on the next apply.
3. Configures prometheus runtime args via `/etc/conf.d/prometheus`
   (listen on `wg0:9090`, retention `30d`).
4. Templates `/etc/loki/loki-config.yml` (filesystem storage, schema
   v13, 30d retention, compactor enabled).
5. Templates `/etc/grafana.ini` + provisioning files for datasources
   (`prometheus`, `loki`) and dashboards.
6. Fetches community dashboards from grafana.com at apply time
   (`get_url`) and rewrites `${DS_PROMETHEUS}`/`${DS_LOKI}`
   placeholders to the provisioned datasource UIDs.
7. Enables all three services.

## Variables

### Prometheus

| Var | Default |
|-----|---------|
| `prometheus_port` | `9090` |
| `prometheus_scrape_interval` | `15s` |
| `prometheus_retention` | `30d` |

### Loki

| Var | Default |
|-----|---------|
| `loki_port` | `3100` |

### Grafana

| Var | Default | Notes |
|-----|---------|-------|
| `grafana_port` | `3000` | |
| `grafana_admin_user` | `admin` | |
| `grafana_admin_password` | `admin` | **Vault before exposing.** |
| `grafana_root_url` | `http://<wg-ip>:3000` | |

### Dashboards

```yaml
grafana_dashboards:
  - { name: node-exporter,  id: 1860,  rev: 41 }   # Node Exporter Full
  - { name: nginx,          id: 12708, rev: 1 }
  - { name: varnish,        id: 8377,  rev: 1 }
  - { name: docker,         id: 11600, rev: 1 }
  - { name: wireguard,      id: 12177, rev: 1 }
  - { name: loki-logs,      id: 13639, rev: 2 }
```

## Dependencies

- The fleet must already be partly provisioned, so each scrape target
  is up. See "Bring-up order" in
  [docs/observability.md](../../docs/observability.md).
- `monitoring_agent` role must be applied to every other host so
  promtail pushes logs to this host's Loki.

## Example

```yaml
# inventory/group_vars/observability.yml
firewall_allow_tcp:
  - { port: 22,   in: wg0 }
  - { port: 3000, in: wg0 }   # grafana
  - { port: 3100, in: wg0 }   # loki ingress
loki_push_url: "http://{{ obs_bind_addr | default('127.0.0.1') }}:3100/loki/api/v1/push"
```

## Troubleshooting

- **Grafana shows "No data" on dashboards** — check the datasource
  URL in Grafana's Data sources page resolves. The default points at
  `wg0` IP; if the obs host's wg0 is down, prometheus is unreachable.
- **Prometheus targets show as DOWN** — confirm the exporter on the
  target host is running and listening on its wg0 IP. `nc -z <wg-ip> 9100`
  from any other host on the tunnel.
- **Loki ingestion fails: "max line size exceeded"** — promtail tail
  hit a long log line. Add a `pipeline_stages: drop` entry in
  promtail config for the offending source.
- **`grafana.com` unreachable during apply** — dashboards won't fetch.
  Either pre-stage the JSON files in `roles/observability/files/dashboards/`
  and skip the `get_url`, or apply when you have outbound HTTPS.
- **Dashboards show `${DS_PROMETHEUS}` literally** — the replace task
  ran but the dashboard JSON uses a different placeholder format.
  Check the JSON; some community dashboards use `"${datasource}"` or
  `"$datasource"`. Add a matching `replace` entry.
