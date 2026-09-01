# One Proxmox VM per entry in var.vms, built from an imported Debian cloud
# image. Every setting a VM needs is stated here. Nothing is inherited from a
# hand-built template, so nothing can silently drift.

resource "proxmox_virtual_environment_vm" "this" {
  for_each = var.vms

  name        = each.key
  vm_id       = each.value.vm_id
  node_name   = each.value.node
  description = "Managed by OpenTofu"
  tags        = sort(var.tags) # Proxmox sorts tags; matching it avoids a permanent diff

  on_boot = true
  started = true

  # Changing a VM's node in var.vms migrates it rather than destroying and
  # recreating it.
  migrate = true

  agent {
    enabled = true
  }
  stop_on_destroy = true

  # UEFI. efi_disk gives the guest somewhere to persist EFI variables; without
  # it OVMF boots but forgets its boot entries. If a VM will not boot at all,
  # switching to bios = "seabios" and deleting efi_disk is the fast fallback.
  bios    = "ovmf"
  machine = "q35"

  efi_disk {
    datastore_id = var.common.vm_datastore
    type         = "4m"
  }

  # type = "host" exposes the physical CPU's full feature set, including every
  # Spectre and Meltdown mitigation, without hand-maintaining a flag list.
  # Safe only while every host is the same model; live migration to a
  # different CPU would fail. Use "x86-64-v2-AES" if the fleet stops matching.
  cpu {
    cores   = var.cores
    sockets = 1
    type    = "host"
  }

  memory {
    dedicated = var.memory
    # floating is omitted, so ballooning stays off. kubelet reserves memory it
    # expects to keep; a balloon driver reclaiming pages underneath it causes
    # eviction loops.
  }

  scsi_hardware = "virtio-scsi-single"
  boot_order    = ["scsi0"]

  disk {
    datastore_id = var.common.vm_datastore
    interface    = "scsi0"
    size         = var.disk_size
    cache        = "none"
    discard      = "on" # pass TRIM through so thin storage reclaims space
    iothread     = true # requires the virtio-scsi-single controller above
    ssd          = true

    import_from = var.common.image_file_ids[each.value.node]
  }

  initialization {
    datastore_id = var.common.vm_datastore

    # Cloud-init drive on the same virtio-scsi controller as the boot disk.
    # Left unset the provider defaults to ide2, which means an emulated IDE
    # controller in the guest for one read-once config drive.
    interface = "scsi1"

    dns {
      servers = var.common.dns_servers
      domain  = var.common.dns_domain
    }

    ip_config {
      ipv4 {
        address = each.value.ip
        gateway = var.common.gateway
      }
    }

    user_account {
      username = var.common.ci_username
      keys     = var.common.ci_ssh_keys
      # No password, so these are SSH-key-only with no console fallback.
      # Setting one here would store it in state in plaintext.
    }
  }

  network_device {
    bridge = var.common.network_bridge
    model  = "virtio"
  }

  operating_system {
    type = "l26"
  }

}
