# Integration tests

Self-contained Ansible playbooks that exercise critical safety paths
without needing remote hosts. They run against `localhost` with
`connection: local`, so they are safe to run on a developer laptop
or in CI.

## `test_raid_idempotency.yml`

Regression test for the 2026-05-15 EBUSY-on-re-run incident (Peter's bug),
where `mdadm --create /dev/md0 ... /dev/sdb /dev/sdc` failed because the
kernel had already auto-assembled the array as `/dev/md127` after a reboot
(initramfs/homehost mismatch). The role's name-only check
(`'md0' not in existing_arrays`) missed it and tried to recreate over the
already-busy members.

Test cases:

| # | Scenario | Expected behavior |
|---|----------|-------------------|
| 1 | Both planned arrays already assembled under different names (md0→md127, md1→md126) | `mdadm --create` skipped for both; `raid_arrays` + `mount_points` device fields remapped to actual `/dev/mdN` |
| 2 | Fresh host, no md arrays exist | Both planned arrays survive the skip filter (no false-positive skips) |
| 3 | Partial overlap — md0 exists as md127, md1 is fresh | Only md1 is created; md0 is skipped |

The tests run the same Jinja expressions the role uses for `_array_md_lookup`,
`_existing_md_for_array`, `_arrays_already_present`, and `_device_remap` —
so a regression in the role logic shows up as a test-2 / test-3 failure.

## `test_boot_device_safety.yml`

Regression test for the 2026-05-14 boot-drive incident, where empty
boot-device detection caused `nvme_discovery` to plan `mkfs.xfs` on
the OS NVMe (kernel `EBUSY` was the only thing that saved it).

Test cases:

| # | Scenario | Expected behavior |
|---|----------|-------------------|
| 1 | Run `detect_boot_device.yml` against the actual control host | `_protected_disks` is non-empty; `_detected_boot_device` is in the list |
| 2 | `_protected_disks: []` and `allow_empty_protected_disks: false` | Playbook hard-fails before any mkfs |
| 3 | `_protected_disks: []` and `allow_empty_protected_disks: true` | Override bypasses the gate (diskless/netboot escape hatch) |
| 4 | Boot drive sneaks into `nvme_devices` | Safety gate in `build_raid_arrays.yml` fires |
| 5 | Clean `nvme_devices` with no overlap | Safety gate does NOT fire (no false positives) |
| 6 | Detection under `LC_ALL=ko_KR.UTF-8` (Keith's host) | Same output as under `C` locale |

## Running

**Linux only** — uses `/proc/mounts`, `/proc/swaps`, `lsblk`, `findmnt`.
On macOS the playbook self-skips at the first task. Run on the Korean-locale
host that hit the original bug (`dskbd079`), inside CI, or any Linux dev box.

```bash
# Boot-drive safety
ansible-playbook tests/integration/test_boot_device_safety.yml -i localhost, -c local

# RAID idempotency (re-run after reboot)
ansible-playbook tests/integration/test_raid_idempotency.yml -i localhost, -c local

# Through the locale wrapper (recommended on non-English systems)
./scripts/run.sh playbook tests/integration/test_boot_device_safety.yml -i localhost, -c local
./scripts/run.sh playbook tests/integration/test_raid_idempotency.yml -i localhost, -c local
```

Exit code is non-zero if any test fails. The final task prints a report:

```
============================================================
BOOT-DRIVE SAFETY REGRESSION TEST REPORT
============================================================
PASSED (6):
  ✓ TEST 1: real detection produces non-empty list
  ✓ TEST 2: empty _protected_disks → hard-fail (expected behavior, caught by rescue)
  ...
FAILED: 0
============================================================
```

## When to run

- Before merging any change to `roles/nvme_discovery/tasks/detect_boot_device.yml`
- Before merging any change to the `rejectattr` filters in
  `roles/nvme_discovery/tasks/main.yml`
- Before merging any change to the safety gate in
  `roles/nvme_discovery/tasks/build_raid_arrays.yml`
- After any change to `roles/precheck/tasks/validate_drives.yml`
- After any change to `roles/raid_setup/tasks/main.yml` (idempotency
  detection, `_device_remap`, or the per-element list rebuild pattern)

Wire into pre-merge CI with whatever Ansible runtime is already
installed in the pipeline.

## Notes

- TEST 6 needs the `ko_KR.UTF-8` locale generated on the host. If
  it's missing, the test will skip rather than fail spuriously.
  Generate with `localectl set-locale ko_KR.UTF-8` (RHEL/Rocky) or
  `locale-gen ko_KR.UTF-8` (Debian/Ubuntu). The test still validates
  locale-resilience because the detection forces `LC_ALL=C`
  internally regardless of the calling environment.
- The tests use `block` / `rescue` to convert expected failures into
  test passes. Real failures bubble up via the final `_test_failures`
  list.
