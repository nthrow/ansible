# wireguard_hub

Hub-and-spoke WireGuard server. Generates the server keypair on first
run, templates `/etc/wireguard/<iface>.conf`, enables IP forwarding,
and brings the interface up via Alpine's `wg-quick.<iface>` openrc
service.

## What it does

1. `apk add wireguard-tools wireguard-tools-wg-quick`.
2. Sets `net.ipv4.ip_forward=1` (and v6 forwarding if a v6 subnet is
   configured) via `sysctl_file: /etc/sysctl.d/wireguard.conf`.
3. Creates `/etc/wireguard` (mode 0700).
4. Generates the server private key with `wg genkey` (`creates:` makes
   it idempotent — never re-rolled).
5. Slurps the private + public keys, sets `wireguard_server_pubkey` as
   a fact.
6. Renders `/etc/wireguard/<iface>.conf` from `wg.conf.j2` (mode 0600,
   `no_log: true` because the file contains the private key).
7. Symlinks `/etc/init.d/wg-quick → /etc/init.d/wg-quick.<iface>`,
   enables it at `default` runlevel.
8. Prints the hub's public key + endpoint at the end of the play (so
   you can paste them into client configs).

## Variables

| Var | Default | Notes |
|-----|---------|-------|
| `wireguard_interface` | `wg0` | |
| `wireguard_port` | `51820` | UDP. |
| `wireguard_external_interface` | `eth0` | The WAN-side iface (used by firewall NAT). |
| `wireguard_subnet_v4` | `10.0.0.0/24` | Tunnel subnet. |
| `wireguard_server_address_v4` | `10.0.0.1/24` | Hub's tunnel IP. |
| `wireguard_subnet_v6` | `""` | Set non-empty to enable v6. |
| `wireguard_server_address_v6` | `""` | |
| `wireguard_privkey_path` | `/etc/wireguard/{{ iface }}.key` | |
| `wireguard_pubkey_path` | `/etc/wireguard/{{ iface }}.pub` | |
| `wireguard_peers` | `[]` | List of `{name, public_key, allowed_ips, [preshared_key, persistent_keepalive]}`. |

## Dependencies

- `firewall` role — opens UDP port + restricts ssh to wg0.
- `community.crypto` collection (for slurp/template handling, indirect).

## Onboarding a peer

1. On the peer:
   ```sh
   wg genkey | tee /tmp/priv | wg pubkey > /tmp/pub
   ```
2. Paste the pubkey into `wireguard_peers` in
   `inventory/group_vars/wireguard_servers.yml`:
   ```yaml
   wireguard_peers:
     - name: desktop1
       public_key: "<paste desktop1's wg pubkey>"
       allowed_ips: ["10.0.0.2/32"]
       persistent_keepalive: 25
   ```
3. Re-run the playbook. It hot-reloads via the `restart wg-quick`
   handler.
4. Configure the peer: hub pubkey (printed by the play), endpoint
   `<hub_public_ip>:51820`, AllowedIPs `10.0.0.0/24` (or `0.0.0.0/0`
   if you want the peer's full traffic to flow through the hub).

## Example

```yaml
# inventory/group_vars/wireguard_servers.yml
wireguard_enable_exit: true   # peers can exit via the hub's WAN
wireguard_peers:
  - { name: desktop1,    public_key: "...", allowed_ips: ["10.0.0.2/32"], persistent_keepalive: 25 }
  - { name: phone,  public_key: "...", allowed_ips: ["10.0.0.10/32"], persistent_keepalive: 25 }
```

## Troubleshooting

- **`wg show` shows no peer endpoint** — peer hasn't connected yet.
  Send any traffic from the peer to wake the tunnel. Confirm
  `persistent_keepalive` is set on NAT'd peers.
- **Peer A can't reach peer B (inter-VPN)** — the firewall's
  `firewall_forward_rules: [{ in: wg0, out: wg0 }]` is what enables
  this. Confirm `iptables -L FORWARD -nv` shows the rule.
- **Tunnel comes up but no internet via exit** — set
  `wireguard_enable_exit: true` and confirm
  `iptables -t nat -L POSTROUTING -nv` shows the MASQUERADE rule.
- **Server key got regenerated** — the role guards against this with
  `creates:` on the keygen task. If it happened anyway, every peer
  will need to be re-pointed at the new pubkey.
