# k8s-training

Docs and automation for building a Kubernetes cluster from scratch on Proxmox VE.

OpenTofu builds eleven virtual machines. Ansible turns them into a three-node control plane behind a highly available API endpoint, plus six workers. Everything is assembled with `kubeadm` and upstream packages rather than a distribution or an installer, so the parts stay visible: certificates, static pods, sysctls, unit files, and a CNI installed by hand.

The cluster is called `d-k8s`. It exists to be broken, rebuilt, and upgraded.

> [!NOTE]
> This is a lab, not a production reference. One layer 2 segment, a self-signed Proxmox certificate, etcd on the same disk as everything else, no backups, no secrets management. Most of those are deliberate simplifications, and they are called out where they matter.

## Documentation Map

Each component has its own README with variables, defaults, and verification commands. This file is the map and the cross-component reasoning. The role READMEs are the detail.

| Layer            | What it does                                                         | Doc                                                            |
| ---------------- | -------------------------------------------------------------------- | -------------------------------------------------------------- |
| OpenTofu         | Builds the 11 VMs on Proxmox from a Debian cloud image               | [opentofu/README.md](opentofu/README.md)                       |
| `pve-vm`         | The VM definition itself, called once per node type                  | [modules/pve-vm/README.md](opentofu/modules/pve-vm/README.md)  |
| `debian_update`  | Patches a host, then reboots or restarts what the patch left stale   | [roles/debian_update](ansible/roles/debian_update/README.md)   |
| `common`         | Baseline for every node, plus runtime and kubeadm prep for k8s nodes | [roles/common](ansible/roles/common/README.md)                 |
| `load_balancers` | HAProxy and keepalived in front of the API server                    | [roles/load_balancers](ansible/roles/load_balancers/README.md) |
| `control_nodes`  | `kubeadm init`, control plane joins, Calico                          | [roles/control_nodes](ansible/roles/control_nodes/README.md)   |
| `worker_nodes`   | `kubeadm join` for the six workers                                   | [roles/worker_nodes](ansible/roles/worker_nodes/README.md)     |

Background reading that didn't fit anywhere else is in [debian_update/NOTES.md](ansible/roles/debian_update/NOTES.md): what `NEEDRESTART_SUSPEND` actually suspends, where `KSTA` is documented, and what `DEBIAN_FRONTEND` does not cover.

## Repo Layout

```
k8s-training/
├── opentofu/
│   ├── dev-cluster/                 root module: one state file, one cluster
│   │   ├── main.tf                  provider, placement maps, image download, module calls
│   │   ├── outputs.tf               Ansible inventory and per-host capacity report
│   │   └── moved.tf                 state moves for the wk -> wn rename
│   └── modules/pve-vm/              the VM definition, called once per node type
└── ansible/
    ├── inventory.yml                hosts and groups only
    ├── group_vars/all.yml           cluster-wide variables
    ├── requirements.yml             Galaxy collections the roles need
    ├── ansible_facts.debian.yml     a fact dump from a Debian node, kept for writing templates
    ├── playbooks/site.yml           the whole build, in order
    └── roles/
        ├── debian_update/
        ├── common/
        ├── load_balancers/
        ├── control_nodes/
        └── worker_nodes/
```

`ansible_facts.debian.yml` isn't read by anything at run time. It's a copy of `ansible_facts` from one Debian node, so a fact name can be checked without running a play to find it.

## The Cluster

| Role          | Name       | IPv4         | VM ID | Proxmox host |
| ------------- | ---------- | ------------ | ----- | ------------ |
| Load Balancer | d-k8s-lb01 | 172.16.1.101 | 1001  | node02       |
| Load Balancer | d-k8s-lb02 | 172.16.1.102 | 1002  | node04       |
| vIP           | d-k8s-api  | 172.16.1.103 |       | floats       |
| Control Node  | d-k8s-cn01 | 172.16.1.104 | 1004  | node01       |
| Control Node  | d-k8s-cn02 | 172.16.1.105 | 1005  | node02       |
| Control Node  | d-k8s-cn03 | 172.16.1.106 | 1006  | node03       |
| Worker Node   | d-k8s-wn01 | 172.16.1.107 | 1007  | node01       |
| Worker Node   | d-k8s-wn02 | 172.16.1.108 | 1008  | node02       |
| Worker Node   | d-k8s-wn03 | 172.16.1.109 | 1009  | node03       |
| Worker Node   | d-k8s-wn04 | 172.16.1.110 | 1010  | node04       |
| Worker Node   | d-k8s-wn05 | 172.16.1.111 | 1011  | node03       |
| Worker Node   | d-k8s-wn06 | 172.16.1.112 | 1012  | node04       |

Placement lives in the three maps at the top of `opentofu/dev-cluster/main.tf`, which is the source of truth if this table ever drifts.

- No Proxmox host carries more than one control node, and the two load balancers are on different hosts. Losing one hypervisor costs at most one etcd member and one load balancer, and the cluster survives either.
- The eleven VMs together commit 40 vCPU and 76 GiB. `tofu output capacity` gives the per-host split. vCPU over-subscription is fine within reason. RAM over-subscription is not, because ballooning is deliberately off. See the [pve-vm README](opentofu/modules/pve-vm/README.md).

| Item                   | Value                                         |
| ---------------------- | --------------------------------------------- |
| Control plane endpoint | `d-k8s-api.opnsense.lab:6443`                 |
| vIP                    | 172.16.1.103                                  |
| LAN                    | 172.16.1.0/24                                 |
| Pod CIDR               | 10.244.0.0/16                                 |
| Service CIDR           | 10.96.0.0/12                                  |
| CNI                    | Calico via the Tigera operator. VXLAN, no BGP |
| Cluster name           | `dev-homelab`                                 |
| Primary control node   | `d-k8s-cn01.opnsense.lab`                     |

Two more addresses are derived rather than chosen:

1. The `kubernetes` Service takes the first address in the service CIDR, 10.96.0.1.
2. CoreDNS takes the tenth, 10.96.0.10, and that address is written into every pod's `/etc/resolv.conf`.

> [!TIP]
> Three ranges are in play and none of them may overlap: the LAN the nodes sit on, the pod network, and the service network. A `/12` starting at 10.96 covers 10.96.0.0 through 10.111.255.255, which is worth working out on paper the first time. An overlap here produces failures that look like anything except an addressing mistake.

## Build Order

The order isn't stylistic. Each stage needs something the one before it produced.

| #   | Stage               | Where            | Why it has to be here                                                                  |
| --- | ------------------- | ---------------- | -------------------------------------------------------------------------------------- |
| 1   | Build the VMs       | `tofu apply`     | Nothing to configure until the machines exist and answer on their addresses            |
| 2   | Patch and reboot    | `debian_update`  | Rebooting after the cluster is up means draining nodes. Do it while they are empty     |
| 3   | Baseline every node | `common`         | containerd, swap off, sysctls, `/etc/hosts`, and the kubeadm packages                  |
| 4   | Load balancers      | `load_balancers` | `controlPlaneEndpoint` is the vIP name, so the vIP has to answer before anything joins |
| 5   | Control plane       | `control_nodes`  | `kubeadm init` on the primary, the other two join, then Calico goes on                 |
| 6   | Workers             | `worker_nodes`   | Workers need a live API server to join and a CNI before they report `Ready`            |

