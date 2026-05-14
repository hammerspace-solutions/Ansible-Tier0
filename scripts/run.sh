#!/usr/bin/env bash
# Wrapper for ansible-playbook / ansible-inventory that forces a UTF-8 locale.
#
# Reason: on non-English systems (e.g. Korean ko_KR locale) Ansible aborts with
#   "ERROR: Ansible could not initialize the preferred locale: unsupported locale setting"
# This wrapper exports en_US.UTF-8 before invoking the requested ansible command.
#
# Usage:
#   ./scripts/run.sh playbook site.yml
#   ./scripts/run.sh playbook site.yml -e deploy_di=true --tags di
#   ./scripts/run.sh inventory -i inventory.yml --list
#   ./scripts/run.sh raw ansible-playbook site.yml      # pass any ansible-* command

set -euo pipefail

export LANG="en_US.UTF-8"
export LC_ALL="en_US.UTF-8"
export LANGUAGE="en_US.UTF-8"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." &> /dev/null && pwd)"
cd "${REPO_ROOT}"

if [[ $# -lt 1 ]]; then
    cat <<EOF
Usage: $0 <subcommand> [args...]

Subcommands:
  playbook   <args>   -> ansible-playbook <args>
  inventory  <args>   -> ansible-inventory <args>
  vault      <args>   -> ansible-vault <args>
  raw        <cmd>    -> exec <cmd> (full ansible-* command)
EOF
    exit 1
fi

sub="$1"
shift

case "${sub}" in
    playbook)   exec ansible-playbook "$@" ;;
    inventory)  exec ansible-inventory "$@" ;;
    vault)      exec ansible-vault "$@" ;;
    raw)        exec "$@" ;;
    *)
        echo "Unknown subcommand: ${sub}" >&2
        exit 2
        ;;
esac
