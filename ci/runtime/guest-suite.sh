#!/usr/bin/env bash
set -euo pipefail
[[ -f /etc/archzfs-ci-guest && $(systemd-detect-virt) =~ ^(kvm|qemu)$ ]] || exit 1
scope=${1:-full}
shard=${2:-all}
results=/var/tmp/archzfs-results

# These are test prerequisites; ZFS packages and upstream tests remain unchanged.
pacman -S --needed --noconfirm jq nfs-utils rsync words xfsprogs cryptsetup samba
systemctl start nfs-server.service
pacman -Q > "$results/suite-installed-packages.txt"

# Match upstream's XFS test-work volume and loopback/scsi_debug strategy. Keep
# the OS and retained diagnostics on their own filesystem, outside this volume.
[[ -z $(zpool list -H -o name) ]]
scratch=/dev/disk/by-id/virtio-archzfs-test-1
[[ $(lsblk -dnro SERIAL "$scratch") == archzfs-test-1 ]]
wipefs --all "$scratch"
mkfs.xfs -f "$scratch"
mkdir -p /var/tmp/zts-work
mount "$scratch" /var/tmp/zts-work
chmod 1777 /var/tmp/zts-work
trap 'umount /var/tmp/zts-work || true' EXIT
df -h > "$results/suite-filesystems.txt"

python /var/tmp/archzfs-ci/select-runfile.py "$scope" "$results/selected.run"
args=(-vKO -s 3G -r "$results/selected.run")
if [[ $shard != all ]]; then
    [[ $shard =~ ^([1-9][0-9]*)/([1-9][0-9]*)$ ]]
    (( BASH_REMATCH[1] <= BASH_REMATCH[2] ))
    args+=(-T "$shard")
fi
printf 'scope=%s\nshard=%s\n' "$scope" "$shard" > "$results/suite-selection.txt"
status=0
sudo -u ci env -u DISKS FILEDIR=/var/tmp/zts-work \
    /usr/share/zfs/zfs-tests.sh "${args[@]}" 2>&1 | tee "$results/zts-console.txt" || status=$?
printf '%s\n' "$status" > "$results/zts-exit-status.txt"
if grep -q '^Results Summary' "$results/zts-console.txt"; then
    printf 'COMPLETED scope=%s shard=%s status=%s\n' "$scope" "$shard" "$status" \
        > "$results/zts-completed.txt"
fi
exit "$status"
