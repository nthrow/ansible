# networking_desktop

NetworkManager + Bluetooth + WireGuard userland for desktop hosts.

## What it does

1. `apk add` networkmanager + plugins (cli, wifi, wwan, bluetooth) +
   `bluedevil` + `iw` + `wpa_supplicant` + `wireguard-tools`.
2. Enables `networkmanager`, `bluetooth`, `chronyd` at the `default`
   runlevel.

## Variables

None — this is a fixed package set.

## Dependencies

The desktop is also a wireguard *peer* (not a hub). The wireguard
client setup (creating wg0 with a peer config) is done manually
post-install — paste the conf into `/etc/wireguard/wg0.conf` and
`wg-quick up wg0`. There's no client-side counterpart to the
`wireguard_hub` role yet.

## Troubleshooting

- **Wifi doesn't show networks** — `nmcli radio wifi on`. If the
  hardware wasn't autodetected, check `lspci -k | grep -A3 Network`
  for the driver.
- **Bluetooth not in KDE's tray** — `rc-service bluetooth start;
  bluetoothctl power on`.
- **NetworkManager and an `/etc/network/interfaces` static config
  fight** — pick one. NetworkManager honors interfaces marked
  `unmanaged` only.
