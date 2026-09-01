# pve-vm

Creates one Proxmox VM per entry in `vms`, built from an imported Debian cloud image and configured on first boot by cloud-init. Every setting a VM needs is stated in the module rather than inherited from a hand-built template, so nothing drifts without showing up in a plan.

Called once per node type, so each gets its own OpenTofu address and `tofu apply -target=module.workers` works.

## Usage

```hcl
module "workers" {
  source = "../modules/pve-vm"

  vms       = local.workers
  common    = local.common
  cores     = 4
  memory    = 8192
  disk_size = 60
  tags      = ["k8s", "worker"]
}
```

## Inputs

All are required.

| Name        | Type                             | Description                                                      |
| ----------- | -------------------------------- | ---------------------------------------------------------------- |
| `vms`       | `map(object({vm_id, ip, node}))` | VMs to create, keyed by hostname. `ip` in CIDR notation          |
| `cores`     | `number`                         | vCPU cores per VM                                                |
| `memory`    | `number`                         | Dedicated memory per VM, MiB                                     |
| `disk_size` | `number`                         | Boot disk size, GiB                                              |
| `tags`      | `list(string)`                   | Proxmox tags, sorted by the module before use                    |
| `common`    | `object`                         | Settings shared by every tier, assembled once in the root module |

Sizing applies to the whole call, so every VM in a tier comes out the same size.

### The `common` Object

| Field            | Type           | Description                                            |
| ---------------- | -------------- | ------------------------------------------------------ |
| `image_file_ids` | `map(string)`  | Proxmox host name --> imported image file ID           |
| `vm_datastore`   | `string`       | Holds the boot disk, EFI disk and cloud-init drive     |
| `network_bridge` | `string`       | Bridge the NIC attaches to                             |
| `gateway`        | `string`       | IPv4 gateway                                           |
| `dns_servers`    | `list(string)` | Passed to cloud-init                                   |
| `dns_domain`     | `string`       | Also used to build the FQDN in the output              |
| `ci_username`    | `string`       | cloud-init user created on first boot                  |
| `ci_ssh_keys`    | `list(string)` | Authorized keys for that user                          |

## Outputs

| Name  | Description                                                                                                                                               |
| ----- | --------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `vms` | Placement and sizing per VM: `fqdn`, `ip`, `node`, `cores`, `memory`. The root module merges these to build the Ansible inventory and the capacity report |

## Why These Settings

| Setting                            | Reason                                                                                                                                                                                           |
| ---------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `cpu.type = "host"`                | Exposes the physical CPU's full feature set, including every Spectre and Meltdown mitigation, without hand-maintaining a flag list. Safe only while all hosts are the same model                 |
| `memory.floating` unset            | Ballooning stays off. The kubelet reserves memory it expects to keep, and a balloon reclaiming pages underneath it causes eviction loops                                                         |
| `sort(var.tags)`                   | Proxmox returns tags sorted, so an unsorted list shows a diff on every plan                                                                                                                      |
| `iothread = true`                  | Requires the `virtio-scsi-single` controller set above it                                                                                                                                        |
| `initialization.interface = scsi1` | Keeps the cloud-init drive off the provider default of `ide2`, which means an emulated IDE controller in the guest for one read-once config drive                                                |
| `bios = "ovmf"` with `efi_disk`    | OVMF needs somewhere to persist EFI variables. Without the disk it boots but forgets its boot entries. `bios = "seabios"` with `efi_disk` removed is the fast fallback if a VM won't boot at all |
| `user_account` with no password    | Key-only login, no console fallback. A password here would sit in state in plaintext                                                                                                             |
| `migrate = true`                   | Changing a VM's `node` moves it instead of destroying and recreating it                                                                                                                          |

## The Guest Agent

`agent.enabled` is currently `true`, but `qemu-guest-agent` isn't in the Debian cloud image. The Ansible `common` role installs it after first boot.

Until it's running, Proxmox tries the agent instead of ACPI for shutdown, so create, refresh and destroy can each block until the fifteen-minute timeout expires. `stop_on_destroy = true` avoids the matching hang on `tofu destroy`. Setting `enabled = false` until Ansible has run is the safer order.

## If a VM Kernel Panics on First Boot

Debian cloud images ship `cloud-initramfs-growroot`. For whatever reason, this image expects a serial console when it expands the root filesystem on first boot, and without one a disk resize can end in `Kernel panic - not syncing: Attempted to kill init!`. Launchpad bug #1123220.

The module defines no `serial_device`. Adding one is the fix if you hit this.
