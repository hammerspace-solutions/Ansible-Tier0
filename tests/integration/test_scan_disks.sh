#!/usr/bin/env bash
# Unit tests for roles/nvme_discovery/files/scan_disks.sh.
#
# Regression test for the 2026-08-26 Azure HBv3 failure:
#
#   TASK [nvme_discovery : FAIL if no protected disks were detected ...]
#   Boot / protected-disk detection returned an EMPTY list (no mounted FS, no swap).
#
# The old detection resolved a mountpoint with `findmnt -n -o SOURCE <mp>` and
# then gated on `[ -b "$src" ]`. Every mount whose SOURCE string is not a
# literal, existing block-device path — /dev/root, a btrfs "/dev/sda2[/@]"
# subvolume, an unevaluated UUID= source — was SILENTLY dropped, so the whole
# protected list came back empty and the boot-drive safety gate hard-stopped a
# perfectly normal host.
#
# These tests drive the production functions directly (via the script's
# --resolve-majmin / --walk / --path-to-name hooks) against a fake sysfs tree,
# so they run anywhere — including macOS, where `readlink -f` does not exist.
#
# Usage:  bash tests/integration/test_scan_disks.sh

set -u

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." > /dev/null 2>&1 && pwd)"
SCAN="${REPO_ROOT}/roles/nvme_discovery/files/scan_disks.sh"

pass=0
fail=0

FAKE=$(mktemp -d "${TMPDIR:-/tmp}/scan_disks_test.XXXXXX")
trap 'rm -rf "${FAKE}"' EXIT

check() {
    local name="$1" expected="$2" actual="$3"
    if [[ "${actual}" == "${expected}" ]]; then
        printf '  ✓ %s\n' "${name}"
        pass=$((pass + 1))
    else
        printf '  ✗ %s\n      expected: %q\n      actual:   %q\n' \
            "${name}" "${expected}" "${actual}"
        fail=$((fail + 1))
    fi
}

# ---------------------------------------------------------------------------
# Build a fake sysfs mirroring a realistic host:
#
#   sda                boot disk
#   ├─ sda1            /boot/efi
#   └─ sda2            /  (this is the one reported as /dev/root)
#   sdb, sdc           members of md127
#   sdd
#   └─ sdd2            LVM PV backing dm-0
#   zram0              swap  (pseudo — must never count as a protected disk)
# ---------------------------------------------------------------------------
build_fake_sys() {
    local d="${FAKE}/sys"
    mkdir -p "${d}/class/block" "${d}/dev/block"

    # Whole disks
    local disk
    for disk in sda sdb sdc sdd zram0; do
        mkdir -p "${d}/devices/virtual/block/${disk}"
        ln -s "../../devices/virtual/block/${disk}" "${d}/class/block/${disk}"
    done

    # Partitions live UNDER their parent disk in the device tree — that
    # parent-directory relationship is exactly what walk_to_disks() follows.
    local part
    for part in sda1 sda2 sdd2; do
        local parent="${part:0:3}"
        mkdir -p "${d}/devices/virtual/block/${parent}/${part}"
        : > "${d}/devices/virtual/block/${parent}/${part}/partition"
        ln -s "../../devices/virtual/block/${parent}/${part}" "${d}/class/block/${part}"
    done

    # md127 over sdb + sdc
    mkdir -p "${d}/devices/virtual/block/md127/slaves"
    ln -s "../../devices/virtual/block/md127" "${d}/class/block/md127"
    ln -s "../../sdb" "${d}/devices/virtual/block/md127/slaves/sdb"
    ln -s "../../sdc" "${d}/devices/virtual/block/md127/slaves/sdc"

    # dm-0 (LVM LV) over the sdd2 PV
    mkdir -p "${d}/devices/virtual/block/dm-0/slaves"
    ln -s "../../devices/virtual/block/dm-0" "${d}/class/block/dm-0"
    ln -s "../../sdd/sdd2" "${d}/devices/virtual/block/dm-0/slaves/sdd2"

    # MAJ:MIN index — the kernel always populates this, which is why the fix
    # resolves through it instead of through the SOURCE string.
    ln -s "../../devices/virtual/block/sda"      "${d}/dev/block/8:0"
    ln -s "../../devices/virtual/block/sda/sda1" "${d}/dev/block/8:1"
    ln -s "../../devices/virtual/block/sda/sda2" "${d}/dev/block/8:2"
    ln -s "../../devices/virtual/block/md127"    "${d}/dev/block/9:127"
    ln -s "../../devices/virtual/block/dm-0"     "${d}/dev/block/253:0"
}

