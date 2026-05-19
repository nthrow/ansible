#!/bin/sh
# Alpine LiveUSB-side bootstrap.
# Does the destructive disk work that doesn't fit Ansible:
#   - random-noise wipe, partition, LUKS, ZFS pool, base alpine install
#   - just enough config to bring sshd up so Ansible can take over
# Run from the Alpine *Extended* iso. busybox ash compatible.
#
# After this completes and the host reboots:
#   ansible-playbook -i inventory/hosts.yml playbooks/desktop.yml -l <host>

set -eu

# ============================================================
# Configuration (override via env)
# ============================================================
HOSTNAME=${HOSTNAME:-desktop1}
TIMEZONE=${TIMEZONE:-UTC}
KEYMAP=${KEYMAP:-us us}
DOMAIN=${DOMAIN:-local}
DNS_SERVERS=${DNS_SERVERS:-1.1.1.1 9.9.9.9}
ZPOOL=${ZPOOL:-rpool}
EFI_MB=${EFI_MB:-512}
BOOT_MB=${BOOT_MB:-1024}
SWAP_MB=${SWAP_MB:-}
WIPE_PASSES=${WIPE_PASSES:-1}
# Public key for ansible to log in as root after reboot.
# Either set ROOT_AUTHORIZED_KEYS or place a file at ./root_authorized_keys.
ROOT_AUTHORIZED_KEYS=${ROOT_AUTHORIZED_KEYS:-}

# ============================================================
say()  { printf '\n=== %s ===\n' "$*"; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }
ask()  { printf '%s ' "$1"; read -r REPLY; [ "$REPLY" = y ] || [ "$REPLY" = Y ]; }

[ "$(id -u)" = 0 ] || die "must run as root"
[ -f /etc/alpine-release ] || die "not Alpine"
modprobe zfs 2>/dev/null || die "boot the *extended* iso (zfs module needed)"

apk update >/dev/null
apk add --quiet sfdisk e2fsprogs e2fsprogs-extra dosfstools cryptsetup \
	openssl zfs

# xkcdpass lives in edge/community; the LiveUSB's repos may still be
# v3.x at this point (the edge-flip happens later, after setup-alpine).
# `-X` adds a repo for this single invocation without modifying
# /etc/apk/repositories — keeps the LiveUSB clean for setup-alpine.
# Edge xkcdpass tracks python3~3.14, so we also need edge/main to pull
# a compatible interpreter alongside (stable's python3 is 3.12).
apk add --quiet --no-cache \
	-X https://dl-cdn.alpinelinux.org/alpine/edge/main \
	-X https://dl-cdn.alpinelinux.org/alpine/edge/community \
	xkcdpass

# ---- pick disk ---------------------------------------------
# Match NVMe, virtio, SATA/SCSI, MMC, Xen — anything that's a "real"
# block device the kernel exposes as a top-level disk.
disks=$(ls /sys/block 2>/dev/null | grep -E '^(nvme[0-9]+n[0-9]+|[svx]d[a-z]+|mmcblk[0-9]+)$' || true)
[ -n "$disks" ] || die "no installable disks found"
say "Installable disks present"
for d in $disks; do
	gib=$(( $(cat /sys/block/$d/size) * 512 / 1024 / 1024 / 1024 ))
	echo "  /dev/$d  ${gib}G"
done
if [ "$(echo "$disks" | wc -l)" -gt 1 ]; then
	printf "Target disk (e.g. nvme0n1)? "; read -r CHOICE
	DISK=/dev/$(basename "$CHOICE")
else
	DISK=/dev/$(echo "$disks" | head -n1)
fi
[ -b "$DISK" ] || die "not a block device: $DISK"
case "$DISK" in
	*nvme*|*mmcblk*|*loop*) PART="${DISK}p" ;;
	*)                       PART="$DISK"   ;;
esac

# ---- swap size ---------------------------------------------
if [ -z "$SWAP_MB" ]; then
	mem_kb=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)
	mem_gib=$(( (mem_kb + 1024*1024 - 1) / 1024 / 1024 ))
	phys_gib=$(( (mem_gib + 3) / 4 * 4 ))
	SWAP_MB=$(( phys_gib * 1024 * 3 / 2 ))
fi

# ---- root authorized_keys ----------------------------------
if [ -z "$ROOT_AUTHORIZED_KEYS" ] && [ -f ./root_authorized_keys ]; then
	ROOT_AUTHORIZED_KEYS=$(cat ./root_authorized_keys)
