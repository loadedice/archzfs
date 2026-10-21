# Initial ZTS failure investigation

Source evidence: OpenZFS `zfs-2.4.4` and both kernel jobs in
https://github.com/loadedice/archzfs/actions/runs/39508468820.
Those incomplete runs each logged the same sixteen failing test names.

Seven are explicitly expected by the release's own
`tests/test-runner/bin/zts-report.py.in`:

- Six casenorm tests: `mixed_none_lookup_ci`, `mixed_formd_lookup_ci`,
  `mixed_formd_lookup`, `mixed_formd_delete`, `sensitive_formd_lookup`,
  and `sensitive_formd_delete`, linked to upstream issue 7633.
- `cli_root/zpool_import/import_rewind_device_replaced`, with the upstream
  reason that arbitrary pool rewind is not guaranteed.

The other nine remain unclassified pending detailed logs and controlled reruns:

- `cli_root/json/json_sanity`: test uses jq, which the initial guest did not
  explicitly install (optional in the test package).
- `cli_root/zfs_set/canmount_002_pos` and
  `cli_root/zpool_import/zpool_import_012_pos`: both exercise NFS sharing;
  the initial guest did not explicitly install/start the NFS server.
- `cli_root/zpool_reopen/zpool_reopen_00{1,2,3,4,5,7}_pos`: tests use SCSI
  remove/reinsert helpers. The initial DISKS list specifies virtio-blk disks,
  whereas upstream's default loopback setup selects scsi_debug for removal.
  Test 003 is separately listed as a possible Linux failure upstream; that
  does not establish the cause of its failure here.

The timeout prevented normal per-test log collection. Diagnosis mode captures
logs from a targeted baseline, repeats with jq/NFS prerequisites, then runs the
same tests three times with default loopback/scsi_debug devices. It records
package identities and environment changes. It has a separate concurrency group
so it does not cancel the full-suite run. Use manual inputs `diagnose=true` and
the recorded candidate run ID. No ZFS source, package, or expected-failure list
is modified. This investigation does not certify filesystem correctness.
