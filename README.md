# k8s-training
Docs and automation for building out kubernetes environment

## Hosts

| Role          | Name       | IPv4         | VM ID |
| ------------- | ---------- | ------------ | ----- |
| Load Balancer | d-k8s-lb01 | 172.16.1.101 | 1001  |
| Load Balancer | d-k8s-lb02 | 172.16.1.102 | 1002  |
| vIP           | d-k8s-api  | 172.16.1.103 | 1003  |
| Control Node  | d-k8s-cn01 | 172.16.1.104 | 1004  |
| Control Node  | d-k8s-cn02 | 172.16.1.105 | 1005  |
| Control Node  | d-k8s-cn03 | 172.16.1.106 | 1006  |


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


If both go down, running pods keep running. The kubelet does not need the API server to keep existing containers alive, and in-cluster traffic to `kubernetes.default.svc` never touches the VIP. What stops is `kubectl`, worker kubelet status reporting, kube-proxy updates, and `kubeadm join`. The control plane itself is unaffected, since its components talk to `127.0.0.1:6443`.

> [!IMPORTANT]
> That state (both HAProxy servers down) is survivable for minutes, not hours. Once worker kubelets stop reporting, the control plane marks those nodes `NotReady` and eventually starts evicting their pods onto nodes it also cannot reach.

## Client path

- `kubectl` resolves `d-k8s-api.opnsense.lab` to `172.16.1.103`, connects on 6443, and HAProxy relays to a healthy control plane node. 

- Worker kubelets, kube-proxy, and `kubeadm join` take the same path (Control plane components talk to `127.0.0.1:6443` and do not depend on the vIP at all).

- *Failover moves an address, not connections.* HAProxy's session state lives in one process on one node and is not replicated. When the VIP moves, the new holder knows nothing about connections established through the old one, so those sessions break. Clients see a reset or a timeout, not a clean close.

- [Watches](https://kubernetes.io/docs/reference/using-api/api-concepts/#efficient-detection-of-changes) reconnect on their own. When the connection breaks, client-go reopens it from the last resource version it saw. `kubectl exec` and `port-forward` don't have that, so those sessions die.

## Where things are

| What              | Where                                                        |
| ----------------- | ------------------------------------------------------------ |
| HAProxy config    | `/etc/haproxy/haproxy.cfg` (identical on both nodes)         |
| Keepalived config | `/etc/keepalived/keepalived.conf` (differs only by priority) |
| Stats page        | `http://<node>:8404/stats`                                   |
| Logs              | `journalctl -fu haproxy`, `journalctl -fu keepalived`        |

Quick checks:

**Stats**

  `http://172.16.1.101:8404/stats`

**Get status**

  ```bash
  ip -br addr show eth0                      # does this node hold the vIP?
  echo "show stat" | socat stdio /run/haproxy/admin.sock | cut -d, -f1,2,18
  curl -k https://172.16.1.30:6443/readyz    # end to end through the vIP
  ```

## Useful Commands

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