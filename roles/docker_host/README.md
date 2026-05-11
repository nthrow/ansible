# docker_host

Docker daemon with sane defaults; toggleable rootless mode and swarm
mode (standalone / manager / worker). One role covers all four
combinations (rootless×rootful × standalone×swarm), with one disallowed
combination — see [Rootless + swarm](#rootless--swarm) below.

## What it does

### Common

1. Renders `daemon.json` (json-file logging w/ rotation, live-restore,
   userland-proxy off, metrics endpoint on `wg0:9323` in rootful mode)
   merged with `docker_daemon_extra`.
2. Installs `docker_extra_packages` if any (e.g. `ctop`, `lazydocker`).
3. **`flush_handlers`** — daemon.json must be in place before swarm ops.
4. (`docker_swarm_role != "none"`) Includes `swarm.yml`:
   - First manager (alphabetical inventory order) initializes via
     `community.docker.docker_swarm`.
   - Reads tokens via `docker_swarm_info`, sets as facts (no_log).
   - Other managers join with the manager token.
   - Workers join with the worker token.

### Rootful (`docker_rootless: false`)

- `apk add docker docker-openrc docker-cli-compose py3-docker-py`.
- Templates `/etc/docker/daemon.json`.
- Enables `docker` OpenRC service.
- (Optional) Adds `docker_user` to the docker group.

### Rootless (`docker_rootless: true`, default)

- `apk add docker docker-cli-compose docker-rootless-extras shadow-subids
  rootlesskit slirp4netns py3-docker-py`.
- Sets `rc_cgroup_mode="unified"` in `/etc/rc.conf` and enables the
  `cgroups` service at boot (rootless docker requires cgroups v2
  unified hierarchy).
- Stops + disables the system `docker` service.
- Allocates `/etc/subuid` + `/etc/subgid` ranges for the rootless user
  (default 100000–165535).
- Templates `~{{ docker_rootless_user }}/.config/docker/daemon.json`
  (without `data-root` and `metrics-addr` — see template comments).
- Installs a system OpenRC service at `/etc/init.d/docker-rootless`
  that uses `supervise-daemon` to launch `dockerd-rootless` as the
  rootless user. Logs to `/var/log/docker-rootless.log`. Service
  starts at boot — no interactive login needed.
- Adds `export DOCKER_HOST=unix:///run/user/$UID/docker.sock` to the
  rootless user's `.profile` so the docker CLI works without manual
  env setup.

## Variables

### Daemon

| Var | Default | Notes |
|-----|---------|-------|
| `docker_data_root` | `/var/lib/docker` | Rootful only; rootless uses `$HOME/.local/share/docker`. |
| `docker_log_driver` | `json-file` | |
| `docker_log_max_size` | `10m` | |
| `docker_log_max_files` | `5` | |
| `docker_userland_proxy` | `false` | Real client IPs in containers (rootful). |
| `docker_live_restore` | `true` | Containers survive daemon restarts. |
| `docker_daemon_extra` | `{}` | Merged into daemon.json. |
| `docker_user` | `""` | Existing user added to docker group. **Rootful only**, ignored in rootless mode. |
| `docker_extra_packages` | `[]` | E.g. `[ctop, lazydocker]`. |

### Rootless

| Var | Default | Notes |
|-----|---------|-------|
| `docker_rootless` | `true` | Sane default. Set `false` on swarm hosts. |
| `docker_rootless_user` | `""` | **Required** when rootless. Must already exist. |
| `docker_rootless_subid_start` | `100000` | First host UID for the user-namespace mapping. |
| `docker_rootless_subid_count` | `65536` | Range size. |

### Swarm

| Var | Default | Notes |
|-----|---------|-------|
| `docker_swarm_role` | `none` | `none`/`manager`/`worker`. Set in group_vars. |
| `docker_advertise_iface` | `wg0` | Swarm advertises here. |
| `docker_advertise_addr` | derived | Auto from `ansible_facts[<iface>].ipv4`. |

## Rootless + swarm

**Not supported.** Overlay networks — which swarm requires for
inter-node communication — do not work in rootless mode. The role
hard-fails when `docker_rootless: true` is combined with
`docker_swarm_role != none`, rather than silently downgrading
(silent downgrade defeats the security posture rootless was chosen
for in the first place).

The included `group_vars/docker_managers.yml` and
`group_vars/docker_workers.yml` already pin `docker_rootless: false`,
so a normal `playbooks/docker.yml` run gives you rootless on
`docker_standalone` hosts and rootful on swarm hosts with no extra
config.

## Dependencies

- `firewall` role (opens 2377/7946-tcp + 7946/4789-udp on wg0 for
  swarm hosts).
- `community.docker` collection (uses `community.docker.docker_swarm`
  + `docker_swarm_info`). For rootless hosts the module talks to the
  rootless daemon via `DOCKER_HOST`; ansible inherits the user's env
  if invoked over ssh as `docker_rootless_user`, otherwise set
  `DOCKER_HOST` explicitly when delegating tasks.
- `community.general` collection (`apk` module).
- All swarm hosts must be on the wireguard network (or override
  `docker_advertise_iface` per group).

## Example

```yaml
# inventory/group_vars/docker_standalone.yml
docker_swarm_role: none
docker_rootless: true
docker_rootless_user: nat       # must already exist on the host
docker_extra_packages: [ctop]

# inventory/group_vars/docker_managers.yml      (set by this repo already)
docker_swarm_role: manager
docker_rootless: false
docker_user: alice              # added to docker group

# inventory/group_vars/docker_workers.yml       (set by this repo already)
docker_swarm_role: worker
docker_rootless: false
```

## Troubleshooting

### Rootless

- **`newuidmap: write to uid_map failed`** — `/etc/subuid` or
  `/etc/subgid` is missing the entry for the rootless user. The role
  writes these via `lineinfile`; if you tampered with them manually,
  re-run the playbook.
- **`failed to start daemon: Error initializing network controller`**
  on first start — usually cgroups v2 unified isn't active. Check
  `cat /sys/fs/cgroup/cgroup.controllers`; if missing, confirm
  `rc_cgroup_mode="unified"` in `/etc/rc.conf` and reboot (the
  setting only takes effect at boot).
- **`docker.sock: no such file`** — service didn't start. Check
  `tail /var/log/docker-rootless.log`. Common: missing
  `XDG_RUNTIME_DIR` (the init script's `start_pre` should create
  `/run/user/$UID`; verify it exists and is owned by the rootless
  user).
- **`hello-world` container stuck in pull** — slirp4netns DNS
  fallback. Add `dns: ["1.1.1.1"]` to `docker_daemon_extra` until
  upstream DNS works.

### Swarm

- **Swarm init fails: "this node is already part of a swarm"** —
  leave first: `docker swarm leave --force` on the host, then
  re-run.
- **Workers can't reach the manager: "rpc error: code = Unavailable"**
  — firewall didn't open 2377 between hosts, or wireguard isn't up.
  Check `iptables -L INPUT -nv | grep 2377` and `wg show`.
- **Container forwarding broken after firewall change** — docker's
  iptables-restore got wiped. The role's restart-docker handler
  runs on daemon.json changes; for firewall-only changes, manually
  `service docker restart` (or re-apply `docker.yml`, which
  restarts docker via notification).
- **`metrics-addr` field complains** — needs `experimental: true`
  (the role sets it). Check Alpine's docker pkg is recent enough
  (edge has it). Note that `metrics-addr` is only emitted in
  rootful mode.
- **Multi-arch swarm (Pi + amd64)** — works fine, but you must use
  multi-arch images. `docker buildx` or pull manifests with both
  architectures.
