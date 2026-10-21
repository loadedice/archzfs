#!/usr/bin/env bash
set -euo pipefail
[[ ${GITHUB_ACTIONS:-} == true && ${RUNNER_ENVIRONMENT:-} == github-hosted ]] || {
    echo 'This spike boots VMs only on GitHub-hosted Actions runners.' >&2
    exit 1
}
[[ ${MIRROR_URL:-} =~ ^https://[a-zA-Z0-9./:_-]+$ ]] || {
    echo 'MIRROR_URL must be an HTTPS mirror base URL without shell metacharacters.' >&2
    exit 1
}
case ${KERNEL_PACKAGE:-} in linux|linux-lts) ;; *) exit 1 ;; esac
[[ ${RUN_ZTS:-false} == true || ${RUN_ZTS:-false} == false ]]
[[ ${ZTS_DIAGNOSE:-false} == true || ${ZTS_DIAGNOSE:-false} == false ]]
case ${ZTS_SCOPE:-full} in full|focus|tail|unresolved|after-fault|probe|resume|cleanup) ;; *) exit 1 ;; esac
[[ ${ZTS_SHARD:-all} == all || ${ZTS_SHARD:-all} =~ ^[1-9][0-9]*/[1-9][0-9]*$ ]] || exit 1
test -r /dev/kvm && test -w /dev/kvm
work=$(mktemp -d "$RUNNER_TEMP/archzfs-vm.XXXXXXXX")
results="$PWD/runtime-results"
mkdir -p "$results"
ssh-keygen -q -t ed25519 -N '' -f "$work/id_ed25519"
ssh_options=(-i "$work/id_ed25519" -p 10022 -o BatchMode=yes
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5)
scp_options=(-i "$work/id_ed25519" -P 10022 -o BatchMode=yes
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5)
# shellcheck disable=SC2029 # Callers deliberately supply commands to the guest.
guest() { ssh "${ssh_options[@]}" ci@127.0.0.1 "$@"; }
vm_pid=''
stop_vm() {
    if [[ -n $vm_pid ]]; then
        kill "$vm_pid" 2>/dev/null || true
        wait "$vm_pid" 2>/dev/null || true
        vm_pid=''
    fi
}
collect() {
    status=$?
    trap - EXIT
    set +e
    if [[ -n $vm_pid ]] && kill -0 "$vm_pid" 2>/dev/null; then
        timeout 30s ssh "${ssh_options[@]}" ci@127.0.0.1 sudo journalctl -b --no-pager > "$results/guest-journal.txt" 2>&1
        timeout 90s ssh "${ssh_options[@]}" ci@127.0.0.1 'sudo tar -czf /tmp/guest-results.tar.gz /var/tmp/archzfs-results /var/tmp/test_results* 2>/dev/null; sudo chmod a+r /tmp/guest-results.tar.gz'
        timeout 90s scp "${scp_options[@]}" ci@127.0.0.1:/tmp/guest-results.tar.gz "$results/"
    fi
    stop_vm
    exit "$status"
}
trap collect EXIT

image_url=https://geo.mirror.pkgbuild.com/images/latest/Arch-Linux-x86_64-cloudimg.qcow2
printf '%s\n' "$image_url" > "$results/image-url.txt"
curl --fail --location --retry 3 "$image_url" -o "$work/base.qcow2"
curl --fail --location --retry 3 "$image_url.SHA256" -o "$results/image.SHA256"
curl --fail --location --retry 3 "$image_url.sig" -o "$work/base.qcow2.sig"
digest=$(awk 'NR == 1 { print $1 }' "$results/image.SHA256")
[[ $digest =~ ^[a-fA-F0-9]{64}$ ]]
printf '%s  %s\n' "$digest" "$work/base.qcow2" | sha256sum --check
# Arch cloud images use the separate arch-boxes release key, not Pacman's
# package keyring. Pin the official certificate and isolate it from other keys.
mkdir -m 700 "$work/gnupg"
gpg --batch --homedir "$work/gnupg" --dearmor --output "$work/arch-boxes.gpg" \
    ci/runtime/keys/arch-boxes.asc
gpgv --homedir "$work/gnupg" --keyring "$work/arch-boxes.gpg" \
    "$work/base.qcow2.sig" "$work/base.qcow2" \
    2>&1 | tee "$results/image-signature.txt"
qemu-img create -f qcow2 -F qcow2 -b "$work/base.qcow2" "$work/os.qcow2" 40G
for i in 1 2 3; do
    # Equal logical sizes are required by the initial mirrored-pool smoke test.
    # Images remain sparse; ZTS subsequently uses 3G loopbacks on disk 1's XFS.
    qemu-img create -f qcow2 "$work/scratch-$i.qcow2" 64G
done
cat > "$work/user-data" <<EOF
#cloud-config
hostname: archzfs-ci
users:
  - name: ci
    shell: /bin/bash
    sudo: ALL=(ALL) NOPASSWD:ALL
    ssh_authorized_keys:
      - $(cat "$work/id_ed25519.pub")
growpart:
  mode: auto
  devices: ['/']
resize_rootfs: true
write_files:
  - path: /etc/archzfs-ci-guest
    content: disposable-github-actions-guest
