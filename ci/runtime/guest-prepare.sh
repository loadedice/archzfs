#!/usr/bin/env bash
set -euo pipefail
[[ -f /etc/archzfs-ci-guest && $(systemd-detect-virt) =~ ^(kvm|qemu)$ ]] || {
    echo 'Refusing to prepare anything except the disposable CI guest.' >&2
    exit 1
}
kernel=${1:?kernel package}
mirror=${2:?mirror URL}
case "$kernel" in linux|linux-lts) ;; *) exit 1 ;; esac
cd /var/tmp/archzfs-ci/runtime-candidate
sha256sum --check SHA256SUMS
mkdir -p /var/tmp/archzfs-results
cp metadata/build.txt /var/tmp/archzfs-results/
# shellcheck disable=SC2016 # Pacman expands repo and arch, not this shell.
printf 'Server = %s/archlinux/$repo/os/$arch\n' "$mirror" > /etc/pacman.d/mirrorlist
pacman -Syu --noconfirm

# Authenticate the official kernel independently of the unsigned PR packages.
shopt -s nullglob
archives=(official/*.pkg.tar.zst)
[[ ${#archives[@]} == 1 ]]
test -s "${archives[0]}.sig"
pacman-key --verify "${archives[0]}.sig" "${archives[0]}" \
    2>&1 | tee /var/tmp/archzfs-results/kernel-signature.txt
pacman -U --noconfirm "${archives[0]}"

# Resolve dependencies through Pacman, while requiring the candidate packages.
# Only this local candidate repo accepts unsigned packages.
cat >> /etc/pacman.conf <<'EOF'

[candidate]
SigLevel = Optional
Server = file:///var/tmp/archzfs-ci/runtime-candidate/packages
EOF
pacman -Sy --noconfirm
pacman -S --noconfirm candidate/zfs-utils candidate/zfs-tests "candidate/zfs-$kernel"
pacman -S --needed --noconfirm openssh sudo
for archive in packages/*.pkg.tar.zst; do
    identity=$(pacman -Qp "$archive")
    name=${identity%% *}
    [[ $(pacman -Q "$name") == "$identity" ]]
done

release=$(pacman -Ql "$kernel" | sed -n 's@.*/usr/lib/modules/\([^/]*\)/pkgbase$@\1@p')
[[ -n $release && $release != *$'\n'* ]]
test -s "/usr/lib/modules/$release/vmlinuz"
printf '%s\n' "$release" > /var/tmp/archzfs-results/expected-kernel
printf '%s\n' "$kernel" > /var/tmp/archzfs-results/kernel-package
findmnt -nro UUID / > /var/tmp/archzfs-results/root-uuid
pacman -Q > /var/tmp/archzfs-results/installed-packages.txt

# Boot the selected kernel explicitly; the cloud image's bootloader may prefer linux.
cat > /tmp/archzfs-mkinitcpio.conf <<'EOF'
MODULES=(virtio_pci virtio_blk virtio_scsi ext4 btrfs)
BINARIES=()
FILES=()
HOOKS=(base udev modconf block filesystems)
EOF
mkinitcpio -c /tmp/archzfs-mkinitcpio.conf -k "$release" -g /tmp/archzfs-initramfs.img
cp "/usr/lib/modules/$release/vmlinuz" /tmp/archzfs-vmlinuz
chmod a+r /tmp/archzfs-{vmlinuz,initramfs.img}
