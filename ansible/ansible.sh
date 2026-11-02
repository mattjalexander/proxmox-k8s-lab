#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
SOPS_AGE_KEY="$(op read 'op://Homelab/age/private_key')"  # value only in this process tree
export SOPS_AGE_KEY
exec ansible-playbook site.yml "$@" --check --diff