EOF
printf 'instance-id: archzfs-%s\nlocal-hostname: archzfs-ci\n' "$GITHUB_RUN_ID" > "$work/meta-data"
cloud-localds "$work/seed.iso" "$work/user-data" "$work/meta-data"

start_vm() {
    # Runner device permissions can be reset after the previous QEMU exits.
    # Record the state and grant this runner access immediately before each boot.
    getfacl /dev/kvm > "$results/kvm-$1-before.acl"
    sudo setfacl -m "u:$(id -un):rw" /dev/kvm
    getfacl /dev/kvm > "$results/kvm-$1-after.acl"
    test -r /dev/kvm && test -w /dev/kvm
    qemu-system-x86_64 -machine q35,accel=kvm -cpu host -m 8192 -smp 2 \
        -display none -monitor none -serial "file:$results/serial-$1.log" \
        -drive "file=$work/os.qcow2,if=none,id=os,format=qcow2" \
        -device virtio-blk-pci,drive=os,serial=archzfs-os \
        -drive "file=$work/seed.iso,media=cdrom,readonly=on" \
        -drive "file=$work/scratch-1.qcow2,if=none,id=scratch1,format=qcow2" \
        -device virtio-blk-pci,drive=scratch1,serial=archzfs-test-1 \
        -drive "file=$work/scratch-2.qcow2,if=none,id=scratch2,format=qcow2" \
        -device virtio-blk-pci,drive=scratch2,serial=archzfs-test-2 \
        -drive "file=$work/scratch-3.qcow2,if=none,id=scratch3,format=qcow2" \
        -device virtio-blk-pci,drive=scratch3,serial=archzfs-test-3 \
        -netdev user,id=net0,hostfwd=tcp:127.0.0.1:10022-:22 \
        -device virtio-net-pci,netdev=net0 "${boot_args[@]}" &
    vm_pid=$!
    local deadline=$((SECONDS + 300))
    while ((SECONDS < deadline)); do
        if ! kill -0 "$vm_pid" 2>/dev/null; then
            echo 'QEMU exited before SSH became available' >&2
            tail -n 80 "$results/serial-$1.log" >&2
            return 1
        fi
        if guest true 2>/dev/null; then return 0; fi
        sleep 3
    done
    echo 'Timed out waiting for guest SSH' >&2
    tail -n 80 "$results/serial-$1.log" >&2
    return 1
}
boot_args=()
start_vm prepare
guest sudo cloud-init status --wait
guest sudo install -d -o ci -g ci /var/tmp/archzfs-ci
scp "${scp_options[@]}" -r runtime-candidate ci@127.0.0.1:/var/tmp/archzfs-ci/
scp "${scp_options[@]}" ci/runtime/guest-*.sh ci@127.0.0.1:/var/tmp/archzfs-ci/
scp "${scp_options[@]}" ci/runtime/select-runfile.py ci@127.0.0.1:/var/tmp/archzfs-ci/
scp "${scp_options[@]}" ci/runtime/device-access-import-cleanup.patch ci@127.0.0.1:/var/tmp/archzfs-ci/
guest "sudo bash /var/tmp/archzfs-ci/guest-prepare.sh '$KERNEL_PACKAGE' '$MIRROR_URL'"
scp "${scp_options[@]}" ci@127.0.0.1:/tmp/archzfs-vmlinuz "$work/vmlinuz"
scp "${scp_options[@]}" ci@127.0.0.1:/tmp/archzfs-initramfs.img "$work/initramfs.img"
root_uuid=$(guest cat /var/tmp/archzfs-results/root-uuid)
[[ $root_uuid =~ ^[a-fA-F0-9-]+$ ]]
guest sudo systemctl poweroff || true
for ((attempt=0; attempt<30; attempt++)); do
    if ! kill -0 "$vm_pid" 2>/dev/null; then break; fi
    sleep 2
done
if kill -0 "$vm_pid" 2>/dev/null; then
    echo 'Guest did not shut down cleanly; refusing to boot a potentially dirty image.' >&2
    exit 1
fi
stop_vm
diagnostic_boot_args=''
if [[ ${ZTS_SCOPE:-full} == probe ]]; then
    # Keep watchdog stack dumps on the serial console even when the Arch
    # image's console log level hides them and a wedged guest cannot use SSH.
    diagnostic_boot_args=' ignore_loglevel'
fi
boot_args=(-kernel "$work/vmlinuz" -initrd "$work/initramfs.img"
    # The cloud image configures eth0. Its normal boot disables predictable
    # interface naming; preserve that when bypassing its bootloader.
    -append "root=UUID=$root_uuid rw console=ttyS0 net.ifnames=0$diagnostic_boot_args")
start_vm candidate
test_budget=270m
case ${ZTS_SCOPE:-full} in probe|resume) test_budget=20m ;; esac
timeout --signal=INT --kill-after=30s "$test_budget" ssh "${ssh_options[@]}" ci@127.0.0.1 \
    "sudo bash /var/tmp/archzfs-ci/guest-test.sh '${RUN_ZTS:-false}' '${ZTS_DIAGNOSE:-false}' '${ZTS_SCOPE:-full}' '${ZTS_SHARD:-all}'"
printf 'PASS: %s package smoke tests; ZTS requested: %s\n' "$KERNEL_PACKAGE" "${RUN_ZTS:-false}" \
    | tee "$results/result.txt" >> "$GITHUB_STEP_SUMMARY"
