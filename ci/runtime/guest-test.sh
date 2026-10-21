#!/usr/bin/env bash
set -euo pipefail
[[ -f /etc/archzfs-ci-guest && $(systemd-detect-virt) =~ ^(kvm|qemu)$ ]] || {
    echo 'Refusing to test outside the disposable CI guest.' >&2
    exit 1
}
run_zts=${1:-false}
diagnose=${2:-false}
[[ $run_zts == true || $run_zts == false ]]
[[ $diagnose == true || $diagnose == false ]]
results=/var/tmp/archzfs-results
exec > >(tee "$results/runtime.log") 2>&1
trap 'dmesg > /var/tmp/archzfs-results/dmesg.txt' EXIT
[[ $(uname -r) == "$(cat "$results/expected-kernel")" ]]
expected_devices=(/dev/vdb /dev/vdc /dev/vdd)
for i in 1 2 3; do
    disk="/dev/disk/by-id/virtio-archzfs-test-$i"
    test -b "$disk"
    [[ $(lsblk -dnro SERIAL "$disk") == "archzfs-test-$i" ]]
    # Exactly one unpartitioned, unmounted scratch device per serial.
    [[ $(lsblk -nrpo NAME "$disk" | wc -l) == 1 ]]
    [[ -z $(lsblk -nrpo MOUNTPOINTS "$disk" | tr -d '[:space:]') ]]
    # DISKS below uses vdb/vdc/vdd, so check that QEMU assigned those names.
    [[ $(readlink -f "$disk") == "${expected_devices[i-1]}" ]]
done
modprobe zfs
zfs version
modinfo zfs
[[ $(modinfo -F vermagic zfs) == "$(uname -r) "* ]]
module=$(modinfo -n zfs)
pacman -Qo "$module" | tee "$results/module-owner.txt"
[[ $(pacman -Qoq "$module") == "zfs-$(cat "$results/kernel-package")" ]]
zpool list
[[ -z $(zpool list -H -o name) ]]

pool=archzfs-spike
trap 'zpool destroy archzfs-spike || true; dmesg > /var/tmp/archzfs-results/dmesg.txt' EXIT
zpool create -m /mnt/archzfs-spike "$pool" mirror \
    /dev/disk/by-id/virtio-archzfs-test-1 /dev/disk/by-id/virtio-archzfs-test-2
zfs create "$pool/data"
dd if=/dev/urandom of=/mnt/archzfs-spike/data/payload bs=1M count=32 status=none
checksum=$(sha256sum /mnt/archzfs-spike/data/payload | cut -d ' ' -f1)
zfs snapshot "$pool/data@initial"
zfs send "$pool/data@initial" | zfs receive "$pool/received"
[[ $(sha256sum /mnt/archzfs-spike/received/payload | cut -d ' ' -f1) == "$checksum" ]]
zpool export "$pool"
zpool import -d /dev/disk/by-id "$pool"
[[ $(sha256sum /mnt/archzfs-spike/data/payload | cut -d ' ' -f1) == "$checksum" ]]
zpool scrub "$pool"
zpool wait -t scrub "$pool"
zpool status -v "$pool" | tee "$results/pool-status.txt"
[[ $(zpool status -x "$pool") == "pool '$pool' is healthy" ]]
zpool destroy "$pool"
trap 'dmesg > /var/tmp/archzfs-results/dmesg.txt' EXIT
printf 'PASS: package/module/kernel smoke tests\n' | tee "$results/smoke-result.txt"

if [[ $diagnose == true ]]; then
    bash /var/tmp/archzfs-ci/guest-diagnose.sh
    exit
fi

if [[ $run_zts == true ]]; then
    bash /var/tmp/archzfs-ci/guest-suite.sh "${3:-full}" "${4:-all}"
else
    printf 'NOT RUN: optional ZTS\n' > "$results/zts-result.txt"
fi
