#!/usr/bin/env bash
set -euo pipefail
[[ -f /etc/archzfs-ci-guest && $(systemd-detect-virt) =~ ^(kvm|qemu)$ ]] || exit 1
scope=${1:-full}
shard=${2:-all}
results=/var/tmp/archzfs-results

# These are test prerequisites; the ZFS implementation remains unchanged.
pacman -S --needed --noconfirm jq nfs-utils rsync words xfsprogs cryptsetup samba patch
systemctl start nfs-server.service
pacman -Q > "$results/suite-installed-packages.txt"

# Backport upstream's exported-pool cleanup fix to the packaged 2.4.4 test.
# Preserve the original, exact patch and digests as part of runtime evidence.
test_file=/usr/share/zfs/zfs-tests/tests/functional/device_access/device_access_import.ksh
test_patch=/var/tmp/archzfs-ci/device-access-import-cleanup.patch
cp "$test_file" "$results/device-access-import-original.ksh"
cp "$test_patch" "$results/"
printf '%s\n' 'openzfs/zfs 1c8a75f7d3f0aa81ea3560540e706a8fc3808a8f' \
    > "$results/test-backport-source.txt"
sha256sum "$test_file" "$test_patch" > "$results/test-backport-before.sha256"
patch --batch --forward --fuzz=0 "$test_file" < "$test_patch" \
    | tee "$results/test-backport.log"
sha256sum "$test_file" > "$results/test-backport-after.sha256"

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
