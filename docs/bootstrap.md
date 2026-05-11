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

If a bootstrap.sh-installed host won't boot, the right recovery path
depends on what's broken.

### Fast path: ESP-only damage (no ZFS keys needed)

If only the EFI bootloader or other ESP-side files are damaged
(`/efi/EFI/boot/bootx64.efi` missing, renamed, or replaced with an
unsigned binary), the ESP is plain FAT32 — you can fix it from any
LiveUSB without unlocking LUKS or ZFS:

```sh
mount /dev/nvme0n1p1 /mnt
ls /mnt/EFI/boot/
# fix what's broken on the ESP — e.g. rename a .bak back into place,
# copy in a known-good signed bootx64.efi from elsewhere, etc.
umount /mnt
poweroff
```

Common failures that fit this path:
- The bootloader file got renamed or deleted
- A previous fix left an `.efi.bak` in place
- A failed grub re-install left the wrong binary at the fallback path

Try this first if the firmware error is "no bootable device" or
"image not found / Access Denied" — it's the cheapest recovery.

### Full chroot recovery (boot/initramfs/kernel/grub damage)

If the damage is inside `/boot` (kernel, initramfs, GRUB config) or
the rootfs, you need to enter the encrypted system. From the Alpine
**extended** LiveUSB:

```sh
# 1. install the tools we need. The extended ISO has zfs/cryptsetup
#    in its repos but doesn't pre-install the userspace.
apk add zfs cryptsetup
modprobe zfs

# 2. import the pool, then load the encryption key separately.
#    zpool import alone does NOT prompt for a passphrase; ZFS
#    native encryption is loaded per-dataset via zfs load-key.
zpool import -R /mnt rpool
zfs load-key -L prompt rpool          # type the 25-word xkcdpass
mount -t zfs rpool/ROOT/alpine /mnt   # mountpoint=legacy on root

# 3. unlock /boot using the keyfile from the now-mounted rootfs
cryptsetup luksOpen /dev/nvme0n1p2 boot \
    -d /mnt/etc/fstab.boot_keyfile
mount -t ext4 /dev/mapper/boot /mnt/boot   # explicit -t ext4: the
                                            # busybox mount on the
                                            # extended LiveUSB doesn't
                                            # autodetect this layout

mount /dev/nvme0n1p1 /mnt/efi

# 4. bind kernel filesystems and chroot
mount -t proc /proc /mnt/proc
mount --rbind /dev   /mnt/dev
mount --rbind /sys   /mnt/sys
chroot /mnt
```

You're now in the broken system. Common fixes:

- Rebuild initramfs: `mkinitfs $(ls /lib/modules)`
- Re-install grub: `grub-install --target=x86_64-efi --efi-directory=/efi`
- Re-sign bootloader: `sbsign --key /boot/secureboot/sb.key
  --cert /boot/secureboot/sb.crt /efi/EFI/boot/bootx64.efi`

Cleanup and reboot:

```sh
exit                       # leave chroot
# busybox umount on the LiveUSB lacks -R; unwind manually,
# using -l (lazy) on rbind mounts to handle nested submounts:
umount -l /mnt/sys
umount -l /mnt/dev
umount /mnt/proc
umount /mnt/efi
umount /mnt/boot
umount /mnt
zpool export rpool
poweroff
```

In a pinch, `poweroff` alone is sufficient — the kernel force-
unmounts during shutdown. The explicit `zpool export rpool` is for
clean ZFS labels; without it, the next normal boot will need `-f`
on the import (the bootstrap-installed initramfs already passes
`-f` so this is mostly cosmetic, but it matters in production
when juggling pools across machines).

### Recovery under Secure Boot enforcing

Stock Alpine LiveUSB binaries are **unsigned** — the extended ISO's
`/efi/boot/bootx64.efi` carries no signature table at all. If you've
enrolled a self-signed CA into firmware DB and Secure Boot is
enforcing, OVMF (or your bare-metal UEFI) will refuse to launch the
LiveUSB with `Access Denied` / `Image not authorized`.

Workaround for each recovery, until a signed-recovery-image story
exists for this stack:

1. Boot the broken host with the LiveUSB inserted.
2. Enter firmware setup (Esc / F2 / Del at TianoCore or POST splash).
3. **Device Manager → Secure Boot Configuration**, toggle
   **"Attempt Secure Boot"** off. Save & reset.
4. The firmware now boots the LiveUSB. Run the recovery flow above.
5. After `poweroff`, re-enter firmware and **re-enable** Attempt
   Secure Boot before booting into the (now-fixed) installed system
   — otherwise SB stays off until you remember to flip it back.

