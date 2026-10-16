locals {
  # One place to size/place every node. Edit here, re-apply — RAM/cores change in place,
  # disk grows only (never shrink). memory is MiB. Templates: 9000 on alpharius, 9001 on omegon.
  nodes = {
    "k8s-cp-1" = { vmid = 110, node = "alpharius", template = 9000, role = "control-plane", cores = 4, memory = 8192, disk = 40, ip = "192.168.3.110" }
    "k8s-w-1"  = { vmid = 111, node = "alpharius", template = 9000, role = "worker", cores = 4, memory = 12288, disk = 60, ip = "192.168.3.111" }
    "k8s-w-2"  = { vmid = 112, node = "omegon", template = 9001, role = "worker", cores = 4, memory = 12288, disk = 60, ip = "192.168.3.112" }
  }
}

resource "proxmox_virtual_environment_vm" "k8s" {
  for_each = local.nodes

  name      = each.key
  node_name = each.value.node
  vm_id     = each.value.vmid
  tags      = ["k8s", each.value.role, "terraform"]
  on_boot   = true

  clone {
    vm_id = each.value.template # template must live on the same node
    full  = true
  }

  cpu {
    cores = each.value.cores
    type  = "host"
  }
  memory { dedicated = each.value.memory }

  disk {
    datastore_id = "local-lvm"
    interface    = "scsi0" # matches the template's disk
    size         = each.value.disk
  }

  network_device { 
	bridge = "vmbr2"
	vlan_id = 3
  } # LAN bridge — NOT vmbr0

  # qemu-guest-agent is NOT in the Debian cloud image, so leave the agent OFF for now,
  # or `terraform apply` hangs waiting for the guest to report an IP. Static IPs below
  # mean we don't need it. (Enable later once baked into the template.)
  agent { enabled = false }

  initialization {
    dns {
	servers = ["192.168.3.1"]
    }
    ip_config {
      ipv4 {
        address = "${each.value.ip}/24"
        gateway = var.gateway
      }
    
    }
    user_account {
      username = var.ci_user
      keys     = [trimspace(var.ci_ssh_public_key)]
    }
  }
}
