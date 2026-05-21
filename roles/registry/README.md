# registry

Runs a Docker registry (image: `registry:2` by default) on a docker_host
as a private push/pull target.

## What it does

1. Creates a ZFS dataset (`rpool/opt/registry` by default), mounts it at
   `/opt/registry`, chowns to the rootless docker user.
2. Writes a rootless docker `daemon.json` so the host trusts its own
   registry as insecure (no TLS).  Restarts `docker-rootless` to pick it
   up.
3. Starts the registry container under the rootless docker user with
   the dataset bind-mounted to `/var/lib/registry`.  Restart policy
   `unless-stopped`.

## Variables

See [`defaults/main.yml`](defaults/main.yml).  Most-likely-to-change:

- `registry_image` — bump to a newer registry tag if needed
- `registry_port` — host-side port (default 5000)
- `registry_user` — defaults to `{{ docker_rootless_user }}`
- `registry_configure_local_insecure` — set `false` if terminating TLS
  in front

## Client-side (push-from-pad) setup

The role only configures the server.  On a client docker daemon
(`pad`), add the registry to its insecure-registries:

```jsonc
// /etc/docker/daemon.json  (rootful) or
// ~/.config/docker/daemon.json  (rootless)
{
  "insecure-registries": ["air:5000"]
}
```

Then `systemctl restart docker` (or `rc-service docker restart` /
`rc-service docker-rootless restart`) for the client.  Push pattern:

```sh
docker build -t air:5000/myimage:v1 .
docker push air:5000/myimage:v1
```

A future `registry_client` role will codify this once we're sure of the
shape we want.

## Garbage collection

The registry doesn't GC by default.  Until v2 ships a weekly cron drop:

```sh
docker exec registry registry garbage-collect /etc/docker/registry/config.yml
```

## Wiring into the playbook

Add to `playbooks/docker.yml` (or a new dedicated playbook) as the last
role on hosts that should host a registry:

```yaml
- role: registry
  when: "'image_registries' in group_names"
```

Then add host to `[image_registries]` group in inventory.
