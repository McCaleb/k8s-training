locals {
  inventory_groups = {
    k8s_load_balancers = module.load_balancers.vms
    k8s_control_plane  = module.control_plane.vms
    k8s_workers        = module.workers.vms
  }

  # Every VM, taken from the module outputs so the capacity figures below can
  # never drift from the sizing actually applied.
  cluster = merge(
    module.load_balancers.vms,
    module.control_plane.vms,
    module.workers.vms,
  )
}

output "ansible_inventory" {
  description = "Ansible inventory. Write it out with: tofu output -raw ansible_inventory > ../../ansible/inventory/cluster.yml"

  value = yamlencode({
    for group, vms in local.inventory_groups : group => {
      hosts = { for vm in values(vms) : vm.fqdn => { ansible_host = vm.ip } }
    }
  })
}

output "capacity" {
  description = "vCPU and RAM committed per Proxmox host, to check for over-subscription"

  value = {
    for host in distinct([for vm in local.cluster : vm.node]) : host => {
      vms       = length([for vm in local.cluster : vm if vm.node == host])
      vcpus     = sum([for vm in local.cluster : vm.cores if vm.node == host])
      memory_gb = sum([for vm in local.cluster : vm.memory if vm.node == host]) / 1024
    }
  }
}