fi
[ -n "$ROOT_AUTHORIZED_KEYS" ] || \
	die "set ROOT_AUTHORIZED_KEYS or provide ./root_authorized_keys (Ansible needs it)"

# ---- confirm + wipe ----------------------------------------
say "About to DESTROY all data on $DISK"
cat <<EOF
  ${PART}1   EFI    ${EFI_MB}M   (vfat)
  ${PART}2   /boot  ${BOOT_MB}M  (LUKS1 → ext4)
  ${PART}3   swap   ${SWAP_MB}M  (LUKS2 → swap)
  ${PART}4   ZFS    rest         (encrypted pool: $ZPOOL)
EOF
ask "Proceed? [y/N]" || die "aborted"

say "Wiping $DISK with random data ($WIPE_PASSES pass)"
i=1
while [ "$i" -le "$WIPE_PASSES" ]; do
	echo "  pass $i/$WIPE_PASSES"
	dd if=/dev/urandom of="$DISK" bs=8M status=progress conv=fdatasync 2>&1 || true
	i=$(( i + 1 ))
done
dd if=/dev/zero of="$DISK" bs=1M count=8 conv=notrunc 2>/dev/null
end_mib=$(( $(blockdev --getsize64 "$DISK") / 1024 / 1024 ))
dd if=/dev/zero of="$DISK" bs=1M seek=$(( end_mib - 8 )) count=8 conv=notrunc 2>/dev/null
sync

# ---- setup-alpine (host config; disk step is a no-op stub) -
cat > /root/answers <<EOF
KEYMAPOPTS="$KEYMAP"
HOSTNAMEOPTS="$HOSTNAME"
DEVDOPTS=mdev
INTERFACESOPTS="auto lo
iface lo inet loopback
"
DNSOPTS="-d $DOMAIN $DNS_SERVERS"
TIMEZONEOPTS="$TIMEZONE"
PROXYOPTS=none
APKREPOSOPTS="-1 -c"
SSHDOPTS="-c openssh"
NTPOPTS="-c chrony"
DISKOPTS="-z --please-dont-do-anything"
EOF
setup-alpine -e -f /root/answers || true

# Switch to edge + enable testing.
sed -i 's,/v[0-9.]*/,/edge/,g' /etc/apk/repositories
grep -q '/edge/testing' /etc/apk/repositories || \
	sed -n 's,\(.*\)/edge/main,\1/edge/testing,p' /etc/apk/repositories \
		>> /etc/apk/repositories
apk update

# ---- partition ---------------------------------------------
say "Partitioning $DISK"
sfdisk --quiet --label gpt "$DISK" <<EOF
${PART}1: start=1MiB,size=${EFI_MB}MiB,bootable,type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B
${PART}2: size=${BOOT_MB}MiB,type=8DA63339-0007-60C0-C436-083AC8230908
${PART}3: size=${SWAP_MB}MiB,type=8DA63339-0007-60C0-C436-083AC8230908
${PART}4: type=6A898CC3-1DD2-11B2-99A6-080020736631
EOF
# Re-read the partition table AND make sure device nodes exist.
# busybox mdev (alpine extended live) needs `mdev -s` to scan; full
# udev/eudev settles on its own, but `udevadm settle` is harmless if
# both are present.
partprobe   "$DISK" 2>/dev/null || true
blockdev --rereadpt "$DISK" 2>/dev/null || true
command -v mdev    >/dev/null 2>&1 && mdev -s
command -v udevadm >/dev/null 2>&1 && udevadm settle --timeout=5
sleep 2
[ -b "${PART}1" ] || die "partitions did not appear"

# ---- LUKS swap ---------------------------------------------
say "Encrypting swap"
echo -n "$(xkcdpass -n 25)" > /etc/fstab.swap_keyfile
chmod 0400 /etc/fstab.swap_keyfile
cryptsetup luksFormat --type luks2 -q -d /etc/fstab.swap_keyfile "${PART}3"
cryptsetup luksOpen   -d /etc/fstab.swap_keyfile "${PART}3" swap
mkswap -L swap /dev/mapper/swap

