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

Enable Actions on the fork before pushing this branch. If it was first pushed
while fork workflows were disabled, push another change under `ci/runtime/` to
start the branch workflow. GitHub's manual dispatch UI requires the workflow
file to exist on the default branch; until then, branch pushes run smoke tests.

While iterating on VM setup, the workflow defaults to reusing both completed
candidate builds from run `39414535555`. This skips the builder image and all
package compilation. `reuse-candidate.sh` verifies the artifact manifest and
recorded provenance, rejects changes to packaging/build inputs since that run,
and records the distinct build and harness SHAs. Expired or incomplete artifacts
fail explicitly. Change the workflow's run ID (or manual `candidate_run` input)
to `fresh` when a rebuild is required. This temporary pin is for spike iteration,
not a production package-selection policy.

## What it exercises

Each matrix job targets `linux` or `linux-lts`. Fresh mode builds the candidates
below; reuse mode downloads the recorded candidates before booting the VM:

1. Build the existing builder image and regenerate utilities and kernel recipes
   from this control-repository commit. Build fresh `zfs-utils`, `zfs-tests`, and
   the chosen kernel module. No release assets or failover packages are reused.
2. Save the exact official kernel archive and signature, generated recipes,
   package metadata, source SHA, run ID, URLs, and SHA-256 manifest.
3. Download an official Arch cloud image and verify its checksum and signature
   against the pinned official arch-boxes release key in `keys/`. This is a
   separate trust anchor from the Arch package keyring.
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

For the pinned 2.4.4 candidates, ZTS applies the upstream test-only cleanup fix
[1c8a75f](https://github.com/openzfs/zfs/commit/1c8a75f7d3f0aa81ea3560540e706a8fc3808a8f).
It clears labels left by `device_access_import` so subsequent tests do not
discover an unrelated exported pool with the same name. The original installed
test, patch, upstream commit, application log and before/after digests are
retained. ZFS binaries and test assertions are unchanged. Patch mismatch fails
explicitly; revisit this backport when updating the candidate generation.
Manual scope `cleanup` runs that test followed by `large_dnode_009_pos` and
`inuse_004_pos`, the two tests affected by the residual pool in the full run.

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
  The workflow restores checkout ownership to the Actions runner after the
  container exits, including on failure, before VM setup and artifact upload.
- ZTS uses the three scratch devices and passwordless sudo inside the VM.
  Only loopback SSH is exposed; its key and VM disks are never uploaded. No host
  block devices or checkout are mounted into the VM.
- The selected kernel is direct-booted. This tests a matching kernel/initramfs
  and installed packages, **not** bootloader configuration, root-on-ZFS,
  encrypted-root recovery, DKMS, other kernel flavors, or upgrade compatibility.
- Smoke tests do not persist a pool across another guest reboot yet.
- Full ZTS can exceed the job's time budget or need additional optional tools;
  preserve such failures rather than treating them as successful skips.
  The VM/test step allows five hours, within a six-hour overall job limit.
- No release promotion, cancellation, mirror-outage, or watcher tests are added
  here. Those require separate tests of the automation itself.

For production integration, separate the candidate build from VM jobs, reuse
exact per-kernel artifacts, and make promotion depend on explicit runtime
results. Preserve the existing publication critical section and fork-safe token
boundary. This spike requests read-only contents and Actions access, persists no checkout
credentials, and uses no repository secrets or signing environment.
