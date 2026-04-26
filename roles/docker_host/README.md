# docker_host

Docker daemon with sane defaults; toggleable swarm mode (standalone /
manager / worker) via `docker_swarm_role`. One role covers all three.

## What it does

1. `apk add docker docker-cli-compose py3-docker` (the last is for the
   `community.docker` ansible module to work).
2. Templates `/etc/docker/daemon.json` (json-file logging w/ rotation,
   live-restore, userland-proxy off, metrics endpoint on
   `wg0:9323`) merged with `docker_daemon_extra`.
3. Enables `docker` service, restarts on daemon.json changes.
4. (Optional) Adds `docker_user` to the docker group.
5. **`flush_handlers`** — daemon.json must be in place before swarm ops.
6. (`docker_swarm_role != "none"`) Includes `swarm.yml`:
   - First manager (alphabetical inventory order) initializes via
     `community.docker.docker_swarm`.
   - Reads tokens via `docker_swarm_info`, sets as facts (no_log).
   - Other managers join with the manager token.
   - Workers join with the worker token.

## Variables

### Daemon

| Var | Default | Notes |
|-----|---------|-------|
| `docker_data_root` | `/var/lib/docker` | |
| `docker_log_driver` | `json-file` | |
| `docker_log_max_size` | `10m` | |
| `docker_log_max_files` | `5` | |
| `docker_userland_proxy` | `false` | Real client IPs in containers. |
| `docker_live_restore` | `true` | Containers survive daemon restarts. |
| `docker_daemon_extra` | `{}` | Merged into daemon.json. |
| `docker_user` | `""` | Existing user added to docker group. |
| `docker_extra_packages` | `[]` | E.g. `[ctop, lazydocker]`. |

### Swarm

| Var | Default | Notes |
|-----|---------|-------|
| `docker_swarm_role` | `none` | `none`/`manager`/`worker`. Set in group_vars. |
| `docker_advertise_iface` | `wg0` | Swarm advertises here. |
| `docker_advertise_addr` | derived | Auto from `ansible_facts[<iface>].ipv4`. |

## Dependencies

- `firewall` role (opens 2377/7946-tcp + 7946/4789-udp on wg0).
- `community.docker` collection.
- All swarm hosts must be on the wireguard network (or override
  `docker_advertise_iface` per group).

## Example

```yaml
# inventory/group_vars/docker_managers.yml
docker_swarm_role: manager
docker_user: alice
docker_extra_packages: [ctop]

# group_vars/docker_workers.yml
docker_swarm_role: worker

# group_vars/docker_standalone.yml
docker_swarm_role: none
```

## Troubleshooting

- **Swarm init fails: "this node is already part of a swarm"** — leave
  the existing swarm first: `docker swarm leave --force` on the host,
  then re-run the playbook.
- **Workers can't reach the manager: "rpc error: code = Unavailable"**
  — the firewall didn't open 2377 between hosts, or the wireguard
  tunnel isn't up. Check `iptables -L INPUT -nv | grep 2377` and
  `wg show`.
- **Container forwarding broken after a firewall change** — docker's
  iptables-restore got wiped. The role's restart-docker handler runs
  on daemon.json changes; for firewall-only changes, manually
  `service docker restart` (or re-apply `docker.yml`, which restarts
  docker via notification).
- **`metrics-addr` field in daemon.json complains** — it requires
  `experimental: true` (the role sets it). Check Alpine's docker pkg
  is recent enough (edge has it).
- **Multi-arch swarm (Pi + amd64)** — works fine, but you must use
  multi-arch images. `docker buildx` or pull manifests with both
  architectures.
