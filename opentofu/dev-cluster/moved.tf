# Worker hostnames changed from d-k8s-wk* to d-k8s-wn*, matching the Ansible
# inventory. The map key is the for_each key, so without these the rename reads
# as six destroys and six creates. With them it is a state move plus an in-place
# rename of the VM in Proxmox.
#
# Safe to delete once every environment has applied it.

moved {
  from = module.workers.proxmox_virtual_environment_vm.this["d-k8s-wk01"]
  to   = module.workers.proxmox_virtual_environment_vm.this["d-k8s-wn01"]
}

moved {
  from = module.workers.proxmox_virtual_environment_vm.this["d-k8s-wk02"]
  to   = module.workers.proxmox_virtual_environment_vm.this["d-k8s-wn02"]
}

moved {
  from = module.workers.proxmox_virtual_environment_vm.this["d-k8s-wk03"]
  to   = module.workers.proxmox_virtual_environment_vm.this["d-k8s-wn03"]
}

moved {
  from = module.workers.proxmox_virtual_environment_vm.this["d-k8s-wk04"]
  to   = module.workers.proxmox_virtual_environment_vm.this["d-k8s-wn04"]
}

moved {
  from = module.workers.proxmox_virtual_environment_vm.this["d-k8s-wk05"]
  to   = module.workers.proxmox_virtual_environment_vm.this["d-k8s-wn05"]
}

moved {
  from = module.workers.proxmox_virtual_environment_vm.this["d-k8s-wk06"]
  to   = module.workers.proxmox_virtual_environment_vm.this["d-k8s-wn06"]
}
