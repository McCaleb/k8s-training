# OpenTofu

Provisions virtual machines for the `d-k8s` Kubernetes cluster on Proxmox VE: 
  - 2 load balancers, 
  - 3 control plane nodes
  - 6 workers

- Every VM is built from an upstream Debian cloud image (not cloned).
- OpenTofu builds, Ansible configures.

## Layout

```
opentofu/
├── dev-cluster/        root module: one state file, one cluster
│   ├── main.tf         provider, placement, image download, node type module calls
│   └── outputs.tf      Ansible inventory and capacity report
└── modules/pve-vm/     the VM definition, called once per node type
```

## Prereqs

### Import content type

- The Debian image is downloaded using Proxmox's `import` content type, which is not enabled by default. 
  * In the web UI: **Datacenter --> Storage --> local --> Edit --> Content**, and tick **Import**.
- The image is ~340 MB and `local` is per-host storage, so a copy goes onto each of the four hosts.

### Proxmox API token

#### Create 

- Create a role. Run on any node, as root:

  ```sh
  pveum role add TofuProvisioner --privs \
  "Datastore.Allocate Datastore.AllocateSpace Datastore.AllocateTemplate Datastore.Audit \
  SDN.Use Sys.Audit Sys.Modify \
  VM.Allocate VM.Audit VM.Config.CDROM VM.Config.Cloudinit VM.Config.CPU \
  VM.Config.Disk VM.Config.HWType VM.Config.Memory VM.Config.Network \
  VM.Config.Options VM.PowerMgmt VM.GuestAgent.Audit"
  ```

- Then, add a user that's in that role:

  ```sh
  pveum user add tofu@pve
  pveum aclmod / -user tofu@pve -role TofuProvisioner
  pveum user token add tofu@pve dev-cluster --privsep 0
  ```

- It'll print a table:

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


- *The token secret prints exactly once at creation and cannot be retrieved again.* 
- `--privsep 0` matters: a privilege-separated token starts with no rights at all regardless of what its user can do. 
  * That causes permission errors that look like the token is broken.
- `SDN.Use` is a non-obvious one. It's required to attach a NIC to a bridge. Without it, VM creation fails with an error that says nothing about networking.

#### Verify

  ```
  pveum acl list
  pveum user list
  pveum role list
  ```
#### Teardown

  ```
  pveum acl delete / --users tofu@pve --roles TofuProvisioner
  pveum user token delete tofu@pve dev-cluster
  pveum user delete tofu@pve
  pveum role delete TofuProvisioner
  ```

- Deleting the user should take its tokens with it, but removing the token explicitly first removes any doubt.

## Usage

  ```sh
  cd dev-cluster
  export PROXMOX_VE_API_TOKEN='tofu@pve!dev-cluster=<uuid>'

  tofu init
  tofu plan -out=cluster.tfplan
  tofu apply -parallelism=1 cluster.tfplan
  ```

`-parallelism=1` is required on my cluster. Creating multiple VMs at once triggers lock errors from Proxmox I/O contention. YMMV.

### Working on one node type

- Each node type is a separate module call, so each has its own address:

  ```sh
  tofu apply   -target=module.workers
  tofu destroy -target=module.workers
  tofu apply   -target=module.load_balancers -target=module.control_plane
  ```

- `-target` applies a partial plan and skips branches of the dependency graph. 
  * To rebuild a single machine, use `-replace`, which computes a full plan and marks one resource for recreation:

  ```sh
  tofu apply -replace='module.workers.proxmox_virtual_environment_vm.this["d-k8s-wk03"]'
  ```

### Handing off to Ansible

  ```sh
  tofu output -raw ansible_inventory > ../../ansible/inventory/cluster.yml
  ```

### Checking capacity

  ```sh
  tofu output capacity
  ```

- Reports committed vCPU and RAM per Proxmox host. 
- The figures are derived from the module outputs, so they can't disagree with the sizing actually applied. 
- vCPU over-subscription is ok. RAM over-subscription is not.

## Adding or moving a VM

- Edit the relevant map in `dev-cluster/main.tf`. 
- Each entry is keyed by hostname and carries three fields:

  ```hcl
  d-k8s-wk07 = { vm_id = 1013, ip = "172.16.1.113/24", node = "node01" }
  ```

- The `node` field is the physical Proxmox host, matching the names under `/etc/pve/nodes/`. 
- Because `migrate = true` is set on the resource, changing a VM's `node` moves it rather than destroying and recreating it.
- Sizing is per node type, set on the module call, so all six workers are the same size. A VM that needs different sizing needs its own module call.

## Notes and Issues

- The Debian image is pinned to a dated build. The filename is derived from it.

- `qemu-guest-agent` is not present in the Debian cloud image. So the `agent` block is disabled and Ansible installs the agent later. 
  * Enabling it before the agent is running makes Proxmox use it for shutdown, and every create, refresh and destroy then blocks for fifteen minutes.

- `bios = "ovmf"`. UEFI plus a resized cloud image is the combination in the reported kernel panic issues, which is why a serial device is needed.

- `.terraform.lock.hcl` is committed on purpose so every run resolves the same provider build.

- The provider is `bpg/proxmox`. It looks like Proxmox publishes no official Terraform or OpenTofu provider. It's pre-1.0 and says that minor versions may break compatibility.

## First run

- Don't apply all eleven at once on the first attempt. Prove one machine first:

```sh
tofu apply -target='module.workers.proxmox_virtual_environment_vm.this["d-k8s-wk01"]'
```

If it boots and answers on `172.16.1.107`, drop the `-target` and apply the rest.
