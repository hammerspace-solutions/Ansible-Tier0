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
| 5 | `/dev/md127` mounted at `/hammerspace/hsvol0` (2026-05-20 regression) | Members `sdb`/`sdc` NOT classified as protected — `detect_boot_device.yml` only walks system mountpoints, not data mounts |
| 6 | Azure ephemeral resource disk mounted at `/mnt` | `sdb` excluded from discovery; data disks `sdc`/`sdd` survive. Also audits that `/mnt` + `/mnt/resource` remain in the `SYSTEM_MOUNTS` allow-list |

## `test_azure_az_map.yml`

Covers Azure AZ derivation, added with Azure support on 2026-08-24.

Azure exposes two different placement values that are easy to conflate:
`zone` (availability zone, **1-based**, and an **empty string** rather than
absent on non-zonal VMs) and `platformFaultDomain` (**0-based**, IMDS only).
Getting either wrong is silent: an `is defined` test on `zone` makes every
non-zonal node render a bare `AZ`, and a missing `+1` on the fault domain
renders `AZ0` — a zone label Hammerspace never assigns.

The AZ expression lives once in `vars/main.yml` as `_cloud_az_detected`. This
test loads the **real** expression via `include_vars` rather than copying it,
so the assertions cannot drift from production.

Test cases:

| # | Scenario | Expected behavior |
|---|----------|-------------------|
| 1 | `vars/main.yml` defines `_cloud_az_detected` + the Azure IMDS vars | Present; `hammerspace_azure_imds_az` defaults `false` |
| 2 | `azure_zone: "2"` | → `AZ2` (1-based, verbatim) |
| 3 | `azure_zone: "3"` + `azure_fault_domain: "0"` | → `AZ3` — zone outranks fault domain |
| 4 | Non-zonal VM: `azure_zone: ""` + `azure_fault_domain: "0"` / `"2"` | → `AZ1` / `AZ3` — empty zone skipped, fault domain `+1`. Never `AZ0` or bare `AZ` |
| 5 | `oci_fault_domain: FAULT-DOMAIN-3`, incl. alongside `azure_zone` | → `AZ3` — OCI unchanged and still highest priority |
| 6 | No cloud metadata at all | Renders empty; `az_map` falls through to name prefix → group → `hammerspace_default_az` |
| 7 | `hammerspace_node_az` set; volume-name prefix on Azure | Override wins; prefix renders `AZ2:` on Azure and `''` with no metadata |
| 8 | **Audit:** all three call sites, include order, inventory, requirements | `az_map.yml` / `add_volume.yml` / `plays/storage.yml` all delegate to `_cloud_az_detected`; `azure_imds_az.yml` is included *before* `az_map.yml`; `inventory.azure.yml` uses `azure.azcollection.azure_rm`; `requirements.yml` pins `azure.azcollection` |
| 9 | IMDS request failed (no `json` key) / sparse payload / full payload | Parses to `{}` and empty strings without raising; full payload → `AZ2`. **Audits** that `azure_imds_az.yml` uses no `result.attr \| default(...)` — the 2026-07-21 sunrpc failure mode |

TEST 8 is the regression-prevention case: if anyone re-derives the AZ locally
from `oci_fault_domain` in a call site again, Azure hosts silently fall back to
`hammerspace_default_az` there — this test fails before merge.

**Second gotcha:** the IMDS request uses `failed_when: false`, so on a
non-Azure host the registered result has **no `json` key at all**. Writing
`_azure_imds_raw.json | default({})` would hard-fail with `'dict object' has
no attribute 'json'` before `default` ever runs — the exact 2026-07-21 sunrpc
failure mode. TEST 9's audit case blocks that from coming back.

**Gotcha this test encodes:** `ansible.cfg` enables `jinja2_native`, so
`_cloud_az_detected` renders to `None`, not `""`, when no branch matches. A
plain `| default('')` does not catch `None`, and `None | trim` stringifies to
the literal `"None"` — which would become the AZ label. Every consumption site
must use `| default('', true) | trim`.

