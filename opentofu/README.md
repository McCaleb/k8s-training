# OpenTofu

Provisions 11 virtual machines for the `d-k8s` Kubernetes cluster on Proxmox VE.

OpenTofu builds the machines, Ansible configures them.

Every VM is built from an upstream Debian cloud image.

## Layout

```
opentofu/
├── dev-cluster/        root module: one state file, one cluster
│   ├── main.tf         provider, placement, image download, module calls
│   └── outputs.tf      Ansible inventory and capacity report
└── modules/pve-vm/     the VM definition, called once per node type
```

## What Gets Built

| Tier           | Module                  | Count | vCPU | RAM   | Disk   | Addresses          |
| -------------- | ----------------------- | ----- | ---- | ----- | ------ | ------------------ |
| Load balancers | `module.load_balancers` | 2     | 2    | 2 GiB | 20 GiB | `172.16.1.101-102` |
| Control plane  | `module.control_plane`  | 3     | 4    | 8 GiB | 60 GiB | `172.16.1.104-106` |
| Workers        | `module.workers`        | 6     | 4    | 8 GiB | 60 GiB | `172.16.1.107-112` |

- `172.16.1.103` is left free for the keepalived vIP, which the `load_balancers` Ansible role manages.

- `cores`, `memory` and `disk_size` are set once on each module call, so every VM in a tier comes out the same size. The maps in `main.tf` only hold `vm_id`, `ip` and `node`.

- So there's no way to give one worker more RAM than the other five. That takes a fourth module call with its own map and its own sizing, plus an entry in the `merge()` in `outputs.tf`. Miss that last step and the new VM won't show up in the inventory or the capacity report. If per-VM sizing ever comes up for real, moving those three settings into the maps is the cleaner fix.

## Requirements