Future improvement: producing a signed-with-the-install-CA recovery
ISO at install time would skip steps 2-3 and 5. Not implemented;
tracked as a TODO.

### Migrating an older install from openssl-derived to xkcdpass keys

Earlier versions of bootstrap.sh generated the ZFS keyfile via
`openssl rand ...` (binary-shaped) before xkcdpass was confirmed
available in Alpine's `community` repo. Such installs have a ZFS
"passphrase" that's effectively impossible to type at a recovery
prompt — leaving them recoverable only if the keyfile bytes are
saved out-of-band somewhere accessible from a LiveUSB.

To rotate to a typeable xkcdpass passphrase **without re-encrypting
the data** (uses ZFS native key rotation, which only re-wraps the
master key — fast even on multi-TB pools):

```sh
# back up the old keyfile so we can roll back if anything fails
cp -p /etc/fstab.zfs_keyfile /etc/fstab.zfs_keyfile.openssl-bak

# generate a typeable replacement (xkcdpass lives in edge/community)
apk add xkcdpass
umask 077
xkcdpass -n 25 > /etc/fstab.zfs_keyfile.new
chmod 0400 /etc/fstab.zfs_keyfile.new

# SAVE THE NEW PASSPHRASE OUT-OF-BAND BEFORE PROCEEDING
cat /etc/fstab.zfs_keyfile.new   # copy these 25 words to your
                                  # password manager or paper backup
                                  # NOW

# rotate the wrapping key. This re-derives + re-wraps in place;
# the master key (and therefore your data) is untouched.
zfs change-key -o keylocation=file:///etc/fstab.zfs_keyfile.new rpool
zfs get keystatus rpool   # should still read "available"

# consolidate to the canonical /crypto_keyfile.bin path that
# initramfs's cryptkey feature expects
mv /etc/fstab.zfs_keyfile.new /etc/fstab.zfs_keyfile
zfs set keylocation=file:///crypto_keyfile.bin rpool

# rebuild initramfs to embed the new keyfile content
mkinitfs $(ls /lib/modules)

# verify the rebuilt initramfs has the new keyfile
diff <(sha256sum /etc/fstab.zfs_keyfile | cut -d' ' -f1) \
     <(zcat /boot/initramfs-lts | cpio -i --to-stdout etc/fstab.zfs_keyfile 2>/dev/null | sha256sum | cut -d' ' -f1)
# (no output = match)

# reboot; if auto-unlock works, the migration is done. Then:
# rm /etc/fstab.zfs_keyfile.openssl-bak
```

If the reboot fails to auto-unlock, you can recover via LiveUSB
with either the **new** xkcdpass passphrase (via
`zfs load-key -L prompt rpool` and the words you saved) or by
restoring the `.openssl-bak` file and rebuilding initramfs to
re-embed the old key.

## Recovery: lost the boot LUKS passphrase

You used `luksAddKey` with the keyfile *and* a passphrase. Either
key works to unlock. So if you forgot the passphrase:

1. From the LiveUSB, open with the keyfile:
   `cryptsetup luksOpen /dev/nvme0n1p2 boot -d /mnt/etc/fstab.boot_keyfile`
2. Add a new passphrase: `cryptsetup luksAddKey /dev/nvme0n1p2`
3. (Optional) Remove the old slot if you remember its keyslot index.

## Recovery: ZFS won't import or you lost the ZFS key

If the keyfile is intact and accessible:
```sh
zpool import rpool
zfs load-key -L file:///etc/fstab.zfs_keyfile rpool
```

If the keyfile is gone (deleted, or living on an encrypted dataset
you can't unlock) **and** you have no out-of-band copy of its
contents (the xkcdpass words or the openssl-derived bytes), **the
pool is unrecoverable.**

Two mitigations should be in place before this becomes a problem:

1. **Save the xkcdpass words out-of-band at install time.** Password
   manager, paper backup, or both. The 25-word xkcdpass keeps its
   ~323 bits of entropy strong as long as the words stay private;
   the threat model isn't passphrase guessing, it's losing the
   passphrase entirely.
2. **GPG-encrypted backup on ESP** (originally in `alpine.sh` from
   wejn.org; not currently implemented in this bootstrap). Encrypts
   the keyfiles to your gpg public key and drops the `.asc` files in
   `/efi`, so a different machine with your gpg secret key can
   recover. Tracked as a TODO; the alpine.sh approach is straight-
   forward to port if you want it.

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
