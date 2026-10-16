output "k8s_nodes" {
  value = { for k, v in local.nodes : k => "${v.ip}  (${v.role}, vmid ${v.vmid} on ${v.node})" }
}
