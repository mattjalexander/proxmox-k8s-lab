variable "proxmox_endpoint" {
  type    = string
  default = "https://192.168.1.97:8006/"
}

variable "proxmox_api_token" {
  type      = string
  sensitive = true # supply via TF_VAR_proxmox_api_token
}

variable "gateway" {
  type    = string
  default = "192.168.3.1"
}

variable "ci_user" {
  type    = string
  default = "debian"
}

variable "ci_ssh_public_key" {
  type = string # ~majelix/.ssh/id_ed25519.pub
}
