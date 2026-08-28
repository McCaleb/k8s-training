# k8s-training
Docs and automation for building out kubernetes environment

| Role          | Name       | IPv4         | VM ID |
| ------------- | ---------- | ------------ | ----- |
| Load Balancer | d-k8s-lb01 | 172.16.1.101 | 1001  |
| Load Balancer | d-k8s-lb02 | 172.16.1.102 | 1002  |
| vIP           | d-k8s-api  | 172.16.1.103 |       |
| Control Node  | d-k8s-cn01 | 172.16.1.104 | 1004  |
| Control Node  | d-k8s-cn02 | 172.16.1.105 | 1005  |
| Control Node  | d-k8s-cn03 | 172.16.1.106 | 1006  |
| Worker Node   | d-k8s-wk01 | 172.16.1.107 | 1007  |
| Worker Node   | d-k8s-wk02 | 172.16.1.108 | 1008  |
| Worker Node   | d-k8s-wk03 | 172.16.1.109 | 1009  |
| Worker Node   | d-k8s-wk04 | 172.16.1.110 | 1010  |
| Worker Node   | d-k8s-wk05 | 172.16.1.111 | 1011  |
| Worker Node   | d-k8s-wk06 | 172.16.1.112 | 1012  |

| Item                   | Value                                            | 
| ---------------------- | ------------------------------------------------ |
| Control plane endpoint | `d-k8s-api.opnsense.lab:6443`                    |
| vIP                    | 172.16.1.103                                     |
| LAN                    | 172.16.1.0/24                                    |
| Pod CIDR               | 10.244.0.0/16                                    |
| Service CIDR           | 10.96.0.0/12                                     |
| CNI                    | Calico via Tigera operator. VXLAN & BGP disabled |

- Two other addresses are derived rather than chosen:
  1. The `kubernetes` Service takes the first address in the service CIDR, 10.96.0.1. 
  2. CoreDNS takes the tenth, 10.96.0.10, and that address is written into every pod's `/etc/resolv.conf`.

## Version