Stages 2 through 6 are all in `playbooks/site.yml`, which runs against `all` and guards each role on group membership. The whole build is one command.

> [!IMPORTANT]
> Stage 4 before stage 5 is the ordering people get wrong. `kubeadm init` bakes `d-k8s-api.opnsense.lab:6443` into every generated kubeconfig and into the API server certificate. If that name doesn't resolve, or nothing is listening on the vIP, the bootstrap fails partway and leaves state behind. HAProxy binds `*:6443` rather than the vIP precisely so it can start before there is anything behind it to proxy to.

## Quick Start

### Build the VMs

Full detail, including the Proxmox API token and the `import` content type, is in the [OpenTofu README](opentofu/README.md).

```sh
cd opentofu/dev-cluster
export PROXMOX_VE_API_TOKEN='tofu@pve!dev-cluster=<uuid>'

tofu init
tofu plan -out=cluster.tfplan
tofu apply -parallelism=1 cluster.tfplan
```

`-parallelism=1` is needed on this Proxmox cluster. Several simultaneous creates trigger lock errors from I/O contention.

### Configure the cluster

```sh
cd ansible
ansible-galaxy collection install -r requirements.yml
ansible-playbook -i inventory.yml playbooks/site.yml
```

> [!WARNING]
> There is no `ansible.cfg` in this repo, and `playbooks/site.yml` uses roles that sit in `../roles`. Ansible looks for a `roles/` directory beside the playbook, which here would be `playbooks/roles/` and doesn't exist, so a fresh clone fails with `the role 'debian_update' was not found`. Until an `ansible.cfg` lands, set the path for the run:
>
> ```sh
> ANSIBLE_ROLES_PATH=roles ansible-playbook -i inventory.yml playbooks/site.yml
> ```
>
> The fix is an `ansible/ansible.cfg` containing `roles_path = roles`. See [Known Gaps](#known-gaps).

Flags worth knowing while learning:

| Flag                    | Effect                                                                          |
| ----------------------- | ------------------------------------------------------------------------------- |
| `--list-tasks`          | What will run, in order, without running it                                     |
| `--check --diff`        | Dry run with a diff. Tasks whose input doesn't exist yet will report as skipped |
| `--limit d-k8s-wn01*`   | One host. The roles still read `groups[...]`, so keep the inventory whole       |
| `--start-at-task "..."` | Resume a long run after fixing something                                        |
| `-vv`                   | Show the command each task actually ran                                         |

`any_errors_fatal: true` is set on the play, so a failure on one host stops the run everywhere instead of leaving a half-built cluster.

## Versions

The plan is to build on 1.35, then upgrade to 1.36 as a separate exercise.

- `k8s_release` in `group_vars/all.yml` sets the minor version. It selects the `pkgs.k8s.io` repository path written to `/etc/apt/sources.list.d/kubernetes.sources`, and that repository carries kubeadm, kubelet, kubectl, and cri-tools.
- Quote it. Unquoted, YAML reads `1.40` as the float `1.4`.
- Each minor version is a separate repository. Upgrading means changing `k8s_release`, not waiting for `apt` to offer something newer.
- CNCF exam environments track recent stable releases, usually within four to eight weeks of them.

| Component          | How to find the version    | Set by                                       | Held |
| ------------------ | -------------------------- | -------------------------------------------- | ---- |
| Debian             | `cat /etc/debian_version`  | dated cloud image in `main.tf`, then patched | No   |
| Node kernel        | `uname -r`                 | Debian release                               | No   |
| systemd            | `systemctl --version`      | Debian release                               | No   |
| nftables userspace | `nft -v`                   | Debian release                               | No   |
| containerd         | `containerd --version`     | Debian release                               | No   |
| runc               | `runc --version`           | Debian release                               | No   |
| cri-tools (crictl) | `crictl --version`         | `pkgs.k8s.io`, installed by `common`         | No   |
| kubeadm            | `kubeadm version`          | `k8s_release`                                | Yes  |
| kubelet            | `kubelet --version`        | `k8s_release`                                | Yes  |
| kubectl            | `kubectl version --client` | `k8s_release`                                | Yes  |
| Calico / Tigera    | `kubectl get tigerastatus` | hardcoded `v3.32.1` in `tasks/primary.yml`   | n/a  |

"Held" means `common` runs `dpkg_selections` with `selection: hold`, so `apt-get dist-upgrade` walks past the package. The list is `common_k8s_hold_packages`.

> [!NOTE]
> A held package still appears in `apt list --upgradable`. That output is not evidence a patch run failed. Cross-check with `apt-mark showhold`.

Calico's two manifest URLs in `control_nodes/tasks/primary.yml` carry the version in the path. They aren't variables yet, so bumping Calico means editing both.

### Upgrading a minor version

Not automated yet. The manual shape of it, for reference:

1. Change `k8s_release` and re-run `common`, so the new repository is in place.
2. `apt-mark unhold kubeadm`, then install the new kubeadm on the primary control node.
3. `kubeadm upgrade plan`, then `kubeadm upgrade apply v1.36.x` on the primary.
4. `kubeadm upgrade node` on the other two control nodes.
5. Per node: `kubectl drain <node> --ignore-daemonsets`, upgrade kubelet and kubectl, `systemctl restart kubelet`, `kubectl uncordon <node>`.
6. `apt-mark hold` the three packages again.

kubeadm upgrades one minor version at a time, and a kubelet may trail the API server by at most three minor versions. Going from 1.35 to 1.37 in one step is not supported.

---

# 1. Load Balancers

**[Load Balancer Ansible role](ansible/roles/load_balancers/README.md)**

- The Kubernetes API server runs on three control plane nodes.
- Clients need *one* address to reach it, and that address has to survive the loss of any single machine.
- Two dedicated Debian VMs provide it. Each runs two daemons:
    * [HAProxy](https://www.haproxy.org/) picks which control plane node serves a connection.
    * [Keepalived](https://www.keepalived.org/) decides which of the two VMs owns the shared address.
      - It does that with the [Virtual Router Redundancy Protocol (VRRP)](https://www.haproxy.com/glossary/what-is-vrrp-virtual-router-redundancy-protocol).

## Keepalived

- The two nodes exchange VRRP advertisements every second and elect the highest-priority healthy node as MASTER.
- The MASTER adds `172.16.1.103/24` to its default IPv4 interface and sends gratuitous ARP so switches relearn where the address lives. The other node carries the address in configuration only. It isn't present on its interface.
- If advertisements stop, the survivor waits out its `Master_Down_Interval` and claims the address.
- *VRRP needs a single layer 2 segment.* Both nodes and the vIP share one broadcast domain.

Two things surprise people reading `keepalived.conf` here for the first time:

- **Both nodes start in `BACKUP`, not one in `MASTER`.** State comes from the election, not from the config file. Combined with `nopreempt`, a node returning from an outage leaves the address where it is instead of taking it back and breaking every established connection.
- **Advertisements are unicast, not multicast.** `unicast_src_ip` and `unicast_peer` are rendered from the inventory, so the pair works on networks that don't forward VRRP multicast. `vrrp_check_unicast_src` makes keepalived ignore advertisements that didn't come from a configured peer.

Priority defaults to the last octet of the node's address, so lb01 gets 101 and lb02 gets 102. lb02 therefore wins when both boot together.

> [!TIP]
> `Master_Down_Interval` is not a tunable. It's derived: `3 × advert_int + (256 − priority) / 256`. With `advert_int 1` and these priorities that comes to about 3.6 seconds on both nodes. The skew term exists so two backups with different priorities don't declare the master down at the same instant and fight over the address.

## HAProxy

HAProxy listens on `*:6443` and forwards to the three control plane nodes on 6443. It runs in `mode tcp`, relaying bytes without decrypting them, so the client's TLS session reaches the API server intact.

That matters because Kubernetes authenticates clients by their TLS certificate. If HAProxy terminated TLS, the API server would see HAProxy's identity on every request instead of the real client's, and RBAC would fall apart.

| Setting                                 | Value                 | Why                                                                                       |
| --------------------------------------- | --------------------- | ----------------------------------------------------------------------------------------- |
| `mode tcp`                              | pass-through          | Terminating TLS would break client certificate authentication                             |
| `bind *:6443`                           | wildcard, not the vIP | HAProxy starts and health checks whether or not this node holds the address               |
| `balance leastconn`                     | least connections     | API connections are long-lived watches, so counts drift apart under round robin           |
| `timeout client` / `timeout server`     | 4h                    | Debian's stock 50s cuts off `kubectl exec` and `kubectl port-forward` mid-session         |
| `option redispatch` with `retries 3`    | retry elsewhere       | A failed *connect* is retried against a different backend instead of returned as an error |
| `default-server inter 3s fall 3 rise 2` | ~9s down, ~6s back    | Three failed checks mark a node down, two good ones bring it back                         |
| `hard-stop-after 15m`                   | cap on old workers    | Bounds how long pre-reload worker processes linger with their old configuration           |

### Health Checks

The Kubernetes docs describe the endpoints used for health checks: [livez and readyz](https://kubernetes.io/docs/reference/using-api/health-checks/).

- The backend check is `option httpchk GET /readyz` with `http-check expect status 200`, every 3 seconds, and three consecutive failures mark a backend down. Worst-case detection is roughly 9 seconds.
- `check-ssl verify none` sits on each server line: the check speaks TLS to the API server but doesn't validate its certificate. HAProxy isn't a cluster client, has no CA bundle, and only needs to know whether the port answers with a 200.
- Without `http-check expect status 200`, HAProxy would treat *any* HTTP response as healthy, including a 500.

> Sometimes `/readyz` and `/livez` disagree during shutdown. On SIGTERM, the API server starts failing `/readyz` immediately while it keeps serving existing work. And `/livez` stays green throughout. **That gap is what lets a draining node be pulled from rotation before it stops listening.**

- HAProxy runs on both nodes no matter which one holds the vIP. The idle instance *keeps health checking*, so it already knows which API servers are alive the moment the address moves to it.

## Coupling

- VRRP doesn't detect application failure. If HAProxy dies on the node holding the vIP, keepalived is perfectly happy.
- The machine is up, advertisements keep flowing, and the address stays put while clients hit a closed port.
- `track_script` closes that gap. `check_haproxy.sh` runs every 2 seconds and passes only when both of these hold:
  1. `pgrep -x haproxy` finds the process.
  2. `ss -Hlnt 'sport = :6443'` returns a listener.
- Two consecutive failures put the instance into FAULT and release the vIP.

The script deliberately stops there. It says nothing about whether any control plane node is healthy, and that is the point:

- Tie the vIP to backend health and the address refuses to exist before the cluster is built, which is a bootstrap deadlock. `controlPlaneEndpoint` has to answer before `kubeadm init` runs.
- It would also move the address during routine control plane maintenance, when the local HAProxy is perfectly capable of serving whichever nodes remain.

The script runs as the unprivileged `keepalived_script` user because `enable_script_security` is set. keepalived refuses to run a tracking script as root if any component of its path is writable by a non-root user.

## Failure handling

| Failure                            | Handled by           | Detection |
| ---------------------------------- | -------------------- | --------- |
| Control plane node stops answering | HAProxy health check | ~9 s      |
| Load balancer node disappears      | VRRP election        | ~3.6 s    |
| HAProxy process dies               | `track_script`       | ~4 s      |

With two load balancer nodes there is no spare. While one is down for patching, the other is a single point of failure for the API endpoint.

If both go down, running pods keep running. The kubelet doesn't need the API server to keep existing containers alive, and in-cluster traffic to `kubernetes.default.svc` never touches the vIP. What stops is `kubectl`, worker kubelet status reporting, kube-proxy updates, and `kubeadm join`. The control plane itself is unaffected, since its components talk to `127.0.0.1:6443`.

> [!IMPORTANT]
> That state (both HAProxy servers down) is survivable for minutes, not hours. Once worker kubelets stop reporting, the control plane marks those nodes `NotReady` and eventually starts evicting their pods onto nodes it also can't reach.

## Client path

- `kubectl` resolves `d-k8s-api.opnsense.lab` to `172.16.1.103`, connects on 6443, and HAProxy relays to a healthy control plane node.

- Worker kubelets, kube-proxy, and `kubeadm join` take the same path. Control plane components talk to `127.0.0.1:6443` and don't depend on the vIP at all.

- *Failover moves an address, not connections.* HAProxy's session state lives in one process on one node and isn't replicated. When the vIP moves, the new holder knows nothing about connections established through the old one, so those sessions break. Clients see a reset or a timeout, not a clean close.

- [Watches](https://kubernetes.io/docs/reference/using-api/api-concepts/#efficient-detection-of-changes) reconnect on their own. When the connection breaks, client-go reopens it from the last resource version it saw. `kubectl exec` and `port-forward` don't have that, so those sessions die.

## Where things are

| What              | Where                                                        |
| ----------------- | ------------------------------------------------------------ |
| HAProxy config    | `/etc/haproxy/haproxy.cfg` (identical on both nodes)         |
| Keepalived config | `/etc/keepalived/keepalived.conf` (differs only by priority) |
| Health check      | `/usr/local/bin/check_haproxy.sh`                            |
| Stats page        | `http://<node>:8404/stats`                                   |
| Admin socket      | `/run/haproxy/admin.sock`                                    |
| Logs              | `journalctl -fu haproxy`, `journalctl -fu keepalived`        |

## Checks and Useful Commands

**Stats**

  `http://172.16.1.101:8404/stats`

  The stats listener binds each node's own address rather than the vIP, so each page reports on that node only. Check both.

**Get status**

  ```bash
  ip -br addr                                 # which node holds the vIP?
  echo "show stat" | socat stdio /run/haproxy/admin.sock | cut -d, -f1,2,18
  curl -k https://172.16.1.103:6443/readyz    # end to end through the vIP
  ```

**`timeout 2 curl -sk -o /dev/null -w '%{http_code}' https://127.0.0.1:6443/readyz`**

  - Tests the full path from this node's HAProxy to a live API server.
  - A `200` means the frontend is listening and at least one backend is healthy.
  - Probably not great for the keepalived track script. It would tie vIP ownership to backend health.

**`echo "show stat" | socat stdio /run/haproxy/admin.sock | cut -d, -f1,2,18`**

  - Backend state from the shell instead of the stats page.
  - Fields 1, 2, and 18 are proxy name, server name, and status, giving lines like `k8s_controlplane,d-k8s-cn01,UP`.

**`echo "disable server k8s_controlplane/d-k8s-cn02" | socat stdio /run/haproxy/admin.sock`**

  - Pulls a control plane node from rotation immediately instead of waiting the approx. 9 seconds the health check needs.
  - Run it on both load balancer nodes before rebooting or upgrading that node.

**`echo "enable server k8s_controlplane/d-k8s-cn02" | socat stdio /run/haproxy/admin.sock`**

  - Returns the node to rotation.
  - Runtime state doesn't survive a reload, so a reload during maintenance will silently put a disabled node back in rotation. Re-running the Ansible role is one way that happens.

**Test failover**

  Stop HAProxy on whichever node holds the address, then look for the vIP on the other one a few seconds later. `journalctl -fu keepalived` on both nodes shows the transition.

---

# 2. Control Nodes

Three VMs run the Kubernetes control plane.

**[Control Nodes role](ansible/roles/control_nodes/README.md)**

- Each runs the same four programs as *static pods*:
  * `kube-apiserver`
  * `etcd`
  * `kube-controller-manager`
  * `kube-scheduler`
- `kubelet` runs as a systemd service on every node, and it is what starts static pods.
- etcd needs a majority of its members to agree before it accepts a write.
  * Three members tolerate one failure, because two of three is still a majority.
  * Two members tolerate none, because one of two isn't.

Terms used throughout this document are collected in the [Glossary](#glossary).

## Quorum, Concretely

| etcd members | Majority needed | Failures tolerated | Worth running? |
| ------------ | --------------- | ------------------ | -------------- |
| 1            | 1               | 0                  | Lab of one     |
| 2            | 2               | 0                  | No             |
| 3            | 2               | 1                  | Yes            |
| 4            | 3               | 1                  | No             |
| 5            | 3               | 2                  | Yes            |

Even member counts buy nothing. Four members still tolerate only one failure, and they give you one more machine that can break. This is why control plane counts are always odd.

> [!WARNING]
> Losing quorum is not a read-only degradation. With two of three members gone, etcd stops serving reads as well as writes, and the API server goes down with it. Running pods keep running, but nothing can be scheduled, changed, or reported.

## What `kubeadm init` Actually Does

The role runs one command on the primary, but `kubeadm init` is a sequence of phases. Knowing them turns "the bootstrap failed" into "the bootstrap failed *at* a specific step." Run `kubeadm init phase --help` on a node to list them.

| Phase                | What it produces                                                                              |
| -------------------- | --------------------------------------------------------------------------------------------- |
| `preflight`          | Checks swap, ports, cgroup driver, required binaries. Most first-run failures stop here       |
| `certs`              | The cluster CA and every leaf certificate, in `/etc/kubernetes/pki/`                          |
| `kubeconfig`         | `admin.conf`, `super-admin.conf`, `controller-manager.conf`, `scheduler.conf`, `kubelet.conf` |
| `etcd`               | The static pod manifest for the local etcd member                                             |
| `control-plane`      | Static pod manifests for the API server, controller manager, and scheduler                    |
| `kubelet-start`      | `/var/lib/kubelet/config.yaml`, then starts the kubelet, which starts those static pods       |
| `upload-config`      | The `kubeadm-config` and `kubelet-config` ConfigMaps in `kube-system`                         |
| `upload-certs`       | The CA material, encrypted, in the `kubeadm-certs` Secret. Expires after 2 hours              |
| `mark-control-plane` | The control plane label and the `NoSchedule` taint                                            |
| `bootstrap-token`    | A token a joining node can use before it has a certificate of its own                         |
| `addon`              | CoreDNS and kube-proxy                                                                        |

The role checks `GET /healthz` before it starts, and skips the whole block if the control plane already answers. `kubeadm init` fails against a working cluster, so that check is what makes the role safe to re-run.

### The Two Arguments Worth Explaining

`kubeadm-config.yaml.j2` passes two API server flags that aren't obvious:

**`shutdown-delay-duration: 15s`**

On SIGTERM the API server immediately starts failing `/readyz` but keeps serving requests for this long before it begins shutting down. HAProxy needs about 9 seconds to notice and stop sending new connections. The delay is what makes a planned restart invisible to clients instead of a burst of connection resets. The default is `0s`, which gives the load balancer no warning at all.

**`goaway-chance: "0.001"`**

HTTP/2 multiplexes many requests over one TCP connection, so a client that connected once keeps talking to the same API server indefinitely, even after the other two come back from a restart. This tells the API server to send a GOAWAY frame on roughly one request in a thousand; client-go reconnects, and the new connection goes through HAProxy's `leastconn` to whichever node is least busy. It's slow, passive rebalancing. The upstream maximum is `0.02`.

## Joining the Other Two

1. Each node skips the join if `/etc/kubernetes/kubelet.conf` already exists, so a re-run is a no-op.
2. Join credentials are generated on the primary with `delegate_to` and `run_once`: a certificate key, a fresh upload of the control plane certificates, and a join token.
3. `throttle: 1` joins the nodes one at a time. Adding an etcd member raises the quorum size before that member is actually serving, so two joins at once can drop the cluster below quorum mid-transition.

Two short-lived secrets are involved, and they expire for different reasons:

| Credential      | Created by                      | Lifetime             | What it's for                                                           |
| --------------- | ------------------------------- | -------------------- | ----------------------------------------------------------------------- |
| Bootstrap token | `kubeadm token create`          | 5m here, 24h default | Authenticates a joining node before it has a cert                       |
| Certificate key | `kubeadm certs certificate-key` | 2 hours, not tunable | Decrypts the `kubeadm-certs` Secret so a control plane node gets the CA |

Both are regenerated on every run, so their short lifetimes never matter to the playbook. They matter when you join a node by hand an hour later and get `couldn't validate the identity of the API Server`. That message usually means the token expired, not that anything is wrong with the cluster.

## Three Addresses That Are Easy to Confuse

| Name                   | Value                         | What it is                                                                |
| ---------------------- | ----------------------------- | ------------------------------------------------------------------------- |
| Control plane endpoint | `d-k8s-api.opnsense.lab:6443` | DNS name                                                                  |
| Virtual IP (vIP)       | 172.16.1.103                  | Floating address that `d-k8s-api.opnsense.lab` resolves to                |
| Advertise address      | 172.16.1.104, .105, .106      | Control plane node's own address, published into the `kubernetes` Service |

- The control plane endpoint is a name.
- The vIP is where that name points.
- The advertise address is how a specific node identifies itself to the cluster.

Traffic to the first two passes through HAProxy. Traffic to the third doesn't.

## Certificates and Their Expiry

`kubeadm` runs its own certificate authority. Nothing here is signed by anything you'd recognise, and every certificate has a clock on it.

| File                                               | Identity                       | Default life          |
| -------------------------------------------------- | ------------------------------ | --------------------- |
| `/etc/kubernetes/pki/ca.crt`                       | The cluster CA                 | 10 years              |
| `/etc/kubernetes/pki/apiserver.crt`                | API server serving cert        | 1 year                |
| `/etc/kubernetes/pki/apiserver-kubelet-client.crt` | API server talking to kubelets | 1 year                |
| `/etc/kubernetes/pki/etcd/*.crt`                   | etcd server, peer, and health  | 1 year                |
| `/etc/kubernetes/admin.conf`                       | Your `kubectl` identity        | 1 year                |
| `/var/lib/kubelet/pki/kubelet-client-current.pem`  | The kubelet's own identity     | Rotates automatically |

```sh
kubeadm certs check-expiration      # every certificate and its remaining life
kubeadm certs renew all             # then restart the static pods
```

> [!IMPORTANT]
> A training cluster left alone for a year comes back with expired certificates and a `kubectl` that reports `x509: certificate has expired or is not yet valid`. The cluster isn't broken and the data is intact; the certificates just need renewing. `kubeadm upgrade` renews them as a side effect, which is why a cluster that gets upgraded regularly never hits this. After `kubeadm certs renew all`, copy `admin.conf` to `~/.kube/config` again, because the old copy carries the old certificate.

## Three command-line tools

They operate at different layers.

| Tool      | Talks to                    | When you use it                                                                                   |
| --------- | --------------------------- | ------------------------------------------------------------------------------------------------- |
| `kubectl` | The API server              | Almost always                                                                                     |
| `crictl`  | containerd, through the CRI | The API server is down, or a pod never started, so `kubectl` can't tell you anything              |
| `ctr`     | containerd directly         | Almost never. Bypasses the CRI and doesn't see k8s containers unless you name the right namespace |

When `kubectl get pods` can't help because the control plane itself is broken, `crictl` on the node is the tool that can:

```sh
crictl ps -a                        # every container, including the ones that died
crictl logs <container-id>          # why the API server won't start
crictl pods                         # sandboxes, including static pods
ctr -n k8s.io containers list       # the namespace k8s images actually live in
```

`crictl` reads `/etc/crictl.yaml`, which the `common` role writes. Without it, `crictl` guesses at the socket path and prints a deprecation warning on every run.

## Disk Latency

- etcd only acknowledges a write after `fdatasync` returns, so its [performance](https://etcd.io/docs/v3.7/op-guide/performance/) depends on fsync latency rather than throughput.
- A disk that does well on sequential writes can still be a problem.
- When fsync is slow, etcd's internal heartbeats miss their deadlines, leader elections churn, and the API server returns intermittent errors.
- This can be confusing. Nothing in the Kubernetes layer points at the disk, so it's worth measuring once, up front, rather than diagnosing later.
- Use `findmnt` to make sure you don't run this against something mounted as tmpfs in memory.

```
apt-get install -y fio
mkdir -p /root/fiotest
fio --rw=write --ioengine=sync \
--fdatasync=1 --directory=/root/fiotest \
--size=22m --bs=2300 --name=etcdtest
```

- Check the 99th percentile figure on the `fsync/fdatasync/sync_file_range` line. etcd's hardware guidance sets the target below 10 ms. Consumer NVMe usually lands near 1 ms.
- On virtual machines, the number you get is the hypervisor's, not the drive's. A `cache` setting other than `none` on the Proxmox disk can make this look far better than it is, because writes land in the host's page cache. The `pve-vm` module sets `cache = "none"` for exactly this reason.

## CNI (Calico)

Kubernetes ships no CNI of its own. Until one is installed, every node reports `NotReady` with `container runtime network not ready: cni plugin not initialized`, and CoreDNS sits `Pending`. That state is expected in the window between `kubeadm init` and Calico coming up. It isn't a fault.

This cluster runs Calico, installed through the [Tigera operator](https://docs.tigera.io/calico/latest/about/):

1. The CRDs and the operator come from upstream manifests, pinned to `v3.32.1`.
2. An `Installation` resource describes the network, and the operator reconciles the rest.
3. The role waits for the CRD to be Established, for `tigerastatus/calico` to appear, and then for it to go Available, so the play doesn't return before the CNI is actually up.

| Setting                      | Value                        | Effect                                                              |
| ---------------------------- | ---------------------------- | ------------------------------------------------------------------- |
| `encapsulation`              | VXLAN                        | Pod traffic is wrapped in UDP 4789 between nodes                    |
| `bgp`                        | Disabled                     | No peering. Nothing on this LAN would speak BGP back                |
| `natOutgoing`                | Enabled                      | Pod traffic leaving the pod network is SNATed to the node's address |
| `nodeAddressAutodetectionV4` | `kubernetes: NodeInternalIP` | Calico uses the address the node registered with, not a guess       |

> [!NOTE]
> VXLAN adds 50 bytes of header, so Calico drops the pod MTU to 1450 on a standard 1500-byte network. Check it with `ip link show vxlan.calico` on a node. An MTU mismatch is a classic overlay failure: small requests succeed, large responses hang, and it looks like an application bug.

> [!TIP]
> `podSubnet` in the kubeadm config makes kube-controller-manager assign a `podCIDR` to each Node object, but Calico's own IPAM doesn't use it. Calico allocates `/26` blocks per node out of the IP pool on demand. So `kubectl get node -o jsonpath='{.spec.podCIDR}'` and the addresses your pods actually get can legitimately disagree. `kubectl get ippools` and `kubectl get ipamblocks` show what Calico is really doing.

Calico manages interfaces directly, so NetworkManager needs to be [configured to leave them alone](https://docs.tigera.io/calico/latest/operations/troubleshoot/troubleshooting#configure-networkmanager). Debian cloud images don't install NetworkManager, so this doesn't bite here, but it's the first thing to check if these roles are ever pointed at a desktop-flavoured distribution.

Calico's own pods land in the `calico-system` namespace, and the operator in `tigera-operator`. Neither is in `kube-system`, which catches people out when they go looking.

```sh
kubectl get tigerastatus                       # the operator's own view of the rollout
kubectl -n calico-system get pods -o wide      # one calico-node per cluster node
kubectl get installation default -o yaml       # the configuration as applied
```

---

# 3. Worker Nodes

Six VMs run the workload.

**[Worker Nodes role](ansible/roles/worker_nodes/README.md)**

A worker is a much simpler machine than a control node. Nothing runs as a static pod, and there is no local API server to fall back on.

| What          | How it runs                  | Notes                                                                    |
| ------------- | ---------------------------- | ------------------------------------------------------------------------ |
| `containerd`  | systemd service              | Installed and configured by `common`                                     |
| `kubelet`     | systemd service              | The only Kubernetes component started by the machine itself              |
| `kube-proxy`  | DaemonSet in `kube-system`   | Programs the Service rules for this node                                 |
| `calico-node` | DaemonSet in `calico-system` | Gives pods their addresses and carries traffic between nodes             |
| Your pods     | Scheduled                    | Workers carry no taint, so anything without a nodeSelector can land here |

## Joining

1. The role checks for `/etc/kubernetes/kubelet.conf` and skips the join if it exists, so a re-run is a no-op.
2. A join command is generated once on `primary_control_node` with `delegate_to` and `run_once`, under `no_log` because the token is in the output.
3. Each worker runs it. No `--control-plane`, no certificate key: a worker never gets a copy of the cluster CA key, and doesn't join etcd.

The printed join command looks like this:

```
kubeadm join d-k8s-api.opnsense.lab:6443 --token <token> \
  --discovery-token-ca-cert-hash sha256:<hex>
```

> [!TIP]
> The `--discovery-token-ca-cert-hash` is the part people skip past. The joining node has no certificates yet, so it can't validate the API server it's about to trust with its identity. The hash is a fingerprint of the cluster CA's public key, learned out of band. The node fetches the cluster info, hashes the CA it was handed, and refuses to continue unless it matches. Without it, anything answering on the endpoint could enrol your node into a cluster it controls. Print it yourself with `kubeadm token create --print-join-command` on a control node.

For a worker, `kubeadm join` runs `preflight` and `kubelet-start`. The `control-plane-prepare` and `control-plane-join` phases only apply when `--control-plane` is passed. Discovery happens before the kubelet starts: fetch the cluster info, check it against the CA hash, then use the token to authenticate. The kubelet submits a certificate signing request, the control plane approves it automatically, and the node registers itself. From there the Node authorizer and the `NodeRestriction` admission plugin limit that kubelet to reading and writing only its own node's objects.

A freshly joined worker shows `NotReady` for a few seconds until `calico-node` is scheduled onto it and the CNI configuration lands in `/etc/cni/net.d/`. That's normal.

> [!NOTE]
> The role doesn't run `kubeadm config images pull` on workers, so each one pulls the `pause`, `kube-proxy`, and Calico images on demand during its first join. There is no shared cache or registry mirror here, so all six pull the same images independently. On a slow link that's the slowest part of the play.

## Removing One

Not automated. In order, and the order matters:

```sh
kubectl drain d-k8s-wn06 --ignore-daemonsets --delete-emptydir-data   # move the workload off
kubectl delete node d-k8s-wn06                                        # remove it from the API
ssh d-k8s-wn06 sudo kubeadm reset -f                                  # clean the node itself
```

`kubeadm reset` doesn't remove iptables or nftables rules kube-proxy installed, and it doesn't clean up `/etc/cni/net.d/`. If the machine is being reused rather than destroyed, do both by hand. Here the machine is a VM, so `tofu destroy -target=...` is the honest answer.

## Checking It

```sh
kubectl get nodes -o wide                          # all six registered and Ready
kubectl get pods -A -o wide --field-selector spec.nodeName=d-k8s-wn01
kubectl -n kube-system get ds kube-proxy           # desired should equal ready
kubectl describe node d-k8s-wn01 | sed -n '/Taints/,/Capacity/p'
```

---

# 4. What Every Node Gets First

Before any of the Kubernetes-specific work, every machine goes through two roles. They're covered properly in their own READMEs; this is what they're for and why a Kubernetes cluster cares.

**[debian_update](ansible/roles/debian_update/README.md)** patches the host, then either reboots for a new kernel or restarts the services still holding deleted libraries in memory. It runs first so the reboot happens while the machines are empty. Rebooting a node after the cluster exists means draining it.

**[common](ansible/roles/common/README.md)** does the baseline, and then the Kubernetes preparation on control and worker nodes only.

| What `common` does                                                   | Why Kubernetes cares                                                                            |
| -------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------- |
| Replaces systemd-timesyncd with chrony                               | Certificates are time-sensitive, and etcd tolerates very little drift between members           |
| Blocks until `chronyc waitsync` passes                               | A node with a bad clock fails later, somewhere far less obvious                                 |
| Writes the whole cluster into `/etc/hosts`                           | Node-to-node name resolution doesn't depend on the lab's DNS being up                           |
| Turns swap off, and comments out `fstab`                             | The kubelet refuses to start with swap on unless you tell it otherwise                          |
| Loads `overlay` and `br_netfilter`                                   | containerd's snapshotter needs one; Service routing needs the other                             |
| Sets `net.ipv4.ip_forward=1`                                         | The node routes pod traffic. Without it, pods can't reach anything off-node                     |
| Sets `bridge-nf-call-iptables=1`                                     | Traffic crossing a Linux bridge must be seen by iptables/nftables, or Service rules never apply |
| Installs and configures containerd                                   | The container runtime kubelet talks to over the CRI                                             |
| Sets `SystemdCgroup = true`                                          | Must match the kubelet's `cgroupDriver: systemd`. See below                                     |
| Adds `pkgs.k8s.io` and installs kubeadm, kubelet, kubectl, cri-tools | The actual Kubernetes binaries                                                                  |
| Holds those three packages                                           | An unattended upgrade must not move a cluster to a new minor version behind your back           |
| Makes the journal persistent                                         | Logs from before a reboot survive it. Usually the reboot you need to explain                    |

> [!IMPORTANT]
> The cgroup driver is the single most common kubeadm setup failure. Linux has two cgroup managers on a systemd machine, and if containerd and the kubelet disagree about which one owns the tree, resource accounting is wrong and the kubelet often refuses to start outright. The message is a mouthful: `misconfiguration: kubelet cgroup driver: "cgroupfs" is different from that of container runtime "systemd"`. Both settings are pinned in this repo — `SystemdCgroup = true` in `common`'s containerd template, and `cgroupDriver: systemd` in the kubeadm config — and they have to be changed together or not at all.

> [!NOTE]
> containerd comes from Debian's repositories, not Docker's. `apt install containerd` and `apt install containerd.io` are different packages from different sources, and installing both is a good way to spend an afternoon. The Docker packages also ship a `config.toml` that this role's template would overwrite.

---

# Reference

## Ports

Nothing filters traffic between these machines today, so this table is documentation rather than a firewall policy. It's also the list you'd need if that ever changed.

| Port        | Proto   | Who listens             | Where         | Who connects                           |
| ----------- | ------- | ----------------------- | ------------- | -------------------------------------- |
| 6443        | TCP     | kube-apiserver          | Control nodes | Everything, via the vIP                |
| 6443        | TCP     | HAProxy frontend        | LB nodes      | Every client of the cluster            |
| 2379        | TCP     | etcd client             | Control nodes | The API server on the same node        |
| 2380        | TCP     | etcd peer               | Control nodes | The other two etcd members             |
| 2381        | TCP     | etcd metrics            | Control nodes | Localhost only                         |
| 10250       | TCP     | kubelet API             | All k8s nodes | The control plane: logs, exec, metrics |
| 10256       | TCP     | kube-proxy health       | All k8s nodes | Anything checking node health          |
| 10249       | TCP     | kube-proxy metrics      | All k8s nodes | Localhost only                         |
| 10257       | TCP     | kube-controller-manager | Control nodes | Localhost only                         |
| 10259       | TCP     | kube-scheduler          | Control nodes | Localhost only                         |
| 30000–32767 | TCP/UDP | NodePort range          | All k8s nodes | Whoever you're testing from            |
| 4789        | UDP     | Calico VXLAN            | All k8s nodes | Other cluster nodes                    |
| 179         | TCP     | BGP                     | —             | Not used. BGP is disabled              |
| 8404        | TCP     | HAProxy stats           | LB nodes      | You, per node                          |
| —           | IP 112  | VRRP                    | LB nodes      | The other load balancer                |
| 22          | TCP     | sshd                    | Everything    | The Ansible controller                 |
| 123         | UDP     | outbound only           | Everything    | The NTP sources in `common`            |

`kubeadm` binds the controller manager and the scheduler to `127.0.0.1`, which is why those two are localhost-only despite being cluster components. Reading their metrics means being on the node itself.

## Where Things Live on a Node

| Path                                                        | What it holds                                          | Where   |
| ----------------------------------------------------------- | ------------------------------------------------------ | ------- |
| `/etc/kubernetes/manifests/`                                | Static pod manifests. Drop a file here, get a pod      | Control |
| `/etc/kubernetes/pki/`                                      | Cluster CA and every leaf certificate                  | Control |
| `/etc/kubernetes/admin.conf`                                | The kubeconfig copied to `/root/.kube/config`          | Control |
| `/etc/kubernetes/kubelet.conf`                              | The kubelet's kubeconfig. Its existence means "joined" | All k8s |
| `/var/lib/etcd/`                                            | The entire cluster state                               | Control |
| `/var/lib/kubelet/config.yaml`                              | Kubelet configuration written by kubeadm               | All k8s |
| `/var/lib/kubelet/pki/`                                     | The kubelet's own rotating client certificate          | All k8s |
| `/var/lib/kubelet/kubeadm-flags.env`                        | Extra kubelet flags kubeadm decided on                 | All k8s |
| `/usr/lib/systemd/system/kubelet.service.d/10-kubeadm.conf` | The drop-in that wires the above together              | All k8s |
| `/etc/cni/net.d/`                                           | CNI configuration, written by Calico                   | All k8s |
| `/opt/cni/bin/`                                             | CNI plugin binaries                                    | All k8s |
| `/etc/containerd/config.toml`                               | Runtime configuration, including the cgroup driver     | All k8s |
| `/run/containerd/containerd.sock`                           | The CRI socket `crictl` and the kubelet talk to        | All k8s |
| `/etc/crictl.yaml`                                          | Tells `crictl` where that socket is                    | All k8s |
| `/etc/haproxy/haproxy.cfg`                                  | Frontend, backends, timeouts                           | LB      |
| `/etc/keepalived/keepalived.conf`                           | VRRP instance, priority, track script                  | LB      |

Older Kubernetes packages put the kubelet drop-in at `/etc/systemd/system/kubelet.service.d/10-kubeadm.conf`. If it isn't where the table says, check there. `systemctl cat kubelet` settles it either way.

## Verifying the Cluster

Work outward: does the endpoint answer, is the control plane healthy, are the nodes ready, does the network work.

```sh
# 1. The endpoint, from your workstation
getent hosts d-k8s-api.opnsense.lab
curl -sk https://d-k8s-api.opnsense.lab:6443/readyz    # expect: ok

# 2. The control plane, in detail
kubectl get --raw '/readyz?verbose'                    # every check, one per line
kubectl -n kube-system get pods -o wide                # 12 static pods: four on each control node

# 3. Nodes
kubectl get nodes -o wide                              # 3 control + 6 workers, all Ready
kubectl describe node d-k8s-cn01 | grep -A5 Taints     # control nodes carry NoSchedule

# 4. Networking
kubectl get tigerastatus
kubectl -n kube-system get pods -l k8s-app=kube-dns    # CoreDNS running, not Pending
```

etcd's own view of itself, run from a control node:

```sh
kubectl -n kube-system exec -it etcd-d-k8s-cn01 -- etcdctl \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  endpoint status --cluster -w table
```

Three rows, one leader, and a database size that isn't growing without explanation.

> [!NOTE]
> `kubectl get componentstatuses` (`cs`) shows up in older tutorials. It has been deprecated since 1.19, it reports on the local node's view only, and it can print `Healthy` for a component that isn't. Use `/readyz?verbose` instead.

### Smoke test

Proves scheduling, the pod network, Service routing, and DNS in about a minute.

```sh
kubectl create deployment web --image=nginx --replicas=3
kubectl rollout status deployment/web
kubectl get pods -o wide -l app=web           # spread across workers, each with a 10.244.x address

kubectl expose deployment web --port=80 --type=NodePort
kubectl get svc web                           # note the 3xxxx port
curl -s http://d-k8s-wn01:<nodeport> | head -4

kubectl run dnstest --rm -it --restart=Never --image=busybox:1.36 -- \
  nslookup web.default.svc.cluster.local      # expect an address in 10.96.0.0/12

kubectl delete deployment web
kubectl delete svc web
```

Hitting the NodePort on `d-k8s-wn01` reaches pods on the other workers too. If that works, kube-proxy and the overlay are both doing their jobs.

## Troubleshooting

| Symptom                                                          | Usual cause                                           | First thing to run                                                         |
| ---------------------------------------------------------------- | ----------------------------------------------------- | -------------------------------------------------------------------------- |
| Node `NotReady`, `cni plugin not initialized`                    | Calico isn't up yet, or `calico-node` is crashlooping | `kubectl get tigerastatus; kubectl -n calico-system get pods`              |
| kubelet dead after a reboot                                      | Swap came back                                        | `swapon --show; grep -i swap /etc/fstab`                                   |
| kubelet won't start, complains about cgroup drivers              | containerd and kubelet disagree                       | `grep SystemdCgroup /etc/containerd/config.toml`                           |
| `kubeadm join`: couldn't validate the identity of the API Server | The bootstrap token expired. TTL here is 5 minutes    | `kubeadm token list` on the primary                                        |
| `kubeadm join`: port already in use, or files exist              | A previous attempt left state behind                  | `kubeadm reset -f` on that node, then retry                                |
| `x509: certificate is valid for ..., not d-k8s-api.opnsense.lab` | The name isn't in the API server's SAN list           | `openssl x509 -noout -text -in /etc/kubernetes/pki/apiserver.crt`          |
| `kubectl`: connection refused through the vIP                    | Nobody holds the address, or HAProxy is down          | `ip -br addr` on both load balancers                                       |
| Works from a control node, not from your workstation             | The local kubeconfig is stale or points at a node     | `kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}'` |
| Pods can't resolve anything                                      | CoreDNS is Pending or crashlooping                    | `kubectl -n kube-system get pods -l k8s-app=kube-dns`                      |
| Small requests fine, large responses hang                        | MTU mismatch on the VXLAN overlay                     | `ip link show vxlan.calico`                                                |
| Intermittent API 500s, etcd leader elections in the log          | fsync latency on the etcd disk                        | The `fio` test in [Disk Latency](#disk-latency)                            |
| A PersistentVolumeClaim sits `Pending` forever                   | There is no storage class in this cluster             | `kubectl get sc` returns nothing. See [Known Gaps](#known-gaps)            |
| Ansible: `the role 'debian_update' was not found`                | `roles_path`                                          | `ANSIBLE_ROLES_PATH=roles` before the command                              |
| `apt list --upgradable` isn't empty after patching               | The kubeadm packages are held on purpose              | `apt-mark showhold`                                                        |

When the API server itself is down, `kubectl` can tell you nothing. Go to a control node and use `crictl` and the journal:

```sh
crictl ps -a --name kube-apiserver
crictl logs $(crictl ps -aq --name kube-apiserver | head -1)
journalctl -u kubelet -n 100 --no-pager
```

## Glossary

**Advertise address**
A control plane node's own address, published into the `kubernetes` Service so the cluster knows where that member actually is. Distinct from the vIP: traffic to an advertise address does not pass through HAProxy.

**cgroup driver**
Which component manages the control group hierarchy for containers, `systemd` or `cgroupfs`. containerd and the kubelet have to agree. See the warning in [section 4](#4-what-every-node-gets-first).

**Certificate Subject Alternative Name (SAN)**
A field in a TLS certificate listing the names and addresses that certificate is valid for. Connecting to an API server by a name absent from its SAN list produces a certificate error. This is why the SAN list is decided before the certificates are generated and is awkward to change afterward.

**Container Network Interface (CNI)**
The plugin system that gives pods their addresses and carries traffic between them. Kubernetes ships no CNI of its own. Until you install one, the kubelet reports the node as NotReady.

**Control plane endpoint**
The single name clients use to reach the API server: `d-k8s-api.opnsense.lab:6443`. Baked into every kubeconfig `kubeadm` generates.

**DaemonSet**
A workload that runs one pod on every node, or on every node matching a selector. `kube-proxy` and `calico-node` are DaemonSets, which is why they appear on a new worker without anyone scheduling them.

**Endpoint**
This word carries three unrelated meanings in this guide:
1. The control plane endpoint, `d-k8s-api.opnsense.lab:6443`, the name clients dial.
2. Service endpoints, the backend pod addresses behind a Kubernetes Service.
3. An HAProxy backend, sometimes called an endpoint in proxy documentation.

**Gratuitous ARP**
An unsolicited ARP announcement. Keepalived sends one when it takes the vIP so switches and neighbours update their tables immediately instead of waiting for their caches to expire.

**Held package**
A package marked so `apt` will not upgrade it, via `dpkg_selections` here and `apt-mark hold` by hand. Held packages still appear as upgradable.

**MASTER / BACKUP**
VRRP states, not roles you assign. Both load balancers start as BACKUP and elect a MASTER, which is the one that holds the vIP.

**nopreempt**
A keepalived setting that stops a recovered higher-priority node from taking the vIP back from a working lower-priority one. It trades "the preferred node holds the address" for "the address stops moving."

**Quorum**
The majority of etcd members required before a write is accepted. Two of three. Lose two of three members and etcd stops serving reads as well as writes, so the API server becomes unavailable rather than read-only.

**Static pod**
A pod the kubelet runs from a manifest file in `/etc/kubernetes/manifests/`, without the API server's involvement. The API server, controller manager, scheduler, and etcd all run this way, which is how a control plane starts itself before there is an API server to schedule anything.

Deleting a static pod with kubectl doesn't remove it, because the kubelet recreates it from the file within seconds. To stop one, move its manifest out of the directory.

**Taint / toleration**
A taint is a marker on a node that repels pods which don't explicitly tolerate it. `kubeadm` applies `node-role.kubernetes.io/control-plane:NoSchedule` to every control plane node, which is why ordinary pods won't schedule on this cluster until worker nodes exist.

**Virtual IP (vIP)**
The floating address, 172.16.1.103, that one load balancer holds at a time and that `d-k8s-api.opnsense.lab` resolves to.

**VRRP**
Virtual Router Redundancy Protocol. How the two load balancers agree on which of them owns the vIP. IP protocol 112, unicast in this configuration.

**VXLAN**
The encapsulation Calico uses here. Pod-to-pod traffic between nodes is wrapped in UDP 4789 and unwrapped on the far side, so the underlying network never has to know pod addresses exist. Costs 50 bytes of MTU.

## Known Gaps

Honest list of what isn't finished or isn't right yet.

| Gap                                                                             | Impact                                                                           |
| ------------------------------------------------------------------------------- | -------------------------------------------------------------------------------- |
| No `ansible.cfg`, so roles don't resolve from a fresh clone                     | Every run needs `ANSIBLE_ROLES_PATH=roles`. Fix: `ansible/ansible.cfg`           |
| `tofu output ansible_inventory` uses different group names than `inventory.yml` | The generated inventory can't be used as-is. Reconcile the names first           |
| `agent.enabled = true` before `qemu-guest-agent` exists                         | Proxmox operations can block until a 15-minute timeout. See the OpenTofu README  |
| No CSI driver and no StorageClass                                               | Any PersistentVolumeClaim stays `Pending` forever                                |
| No ingress controller, no metrics-server                                        | No cluster-external HTTP routing, and `kubectl top` returns an error             |
| No upgrade playbook                                                             | The 1.35 to 1.36 exercise is manual for now                                      |
| Calico's version is hardcoded in two URLs                                       | Bumping it means editing `tasks/primary.yml` in two places                       |
| Two load balancers, no spare                                                    | Patching one leaves the other as a single point of failure                       |
| etcd shares a disk with everything else, and nothing snapshots it               | An etcd loss is a cluster rebuild. Fine for a lab, stated so it's a choice       |
| `auth_pass` and the cloud-init public key are committed                         | Low risk here, but neither would belong in git in anything real                  |
| kube-proxy's `mode` isn't pinned                                                | The cluster takes the release default, and that default changes between releases |

On that last one: keepalived's `auth_pass` is a group identifier rather than a credential, and VRRP sends it in cleartext anyway, so committing it changes nothing about the security of this lab. A public key is public. Both are noted because "it's fine here" and "it's fine" are different statements, and the next repo might not be a lab.

Pinning kube-proxy's `mode` is worth doing before the 1.35 to 1.36 upgrade rather than after, so the backend is a decision rather than a surprise. Check what it's using now with `kubectl -n kube-system get cm kube-proxy -o yaml`.

## License

MIT. See [LICENSE](LICENSE).