## `test_vault_loading.yml`

Regression test for the vault-loading failure mode, hit 2026-08-25 on an Azure
CycleCloud controller running `preflight_check.yml`.

`vars/main.yml` maps the password to the vault variable:

```yaml
hammerspace_api_password: "{{ vault_hammerspace_api_password }}"
```

So loading `vars/main.yml` alone leaves the key present but its **value**
referencing an undefined var — and `hammerspace_api_password is defined`
evaluates **false**. The resulting error tells you to fix `vars/main.yml`,
which is the one file that is not at fault. `preflight_check.yml` loaded
`vars/main.yml` via `vars_files` but never included `vars/vault.yml`; every
other API-touching playbook already did.

Same class as the 2026-05-15 incident, where the `plays/` split broke
`{{ playbook_dir }}/vars/vault.yml` resolution and the password went silently
undefined.

Test cases:

| # | Scenario | Expected |
|---|----------|----------|
| 1 | A var whose value references an undefined var | `is defined` is **false**; true once the vault var exists (root cause) |
| 2 | `vars/main.yml` still maps password → vault var | Present — the premise the audit rests on |
| 3 | **Audit:** every playbook loading `vars/main.yml` + using API creds | All also load `vars/vault.yml` |
| 4 | `preflight_check.yml` specifically | Loads the vault via `repo_root`, with `failed_when: false` |

TEST 3 is the regression-prevention case: a new playbook that talks to the API
without loading the vault fails here rather than in front of a customer.

**Gotcha this test encodes:** the audit requires `vault.yml` to appear near an
`include_vars` / `vars_files` key, not merely somewhere in the file. A bare
`'vault.yml' in text` check is a false negative — `preflight_check.yml` now
mentions `vault.yml` in its own fail_msg, and that alone was enough to make a
naive audit pass while the include was absent. Found by negative-testing this
test; TEST 4 caught the reverted fix and TEST 3 did not.

## `test_run_sh_locale.sh`

Unit tests for `scripts/run.sh`. Pure bash, no Ansible required. Two sections:

### Locale fallback (8 cases)

- en_US.UTF-8 present → picks it first
- en_US.UTF-8 missing → falls back to C.UTF-8
- lowercase variants (utf8 vs UTF-8)
- ko_KR-only host → returns empty (triggers the install-instruction error path)
- empty locale list (broken libc)
- case-insensitive matching
- priority ordering when all 4 candidates are present

### ANSIBLE_LOG_PATH default (4 cases)

- No preset env vars → defaults to `${HOME}/logs/ansible-<timestamp>.log`
- `ANSIBLE_LOG_DIR=/tmp/x` → log path lands under `/tmp/x`
- User-set `ANSIBLE_LOG_PATH` wins over the default
- User-set `ANSIBLE_LOG_PATH` wins even when `ANSIBLE_LOG_DIR` is also set

Run directly:
```bash
bash tests/integration/test_run_sh_locale.sh
```

## `test_di_k8s_render.yml`

Renders the four Kubernetes manifest templates under
`roles/di/templates/` (namespace, image-pull secret, API-credentials
secret, DaemonSet) with mock vars and asserts the structural shape
required by the customer ask. No cluster, no kubeconfig.

Test cases:

| # | Scenario | Expected |
|---|----------|----------|
| 1 | `namespace.yaml.j2` | PSA enforce/audit/warn = `privileged` |
| 2 | `image_pull_secret.yaml.j2` | type `kubernetes.io/dockerconfigjson`, base64 payload present |
| 3 | `api_credentials_secret.yaml.j2` | `HAMMERSPACE_API_*` keys present, `DI_IGNORE_IP_CONFLICTS=true` |
| 4 | `daemonset.yaml.j2` | hostNetwork, ClusterFirstWithHostNet, nodeSelector, tolerations include `nvidia.com/gpu`, priorityClassName, hostAliases, initContainer `register-node`, privileged + SYS_ADMIN/NET_ADMIN/SYS_PTRACE, ports 9095+9096 with `hostPort`, cgroup+modules hostPath, run+tmp emptyDir Memory, and **the API password is NOT in the rendered file** (only referenced via Secret envFrom) |

