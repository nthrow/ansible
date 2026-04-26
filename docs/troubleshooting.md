# Troubleshooting

Cross-cutting failure modes and their fixes. For role-specific issues,
see each `roles/<role>/README.md`.

## "First, gather facts"

Before debugging anything, get a baseline:

```sh
# Is the host reachable + python working?
ansible <host> -m ping

# Full fact dump (long but useful):
ansible <host> -m setup

# Specific var resolution:
ansible <host> -m debug -a "var=firewall_allow_tcp"
ansible <host> -m debug -a "var=hostvars[inventory_hostname]"

# Group membership:
ansible-inventory --host <host>

# Dry-run with diff:
ansible-playbook -i inventory/hosts.yml playbooks/<x>.yml -l <host> --check --diff
```

## Connection issues

### `Permission denied (publickey)`

The bootstrap.sh authorized_keys drop didn't happen, or you're using
the wrong key.

```sh
ssh -v root@<host>           # see which key it tried
ansible <host> -m ping -vvvv  # see ansible's connection attempt
```

Fixes:
- Re-paste your public key into `/root/.ssh/authorized_keys` via the
  console.
- Confirm `ansible_user: root` (defaults to that in `group_vars/all.yml`).
- Confirm `ansible_host` resolves: `getent hosts <ansible_host>`.

### `Connection refused`

sshd isn't running, or the firewall is dropping you.

If you can reach the console:

```sh
service sshd status
service sshd start
iptables -L INPUT -nv | head    # is 22 allowed at all?
```

If sshd is fine but iptables is blocking:

```sh
# Temporary recovery — this won't survive a reboot:
iptables -I INPUT -p tcp --dport 22 -j ACCEPT
```

Then re-apply `firewall` role with the right `firewall_allow_tcp`.

### `UNREACHABLE: timeout`

Network problem. Check:
- Wireguard: `wg show` on both ends.
- Routing: `ip route get <ansible_host>`.
- Firewall on intermediate hops.

## Idempotency surprises

### "Same play, different result on rerun"

Almost always one of:

- **A handler has side effects you didn't expect.** Check what fires
  with `ansible-playbook ... --start-at-task='...' --diff`.
- **`changed_when:` is too eager** on a `command:` task. Tighten it
  to a real condition.
- **A template's input vars depend on `ansible_facts`** that change
  between runs (e.g. `ansible_date_time`). Don't put time-varying
  values in templates.

### "Task is `changed` every run for no reason"

A `copy:` or `template:` task is producing slightly different content
each run. Common causes:

- Trailing whitespace in templates (Jinja's whitespace control:
  `{%-` and `-%}`).
- Dict ordering — Python dicts are ordered now, but Jinja's
  `to_nice_json` filter may sort keys differently across versions.
