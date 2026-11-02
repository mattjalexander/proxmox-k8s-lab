#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

SOPS_AGE_KEY="$(op read 'op://Homelab/age/private_key')"  # value only in this process tree
export SOPS_AGE_KEY

SSH_HOST_CA_KEY="$(op read 'op://Homelab/ssh-host-ca/private_key')"
export SSH_HOST_CA_KEY

exec ansible-playbook site.yml "$@" --check --diff
