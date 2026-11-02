#!/usr/bin/env bash
set -euo pipefail
TF_VAR_proxmox_api_token="$(op read 'op://Homelab/terraform/token')"
export TF_VAR_proxmox_api_token
TF_VAR_ci_ssh_public_key="$(cat ~/.ssh/id_ed25519.pub)"
export TF_VAR_ci_ssh_public_key 
terraform init
terraform plan
# terraform apply
