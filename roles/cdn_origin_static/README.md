# cdn_origin_static

PoC-only origin: nginx serving `/srv/origin` with an `X-Tier: origin`
response header and a tiny seeded sample tree
(`index.html`, `api/status.json`). Plus an `nginx-prometheus-exporter`
for parity with the production tiers.

This role exists so the `cdn-poc.yml` playbook has something to point
edges at without dragging in a full object store. **Don't use it in
production** — replace with real `cdn_varnish_object_store_backends`
pointing at Isilon/MinIO/etc.

## What it does

1. `apk add nginx nginx-prometheus-exporter`.
2. Drops Alpine's default nginx confs.
3. Renders `/etc/nginx/nginx.conf` with a server block on
   `<listen_addr>:<port>` rooted at `<root>`, plus a stub_status block
   for the exporter.
4. Creates the content tree (`<root>` and `<root>/api`).
5. Seeds `index.html` and `api/status.json` with `force: false` (never
   overwrites if you've added your own content).
6. Configures + enables the exporter.
7. Enables nginx.

## Variables

| Var | Default | Notes |
|-----|---------|-------|
| `cdn_origin_listen_addr` | `0.0.0.0` | |
| `cdn_origin_listen_port` | `80` | |
| `cdn_origin_root` | `/srv/origin` | |

## Dependencies

None beyond apk.

## Example

```yaml
# inventory/poc/group_vars/cdn_origins.yml
cdn_origin_root: /srv/origin
```

## Troubleshooting

- **404s for content you added under `/srv/origin`** — confirm file
  permissions allow nginx to read; the role doesn't chown the tree
  beyond what it seeds.
- **Sample files are wrong** — `force: false` is *seed only*. To reset
  the seed, delete the files and re-apply.