# ---- ZFS pool ----------------------------------------------
say "Creating ZFS pool $ZPOOL"
echo -n "$(xkcdpass -n 25)" > /etc/fstab.zfs_keyfile
chmod 0400 /etc/fstab.zfs_keyfile
zpool create -f \
	-o ashift=12 \
	-O acltype=posixacl -O canmount=off -O compression=lz4 \
	-O dnodesize=auto -O normalization=formD -O relatime=on -O xattr=sa \
	-O encryption=aes-256-gcm \
	-O keyformat=passphrase -O keylocation=file:///etc/fstab.zfs_keyfile \
	-O mountpoint=/ -R /mnt \
	"$ZPOOL" "${PART}4"
zfs create -o mountpoint=none    -o canmount=off "$ZPOOL/ROOT"
zfs create -o mountpoint=legacy  -o canmount=off "$ZPOOL/ROOT/alpine"
zfs create -o mountpoint=legacy                  "$ZPOOL/ROOT/home"
mount -t zfs "$ZPOOL/ROOT/alpine" /mnt
mkdir /mnt/home
mount -t zfs "$ZPOOL/ROOT/home" /mnt/home
rc-update add zfs-import sysinit
rc-update add zfs-mount  sysinit

# ---- ESP + LUKS /boot --------------------------------------
mkfs.vfat -F32 -n efi "${PART}1"
mkdir /mnt/efi
mount -t vfat "${PART}1" /mnt/efi

say "Encrypting /boot — set the GRUB unlock passphrase next"
echo -n "$(xkcdpass -n 25)" > /etc/fstab.boot_keyfile
chmod 0400 /etc/fstab.boot_keyfile
cryptsetup luksFormat --type luks1 -q -d /etc/fstab.boot_keyfile "${PART}2"
cryptsetup luksAddKey -d /etc/fstab.boot_keyfile "${PART}2"
cryptsetup luksOpen   -d /etc/fstab.boot_keyfile "${PART}2" boot
mkfs.ext4 -L boot /dev/mapper/boot
mkdir /mnt/boot
mount -t ext4 /dev/mapper/boot /mnt/boot

# ---- base install ------------------------------------------
say "Installing base system to /mnt"
setup-disk -k lts /mnt
# Past this point, /etc on LiveUSB is no longer auto-mirrored to /mnt.

# carry keyfiles
cp -p /etc/fstab.swap_keyfile /mnt/etc/
cp -p /etc/fstab.boot_keyfile /mnt/etc/
cp -p /etc/fstab.zfs_keyfile  /mnt/etc/
chmod 0400 /mnt/etc/fstab.*_keyfile
ln -sf /etc/fstab.zfs_keyfile /mnt/crypto_keyfile.bin
zfs set keylocation=file:///crypto_keyfile.bin "$ZPOOL"

# minimal fstab — Ansible will template the full one with bind mounts.
# Reference the ESP by LABEL (set at mkfs time) instead of UUID — busybox
# blkid in the live ISO doesn't support `-s UUID -o value` cleanly.
cat > /mnt/etc/fstab <<EOF
$ZPOOL/ROOT/alpine	/		zfs	rw,relatime,xattr,posixacl,casesensitive 0 1
$ZPOOL/ROOT/home	/home		zfs	rw,relatime,xattr,posixacl,casesensitive,nosuid,nodev,noexec 0 1
LABEL=efi		/efi		vfat	rw,relatime,fmask=0022,dmask=0022,codepage=437,iocharset=utf8,shortname=mixed,errors=remount-ro 0 2
/dev/mapper/boot	/boot		ext4	rw,relatime,noauto 0 2
tmpfs			/tmp		tmpfs	nosuid,nodev	0	0
EOF

# minimal dmcrypt (Ansible will keep this in sync)
cat > /mnt/etc/conf.d/dmcrypt <<EOF
target='swap'
source='${PART}3'
key='/etc/fstab.swap_keyfile'

target='boot'
source='${PART}2'
key='/etc/fstab.boot_keyfile'
EOF

