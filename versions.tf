terraform {
  required_version = ">= 1.6"
  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = ">= 0.66" # exact version pinned by .terraform.lock.hcl - commit that file
    }
  }
}