- The plan is to build on 1.35, then upgrade to 1.36 as a separate exercise.
  * This is set with the `k8s_minor_version` Ansible variable.
  * That variable sets the `pkgs.k8s.io` repo path within the `.sources file. And that repo carries kubeadm, kubelet, kubectl, and cri-tools.
- The CNCF exam environment tracks recent stable releases within ~four to eight weeks.

| Component          | How to find version        | Version set by        | Pinned  |
|--------------------|----------------------------|-----------------------|---------|
| Debian             | `cat /etc/debian_version`  | *latest stable        | n/a     |
| Node kernel        | `uname -r`                 | Debian release        | No      |
| systemd            | `systemctl --version`      | Debian release        | No      |
| nftables userspace | `nft -v`                   | Debian release        | No      |
| containerd         | `containerd --version`     | Debian release        | No      |
| runc               | `runc --version`           | Debian release        | No      |
| cri-tools (crictl) | `crictl --version`         | kubeadm dependency    | No      | 
| kubeadm            | `kubeadm version`          | pkgs.k8s.io repo path | Yes     |
| kubelet            | `kubelet --version`        | pkgs.k8s.io repo path | Yes     |
| kubectl            | `kubectl version --client` | pkgs.k8s.io repo path | No      |
| Tigera operator    |  URL in manifest           | Ansible variable      | **Yes** |

# ProxMox

## Affinity



# API server load balancers

- The Kubernetes API server runs on 3 control plane nodes. 
- Clients need *one* address to reach it, and that address has to survive the loss of any single system. 
- Two dedicated Debian VMs provide this. Each runs two daemons:
    * [HAProxy](https://www.haproxy.org/) picks which control plane node serves a connection.
    * [Keepalived](https://www.keepalived.org/) decides which of the two VMs owns the shared address.
      - Keepalived does this using [Virtual Router Redundancy Protocol (VRRP)](https://www.haproxy.com/glossary/what-is-vrrp-virtual-router-redundancy-protocol)

## Keepalived

- The two nodes exchange VRRP advertisements every second and elect the highest-priority healthy node as MASTER. 
- The MASTER adds `172.16.1.30/24` to `eth0` and sends gratuitous ARP so switches relearn where the address lives. 
- The other two carry it in configuration only. It is not present on their interfaces.
- If advertisements stop, each remaining node waits out `Master_Down_Interval` (about 3.5 seconds) and the highest-priority survivor claims the address.
- *VRRP needs a single layer 2 segment.* All two nodes and the vIP share one broadcast domain. 

## HAProxy

HAProxy listens on `*:6443` and forwards to the two control plane nodes on 6443. It runs in `mode tcp`, relaying bytes without decrypting them, so the client's TLS session reaches the API server intact.

That matters because Kubernetes authenticates clients by their TLS certificate. If HAProxy terminated TLS, the API server would see HAProxy's identity on every request instead of the real client's, and RBAC would fall apart.

Backend selection is `leastconn`. 

### Health Checks
- The k8s docs explain API endpoints used for health checks: [livez, and readyz](https://kubernetes.io/docs/reference/using-api/health-checks/).
  * We're using `GET /readyz` for health checks, every 3 seconds, and two consecutive failures mark a backend down. So worst-case detection is ~9 seconds.

> Sometimes `/readyz` and `/livez` disagree during shutdown. On SIGTERM, the API server starts failing `/readyz` immediately while it keeps serving existing work. And `/livez` stays green throughout. **That gap is what lets a draining node be pulled from rotation before it stops listening.**

- HAProxy runs on all two nodes no matter which one holds the vIP. Idle instances *keep health checking*, so they already know which API servers are alive the moment the address moves to them.

## Coupling 

- VRRP does not detect application failure. If HAProxy dies on the node holding the vIP, keepalived is perfectly happy. 
- The machine is up, advertisements keep flowing, and the address stays put while clients hit a closed port.
- To deal with this, a `track_script` runs `pgrep -x haproxy` every 2 seconds. On failure the instance enters FAULT and releases the vIP.
- The check only confirms the process exists. Don't tie it to a backend health check, because that would mean the vIP refuses to exist before the cluster is built...and it would move the address during routine control plane maintenance.

## Failure handling

| Failure            | Handled by           | Detection    |
| ------------------ | -------------------- | ------------ |
| Control plane node | HAProxy health check | ~9 s         |
| Load balancer node | VRRP election        | 3.4 to 3.6 s |
| HAProxy process    | `track_script`       | ~4 s         |

With two load balancer nodes there is no spare. While one is down for patching, the other is a single point of failure for the API endpoint. 


If both go down, running pods keep running. The kubelet does not need the API server to keep existing containers alive, and in-cluster traffic to `kubernetes.default.svc` never touches the vIP. What stops is `kubectl`, worker kubelet status reporting, kube-proxy updates, and `kubeadm join`. The control plane itself is unaffected, since its components talk to `127.0.0.1:6443`.

> [!IMPORTANT]
> That state (both HAProxy servers down) is survivable for minutes, not hours. Once worker kubelets stop reporting, the control plane marks those nodes `NotReady` and eventually starts evicting their pods onto nodes it also cannot reach.

## Client path

- `kubectl` resolves `d-k8s-api.opnsense.lab` to `172.16.1.103`, connects on 6443, and HAProxy relays to a healthy control plane node. 

- Worker kubelets, kube-proxy, and `kubeadm join` take the same path (Control plane components talk to `127.0.0.1:6443` and do not depend on the vIP at all).

- *Failover moves an address, not connections.* HAProxy's session state lives in one process on one node and is not replicated. When the vIP moves, the new holder knows nothing about connections established through the old one, so those sessions break. Clients see a reset or a timeout, not a clean close.

- [Watches](https://kubernetes.io/docs/reference/using-api/api-concepts/#efficient-detection-of-changes) reconnect on their own. When the connection breaks, client-go reopens it from the last resource version it saw. `kubectl exec` and `port-forward` don't have that, so those sessions die.

## Where things are

| What              | Where                                                        |
| ----------------- | ------------------------------------------------------------ |
| HAProxy config    | `/etc/haproxy/haproxy.cfg` (identical on both nodes)         |
| Keepalived config | `/etc/keepalived/keepalived.conf` (differs only by priority) |
| Stats page        | `http://<node>:8404/stats`                                   |
| Logs              | `journalctl -fu haproxy`, `journalctl -fu keepalived`        |

## Checks and Useful Commands

**Stats**

  `http://172.16.1.101:8404/stats`

