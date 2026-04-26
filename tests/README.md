# tests/

End-to-end validation harness. Spins up alpine containers on a docker
network, applies the relevant playbooks, asserts on real behavior
(curl through CDN chain, prometheus targets UP, alloy → loki shipping,
docker `/metrics` endpoint, wireguard tunnel handshake), tears down.

This is the same flow that caught ~25 real bugs during initial
verification. Run it on every meaningful change to roles or
playbooks.

## Requirements

- `docker` on the host (any modern engine — tested with docker 29.x)
- `ssh` + `ssh-keygen` available
- For the `wg` test: the host kernel needs `wireguard` module loaded
  (`sudo modprobe wireguard`). The harness skips `wg` if absent.

No ansible needed on the host — installed inside the controller
container.

## Usage

```sh
./tests/run.sh                  # all five suites (static + four runtime)
./tests/run.sh cdn              # just the CDN PoC
./tests/run.sh static           # just lint
./tests/run.sh wg obs           # multiple suites
./tests/run.sh --keep           # leave containers running for debug
./tests/run.sh --no-idempotency # skip the rerun-and-check step
```

Exit code: 0 if all assertions pass, 1 otherwise. Output uses three
levels:
- `✓ <message>` — assertion passed
- `⚠ <message>` — non-blocking warning (e.g. lint advisories,
  service-only "changes" on idempotent rerun in the container quirk)
- `✗ <message>` — hard failure, sets exit code 1

## What each suite covers

### `static`
- `yamllint` across `inventory/`, `roles/`, `playbooks/`
- `ansible-lint` across `playbooks/*.yml`
- Errors fail the run; warnings are advisory
- No containers spun up beyond the controller — fast (~30s)

### `cdn`
- spawns edge / varnish / origin
- runs `playbooks/cdn-poc.yml`
- asserts: 200 response, `X-CDN: poc` and `X-Tier: varnish` headers,
  origin body served
- **idempotency**: reruns the play, asserts `changed=0` (or warns if
  only service-state tasks flap due to container quirks)

### `obs`
- spawns obs (plus the cdn boxes from the cdn suite if run together)
- applies `monitoring_agent` fleet-wide + `observability` on obs
- asserts: prometheus self-scrape, at least one target UP,
  loki `/ready`, grafana login serving, all expected dashboards
  loaded, alloy actually shipping logs to loki
- **idempotency**: reruns the combined play

### `docker`
- spawns dock (--privileged for DinD)
- applies `common` + `docker_host` (standalone)
- asserts: live-restore enabled, metrics endpoint responding on
  `:9323`
- **idempotency**: reruns the play

### `wg`
- spawns wg-hub + wg-peer
- runs `wireguard_hub` role twice (first w/o peers, then w/ peer)
- manually configures the peer side
- asserts: `wg0` listening on 51820, peer can ping hub via 10.0.0.1
- **idempotency**: reruns the (peer-included) play

## Container layout

| name        | port | docker IP    | what's there |
|-------------|------|--------------|--------------|
| controller  | 22210| 172.31.0.5   | ansible-core, repo, runs all plays |
| obs         | 22250| 172.31.0.40  | prometheus + loki + grafana |
| edge        | 22220| 172.31.0.10  | nginx (reverse proxy) |
| varnish     | 22221| 172.31.0.20  | varnish + local nginx |
| origin      | 22222| 172.31.0.30  | nginx-as-origin |
| dock        | 22240| 172.31.0.70  | docker daemon (DinD) |
| wg-hub      | 22230| 172.31.0.50  | wireguard hub |
| wg-peer     | 22231| 172.31.0.60  | wireguard peer (test only) |

All on the `cdn-poc-test` docker network.

## Known container-only quirks

The harness papers over a few docker-vs-real-Alpine differences:

- **`/sys/fs/cgroup` is RO by default in containers** — harness
  remounts RW (needs `--cap-add SYS_ADMIN`).
- **`/tmp` is mounted with `noexec`** — harness sets `--tmpfs /tmp:exec`
  on container create. Varnish refuses to compile VCL otherwise.
- **`/etc/hostname` is bind-mounted** — the `common` role uses
  `shell:` echo instead of `copy:` to avoid the EBUSY rename failure.
- **openrc isn't pid 1** — harness writes `/run/openrc/softlevel`
  manually; openrc service tracking is fragile across restarts but
  fine on first run, which is what the role contracts cover.

These all become non-issues on real hardware.
