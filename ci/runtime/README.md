# Arch package runtime spike

This branch explores testing the **actual ArchZFS packages** in disposable Arch
VMs on GitHub-hosted Actions runners. It does not change production release
gates, sign packages, publish releases, or use production signing credentials.
It is independent of the older `testing/test.sh` harness.

The `Arch VM runtime spike` workflow runs on pushes to this spike branch and
offers a manual `zts` boolean for longer upstream functional testing. Set the
fork's `MIRROR_URL` variable to an HTTPS mirror base (without `/archlinux`).
Missing configuration fails deliberately; there is no implicit friendly mirror.
The scripts reject execution outside GitHub-hosted runners; do not run them
locally. The VM and privileged build run remotely, including all scratch disk
and pool operations.

## What it exercises

Each matrix job targets `linux` or `linux-lts`:

1. Build the existing builder image and regenerate utilities and kernel recipes
   from this control-repository commit. Build fresh `zfs-utils`, `zfs-tests`, and
   the chosen kernel module. No release assets or failover packages are reused.
2. Save the exact official kernel archive and signature, generated recipes,
   package metadata, source SHA, run ID, URLs, and SHA-256 manifest.
3. Download an official Arch cloud image and verify its checksum and signature
   against the Arch keyring in the freshly built builder image.
4. Boot a disposable KVM guest with three new virtual scratch disks. Update
   Arch, authenticate and install the retained official kernel, then install the
   unsigned candidate packages using a guest-only local Pacman repository.
5. Shut down and boot explicitly with the installed target kernel and a newly
   generated initramfs. Assert that `uname -r`, module vermagic, and package
   ownership match the intended kernel/module combination.
6. Create a mirrored pool, verify random data, snapshot and send/receive, verify
   again after export/import, scrub, check pool health, and destroy the pool.
7. Optionally run `/usr/share/zfs/zfs-tests.sh` from the matching installed
   `zfs-tests` package. Tests are reused directly, rather than copied or ported.

The upstream [QEMU workflow] and [ZTS instructions] inform this design. Upstream
already supports an Arch cloud-image target. This spike uses a smaller harness
because its inputs are ArchZFS package artifacts rather than an upstream source
build. No upstream test sources are vendored.

[QEMU workflow]: https://github.com/openzfs/zfs/blob/master/.github/workflows/zfs-qemu.yml
[ZTS instructions]: https://github.com/openzfs/zfs/blob/master/tests/README.md

## Evidence and interpretation

Each job uploads `arch-runtime-<kernel>-<attempt>` for seven days, including
candidate archives, official kernel/signature, recipes, metadata, build output,
cloud-image verification, serial logs, guest journal, installed versions, module
ownership, pool status, and upstream test output when requested. The artifact's
Actions run and source SHA bind the unsigned candidates to their build. Their
digests identify bytes; they do not make these production-signed packages.

Only a successful runtime result validates the candidate combination. Build
success, reused packages, or an interrupted/timed-out VM are not runtime passes.
Smoke success does not imply ZTS ran. A successful ZTS command is useful
functional evidence, not proof against all corruption or kernel bugs; review
its executed/skipped test counts and failures before relying on its coverage.

## Spike limits and follow-up

- This harness has not yet been established as a release gate. Review the
  Actions evidence and fix platform/dependency assumptions before adopting it.
- The cloud image, mirror contents, and hosted runner are moving inputs. Image
  checksum/signature, kernel archive, package identities, and generated recipes
  are retained for diagnosis. A mirror/official metadata race can fail a build
  or dependency installation; it must not silently substitute another kernel.
- The package build still uses the repository's existing privileged container
  and clean-chroot-manager. It requires substantial runner disk and time.
- ZTS uses the three scratch devices and passwordless sudo inside the VM.
  Only loopback SSH is exposed; its key and VM disks are never uploaded. No host
  block devices or checkout are mounted into the VM.
- The selected kernel is direct-booted. This tests a matching kernel/initramfs
  and installed packages, **not** bootloader configuration, root-on-ZFS,
  encrypted-root recovery, DKMS, other kernel flavors, or upgrade compatibility.
- Smoke tests do not persist a pool across another guest reboot yet.
- Full ZTS can exceed the job's time budget or need additional optional tools;
  preserve such failures rather than treating them as successful skips.
- No release promotion, cancellation, mirror-outage, or watcher tests are added
  here. Those require separate tests of the automation itself.

For production integration, separate the candidate build from VM jobs, reuse
exact per-kernel artifacts, and make promotion depend on explicit runtime
results. Preserve the existing publication critical section and fork-safe token
boundary. This spike requests read-only contents access, persists no checkout
credentials, and uses no repository secrets or signing environment.
