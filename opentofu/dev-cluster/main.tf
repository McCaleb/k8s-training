terraform {
  required_version = ">= 1.6"

  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "~> 0.111.0"
    }
  }
}

# Proxmox API token is read from the environment for now: 'export PROXMOX_VE_API_TOKEN='tofu@pve!dev-cluster=<uuid>'
provider "proxmox" {
  endpoint = "https://172.16.1.201:8006/"
  insecure = true
}

locals {
  load_balancers = {
    d-k8s-lb01 = { vm_id = 1001, ip = "172.16.1.101/24", node = "node02" }
    d-k8s-lb02 = { vm_id = 1002, ip = "172.16.1.102/24", node = "node04" }
  }

  control_nodes = {
    d-k8s-cn01 = { vm_id = 1004, ip = "172.16.1.104/24", node = "node01" }
    d-k8s-cn02 = { vm_id = 1005, ip = "172.16.1.105/24", node = "node02" }
    d-k8s-cn03 = { vm_id = 1006, ip = "172.16.1.106/24", node = "node03" }
  }

  workers = {
    d-k8s-wn01 = { vm_id = 1007, ip = "172.16.1.107/24", node = "node01" }
    d-k8s-wn02 = { vm_id = 1008, ip = "172.16.1.108/24", node = "node02" }
    d-k8s-wn03 = { vm_id = 1009, ip = "172.16.1.109/24", node = "node03" }
    d-k8s-wn04 = { vm_id = 1010, ip = "172.16.1.110/24", node = "node04" }
    d-k8s-wn05 = { vm_id = 1011, ip = "172.16.1.111/24", node = "node03" }
    d-k8s-wn06 = { vm_id = 1012, ip = "172.16.1.112/24", node = "node04" }
  }

  all_vms = merge(local.load_balancers, local.control_nodes, local.workers)

  image_url  = "https://cloud.debian.org/images/cloud/trixie/20260826-2582/debian-13-genericcloud-amd64-20260826-2582.qcow2"
  image_name = basename(local.image_url)

  # image_datastore needs "Import" content type enabled: Datacenter > Storage > local > Edit > Content
  image_datastore = "local"
  vm_datastore    = "vmdata00"
}

# `local` is per-host storage, so the image must exist on every Proxmox host.
# toset() collapses the placement maps to distinct hosts.
resource "proxmox_download_file" "debian" {
  for_each = toset([for v in local.all_vms : v.node])

  node_name    = each.value
  datastore_id = local.image_datastore
  content_type = "import"
  url          = local.image_url
  file_name    = local.image_name

  # Don't silently re-download and replace the image.
  overwrite = false
}

locals {
  common = {
    image_file_ids = { for host, file in proxmox_download_file.debian : host => file.id }
    vm_datastore   = local.vm_datastore
    network_bridge = "vmbr0"
    gateway        = "172.16.1.1"
    dns_servers    = ["172.16.1.1"]
    dns_domain     = "opnsense.lab"
    ci_username    = "local_admin"
    ci_ssh_keys    = ["ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKNwXz4sQ3IgKkPIy/Zycu2EzjWQsmX6z67M7HbaxLbp luke@minisforum-bd895i"]
  }
}

# Each tier is its own module call so it has its own address:
#   tofu apply -target=module.workers
module "load_balancers" {
  source = "../modules/pve-vm"

  vms       = local.load_balancers
  common    = local.common
  cores     = 2
  memory    = 2048
  disk_size = 20
  tags      = ["k8s", "lb"]
}

module "control_plane" {
  source = "../modules/pve-vm"

  vms       = local.control_nodes
  common    = local.common
  cores     = 4
  memory    = 8192
  disk_size = 60
  tags      = ["control-plane", "k8s"]
}

module "workers" {
  source = "../modules/pve-vm"

  vms       = local.workers
  common    = local.common
  cores     = 4
  memory    = 8192
  disk_size = 60
  tags      = ["k8s", "worker"]
}