- Auto-derived facts (an interface's IP) that change between runs.
  Pin the var via `set_fact:` early in the play.

Diagnose with `--check --diff` — the diff shows the actual byte
difference.

## Firewall lockouts

### "Just rolled out a firewall change, can't ssh in"

If you can still reach the console:

```sh
# Restore last known good rules:
iptables-restore < /etc/iptables/rules-save.bak  # if you made a backup
# Or:
iptables -F                                       # nuke everything
iptables -P INPUT ACCEPT                          # default-allow temporarily
service sshd start
```

Then fix `firewall_allow_tcp` and re-apply.

If you're remote with no console: hope you have an out-of-band
access path (IPMI, KVM, cloud-provider serial console).

**Prevention**: the firewall role is one of the higher-risk roles.
Always preview with `--check --diff` before applying.

## ZFS issues

### "rpool not imported on boot"

If you see this on the console:

```
Importing rpool…
cannot open 'rpool': no such pool
```

Possible causes:
- The disk's path changed (e.g. NVMe re-enumerated). Run
  `zpool import` from the LiveUSB and `zpool export rpool`, then
  reboot — the cachefile gets refreshed.
- `cryptkey` feature missing from initramfs. From LiveUSB chroot:
  ```sh
  grep cryptkey /etc/mkinitfs/mkinitfs.conf  # should be there
  mkinitfs $(ls /lib/modules)
  ```

### "zpool import asks for a passphrase even though keyfile exists"

The `keylocation` got reverted. Reset:

```sh
zfs set keylocation=file:///crypto_keyfile.bin rpool
zfs load-key -L file:///crypto_keyfile.bin rpool
```

### "Datasets not mounted but pool imported"

`zfs-mount` service didn't run. `service zfs-mount start`. Check it's
in the `sysinit` runlevel: `rc-status sysinit | grep zfs`.

## docker / swarm issues

### "Container can't reach the network after firewall change"

Docker's iptables-restore got wiped. Fix:

```sh
service docker restart
```

The `docker_host` role's restart handler runs on daemon.json changes;
for firewall-only changes, restart is manual (or re-apply `docker.yml`
which restarts via notify).

### "Swarm init fails: 'this node is already part of a swarm'"

Leftover swarm membership. On the host:

```sh
docker swarm leave --force
```

Then re-run the playbook.

### "Workers won't join: 'context deadline exceeded'"

Either the manager is unreachable, or the firewall isn't open between
hosts.

```sh
# From a worker, test reachability:
nc -zv <manager-wg-ip> 2377

# On the manager, check swarm state:
docker info | grep -A3 Swarm
```

### "Swarm tokens stale after recreation"

If you re-init a swarm, old tokens are invalid. The role re-reads
tokens via `docker_swarm_info` on every run, so subsequent applies
will use fresh tokens. Rerun the playbook.

## Observability issues

### "Prometheus targets all show DOWN"

Most common: the wg interface is down on targets, or the obs host
isn't on the wireguard mesh.

```sh
# From the obs host:
nc -z <target-wg-ip> 9100
curl http://<target-wg-ip>:9100/metrics | head
```

### "Loki shows no logs from a host"

Check promtail on that host:

```sh
service promtail status
tail -f /var/log/messages | grep promtail
```

If promtail isn't running, `loki_push_url` was empty when the
monitoring_agent role applied. Check:

```sh
ansible <host> -m debug -a "var=loki_push_url"
```

If empty, the `observability` group is empty in inventory, OR the
obs host's `ansible_host` is missing.

### "Grafana dashboards have empty panels"

The datasource UID rewrite missed a placeholder format. Open the
dashboard JSON in `/var/lib/grafana/dashboards/`, look for any
literal `${DS_*}` strings, add a matching `replace` task in
`roles/observability/tasks/main.yml`.

### "grafana.com unreachable during apply"

The dashboard `get_url` task fails. Either:

- Run the playbook later when you have outbound HTTPS.
- Pre-stage the JSONs in `roles/observability/files/dashboards/`
  and add a `copy:` task that runs alongside the `get_url:`.

## Apk / package issues

### "package X not found"

Alpine repos don't have it. Check repo membership:

```sh
ansible <host> -a "cat /etc/apk/repositories"
```

`testing` may need to be enabled (it is by default in our `all.yml`).

Some packages exist only in Alpine edge, not stable — make sure
you're on edge if our repo template targets it.

### "service start fails: command not found" or "no init script"

Alpine recently split daemon binaries from their OpenRC init scripts
into separate `<pkg>-openrc` subpackages. So `apk add nginx` no
longer drops `/etc/init.d/nginx` — you also need `apk add nginx-openrc`.

Every role in this repo that runs a daemon installs both. If you
extend a role to add a new daemon (e.g. postgres), include both:

```yaml
community.general.apk:
  name:
    - postgresql
    - postgresql-openrc
```

To find the right subpkg name: `apk search -q <daemon>-openrc` on the
host. Most follow `<pkg>-openrc`, but a handful are exceptions
(`iptables-openrc` covers both v4 and v6 services).

### "package X not found in apk repos at all"

Some upstream tools aren't packaged for Alpine. We have two of these:
`nginx-prometheus-exporter` and `prometheus-varnish-exporter`. The
`cdn_edge`, `cdn_varnish`, and `cdn_origin_static` roles fetch
release tarballs from GitHub via `get_url:` and extract via
`command: tar -xzf` (busybox tar handles this fine; `unarchive:`
module's strict GNU-tar check rejects busybox).

If a release moves or a URL changes (e.g. nginx moved from
`nginxinc/nginx-prometheus-exporter` to
`nginx/nginx-prometheus-exporter`), update the URL in the role's
fetch task.

### "package X conflicts with Y"

Common with kernels: bare-metal `linux-lts` + cloud `linux-virt`.
Pick one. The `kernel_packages` var defaults to `[]`; only bare-metal
groups should set it.

### "apk update is slow"

Default Alpine CDN can be flaky from some networks. Override
`apk_repositories` in `group_vars/all.yml` to use a closer mirror.

## Wireguard issues

### "wg show: no peer endpoints"

Peers haven't sent traffic. Send any packet from a peer to wake it.
Check `persistent_keepalive` is set on NAT'd peers (default is off).

### "Tunnel up but inter-peer traffic doesn't flow"

The hub must FORWARD wg0 → wg0. Check
`firewall_forward_rules: [{ in: wg0, out: wg0 }]` in
`group_vars/wireguard_servers.yml`. Verify with:

```sh
iptables -L FORWARD -nv
```

### "Peer can't get internet via the hub"

Need MASQUERADE. Set `wireguard_enable_exit: true` and re-apply.
Verify: `iptables -t nat -L POSTROUTING -nv`.

## Secure Boot issues

### "Verification failed: Security Violation" at boot

Either the bootloader or the kernel isn't signed with a cert that's
in the firmware's db.

From the LiveUSB recovery shell:

```sh
sbverify --cert /mnt/boot/secureboot/sb.crt /mnt/efi/EFI/boot/bootx64.efi
sbverify --cert /mnt/boot/secureboot/sb.crt /mnt/boot/vmlinuz-lts
```

If either says "no signature found," the secureboot role didn't run
its hook. Re-apply with `apk fix kernel-hooks`.

### "Want to re-enroll certs in firmware"

`/efi/sb.cer` is the file. Boot to firmware, navigate to Secure Boot
→ Custom mode (Lenovo/Dell vary). Import as PK, KEK, db. Save, exit.

## Bootstrap.sh issues

### "ZFS module not loadable from LiveUSB"

You booted the regular Alpine ISO instead of the *Extended* one. Only
extended ships ZFS. Boot the right one.

### "sfdisk fails: Device or resource busy"

A previous partition is still in use (mounted, swap on, LUKS open).
Reboot the LiveUSB to clear state.

### "luksFormat fails: incompatible kernel"

Your LiveUSB's kernel is missing dm-crypt support — extremely rare on
official Alpine ISOs. Pick a different ISO release.

## Recovery escalation path

When in doubt:

1. **Read the role's README.md.** Often the answer is there.
2. **Check `/var/log/messages`** on the host for the actual error.
3. **Re-run the play with `-vvv`** to see ansible's reasoning.
4. **From the LiveUSB chroot** for boot/disk issues; see
   [bootstrap.md](bootstrap.md) for the recovery flow.
5. **Out-of-band access** (IPMI, console, cloud-provider serial) for
   network issues.
6. **Restore from backup** if you have ZFS snapshots.