- OpenTofu 1.6 or newer.
- A Proxmox VE cluster with four hosts named `node01` through `node04`, matching the directory names under `/etc/pve/nodes/`.
- A shared datastore named `vmdata00` for VM disks.
- The `local` datastore with the `import` content type enabled. See below.
- A Proxmox API token. See [Proxmox API Token](#proxmox-api-token).

The provider is `bpg/proxmox`, pinned to `~> 0.111.0`. Proxmox publishes no official Terraform or OpenTofu provider, and this one is pre-1.0 and states that minor releases may break compatibility, so the pin is deliberate. `.terraform.lock.hcl` is committed for the same reason: every run resolves the same provider build.

The endpoint is hardcoded to `https://172.16.1.201:8006/` with `insecure = true`, since Proxmox ships a self-signed certificate.

### Import Content Type

The Debian image is downloaded using Proxmox's `import` content type, which isn't enabled by default. In the web UI: **Datacenter --> Storage --> local --> Edit --> Content**, then tick **Import**.

The image is roughly 340 MB, and `local` is per-host storage, so a copy is downloaded onto each of the four hosts.

## Proxmox API Token

### Create

Create the role. Run on any node, as root:

    ```sh
    pveum role add TofuProvisioner --privs \
    "Datastore.Allocate Datastore.AllocateSpace Datastore.AllocateTemplate Datastore.Audit \
    SDN.Use Sys.Audit Sys.Modify \
    VM.Allocate VM.Audit VM.Config.CDROM VM.Config.Cloudinit VM.Config.CPU \
    VM.Config.Disk VM.Config.HWType VM.Config.Memory VM.Config.Network \
    VM.Config.Options VM.Migrate VM.PowerMgmt VM.GuestAgent.Audit"
    ```

Then add a user in that role, and a token:

    ```sh
    pveum user add tofu@pve
    pveum aclmod / -user tofu@pve -role TofuProvisioner
    pveum user token add tofu@pve dev-cluster --privsep 0
    ```

That prints the secret:

    ```
    ┌──────────────┬──────────────────────────────────────┐
    │ key          │ value                                │
    ╞══════════════╪══════════════════════════════════════╡
    │ full-tokenid │ tofu@pve!dev-cluster                 │
    ├──────────────┼──────────────────────────────────────┤
    │ info         │ {"privsep":"0"}                      │
    ├──────────────┼──────────────────────────────────────┤
    │ value        │ 123cb2e7-45ab-6d7d-b89a-98765f84c3f2 │
    └──────────────┴──────────────────────────────────────┘
    ```

**The token secret prints exactly once and can't be retrieved again.**

### Verify

    ```sh
    pveum acl list
    pveum user list
    pveum role list
    ```

### Teardown

    ```sh
    pveum acl delete / --users tofu@pve --roles TofuProvisioner
    pveum user token delete tofu@pve dev-cluster
    pveum user delete tofu@pve
    pveum role delete TofuProvisioner
    ```

Deleting the user should take its tokens with it, but removing the token first means you know for sure.

## Usage

    ```sh
    cd dev-cluster
    export PROXMOX_VE_API_TOKEN='tofu@pve!dev-cluster=<uuid>'

    tofu init
    tofu plan -out=cluster.tfplan
    tofu apply -parallelism=1 cluster.tfplan
    ```

`-parallelism=1` is needed on my cluster: creating several VMs at once triggers lock errors from Proxmox I/O contention. YMMV.

### First Run

Don't apply all el11even on the first attempt. Prove one machine first:

    ```sh
    tofu apply -target='module.workers.proxmox_virtual_environment_vm.this["d-k8s-wn01"]'
    ```

If it boots and answers on `172.16.1.107`, drop the `-target` and apply the rest.

VMs come up with the cloud-init user `local_admin` and an SSH key (no password).

### Working on One Node Type

Each node type is a separate module call, so each has its own address:

    ```sh
    tofu apply   -target=module.workers
    tofu destroy -target=module.workers
    tofu apply   -target=module.load_balancers -target=module.control_plane
    ```

`-target` applies a partial plan and skips branches of the dependency graph. To rebuild a single machine, use `-replace` instead. That will compute a full plan and mark one resource for recreation:

    ```sh
    tofu apply -replace='module.workers.proxmox_virtual_environment_vm.this["d-k8s-wn03"]'
    ```

### Checking Capacity

    ```sh
    tofu output capacity
    ```

Reports committed vCPU and RAM per Proxmox host. The figures are derived from the module outputs, so they can't disagree with the sizing actually applied. 

vCPU over-subscription should be fine, to an extent. RAM over-subscription isn't.

### Handing Off to Ansible

    ```sh
    tofu output -raw ansible_inventory
    ```

This emits a YAML inventory built from the module outputs, one group per node type, with `ansible_host` set from the placement maps.

It isn't yet wired into the Ansible side. The output uses the group names `k8s_load_balancers`, `k8s_control_plane` and `k8s_workers`, while the roles and templates in `ansible/` expect `load_balancers`, `control_nodes` and `worker_nodes`. Reconcile the names before redirecting `ansible/inventory.yml` at this output. See [Known Gaps](#known-gaps).

## Adding or Moving a VM

Edit the relevant map in `dev-cluster/main.tf`. Each entry is keyed by hostname and carries three fields:

    ```hcl
    d-k8s-wn07 = { vm_id = 1013, ip = "172.16.1.113/24", node = "node01" }
    ```

`node` is the physical Proxmox host, matching the names under `/etc/pve/nodes/`. Because `migrate = true` is set on the resource, changing a VM's `node` moves it rather than destroying and recreating it.

## Notes

**The image is pinned to a dated Debain build.** 
  - The filename is derived from the URL, so bumping the date is a single edit. `overwrite = false` on the download keeps a re-run from silently replacing the image underneath existing VMs.

**UEFI with an `efi_disk`.** 
  - `bios = "ovmf"` needs somewhere to put EFI variables. Without the disk, OVMF boots but forgets its boot entries. If a VM won't boot at all, `bios = "seabios"` with `efi_disk` removed is the fast fallback/test.

**Ballooning is off.** 
- `memory.floating` is unset deliberately. The kubelet reserves memory it expects to keep, and a balloon driver reclaiming pages underneath it might cause eviction loops.

**`cpu.type = "host"`**
  - Exposes the physical CPU's full feature set, including every Spectre and Meltdown mitigation (without hand-maintaining a flag list). This is safe only while all four hosts are the same model. I'll move to `x86-64-v2-AES` if CPUS in my cluster stop matching.

**Tags are sorted by the module.** 
  - Proxmox returns them sorted! So an unsorted list in the configuration shows a permanent diff on every plan.

**The cloud-init drive is on `scsi1`** 
  - ...alongside the boot disk. Left unset, the provider defaults to `ide2`, which means an emulated IDE controller in the guest for one read-once config drive.

### If a VM Kernel Panics on First Boot

Debian cloud images ship `cloud-initramfs-growroot`, which has bugs that cause it to need a serial console when it expands the root filesystem on first boot. Without one, a disk resize might case `Kernel panic - not syncing: Attempted to kill init!` (Launchpad bug #1123220). The module currently defines no `serial_device`, but seems to work fine for now.

## Known Issues
**`agent.enabled = true` in the module.** 
- `qemu-guest-agent` isn't present in the Debian cloud image. The Ansible `common` role installs it after first boot. Until it's running, Proxmox will try the agent instead of ACPI for shutdown, and create, refresh and destroy can each block until the fifteen-minute timeout expires. Annoying. `stop_on_destroy = true` avoids the matching hang on `tofu destroy`. Setting `enabled = false` until Ansible has run is the safer way to go.
