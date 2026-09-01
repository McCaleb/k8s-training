# pve-vm

- Creates a group of Proxmox VMs from an imported Debian cloud image, configured on first boot by cloud-init.

- Called once per cluster node type, so that each gets its own OpenTofu address. 
  * This makes `tofu apply -target=module.workers` possible.

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

| Name        | Type | Description |
|-------------|----------------------------------|----------------------------------------------------------|
| `vms`       | `map(object({vm_id, ip, node}))` | VMs to create, keyed by hostname. `ip` in CIDR notation. |
| `cores`     | `number`                         | vCPU cores per VM                                        |
| `memory`    | `number`                         | Dedicated memory per VM, MiB                             |
| `disk_size` | `number`                         | Boot disk size, GiB                                      |
| `tags`      | `list(string)`                   | Proxmox tags, sorted by the module before use            |
| `common`    | `object`                         | Shared by all types, assembled in the root module        |


## Notes

### `serial_device` is required

- Debian cloud images ship `cloud-initramfs-growroot`.
- For whatever reason, this image expects a serial console when it expands the root filesystem on first boot. 
- Without one, any disk resize causes `Kernel panic - not syncing: Attempted to kill init!`. 
- Upstream Launchpad bug #1123220.

### Ballooning is off

- `memory.floating` is unset, which disables the balloon driver. 
- kubelet reserves memory it expects to keep, and a balloon reclaiming pages underneath it might cause eviction loops.

### `agent.enabled = false`

- `qemu-guest-agent` is not in the Debian cloud image. 
- Setting this to `true` before the agent is running makes Proxmox try to use it instead of ACPI for shutdown.
- That means every create, refresh and destroy blocks until the fifteen-minute timeout expires. 
- `stop_on_destroy` avoids the matching hang on `tofu destroy`. 
- Ansible `common` role installs the agent after first boot.

### `iothread` and `scsi_hardware`

`iothread = true` requires the `virtio-scsi-single` controller.

### `tags` are sorted

- Proxmox returns tags in *sorted* order. 
- That means an unsorted list in the configuration is different on every plan. 
- The module sorts them so call sites do not have to remember.


