provider "proxmox" {
  endpoint  = var.proxmox_endpoint
  api_token = var.proxmox_api_token # "terraform@pve!provider=<secret>"
  insecure  = true                  # Proxmox ships a self-signed cert
}
