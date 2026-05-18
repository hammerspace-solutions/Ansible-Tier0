#!/usr/bin/env bash
# All-tests runner. Runs every static check + integration test in the repo.
# Exit non-zero if anything fails. Wire into CI as the single entry point.
#
# Usage:
#   ./tests/run_all.sh
#
# Prerequisites (auto-installed via pip/brew if missing):
#   - python3 with PyYAML
#   - ansible-core (ansible-playbook, ansible-galaxy)
#   - ansible-lint, yamllint (pip install)
#   - shellcheck (brew install or apt install)

set -u

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." &> /dev/null && pwd)"
cd "${REPO_ROOT}"

fail=0
report=()

step() {
    local name="$1"; shift
    printf '\n=== %s ===\n' "${name}"
    if "$@"; then
        report+=("✓ ${name}")
    else
        report+=("✗ ${name} (exit $?)")
        fail=$((fail+1))
    fi
}

# -- A: YAML syntax sweep -----------------------------------------------------
yaml_sweep() {
    local f bad=0
    while IFS= read -r f; do
        python3 -c "import yaml; yaml.safe_load(open('$f'))" 2>/dev/null \
            || { echo "  ✗ $f"; bad=$((bad+1)); }
    done < <(find . -type f \( -name '*.yml' -o -name '*.yaml' \) \
               -not -path './.git/*' -not -path './payload/*')
    return $bad
}
step "YAML syntax (all *.yml / *.yaml)" yaml_sweep

# -- B: bash syntax sweep -----------------------------------------------------
bash_sweep() {
    local f bad=0
    while IFS= read -r f; do
        bash -n "$f" 2>/dev/null || { echo "  ✗ $f"; bad=$((bad+1)); }
    done < <(find . -type f -name '*.sh' -not -path './.git/*' -not -path './payload/*')
    return $bad
}
step "bash -n on all *.sh" bash_sweep

# -- C: shellcheck (if available) --------------------------------------------
if command -v shellcheck >/dev/null 2>&1; then
    step "shellcheck (scripts/, tests/integration/*.sh)" \
        shellcheck scripts/run.sh tests/integration/test_run_sh_locale.sh
else
    echo "skipping shellcheck (not installed)"
fi

# -- D: yamllint (if available) ----------------------------------------------
if command -v yamllint >/dev/null 2>&1; then
    step "yamllint (plays/, scripts/, tests/, this-session role files)" \
        yamllint plays/ scripts/ tests/integration/ \
                 roles/nvme_discovery/tasks/detect_boot_device.yml \
                 roles/raid_setup/tasks/main.yml \
                 roles/perf_tuning/
else
    echo "skipping yamllint (not installed)"
fi

# -- E: ansible-playbook --syntax-check --------------------------------------
syntax_sweep() {
    local pb bad=0
    for pb in site.yml plays/*.yml tests/integration/test_*.yml; do
        ansible-playbook --syntax-check "$pb" -i localhost, >/dev/null 2>&1 \
            && echo "  ✓ $pb" || { echo "  ✗ $pb"; bad=$((bad+1)); }
    done
    return $bad
}
step "ansible-playbook --syntax-check (site + plays + tests)" syntax_sweep

# -- F: integration tests (Ansible) ------------------------------------------
integration_sweep() {
    local t bad=0
    for t in tests/integration/test_*.yml; do
        if ansible-playbook "$t" -i localhost, -c local >/tmp/run_all.$$.out 2>&1; then
            grep -E "PASSED \(|FAILED \(" /tmp/run_all.$$.out | head -2 \
                | sed "s|^|  $(basename "$t"): |"
        else
            echo "  ✗ $(basename "$t") failed"
            grep -E "fatal|FAILED" /tmp/run_all.$$.out | head -3 | sed 's|^|    |'
            bad=$((bad+1))
        fi
    done
    rm -f /tmp/run_all.$$.out
    return $bad
}
step "Integration tests (boot-drive, RAID idempotency, protected-split)" integration_sweep

# -- G: locale fallback unit tests -------------------------------------------
step "Locale fallback unit tests (run.sh)" \
    bash tests/integration/test_run_sh_locale.sh

# -- Summary ------------------------------------------------------------------
printf '\n=============================================\n'
printf 'SUMMARY\n'
printf '=============================================\n'
for line in "${report[@]}"; do
    printf '  %s\n' "${line}"
done

if [[ ${fail} -eq 0 ]]; then
    printf '\nAll checks passed.\n'
    exit 0
else
    printf '\n%d check(s) failed.\n' "${fail}"
    exit 1
fi
