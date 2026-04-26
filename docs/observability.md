# Observability

How metrics + logs flow end-to-end, and how the zero-conf scrape
config actually works.

## Architecture

```
                         ┌─────────────────────────────┐
                         │   observability host        │
                         │                             │
                         │   prometheus  ─── scrape ───┼──┐
                         │       │                     │  │
                         │       └── grafana           │  │
                         │            │                │  │
                         │   loki ────┘  ◄── push ─────┼──┤
                         └─────────────────────────────┘  │
                                                          │ wg0
   ┌─────────────────┐    ┌─────────────────┐    ┌────────┴────────┐
   │  desktops       │    │  cdn_edges      │    │  cdn_varnish    │
   │                 │    │                 │    │                 │
   │  node_exporter  │    │  node_exporter  │    │  node_exporter  │
   │  promtail       │    │  promtail       │    │  promtail       │
   │                 │    │  nginx_exporter │    │  varnish_exp.   │
   │                 │    │                 │    │  nginx_exporter │
   └─────────────────┘    └─────────────────┘    └─────────────────┘

   ┌─────────────────┐    ┌─────────────────┐    ┌─────────────────┐
   │  wireguard      │    │  docker_hosts   │    │  cdn_origins    │
   │                 │    │                 │    │  (PoC only)     │
   │  node_exporter  │    │  node_exporter  │    │  node_exporter  │
   │  + wg collector │    │  promtail       │    │  promtail       │
   │  promtail       │    │  daemon /metrics│    │  nginx_exporter │
   └─────────────────┘    └─────────────────┘    └─────────────────┘
```

All inter-host traffic happens over the wireguard mesh. Exporters
bind on `wg0` IPs; Prometheus scrapes via wg; promtail pushes to
Loki via wg.

## What runs where

### Every host (via `monitoring_agent` role)

- **node_exporter** on `<wg0>:9100` — host metrics (cpu, mem, disk,
  net, processes, optionally systemd/wireguard collectors).
- **promtail** on `<wg0>:9080` — tails common log paths and pushes
  to Loki.

### Component-specific exporters

| Host class | Exporter | Port | Installed by |
|-----------|----------|------|--------------|
| cdn_edges | nginx_exporter | 9113 | cdn_edge role |
| cdn_varnish | varnish_exporter | 9131 | cdn_varnish role |
| cdn_varnish | nginx_exporter (local nginx) | 9113 | cdn_varnish role |
| cdn_origins | nginx_exporter | 9113 | cdn_origin_static role |
| docker_hosts | docker daemon /metrics | 9323 | docker_host role (daemon.json) |
| wireguard_servers | (node_exporter wg collector) | 9100 | flag in group_vars |

The pattern: each component's role installs its own exporter as a side
effect. **You never have to remember to "add monitoring."** Joining
the right inventory group does it.

### Central host (via `observability` role)

- **Prometheus** on `<wg0>:9090`
- **Loki** on `<wg0>:3100`
- **Grafana** on `<wg0>:3000`

## How the zero-conf scrape config works

`roles/observability/templates/prometheus.yml.j2` is the magic. It
iterates inventory groups via a `targets()` macro:

```jinja
{% macro targets(group, port) %}
{% for h in groups.get(group, []) %}
        - '{{ hostvars[h].ansible_host | default(h) }}:{{ port }}'
{% endfor %}
{% endmacro %}

scrape_configs:
  - job_name: node
    static_configs:
      - targets:
{{ targets('alpine', 9100) }}

  - job_name: nginx
    static_configs:
{% for grp in ['cdn_edges', 'cdn_origins', 'cdn_varnish'] %}
{%   if groups.get(grp, []) | length > 0 %}
      - targets:
{{ targets(grp, 9113) }}
{%   endif %}
{% endfor %}

  ...
```

So:

- New host added to `cdn_varnish` group → on next `observability.yml`
  apply, it appears in the `varnish` and `node` jobs.
- Empty groups produce empty target lists; Prometheus tolerates them.
- No service-discovery infrastructure (consul, file_sd) needed; the
  inventory *is* the SD.

## How log shipping works

`group_vars/all.yml` derives `loki_push_url` from inventory:

```yaml
loki_push_url: >-
  {{ ('http://' ~ hostvars[groups['observability'][0]].ansible_host
                ~ ':3100/loki/api/v1/push')
     if (groups.get('observability', []) | length > 0) else '' }}
```

Each host's `monitoring_agent` role uses this URL in its promtail
config. If the observability group is empty (e.g. before its host is
provisioned), `loki_push_url` is `""` and promtail isn't enabled at
all — the role gates on this.

## Bring-up order (chicken-and-egg)

The first time you build out the fleet, there's an order:

1. **Provision per-tier hosts.** Their monitoring_agent runs without
   loki_push_url (so promtail is installed but not enabled).
2. **Provision the observability host.** Its `prometheus.yml.j2`
   templates against the now-populated inventory.
3. **Re-run per-tier playbooks** (or `site.yml`). Now `loki_push_url`
   resolves; promtail starts shipping.

After this one-time dance, everything is idempotent.

## Adding a new exporter

Worked example: you've added a Postgres role and want pg_exporter
metrics in Prometheus.

1. **Install the exporter in the role.**
   ```yaml
   # roles/postgres/tasks/main.yml
   - name: Install postgres + exporter
     community.general.apk:
       name: [postgresql, prometheus-postgres-exporter]
       state: present
   ```

2. **Bind on wg0.**
   ```yaml
   - name: Configure postgres exporter
     ansible.builtin.copy:
       dest: /etc/conf.d/prometheus-postgres-exporter
       content: |
         ARGS="--web.listen-address={{ ansible_facts.wg0.ipv4.address }}:9187"
   ```

3. **Add a scrape job.**
   ```jinja
   # roles/observability/templates/prometheus.yml.j2
     - job_name: postgres
       static_configs:
         - targets:
   {{ targets('postgres_hosts', 9187) }}
           labels:
             tier: postgres
   ```

4. **(Optional) Add a community dashboard.**
   ```yaml
   # roles/observability/defaults/main.yml
   grafana_dashboards:
     ...
     - { name: postgres, id: 9628, rev: 7 }
   ```

Re-apply `observability.yml`. New metrics show up; new dashboard
appears in Grafana.

## What gets logged

`monitoring_agent`'s default promtail config tails:

| Source | Label `job` |
|--------|-------------|
| `/var/log/*.log` | `varlogs` |
| `/var/log/nginx/*.log` | `nginx` |
| `/var/log/varnish/*.log` | `varnish` |
| `/var/log/messages` | `messages` |

Every log line is labeled with `host=<inventory_hostname>` and
`group=<comma-separated group_names>`, so you can filter by both in
Grafana's Loki explore.

To add another source, edit
`roles/monitoring_agent/templates/promtail.yml.j2`. Adding a per-role
log source (e.g. a custom app's log dir) means extending
`promtail_log_paths` in that role's defaults and the template's
scrape configs.

## Dashboards

`grafana_dashboards` in `roles/observability/defaults/main.yml` lists
community dashboards by grafana.com ID and revision. They're fetched
during `observability.yml` apply via `get_url`, dropped in
`/var/lib/grafana/dashboards/`, and Grafana's file-provisioning
provider auto-loads them.

The `${DS_PROMETHEUS}` / `${DS_LOKI}` placeholders in the fetched
JSON are rewritten to the provisioned datasource UIDs (`prometheus`
and `loki`) by two `ansible.builtin.replace` tasks. Without those
rewrites, panels show "datasource not found."

If you want a custom dashboard:

1. Build it in Grafana's UI.
2. Export JSON from the dashboard settings.
3. Drop in `roles/observability/files/dashboards/<name>.json`.
4. Add a copy task to the role to install it alongside the fetched
   ones.

## Limits + retention

| Knob | Default | Where |
|------|---------|-------|
| Prometheus retention | `30d` | `prometheus_retention` |
| Loki retention | `720h` (30d) | `loki.yml.j2` `retention_period` |
| Log line max age | `168h` (7d) | `loki.yml.j2` `reject_old_samples_max_age` |
| Scrape interval | `15s` | `prometheus_scrape_interval` |

Bump retention on hosts with disk to spare; trim it on a Pi-class obs
node.

## Common gotchas

- **Targets show "DOWN" in Prometheus** — exporter isn't bound on
  wg0, or wg0 is down on that host. SSH in and `nc -z 127.0.0.1 9100`
  vs `nc -z <wg0-ip> 9100`.
- **Loki returns no logs but promtail looks healthy** — labels mismatch
  between query and config. Check `Explore → Loki → label browser`.
- **Grafana dashboards have empty panels but data exists in Prometheus**
  — datasource UID rewrite didn't catch the placeholder. Open the JSON
  in `/var/lib/grafana/dashboards/`, look for any literal
  `${DS_*}`, add a replace task.
- **Storage filling up on the obs host** — Loki's filesystem store
  isn't compacted aggressively by default. The role enables the
  compactor (`compactor:` block in `loki.yml.j2`), but if you bump
  retention way up, watch disk usage.
- **`apk: package loki-promtail not found`** — Alpine occasionally
  reshuffles the loki/promtail packaging. `apk search promtail` to
  find the current name and update `roles/monitoring_agent/tasks/main.yml`.
