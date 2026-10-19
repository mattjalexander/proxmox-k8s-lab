resource "local_file" "ansible_inventory" {
  content = templatefile("${path.module}/templates/inventory.ini.tftpl", {
    vms = local.nodes
  })
  filename = "${path.module}/ansible/inventory.ini"
}
