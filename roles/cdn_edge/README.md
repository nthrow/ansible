# cdn_edge

CDN edge gateway: nginx (TLS termination + reverse proxy) + BIRD
(eBGP anycast announcement) + nginx-prometheus-exporter.

Anycast is **toggleable**: `cdn_edge_anycast_enabled: false` skips
BIRD/VIPs entirely so the same role works for a single-edge PoC.

## What it does

1. `apk add nginx nginx-prometheus-exporter` (always);
   `apk add bird` (when anycast enabled).
2. (Anycast on) Drops `/etc/local.d/anycast-vips.start` to bind each
   VIP in `cdn_edge_anycast_v4`/`_v6` to lo at boot.
3. Templates `/etc/nginx/nginx.conf` with:
   - One `upstream <zone>_pool` block per `cdn_edge_zones` entry.
   - A `127.0.0.1:8081/stub_status` server block for the exporter.
4. Templates one `/etc/nginx/http.d/zone-<name>.conf` per zone:
   - With `tls_cert`/`tls_key` set → HTTPS server block + 80→443
     redirect + HSTS.
   - Without → plain HTTP only (PoC mode).
5. Configures `nginx-prometheus-exporter` (binds to `wg0:9113`, scrapes
   the local stub_status).
6. (Anycast on) Templates `/etc/bird/bird.conf` — eBGP per peer, exports
   the static anycast routes.

## Variables

### Anycast

| Var | Default | Notes |
|-----|---------|-------|
| `cdn_edge_anycast_enabled` | `true` | Master switch. |
| `cdn_edge_local_asn` | `65000` | |
| `cdn_edge_router_id` | `ansible_host` | One per node. |
| `cdn_edge_bgp_peers` | `[]` | `[{ip, asn, [password, description]}]` |
| `cdn_edge_anycast_v4` | `[]` | List of `<vip>/32` strings. |
| `cdn_edge_anycast_v6` | `[]` | List of `<vip>/128` strings. |

### Zones

```yaml
cdn_edge_zones:
  - name: media                       # used for upstream block + filename
    server_names: ["media.example.com"]
    listen_v4: "203.0.113.10"          # match an anycast VIP (omit for 0.0.0.0)
    listen_v6: "2001:db8:cafe::10"     # optional
    tls_cert: "/etc/ssl/cdn/media.crt"  # omit both for plain HTTP
    tls_key:  "/etc/ssl/cdn/media.key"
    upstream_servers:
      - "10.0.20.21:6081"
      - "10.0.20.22:6081"
    keepalive: 32                       # default 32
```

### TLS

| Var | Default |
|-----|---------|
| `cdn_edge_tls_protocols` | `TLSv1.2 TLSv1.3` |
| `cdn_edge_tls_ciphers` | ECDHE-only modern set |
| `cdn_edge_hsts_max_age` | `63072000` (2 years) |

### nginx tuning

| Var | Default |
|-----|---------|
| `cdn_edge_nginx_user` | `nginx` |
| `cdn_edge_nginx_worker_processes` | `auto` |
| `cdn_edge_nginx_worker_connections` | `8192` |

## Dependencies

- `firewall` role — opens 80, 443, 179 (BGP, restricted to peers).
- `community.general.apk`.
- BIRD 2.x (Alpine's `bird` package).
- TLS certs are NOT managed by this role — provision them separately
  (acme.sh, certbot, manual deploy).

## Example

See `inventory/group_vars/cdn_edges.yml` for the full annotated config.

## Troubleshooting

- **`nginx -t` fails on `validate:` step** — the template's diff is in
  `--diff`. Most often: an upstream pool with no servers, or a zone
  with `tls_cert` set but the cert file missing.
- **BIRD session won't come up** — check `birdc show protocols` on the
  edge. Common causes: ASN mismatch, MD5 password mismatch, peer
  unreachable on the BGP-listening interface.
- **Anycast traffic only lands on one edge** — verify the *switch* is
  doing per-flow ECMP, not per-prefix. The router-id must be unique
  per edge.
- **Exporter shows 0 active connections but traffic is flowing** —
  confirm `nginx -V 2>&1 | grep stub_status` returns a match
  (`with-http_stub_status_module`). Alpine's nginx ships with it.
- **Need to roll out new zones without restarting nginx** — change
  `cdn_edge_zones`, run the playbook. The handler reloads (not
  restarts), so existing connections survive.