build_fake_dev() {
    local d="${FAKE}/dev"
    mkdir -p "${d}/mapper"
    local n
    for n in sda sda1 sda2 sdb sdc sdd sdd2 dm-0 zram0; do
        : > "${d}/${n}"
    done
    ln -s "../dm-0" "${d}/mapper/rootvg-lv_root"
}

build_fake_sys
build_fake_dev

run() {
    SCAN_SYSROOT="${FAKE}/sys" SCAN_DEVROOT="${FAKE}/dev" \
        SCAN_PROCROOT="${FAKE}/proc" bash "${SCAN}" "$@" 2>/dev/null
}

printf '\n--- majmin_to_name (the /dev/root fix) ---\n'
# THE regression case: root reports SOURCE=/dev/root, which has no device node,
# so `[ -b ]` rejected it. MAJ:MIN 8:2 resolves regardless.
check "8:2 -> sda2 (root partition, unusable SOURCE string)" "sda2" "$(run --resolve-majmin 8:2)"
check "8:1 -> sda1 (ESP)"                                    "sda1" "$(run --resolve-majmin 8:1)"
check "8:0 -> sda (whole disk)"                              "sda"  "$(run --resolve-majmin 8:0)"
check "253:0 -> dm-0 (LVM LV)"                               "dm-0" "$(run --resolve-majmin 253:0)"
# Major 0 is the anonymous major: tmpfs / overlay / nfs have no block device.
check "0:24 -> empty (tmpfs, anonymous major)"               ""     "$(run --resolve-majmin 0:24)"
check "empty arg -> empty"                                   ""     "$(run --resolve-majmin '')"
check "garbage -> empty"                                     ""     "$(run --resolve-majmin 'not-a-majmin')"
check "unknown MAJ:MIN -> empty"                             ""     "$(run --resolve-majmin '99:99')"

printf '\n--- walk_to_disks (topology walk) ---\n'
check "sda2 -> sda (partition to parent disk)"      "sda"      "$(run --walk sda2)"
check "sda -> sda (already a whole disk)"           "sda"      "$(run --walk sda)"
check "md127 -> sdb sdc (array to members)"         $'sdb\nsdc' "$(run --walk md127)"
check "dm-0 -> sdd (LV to PV partition to disk)"    "sdd"      "$(run --walk dm-0)"
check "nonexistent -> empty"                        ""         "$(run --walk nosuchdev)"
check "empty arg -> empty"                          ""         "$(run --walk '')"

printf '\n--- path_to_name (SOURCE string normalisation) ---\n'
check "btrfs subvolume suffix is stripped" "sda2" "$(run --path-to-name "${FAKE}/dev/sda2[/@]")"
check "plain device node"                  "sda2" "$(run --path-to-name "${FAKE}/dev/sda2")"
check "/dev/mapper symlink is followed"    "dm-0" "$(run --path-to-name "${FAKE}/dev/mapper/rootvg-lv_root")"
check "UUID= source -> empty"              ""     "$(run --path-to-name 'UUID=1234-abcd')"
check "overlay -> empty"                   ""     "$(run --path-to-name 'overlay')"
check "missing node -> empty"              ""     "$(run --path-to-name "${FAKE}/dev/sdz9")"

printf '\n--- real host scan ---\n'
if [[ "$(uname -s)" == "Linux" ]]; then
    real_out=$(bash "${SCAN}" 2>/dev/null)
    if grep -q '^PROTECTED ' <<< "${real_out}"; then
        printf '  ✓ real scan produced at least one PROTECTED disk\n'
        pass=$((pass + 1))
    else
        printf '  ✗ real scan produced NO PROTECTED disks (this is the reported bug)\n'
        printf '      output: %q\n' "${real_out}"
        fail=$((fail + 1))
    fi
    if grep -q '^ROOT ' <<< "${real_out}"; then
        printf '  ✓ real scan identified the root disk\n'
        pass=$((pass + 1))
    else
        printf '  ✗ real scan did not identify a ROOT disk\n'
        fail=$((fail + 1))
    fi
    # zram swap must not be able to satisfy the non-empty gate on its own.
    if grep -Eq '^PROTECTED (zram|ram|loop|fd)[0-9]+$' <<< "${real_out}"; then
        printf '  ✗ pseudo device leaked into PROTECTED (disarms the safety gate)\n'
        fail=$((fail + 1))
    else
        printf '  ✓ no pseudo devices in PROTECTED\n'
        pass=$((pass + 1))
    fi
else
    printf '  – skipped (real scan needs Linux; ran on %s)\n' "$(uname -s)"
fi

printf '\n=============================================\n'
printf 'scan_disks.sh: %d passed, %d failed\n' "${pass}" "${fail}"
printf '=============================================\n'
[[ ${fail} -eq 0 ]]