# minimal local.d so the system reboots cleanly even before Ansible runs
mkdir -p /mnt/etc/local.d
printf '#!/bin/sh\nmount /boot\n'              > /mnt/etc/local.d/boot.start
printf '#!/bin/sh\numount /boot\n'             > /mnt/etc/local.d/boot.stop
printf '#!/bin/sh\nswapon /dev/mapper/swap\n'  > /mnt/etc/local.d/swap.start
printf '#!/bin/sh\nswapoff /dev/mapper/swap\n' > /mnt/etc/local.d/swap.stop
chmod +x /mnt/etc/local.d/*.start /mnt/etc/local.d/*.stop

sed -i 's|^features=.*|features="ata base ide scsi usb virtio nvme cryptsetup cryptkey ext4 zfs keymap"|' \
	/mnt/etc/mkinitfs/mkinitfs.conf

# ---- chroot prep -------------------------------------------
mount -t proc /proc /mnt/proc
mount --rbind /dev /mnt/dev   && mount --make-rslave /mnt/dev
mount --rbind /sys /mnt/sys   && mount --make-rslave /mnt/sys
cp -p /etc/apk/repositories /mnt/etc/apk/repositories
chroot /mnt apk update

# ---- minimal GRUB so the host can reboot -------------------
say "Installing minimal GRUB-EFI (Ansible will retune)"
chroot /mnt apk add grub grub-efi efibootmgr kernel-hooks sbsigntool openssl python3
chroot /mnt apk del syslinux 2>/dev/null || true
chattr -i /mnt/boot/ldlinux* 2>/dev/null || true
rm -f /mnt/boot/*.c32 /mnt/boot/ldlinux* /mnt/boot/extlinux.conf /mnt/boot/boot

cat > /mnt/etc/default/grub <<EOF
GRUB_DISTRIBUTOR="Alpine"
GRUB_TIMEOUT=2
GRUB_DISABLE_SUBMENU=y
GRUB_DISABLE_RECOVERY=true
GRUB_PRELOAD_MODULES="luks cryptodisk part_gpt"
GRUB_ENABLE_CRYPTODISK=y
GRUB_DISABLE_LINUX_PARTUUID=true
GRUB_DISABLE_LINUX_UUID=true
GRUB_DEVICE=ZFS=$ZPOOL/ROOT/alpine
GRUB_FS=noneofyourbusiness
GRUB_CMDLINE_LINUX_DEFAULT=" ro"
EOF
chroot /mnt grub-mkconfig -o /boot/grub/grub.cfg
chroot /mnt grub-install --target=x86_64-efi --efi-directory=/efi --boot-directory=/boot
mkdir -p /mnt/efi/EFI/boot
sed -i 's/SecureBoot/SecureB00t/' /mnt/efi/EFI/alpine/grubx64.efi
mv /mnt/efi/EFI/alpine/grubx64.efi /mnt/efi/EFI/boot/bootx64.efi
rmdir /mnt/efi/EFI/alpine 2>/dev/null || true
rm -f /mnt/boot/grub/grubenv

KVER=$(ls /mnt/lib/modules/ | head -n1)
chroot /mnt mkinitfs "$KVER"

# ---- enable enough services to boot + accept ssh -----------
chroot /mnt rc-update add dmcrypt        boot
chroot /mnt rc-update add local          default
chroot /mnt rc-update add networking     boot      || true
chroot /mnt rc-update add sshd           default
chroot /mnt rc-update add chronyd        default

# Use NetworkManager only after Ansible installs/configures it on a desktop.
# For first boot we let the iso-default networking carry us through DHCP.

# ---- root login for ansible --------------------------------
mkdir -m 0700 /mnt/root/.ssh
printf '%s\n' "$ROOT_AUTHORIZED_KEYS" > /mnt/root/.ssh/authorized_keys
chmod 0600 /mnt/root/.ssh/authorized_keys

# Lock root login to keys-only. busybox sed in the live ISO doesn't
# support BRE `\?`, so use ERE (`-E`) with `?`. Last-line-wins in
# sshd_config means we could also just append, but rewriting in place
# keeps the file tidy.
sed -i -E 's/^#?PermitRootLogin.*/PermitRootLogin prohibit-password/' /mnt/etc/ssh/sshd_config
sed -i -E 's/^#?PubkeyAuthentication.*/PubkeyAuthentication yes/'      /mnt/etc/ssh/sshd_config

# ---- cleanup -----------------------------------------------
sync
umount -l /mnt/dev /mnt/proc /mnt/sys
umount /mnt/boot /mnt/efi /mnt/home /mnt
zpool export "$ZPOOL"
cryptsetup luksClose boot 2>/dev/null || true
cryptsetup luksClose swap 2>/dev/null || true

cat <<EOF

================================================================
Bootstrap complete. Reboot, then from your control node:

  ansible-playbook -i inventory/hosts.yml playbooks/desktop.yml -l $HOSTNAME

If this is a server target instead, run a different playbook
(e.g. cdn.yml) with the same inventory.
================================================================
EOF
