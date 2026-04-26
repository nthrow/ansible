# Bootstrap

Walkthrough of `bootstrap.sh` — the LiveUSB-side script that turns a
bare-metal Alpine box into something Ansible can SSH into.

## When to use it

- **Bare-metal desktops.** Always.
- **Bare-metal servers** (theoretical CDN nodes on owned hardware).
- **VMs** where you want the same FDE+ZFS layout as bare metal.

When NOT to use it:

- **Cloud VPS hosts** (wireguard hub on a $5 VPS, etc.). The provider's
  Alpine image already has the OS installed; just SSH in and run
  Ansible.

## Prerequisites

1. Alpine **Extended** ISO (the regular `alpine-virt`/`alpine-standard`
   doesn't ship ZFS).
2. A target NVMe disk. The script auto-detects single-NVMe systems and
   prompts when there are multiple.
3. The public SSH key Ansible will use, in either:
   - environment variable: `ROOT_AUTHORIZED_KEYS=$(cat ~/.ssh/id_ed25519.pub)`
   - or a file at `./root_authorized_keys` in the same directory as
     `bootstrap.sh`.

## Phases

### 1. Configuration + sanity

Reads env vars (HOSTNAME, TIMEZONE, KEYMAP, ZPOOL, EFI_MB, BOOT_MB,
SWAP_MB, WIPE_PASSES, ROOT_AUTHORIZED_KEYS). Confirms we're root,
on Alpine, and that the ZFS module is loadable.

Auto-computes `SWAP_MB = round(physical_RAM * 1.5)` if not set —
rounding MemTotal up to a 4 GiB boundary to estimate physical RAM.

### 2. Disk pick + wipe confirm

Lists NVMe disks, prompts (or auto-picks single). Shows the planned
layout, asks `y/N` to proceed.

```
${DISK}p1   EFI    512M     (vfat)
${DISK}p2   /boot  1G       (LUKS1 → ext4)
${DISK}p3   swap   <auto>   (LUKS2 → swap)
${DISK}p4   ZFS    rest     (encrypted pool)
```

### 3. Random-noise wipe

`dd if=/dev/urandom of=$DISK bs=8M`, `WIPE_PASSES` times (default 1).
Then zero the first 8MB and the last 8MB (GPT secondary). On a 4TB
NVMe at ~1 GB/s, this is ~70 minutes per pass.

### 4. setup-alpine (host config only)

`setup-alpine -e -f /root/answers` — runs Alpine's installer in
non-interactive mode. The answers file uses
`DISKOPTS="-z --please-dont-do-anything"` so the disk-setup phase
intentionally fails fast (we'll do disks ourselves).

What setup-alpine *does* configure: keymap, hostname, network,
timezone, sshd, ntp, apk repos.

### 5. Partition

`sfdisk` with GPT label, four partitions matching the layout above.
GPT type GUIDs:
- p1: `C12A...` (EFI System)
- p2/p3: `8DA6...` (Linux generic — for LUKS)
- p4: `6A89...` (Solaris/illumos — for ZFS)

### 6. LUKS swap

```sh
echo -n "$(xkcdpass -n 25)" > /etc/fstab.swap_keyfile
chmod 0400 /etc/fstab.swap_keyfile
cryptsetup luksFormat --type luks2 -q -d /etc/fstab.swap_keyfile $SWAP_PART
cryptsetup luksOpen   -d /etc/fstab.swap_keyfile $SWAP_PART swap
mkswap -L swap /dev/mapper/swap
```

The swap keyfile is generated as a 25-word passphrase; nobody types
this, the keyfile lives on the encrypted ZFS root.

### 7. ZFS pool

```sh
echo -n "$(xkcdpass -n 25)" > /etc/fstab.zfs_keyfile
chmod 0400 /etc/fstab.zfs_keyfile
zpool create -f \
    -o ashift=12 \
    -O acltype=posixacl -O canmount=off -O compression=lz4 \
    -O dnodesize=auto -O normalization=formD -O relatime=on -O xattr=sa \
    -O encryption=aes-256-gcm \
    -O keyformat=passphrase -O keylocation=file:///etc/fstab.zfs_keyfile \
    -O mountpoint=/ -R /mnt \
    $ZPOOL $ZFS_PART
zfs create -o mountpoint=none    -o canmount=off rpool/ROOT
zfs create -o mountpoint=legacy  -o canmount=off rpool/ROOT/alpine
zfs create -o mountpoint=legacy                  rpool/ROOT/home
```

The pool's keylocation initially points at the LiveUSB's keyfile so
the install can proceed. We'll re-point it later (phase 11).

### 8. ESP

vfat32, label `efi`. Mounted at `/mnt/efi`.

### 9. LUKS /boot

LUKS1 (not LUKS2 — GRUB cryptodisk doesn't read LUKS2's argon2id
PBKDF by default), `ext4` filesystem.

After the keyfile-based format, `cryptsetup luksAddKey` prompts
**interactively** for a passphrase. **This is what you'll type at
GRUB** every boot. Pick something memorable but strong.

### 10. setup-disk

`setup-disk -k lts /mnt` runs Alpine's disk-install routine with our
ZFS root mounted. It:

- Copies the LiveUSB's selected packages into `/mnt`
- Installs `linux-lts`
- Copies `/etc/apk/repositories`, `/etc/network/interfaces`,
  `/etc/hostname`, etc. from / to /mnt
- Sets up an extlinux/grub bootloader (we'll overwrite it)

After this point, the LiveUSB's `/etc` is no longer mirrored to
`/mnt`. Any further config goes directly to `/mnt/etc`.

### 11. Carry keyfiles + fix ZFS keylocation

Copies the three keyfiles into `/mnt/etc/`. Symlinks
`/mnt/crypto_keyfile.bin → /etc/fstab.zfs_keyfile` and updates the
pool's `keylocation=file:///crypto_keyfile.bin`. The mkinitfs
`cryptkey` feature picks up `/crypto_keyfile.bin` so the initramfs
can unlock ZFS without prompting.

### 12. fstab + dmcrypt + local.d

Templated fstab: ZFS root, ZFS home, ESP UUID, `/dev/mapper/boot`
(noauto), tmpfs.

```
/etc/conf.d/dmcrypt:
  target='swap' source='${PART}3' key='/etc/fstab.swap_keyfile'
  target='boot' source='${PART}2' key='/etc/fstab.boot_keyfile'

/etc/local.d/{boot,swap}.{start,stop}:
  mount/umount /boot, swapon/swapoff /dev/mapper/swap
```

Why `local.d` for /boot+swap? Their keyfiles live on the ZFS root,
which is mounted at `sysinit`. The dmcrypt service is at `boot`
runlevel. fstab tries to mount /boot at `boot` runlevel — there's a
race. `local.d` runs at `default` (late), so by then everything's
ready. See [roles/dmcrypt/README.md](../roles/dmcrypt/README.md).

### 13. mkinitfs features

```
features="ata base ide scsi usb virtio nvme cryptsetup cryptkey ext4 zfs keymap"
```

`cryptkey` is the special one — it copies `/crypto_keyfile.bin` into
the initramfs. `nvme` is needed for our disk. `zfs` brings the ZFS
module + tools.

### 14. Minimal GRUB

```sh
chroot /mnt apk add grub grub-efi efibootmgr kernel-hooks sbsigntool openssl python3
```

Note: `python3` is here so Ansible can SSH in and run modules later.

Then:
- Render `/etc/default/grub` with `GRUB_ENABLE_CRYPTODISK=y` and the
  `GRUB_DEVICE=ZFS=...` workaround.
- `grub-mkconfig -o /boot/grub/grub.cfg`
- `grub-install --target=x86_64-efi`
- Patch `SecureBoot` → `SecureB00t` in the binary.
- Move grubx64.efi to `/efi/EFI/boot/bootx64.efi` (firmware fallback
  path, no NVRAM dependency).
- `mkinitfs <kver>` to rebuild with the new feature set.

### 15. Services + ssh access

```sh
chroot /mnt rc-update add dmcrypt        boot
chroot /mnt rc-update add local          default
chroot /mnt rc-update add networking     boot
chroot /mnt rc-update add sshd           default
chroot /mnt rc-update add chronyd        default
```

Drop the public key:

```sh
mkdir -m 0700 /mnt/root/.ssh
echo "$ROOT_AUTHORIZED_KEYS" > /mnt/root/.ssh/authorized_keys
chmod 0600 /mnt/root/.ssh/authorized_keys
```

Configure sshd: `PermitRootLogin prohibit-password`,
`PubkeyAuthentication yes`.

### 16. Cleanup + reboot

Unmount everything, `zpool export`, close LUKS containers. Print the
post-install instructions:

```
ansible-playbook -i inventory/hosts.yml playbooks/<x>.yml -l <hostname>
```

## Recovery flow

If a bootstrap.sh-installed host won't boot:

### From the Alpine extended LiveUSB

```sh
modprobe zfs
zpool import -R /mnt rpool          # prompts for ZFS passphrase
mount -t zfs rpool/ROOT/alpine /mnt
cryptsetup luksOpen /dev/nvme0n1p2 boot \
    -d /mnt/etc/fstab.boot_keyfile  # use saved keyfile
mount /dev/mapper/boot /mnt/boot
mount /dev/nvme0n1p1   /mnt/efi
mount -t proc /proc /mnt/proc
mount --rbind /dev  /mnt/dev
mount --rbind /sys  /mnt/sys
chroot /mnt
```

You're now in the broken system. Common fixes:

- Rebuild initramfs: `mkinitfs $(ls /lib/modules)`
- Re-install grub: `grub-install --target=x86_64-efi --efi-directory=/efi`
- Re-sign bootloader: `sbsign --key /boot/secureboot/sb.key
  --cert /boot/secureboot/sb.crt /efi/EFI/boot/bootx64.efi`

## Recovery: lost the boot LUKS passphrase

You used `luksAddKey` with the keyfile *and* a passphrase. Either
key works to unlock. So if you forgot the passphrase:

1. From the LiveUSB, open with the keyfile:
   `cryptsetup luksOpen /dev/nvme0n1p2 boot -d /mnt/etc/fstab.boot_keyfile`
2. Add a new passphrase: `cryptsetup luksAddKey /dev/nvme0n1p2`
3. (Optional) Remove the old slot if you remember its keyslot index.

## Recovery: ZFS won't import

If the keyfile is intact:
```sh
zpool import rpool
zfs load-key -L file:///etc/fstab.zfs_keyfile rpool
```

If the keyfile is gone (you deleted /etc/fstab.zfs_keyfile somehow),
the pool is unrecoverable without a backup. **This is why the
bootstrap.sh's optional GPG-encrypted backup step (in the original
alpine.sh from wejn.org) is worth setting up** — encrypts the
keyfiles to your gpg key and drops the .asc files on the ESP for
recovery from a different machine.

## Customization points

The script's top has all the env-overridable knobs. Common ones:

| Var | Default | Purpose |
|-----|---------|---------|
| `HOSTNAME` | `desktop1` | |
| `TIMEZONE` | `America/New_York` | |
| `EFI_MB` | `512` | Big enough for fwupd capsules. |
| `BOOT_MB` | `1024` | Few kernels' worth. |
| `SWAP_MB` | (auto) | Override for non-standard memory configs. |
| `WIPE_PASSES` | `1` | Bump for paranoia; each pass is slow. |
| `ZPOOL` | `rpool` | |

## What the script *doesn't* do

- **No HiDPI / accessibility tweaks.** Console works, KDE handles its
  own DPI later.
- **No custom kernel tuning.** Alpine's defaults are fine.
- **No swap encryption with a per-boot random key.** We use a
  persistent keyfile so you don't have to re-create swap structure
  every boot. Swap contents are still encrypted; only the key is
  static-on-disk (and that disk is the ZFS root, also encrypted).
- **No initramfs SSH for remote unlock.** If you want headless boot
  unlock, layer dropbear-initramfs on top.