## `test_di_k8s_validation.yml`

Static-grep validation that the k8s wiring is in place across:

| # | Scenario | Expected |
|---|----------|----------|
| 1 | `plays/di.yml` validator | accepts `'host', 'container', 'kubernetes'` |
| 2 | `container_runtime.yml` | accepts `containerd` as a passthrough (short-circuits via `end_host`) |
| 3 | `roles/di/tasks/main.yml` | k8s mode routes to `kubernetes_deploy.yml` + `kubernetes_status_label.yml`, tagged `di-k8s` + `di-k8s-status` |
| 4 | `decommission.yml` | dispatches `kubernetes_decommission.yml` when k8s mode is selected |

## `test_di_activate_tag.yml`

Tag-propagation regression (Peter's 2026-05-21 report) + extended for the
new `di-k8s` tag (2026-05-26).

Test cases:

| # | Scenario | Expected |
|---|----------|----------|
| 1 | Every `di-activate`-tagged `include_tasks` in `roles/di/tasks/main.yml` carries `apply: tags:` propagation | Pass |
| 2 | Every pre_task / post_task in `plays/di.yml` is tagged `[always]` | Pass |
| 3 | `ansible-playbook --list-tasks --tags di-activate site.yml` lists at least one activation task | Pass |
| 4 | Same propagation rule for the `di-k8s` tag | Pass |

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
| 1 | Run `detect_boot_device.yml` against the actual control host (via `include_role`, which the `script` module needs to resolve `files/`) | `_protected_disks` is non-empty; `_detected_boot_device` is in the list |
| 2 | `_protected_disks: []` and `allow_empty_protected_disks: false` | Playbook hard-fails before any mkfs |
| 3 | `_protected_disks: []` and `allow_empty_protected_disks: true` | Override bypasses the gate (diskless/netboot escape hatch) |
| 4 | Boot drive sneaks into `nvme_devices` | Safety gate in `build_raid_arrays.yml` fires |
| 5 | Clean `nvme_devices` with no overlap | Safety gate does NOT fire (no false positives) |
| 6 | The real `files/scan_disks.sh` run under `LC_ALL=ko_KR.UTF-8` (Keith's host) | Still emits `PROTECTED` lines — the script pins `LC_ALL=C` internally |

## `test_scan_disks.sh`

Unit tests for `roles/nvme_discovery/files/scan_disks.sh`, the protected-disk
resolver.

Regression test for the **2026-08-26** Azure HBv3 failure: a normal host hard-
stopped with `Boot / protected-disk detection returned an EMPTY list`. The old
detection took `findmnt -n -o SOURCE <mp>` and gated on `[ -b "$src" ]`, so any
mount whose `SOURCE` string is not a literal, existing block-device path was
silently dropped — `/dev/root`, a btrfs `/dev/sda2[/@]` subvolume, an
unevaluated `UUID=`. Every `SYSTEM_MOUNTS` entry dropped out, the list came back
empty, and the boot-drive gate refused to run.

The fix resolves through `MAJ:MIN` (which the kernel always reports) and walks
the sysfs topology. These tests drive the production functions directly through
the script's `--resolve-majmin` / `--walk` / `--path-to-name` hooks against a
fake `SCAN_SYSROOT` tree, so **they run on macOS too** — only the final
"real host scan" section self-skips on non-Linux.

| Group | Cases | Expected behavior |
|---|---|---|
| `majmin_to_name` | `8:2`, `8:1`, `8:0`, `253:0`, `0:24`, empty, garbage, unknown | Real MAJ:MIN → kernel name even when the `SOURCE` string is unusable; major `0` (tmpfs/overlay/nfs) and junk → empty |
| `walk_to_disks` | `sda2`, `sda`, `md127`, `dm-0`, missing, empty | partition → parent disk; md → members; LV → PV partition → disk; whole disk → itself |
| `path_to_name` | `sda2[/@]`, plain node, `/dev/mapper/*` symlink, `UUID=`, `overlay`, missing | btrfs subvol suffix stripped, symlink chains followed, non-paths → empty |
| real host scan (Linux only) | full script run | ≥1 `PROTECTED` line, a `ROOT` line, and **no** pseudo device (`zram*`/`ram*`/`loop*`/`fd*`) in `PROTECTED` — a pseudo device must never be able to satisfy the non-empty gate on its own |

```bash
bash tests/integration/test_scan_disks.sh
```

## Running

**Linux only** (except `test_scan_disks.sh`, which runs anywhere) — uses
`/proc/mounts`, `/proc/swaps`, `lsblk`, `findmnt`.
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

## `test_nfs_sunrpc_status.yml`

Regression test for the 2026-07-21 `'dict object' has no attribute 'rc'`
crash in `roles/nfs_setup/tasks/main.yml` (Display sunrpc pool_mode status).
`sunrpc_unload` is registered by a task *inside* a `when`-guarded block; when
the block is skipped (check mode / `pool_mode` already set /
`node_already_in_hammerspace`), the skipped task still defines the variable as
a `{skipped: true, ...}` dict **without an `rc` key**. The old status template
did `sunrpc_unload.rc | default(0)`, which hard-fails on strict ansible-core
versions before `default` can run. Fix guards the attribute:
`sunrpc_unload.rc is defined and sunrpc_unload.rc != 0`.

Test cases:

| # | Scenario | Expected |
|---|----------|----------|
| 1 | Skipped register result shape | Defined dict, `skipped: true`, **no `rc` key** (root-cause invariant, version-independent) |
| 2 | Fixed template + skipped dict | Renders `SAVED`, no crash |
| 3 | Fixed template + `rc=0` (unload succeeded) | Renders `SAVED` |
| 4 | Fixed template + `rc=1` (unload failed, module in use) | Renders `REBOOT` — the branch still fires |
| 5 | `sunrpc_unload` undefined + `pool_mode=pernode` | Renders `OK` — `is defined` short-circuits cleanly |

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
- After any change to `roles/nfs_setup/tasks/main.yml` that references a
  variable registered inside a `when`-guarded block (skipped-result dicts
  lack `rc`/`stdout`/etc. — always guard with `is defined`)
- After any change to `_cloud_az_detected` in `vars/main.yml`, to
  `roles/hammerspace_integration/tasks/az_map.yml` /
  `azure_imds_az.yml` / `add_volume.yml`, or to the AZ columns in
  `plays/storage.yml`'s instance report
- After adding a cloud provider, an inventory plugin, or a new entry to the
  `SYSTEM_MOUNTS` allow-list in
  `roles/nvme_discovery/tasks/detect_boot_device.yml`
- After adding any playbook that talks to the Hammerspace API — it must load
  `vars/vault.yml` via `{{ repo_root }}` or the password is silently undefined

Wire into pre-merge CI as `./tests/run_all.sh` — it runs every check in one
command and exits non-zero on any failure.

## Notes

- TEST 6 **of `test_run_sh_locale.sh`** needs the `ko_KR.UTF-8` locale
  generated on the host. If
  it's missing, the test will skip rather than fail spuriously.
  Generate with `localectl set-locale ko_KR.UTF-8` (RHEL/Rocky) or
  `locale-gen ko_KR.UTF-8` (Debian/Ubuntu). The test still validates
  locale-resilience because the detection forces `LC_ALL=C`
  internally regardless of the calling environment.
- The tests use `block` / `rescue` to convert expected failures into
  test passes. Real failures bubble up via the final `_test_failures`
  list.
