# sshd

OpenSSH daemon with sane defaults: key-only auth, no passwords, no
PAM, no X11 forwarding, sftp subsystem on, keepalives configured.

## What it does

1. `apk add openssh`.
2. Templates `/etc/ssh/sshd_config` (`validate: sshd -t -f %s` runs
   before the file is moved into place — if the config is bad, the
   role fails and the old config stays).
3. Enables and starts the `sshd` service. A handler restarts it on
   any config change.

## Variables

| Var | Default | Notes |
|-----|---------|-------|
| `sshd_port` | `22` | |
| `sshd_permit_root` | `prohibit-password` | Set to `no` once you have a non-root admin user. |
| `sshd_password_auth` | `false` | Keep false. |

## Dependencies

The bootstrap.sh installer drops your `ROOT_AUTHORIZED_KEYS` into
`/root/.ssh/authorized_keys` so this role is reachable on first run.
For cloud VPS hosts, ensure the same is done at image-bake time (most
providers honor a public key uploaded to the panel).

## Example

```yaml
# group_vars/exposed_servers.yml
sshd_port: 2222
sshd_permit_root: "no"
```

## Troubleshooting

- **Locked yourself out** — the validate step prevents bad configs
  from being applied, but firewall changes happen separately. Always
  ensure 22/tcp (or your alt port) is allowed from where you connect
  *before* changing it.
- **Connection refused after a play** — if `sshd_permit_root: "no"`
  was set without a non-root admin user, root key auth is disabled.
  Recover via the host's console.
- **`sshd -t` fails on validate** — check the diff against your last
  known-good `sshd_config` template. Most often this is an unknown
  directive in a too-old/too-new sshd build.
