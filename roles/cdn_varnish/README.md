# cdn_varnish

Varnish-as-L7-manipulator with a co-located nginx for static content
and optional NFS server/client modes. Plus `prometheus-varnish-exporter`
and `nginx-prometheus-exporter` for zero-conf observability.

## What it does

1. `apk add varnish nginx nfs-utils prometheus-varnish-exporter
   nginx-prometheus-exporter`.
2. Creates `/srv/cdn-content` (mode 0755).
3. (`nfs_role: server`) Templates `/etc/exports`, enables `rpcbind` +
   `nfs` services, runs `exportfs -ra` on changes.
4. (`nfs_role: client`) Mounts the remote export at the content path
   with hardened mount opts.
5. Drops Alpine's default nginx confs, templates a local nginx that
   listens on `127.0.0.1:<port>` serving the content path with a
   `/healthz` endpoint and a `127.0.0.1:8081/stub_status` block.
6. Templates `/etc/conf.d/varnishd` (passes args via `VARNISHD_OPTS`)
   and `/etc/varnish/default.vcl` (validated via `varnishd -C` before
   moving into place).
7. Configures the two exporters to bind on `wg0:{9131,9113}`.
8. Enables nginx + varnishd + both exporters.

## Variables

### Varnish

| Var | Default | Notes |
|-----|---------|-------|
| `cdn_varnish_listen_addr` | `0.0.0.0` | |
| `cdn_varnish_listen_port` | `6081` | What edges connect to. |
| `cdn_varnish_admin_addr` | `127.0.0.1` | |
| `cdn_varnish_admin_port` | `6082` | |
| `cdn_varnish_storage` | `malloc,256m` | L7 manipulation isn't cache-heavy. |
| `cdn_varnish_extra_args` | `""` | Appended to varnishd cmdline. |

### Backends + routing

```yaml
cdn_varnish_object_store_backends:
  - name: isilon
    host: "isilon.internal"
    port: 80
    probe_url: "/_health"      # optional; else no probe
  - name: minio
    host: "minio.internal"
    port: 9000

cdn_varnish_routes:
  - { match_host: "media.example.com",      backend: local_nginx }
  - { match_path_prefix: "/api/",           backend: minio       }
  - { match_path_regex: "\\.jpg$",          backend: isilon      }
  - { match_host_in: ["a.com", "b.com"],    backend: local_nginx }

# Fallthrough: round-robin over object_store_backends, or local_nginx
# if no object stores configured.
```

`local_nginx` is always declared as a backend (probes
`127.0.0.1:8080/healthz`).

### L7 manipulation

```yaml
cdn_varnish_set_response_headers:
  - { name: "X-CDN", value: "edge-1" }
cdn_varnish_unset_response_headers:
  - "Server"
  - "X-Powered-By"
```

### Local nginx + NFS

| Var | Default | Notes |
|-----|---------|-------|
| `cdn_varnish_local_nginx_port` | `8080` | Bound to 127.0.0.1 only. |
| `cdn_varnish_content_path` | `/srv/cdn-content` | nginx root. |
| `cdn_varnish_nfs_role` | `none` | `none`/`server`/`client` |
| `cdn_varnish_nfs_clients` | `[]` | If server: `[{network, options}]` |
| `cdn_varnish_nfs_remote_host` | `""` | If client. |
| `cdn_varnish_nfs_remote_export` | `""` | If client. |
| `cdn_varnish_nfs_mount_options` | `ro,nfsvers=4.2,hard,intr,nodev,nosuid,noexec` | If client. |

## Dependencies

- `firewall` role — opens varnish port (restricted to internal subnet)
  and 2049 for NFS server mode.

## Example

See `inventory/group_vars/cdn_varnish.yml`.

## Troubleshooting

- **Varnish refuses to start: "Backend host '...' could not be resolved"**
  — declared an object_store_backends entry pointing at an unresolvable
  hostname. `varnishd -C` validates this; check `validate:` output.
- **Routes never match** — VCL is order-sensitive. The first match
  wins. Verify with `varnishlog -g request` (or `varnishncsa`) which
  backend was hit.
- **Exporter scrape returns no metrics** — `prometheus-varnish-exporter`
  reads from the `varnishstat` socket; if varnish was restarted while
  the exporter held the connection, restart the exporter.
- **NFS export not picked up after re-rendering `/etc/exports`** —
  the handler runs `exportfs -ra`, which is correct. If exports still
  don't show, check `showmount -e localhost`.
- **"VCL was not loaded" / "VCL.show" errors** — usually a syntax
  error or missing `vmod_directors`. Alpine's varnish ships the std
  vmods. Reload via `varnishreload`, restart only on hard breakage.
