variable "vms" {
  description = "VMs in this tier, keyed by hostname"
  type = map(object({
    vm_id = number
    ip    = string # CIDR (e.g. 172.16.1.107/24)
    node  = string
  }))
}

variable "cores" {
  description = "vCPU cores per VM"
  type        = number
}

variable "memory" {
  description = "Dedicated memory per VM in MiB"
  type        = number
}

variable "disk_size" {
  description = "Boot disk size in GiB"
  type        = number
}

variable "tags" {
  description = "Proxmox tags. Sorted by the module, since Proxmox sorts them and an unsorted list shows a permanent diff."
  type        = list(string)
}

variable "common" {
  description = "Settings shared by every tier, assembled once in the root module"
  type = object({
    image_file_ids = map(string) # Proxmox host name => imported image file ID
    vm_datastore   = string
    network_bridge = string
    gateway        = string
    dns_servers    = list(string)
    dns_domain     = string
    ci_username    = string
    ci_ssh_keys    = list(string)
  })
}
