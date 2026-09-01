# Ansible Role: load_balancers

Builds a pair of nodes that serve as an endpoint for the Kubernetes API server. 

HAProxy forwards TCP connections on 6443 to whichever control plane nodes are healthy, and keepalived floats a virtual IP (vIP) between the two load balancers.

Written for Debian. It installs with `apt` and assumes Debian's HAProxy packaging, so it needs work before it will run on EL.

## Requirements

- Debian (maybe a derivative like Ubuntu).
- `become: true`.
- Two hosts in a `load_balancers` inventory group
  * These need to share a layer 2 segment with the vIP. 
  * VRRP advertisements are unicast, but the vIP still has to live on a subnet both nodes are attached to.
- A `control_nodes` group. Its members become the HAProxy backends.
- VRRP (IP protocol 112) permitted between the two load balancers, and TCP 6443 reachable from anything that talks to the cluster.

## Role Variables

### From Inventory

From in `group_vars/all.yml` (except `ansible_host`, which is in the inventory).

| Variable                                       | Example           | Use                           |
| ---------------------------------------------- | ----------------- | ----------------------------- |
| `vip_cidr`                                     | `172.16.1.103/24` | The floating vIP, with prefix |
| `ansible_host` on each `load_balancers` member | `172.16.1.101`    | VRRP unicast source and peer  |
| `ansible_host` on each `control_nodes` member  | `172.16.1.104`    | Backend server address        |

### Role Defaults

From `defaults/main.yml` (as two dicts).

| Variable                                      | Default                      | Use                                             |
| --------------------------------------------- | ---------------------------- | ----------------------------------------------- |
| `load_balancers_keepalived.virtual_router_id` | `81`                         | The VRID.                                       |
| `load_balancers_keepalived.auth_pass`         | set in `defaults/main.yml`   | VRRP group id (not a credential)                |
| `load_balancers_keepalived.elect_priority`    | last octet of `ansible_host` | Election priority, 1 to 254. Higher wins.       |
| `load_balancers_haproxy.api_server_port`      | `6443`                       | Port for frontend bind and the backend servers  |
| `load_balancers_haproxy.stats_listener_port`  | `8404`                       | Stats listener, bound to the node's own address |

### Election Priority

`elect_priority` defaults to the last octet of the node's address:

  ```jinja
  elect_priority: "{{ ansible_host.split('.')[-1] }}"
  ```

- Maybe the greatest idea? Perhaps, but it works in this case where the setup is relatively simple. 
  * With `.101` and `.102`, lb02 outranks lb01 and takes the vIP when both nodes boot together. 
  * Renumbering the hosts changes which one wins, so set it explicitly in `host_vars` if you'd rather decide the election yourself.

- Both nodes start in `BACKUP` with `nopreempt` set, so a node that comes back after an outage waits for the peer to fail instead of taking the vIP from it.

## Example Playbook

  ```yaml
  - name: Configure load balancers
    hosts: load_balancers
    become: true
    roles:
      - load_balancers
  ```

In this repo it runs from `playbooks/site.yml` against the whole cluster, guarded by group membership:

  ```yaml
  - name: Run load balancer role
    ansible.builtin.include_role:
      name: load_balancers
    when: "'load_balancers' in group_names"
  ```

## What the Role Does

1. Installs haproxy, keepalived, socat and libuser. socat reads backend state off the HAProxy admin socket. libuser is what `ansible.builtin.user` needs to create a local account (sometimes not installed by default on smaller Debian and Ubuntu images).
2. Creates `keepalived_script`, a nologin system account. keepalived runs with `enable_script_security`. We don't want the health check to run as root.
3. Places `check_haproxy.sh` in `/usr/local/bin`.
4. Copies the stock `haproxy.cfg` to `haproxy.cfg.original`, once. `force: false` keeps a second run from overwriting the backup with generated config. We may want to reference it later on.
5. Templates both configs, each validated before it is written (`haproxy -c`, `keepalived -t`), so a bad template (should) fail the task rather than the service.
6. Starts and enables haproxy *first*, then keepalived, so the vIP never lands on a node with nothing listening behind it.

Config changes notify a reload rather than a restart, so established connections should survive a re-run.

## How HAProxy and keepalived Fit Together

HAProxy runs in TCP mode and doesn't terminate TLS (In this case, that would break client certificate auth). 

The frontend binds `*:6443` rather than the vIP, so both instances start and health check whether or not that node holds the address. The idle one is already "warm" when the vIP moves to it.

Backends are checked with `GET /readyz`, expecting a 200. `/readyz` is the endpoint that fails first when a control plane node shuts down; `/livez` keeps answering. Client and server timeouts are four hours, because Debian's stock 50s cuts off `kubectl exec` and `kubectl port-forward`.

keepalived owns the vIP. `check_haproxy.sh` is what ties the two together: it passes only when `pgrep -x haproxy` finds the process and `ss` shows something listening on 6443, so keepalived releases the address when HAProxy is present but not serving.

### Failover Timing

Based on the setup, this is how failover timing *should* work:

| Event                                    | Detected by                            | Time to act                    |
| ---------------------------------------- | -------------------------------------- | ------------------------------ |
| Control node stops answering `/readyz`   | HAProxy, `inter 3s fall 3`             | ~9s to mark it down            |
| HAProxy dies on the node holding the vIP | `check_haproxy.sh`, every 2s, `fall 2` | ~4s to release the vIP         |
| Node holding the vIP stops advertising   | VRRP, `advert_int 1`                   | ~3.5s for the peer to claim it |

## Checking It

  ```sh
  ip -brief addr                              # exactly one node should hold the vIP
  journalctl -u keepalived -f                 # VRRP state changes
  curl -sk https://<vip>:6443/readyz          # the endpoint answers through the vIP
  echo "show stat" | socat /run/haproxy/admin.sock stdio | cut -d, -f1,2,18
  ```

The stats page at `http://<load balancer IP>:8404/stats` binds each node's own address, not the vIP, so each one reports on *itself*, not both nodes.

**To test failover:** Stop HAProxy on whichever node holds the address and look for the vIP on the other one a few seconds later.
