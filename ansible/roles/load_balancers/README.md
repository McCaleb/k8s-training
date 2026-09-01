# Ansible Role: load_balancers

- Builds a endpoints for the Kubernetes API servers.
- HAProxy forwards TCP connections on port 6443 to whichever control plane nodes are healthy
- keepalived floats a virtual IP (vIP) between them.
- Written for Debian. 
  * It installs with `apt` and assumes Debian's HAProxy packaging, so it needs work before it will run on EL (Rocky, AlmaLinux, etc).

## Requirements

- Debian (a Debian derivative like Ubuntu may work).
- Two hosts in a `load_balancers` inventory group, sharing a layer 2 segment with the vIP. 
  * VRRP advertisements are unicast, but the vIP still has to live on a subnet both nodes are attached to.
- A `control_nodes` Ansible group. Its members become the HAProxy backend servers.
- VRRP (IP protocol 112) permitted between the two load balancers, and TCP 6443 reachable from anything that talks to the cluster.

## Role Variables

Two sources: what only the inventory can know, and the role's own defaults.

### From inventory

| Variable                                       | Example           | Used for |
| ---------------------------------------------- | ----------------- | ---------------------------- |
| `vip_cidr`                                     | `172.16.1.103/24` | Ffloating vIP, with prefix   |
| `ansible_host` on each `load_balancers` member | `172.16.1.101`    | VRRP unicast source and peer |
| `ansible_host` on each `control_nodes` member  | `172.16.1.104`    | Backend server address       |

### Priority comes from the address

- *Important*: `elect_priority` defaults to the last octet of the node's `ansible_host`:

    `elect_priority: "{{ ansible_host.split('.')[-1] }}"`
- Not the greatest idea, perhaps, but it works. Set it per host in `host_vars` if you would rather decide the election yourself.
- With `.101` and `.102`, lb02 outranks lb01 and takes the vIP on a cold start where both nodes boot together. 
- Both nodes start in `BACKUP` and `nopreempt` is set. 
- A node that comes back after an outage shouldn't claim the vIP from a healthy peer. It should wait for the peer to fail.

### Role defaults

- In `defaults/main.yml`, as two dicts.

| Variable                                      | Default                      | Used for                                          |
| --------------------------------------------- | ---------------------------- | --------------------------------------------------- |
| `load_balancers_keepalived.virtual_router_id` | `81`                         | The VRID. Needs to be unique on layer 2 segment     |
| `load_balancers_keepalived.auth_pass`         | set in `defaults/main.yml`   | VRRP group id (not a credential).                   |
| `load_balancers_keepalived.elect_priority`    | last octet of `ansible_host` | Election priority, 1 to 254. Higher wins            |
| `load_balancers_haproxy.api_server_port`      | `6443`                       | Port `k8s_apiserver` frontend binds                 |
| `load_balancers_haproxy.stats_listener_port`  | `8404`                       | Port stats listener binds to, on node's own address |

- Heads up on `api_server_port`: it sets the frontend *and* backend `bind` port.

## Example Playbook

    ```yaml
    - name: Configure load balancers
      hosts: load_balancers
      become: true
      roles:
        - load_balancers
    ```

In this repo, the role runs from `playbooks/site.yml` against the whole cluster, guarded by group membership:

    ```yaml
    - name: Run load balancer role
      ansible.builtin.include_role:
        name: load_balancers
      when: "'load_balancers' in group_names"
    ```

## What the role does

1. Installs haproxy, keepalived, socat and libuser. socat is there to read backend state off the HAProxy admin socket. 
2. Creates `keepalived_script`, a nologin system account. keepalived is configured with `enable_script_security`, which means it will not run the health check as root.
3. Drops `check_haproxy.sh` into `/usr/local/bin`.
4. Copies the stock `haproxy.cfg` to `haproxy.cfg.original`, once. `force: false` keeps a second run from overwriting that backup with the generated config.
5. Templates both configs. Each is validated before it is written (`haproxy -c`, `keepalived -t`), so a bad template (should) fail the task.
6. Starts and enables haproxy first, then keepalived, so the vIP never lands on a node with nothing listening behind it.

Config changes notify a reload rather than a restart, so established connections survive a re-run.

## How the two parts fit together

**HAProxy forwards connections.** 
  - Runs in TCP mode and does not terminate TLS (would break client cert auth).
  - The frontend binds `*:6443` rather than the vIP, so HAProxy starts and health checks on both nodes whether or not that node currently holds the address. The idle instance is already warm when the vIP moves to it.

- Backends are checked with `GET /readyz`, expecting a 200. 
  * `/readyz` is the endpoint that fails first when a control plane node shuts down.
  * `/livez` would keep answering. 
  * At `inter 3s fall 3`, a control node is marked down about nine seconds after it stops answering.

- Client and server timeouts are set to four hours. 
- The 50s default cuts off `kubectl exec` and `kubectl port-forward` sessions.

**keepalived owns the virtual IP.** 
- The two nodes exchange VRRP advertisements once a second. 
- If the node holding the vIP stops advertising, the other claims the address in ~3.5s.

- `check_haproxy.sh` ties the two together. 
  * It runs every two seconds.
  * `pgrep -x haproxy` finds the process.
  * `ss` shows something listening on 6443. 
  * Two consecutive failures release the vIP, so HAProxy dying on the active node moves the address in ~4s. 
  * Two consecutive good checks bring the node back into the running.

## Checking it

- Find the vIP. Only one node should have it:

    `ip -brief addr`

- Watch VRRP state changes:

    `journalctl -u keepalived -f`

- Read backend health:

    `echo "show stat" | socat /run/haproxy/admin.sock stdio | cut -d, -f1,2,18`

- Or, open `http://<load balancer IP>:8404/stats` in a browser. 
  * The stats listener binds the node's own address, not the vIP, so each node reports on
itself.

- Confirm the endpoint answers through the vIP:

    `curl -sk https://<vip>:6443/readyz`

- Test failover by stopping HAProxy on whichever node holds the address. Then look for the vIP on the other node a few seconds later.
