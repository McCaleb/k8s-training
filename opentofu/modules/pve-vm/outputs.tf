output "vms" {
  description = "This tier's VMs with placement and sizing, for inventory and capacity reporting"

  value = {
    for name, vm in proxmox_virtual_environment_vm.this : name => {
      fqdn   = "${name}.${var.common.dns_domain}"
      ip     = var.vms[name].ip
      node   = vm.node_name
      cores  = var.cores
      memory = var.memory
    }
  }
}
