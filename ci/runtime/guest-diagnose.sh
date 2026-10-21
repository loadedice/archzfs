#!/usr/bin/env bash
# Compare unchanged tests and packages under controlled guest environments.
set -euo pipefail
[[ -f /etc/archzfs-ci-guest && $(systemd-detect-virt) =~ ^(kvm|qemu)$ ]] || exit 1
results=/var/tmp/archzfs-results/diagnostics
mkdir -p "$results"
runfile=/var/tmp/archzfs-diagnostic.run
cat > "$runfile" <<'EOF'
[DEFAULT]
pre = setup
post = cleanup
pre_user = root
post_user = root
user = root
timeout = 600
quiet = False
failsafe_user = root
failsafe = callbacks/zfs_failsafe
tags = ['functional']

[tests/functional/cli_root/json]
tests = ['json_sanity']

[tests/functional/cli_root/zfs_set]
tests = ['canmount_002_pos']

[tests/functional/cli_root/zpool_import]
tests = ['zpool_import_012_pos']

[tests/functional/cli_root/zpool_reopen]
tests = ['zpool_reopen_001_pos', 'zpool_reopen_002_pos',
    'zpool_reopen_003_pos', 'zpool_reopen_004_pos',
    'zpool_reopen_005_pos', 'zpool_reopen_007_pos']
EOF

{
    uname -a
    pacman -Q
    lsblk -o NAME,TYPE,SERIAL,FSTYPE,MOUNTPOINTS
    ls -l /sys/block/vdb/device/
    command -v jq || true
    command -v exportfs || true
    systemctl status nfs-server --no-pager || true
} > "$results/baseline-environment.txt" 2>&1
printf 'stage\texit_status\n' > "$results/stages.tsv"
run_stage() {
    local stage=$1 disks=$2 status=0 logdir
    echo "=== Diagnostic stage: $stage ==="
    if [[ $disks == virtio ]]; then
        sudo -u ci env DISKS='vdb vdc vdd' /usr/share/zfs/zfs-tests.sh \
            -v -r "$runfile" 2>&1 | tee "$results/$stage-console.txt" || status=$?
    else
        # Upstream's default uses loopback vdevs and scsi_debug for hotplug tests.
        sudo -u ci env -u DISKS /usr/share/zfs/zfs-tests.sh \
            -v -s 3G -r "$runfile" 2>&1 | tee "$results/$stage-console.txt" || status=$?
    fi
    printf '%s\t%s\n' "$stage" "$status" | tee -a "$results/stages.tsv"
    logdir=$(awk '/^Log directory/ {print $3; exit}' "$results/$stage-console.txt")
    if [[ $logdir == /var/tmp/test_results/* && -d $logdir ]]; then
        cp -a "$logdir" "$results/$stage-details"
    fi
    return "$status"
}

# Reproduce the original environment before changing any dependencies.
run_stage baseline virtio || true

# JSON and NFS sharing tests need these optional tools and a running NFS server.
# This changes only test prerequisites in this disposable VM, not ZFS packages.
pacman -S --needed --noconfirm jq nfs-utils
systemctl start nfs-server.service
pacman -Q > "$results/corrected-installed-packages.txt"
systemctl status nfs-server.service --no-pager > "$results/nfs-server.txt"
run_stage dependencies virtio || true

# Repeat all nine tests three times with upstream-style scratch devices.
# Retain failures; repeated passing runs are evidence, not proof of no flakes.
outcome=0
for attempt in 1 2 3; do
    run_stage "loopback-$attempt" loopback || outcome=1
done
exit "$outcome"
