# Integration tests

Self-contained Ansible playbooks that exercise critical safety paths
without needing remote hosts. They run against `localhost` with
`connection: local`, so they are safe to run on a developer laptop
or in CI.

## Single-entry runner

`tests/run_all.sh` runs every check in this directory plus the static
checks (YAML parsing, `bash -n`, `shellcheck`, `yamllint`,
`ansible-playbook --syntax-check`). Wire it into CI:

```bash
./tests/run_all.sh
```

Exits non-zero if anything fails. Prints a per-step summary at the end.

## `test_repo_root.yml`

Regression test for the `playbook_dir` → `repo_root` migration. The
`plays/*.yml` imports cause `playbook_dir` to resolve to `.../plays/`
instead of the repo root, breaking any task that does
`{{ playbook_dir }}/X` for files like `container/Containerfile`,
`vars/vault.yml`, `payload/`, or `gpu_fabric_data.txt`. Three production
incidents (2026-05-15, 2026-05-18) traced back to this pattern.

Fix: `vars/main.yml` defines `repo_root: "{{ playbook_dir }}/.."` once;
every controller-side file path uses `{{ repo_root }}/...`.

Test cases:

| # | Scenario | Expected |
|---|----------|----------|
| 1 | `vars/main.yml` contains the literal `repo_root: "{{ playbook_dir }}/.."` | Pass — definition present |
| 2 | `repo_root` chains through `plays/..` → resolves to repo root | Pass for vault.yml + Containerfile paths |
| 3 | **Audit:** grep for stray `playbook_dir` references in `roles/` and `plays/` | Empty — every controller path uses `repo_root` |
| 4 | Sanity: `container/`, `vars/`, `payload/` actually exist at the repo root | Pass |

TEST 3 is the regression-prevention case: if anyone re-introduces
`{{ playbook_dir }}/X` in a role or play, this test fails before merge.

## `test_protected_vs_md_split.yml`

Regression test for the 2026-05-18 "0 RAID arrays" incident (Peter's
re-run on hosts that already had working arrays). The boot-drive
safety overhaul had put md array members in `_protected_disks`, which
excluded all data disks from discovery on re-runs.

Test cases:

| # | Scenario | Expected behavior |
|---|----------|-------------------|
| 1 | OLD merged behavior (md members in `_protected_disks`) | Reproduces the bug — only fresh disks survive discovery |
| 2 | NEW split (md members in `_md_member_disks` only) | All non-boot disks survive discovery; md members listed informationally |
| 3 | Boot disk somehow leaks into candidate list | Safety gate in `build_raid_arrays.yml` still fires (no regression of boot protection) |
| 4 | End-to-end: discovery + `raid_setup._device_remap` | `mount_points[0].device` correctly remapped from `/dev/md0` to `/dev/md127` |

## `test_run_sh_locale.sh`

Unit tests for the locale-fallback picker in `scripts/run.sh`. Pure
bash, no Ansible required. 8 cases covering:

- en_US.UTF-8 present → picks it first
- en_US.UTF-8 missing → falls back to C.UTF-8
- lowercase variants (utf8 vs UTF-8)
- ko_KR-only host → returns empty (triggers the install-instruction error path)
- empty locale list (broken libc)
- case-insensitive matching
- priority ordering when all 4 candidates are present

Run directly:
```bash
bash tests/integration/test_run_sh_locale.sh
```

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
  (protected-disk / md-member / LVM-PV split, hard-fail behavior)
- Before merging any change to the `rejectattr` filters in
  `roles/nvme_discovery/tasks/main.yml`
- Before merging any change to the safety gate in
  `roles/nvme_discovery/tasks/build_raid_arrays.yml`
- After any change to `roles/precheck/tasks/validate_drives.yml`
- After any change to `roles/raid_setup/tasks/main.yml` (idempotency
  detection, `_device_remap`, or the per-element list rebuild pattern)
- After any change to `scripts/run.sh` (locale-fallback chain)

Wire into pre-merge CI as `./tests/run_all.sh` — it runs every check in one
command and exits non-zero on any failure.

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