**Get status**

  ```bash
  ip -br addr show eth0                      # does this node hold the vIP?
  echo "show stat" | socat stdio /run/haproxy/admin.sock | cut -d, -f1,2,18
  curl -k https://172.16.1.30:6443/readyz    # end to end through the vIP
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
  - Runtime state does not survive a reload, so a reload during maintenance will silently put a disabled node back in rotation.




































# Control Nodes

Three VMs run the K8s control plane.

- Each runs the same 4 programs as *static pods*:
  * `kube-apiserver`
  * `etcd`
  * `kube-controller-manager`
  * `kube-scheduler`
- `kubelet` runs as a systemd serviceon every node and is what starts static pods.
- Three copies of etcd need a majority of its members to agree before it accepts a write. 
  * Three members tolerate one failure, because two of three is still a majority. 
  * Two members tolerate none, because one of two is not.

## Vocabulary

**Static pod**
A pod the kubelet runs from a manifest file in `/etc/kubernetes/manifests/`, without the API server's involvement. The API server, controller manager, scheduler, and etcd all run this way, which is how a control plane starts itself before there is an API server to schedule anything. 

Deleting a static pod with kubectl does not remove it, because the kubelet recreates it from the file within seconds. To stop one, move its manifest out of the directory.

**Taint**
A marker on a node that repels pods which do not explicitly tolerate it. `kubeadm` applies `node-role.kubernetes.io/control-plane:NoSchedule` to every control plane node, which is why ordinary pods will not schedule on this cluster until worker nodes exist.

**Container Network Interface (CNI)** 
The plugin system that gives pods their addresses and carries traffic between them. Kubernetes ships no CNI of its own. Until you install one, the kubelet reports the node as NotReady.

**Quorum**
The majority of etcd members required before a write is accepted. Two of three. Lose two of three members and etcd stops serving reads as well as writes, so the API server becomes unavailable rather than read-only.

**Certificate Subject Alternative Name**
A field in a TLS certificate listing the names and addresses that certificate is valid for. Connecting to an API server by a name absent from its SAN list produces a certificate error. This is  why the SAN list is decided before the certificates are generated and is awkward to change afterward.

**Endpoint** 
This word carries 3 unrelated meanings in this guide:
1. The control plane endpoint is `d-k8s-api.opnsense.lab:6443`
2. The name clients dial. Service endpoints are the backend addresses behind a Kubernetes Service. 
3. An HAProxy backend is sometimes called an endpoint in proxy documentation.

## Three Addresses That Are Easy to Confuse

| Name                   | Value                         | What it is                                                                |
| ---------------------- | ----------------------------- | ------------------------------------------------------------------------- |
| Control plane endpoint | `d-k8s-api.opnsense.lab:6443` | DNS name                                                                  | 
| Virtual IP (vIP)       | 172.16.1.103                  | Floating address that `d-k8s-api.opnsense.lab` resolves to                |
| Advertise address      | 172.16.1.104, .105, .106      | Control plane node's own address, published into the `kubernetes` Service |

- The control plane endpoint is a name. 
- The vIP is where that name points. The
advertise address is how a specific node identifies itself to the cluster.
Traffic to the first two passes through HAProxy. Traffic to the third does not.

## Three command-line tools

They operate at different layers.

| Tool      | Talks to                    | When you use it                                                                                    |
| --------- | --------------------------- | -------------------------------------------------------------------------------------------------- |
| `kubectl` | The API server              | Almost always                                                                                      |
| `crictl`  | containerd, through the CRI | The API server is down, or a pod never started, so `kubectl` cannot tell you anything              |
| `ctr`     | containerd directly         | Almost never. Bypasses the CRI and does not see k8s containers unless you name the right namespace |

- When `kubectl get pods` can't help because the control plane itself is broken, `crictl ps -a` on the node is the tool that can.


## Disk Latency

- etcd only acknowledges a write after fdatasync returns, so its [performance](https://etcd.io/docs/v3.7/op-guide/performance/) depends on fsync latency rather than throughput. 
- A disk that does well on sequential writes can still be an issue. 
- When fsync is slow, etcd's internal heartbeats miss their deadlines, leader elections churn, and the API server returns intermittent errors. 
- This can be confusing: Nothing in the k8s layer points at the disc, so this is worth ruling out before it can happen.
- Use `findmnt` to make sure you don't run this against something mounted as tmpfs in memory.

```
apt-get install -y fio
mkdir -p /root/fiotest
fio --rw=write --ioengine=sync \
--fdatasync=1 --directory=/root/fiotest \
--size=22m --bs=2300 --name=etcdtest
```

- Check out the 99th percentile figure on the fsync/fdatasync/sync_file_range line. etcd's hardware guidance sets the target below 10 ms. Consumer NVMe drives usually lands near 1 ms.

