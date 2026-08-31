# Ansible Role: load_balancers

Builds a highly available endpoint for the Kubernetes API server on a pair of
nodes. HAProxy forwards TCP connections on port 6443 to whichever control plane
nodes are healthy, and keepalived floats a virtual IP between the two load
balancers so the endpoint survives losing one of them.

Written for Debian. It installs with `apt` and assumes Debian's HAProxy
packaging, so it needs work before it will run on EL (RHEL, AlmaLinux,
Rocky).

## Requirements

- Debian, or a Debian derivative, on the target hosts.
- Privilege escalation. The role writes to `/etc`, creates a system account and
  manages services.
- Fact gathering. The templates read `ansible_facts.hostname` and
  `ansible_facts.default_ipv4.interface`.
- Two hosts in a `load_balancers` inventory group, sharing a layer 2 segment
  with the VIP. VRRP advertisements are unicast, but the VIP still has to live
  on a subnet both nodes are attached to.
- A `control_nodes` group. Its members become the HAProxy backend servers.
- VRRP (IP protocol 112) permitted between the two load balancers, and TCP 6443
  reachable from anything that talks to the cluster.

## Role Variables

The role ships no defaults of its own. It reads the following from inventory:

| Variable | Example | Used for |
| --- | --- | --- |
| `vip_cidr` | `172.16.1.103/24` | The floating address, with prefix length. Required. Added to the default route's interface. |
| `ansible_host` on each `load_balancers` member | `172.16.1.101` | VRRP unicast source and peer, the stats listener bind address, and the keepalived priority. |
| `ansible_host` on each `control_nodes` member | `172.16.1.104` | Backend server address. |

### Priority comes from the address

keepalived's priority is the last octet of the node's `ansible_host`:

    priority {{ ansible_host.split('.')[-1] }}

With `.101` and `.102`, lb02 outranks lb01 and takes the VIP on a cold start
where both nodes boot together. Renumbering the hosts changes which one is
preferred, so it is worth knowing the rule exists.

Both nodes start in `BACKUP` and `nopreempt` is set. A node that comes back
after an outage does not claim the VIP from a healthy peer; it waits for the
peer to fail.

### Settings held in the templates

These are not variables. Change them in the template if you need to.

| Setting | Value | File |
| --- | --- | --- |
| Virtual router ID | 81, must be unique on the layer 2 segment | `keepalived.conf.j2` |
| VRRP `auth_pass` | a group identifier, not a credential. Keeps a stray keepalived from joining the instance | `keepalived.conf.j2` |
| Stats listener | the node's own IP, port 8404, path `/stats` | `haproxy.cfg.j2` |
| API server port | 6443, frontend and backend | `haproxy.cfg.j2` |

## Dependencies

None.

## Example Playbook

    - name: Configure load balancers
      hosts: load_balancers
      become: true
      roles:
        - load_balancers

In this repo the role runs from `playbooks/site.yml` against the whole cluster,
guarded by group membership:

    - name: Run load balancer role
      ansible.builtin.include_role:
        name: load_balancers
      when: "'load_balancers' in group_names"

## What the role does

1. Installs haproxy, keepalived, socat and libuser. socat is there to read
   backend state off the HAProxy admin socket; libuser is what
   `ansible.builtin.user` needs to create a local account.
2. Creates `keepalived_script`, a nologin system account. keepalived is
   configured with `enable_script_security`, which means it will not run the
   health check as root.
3. Drops `check_haproxy.sh` into `/usr/local/bin`.
4. Copies the stock `haproxy.cfg` to `haproxy.cfg.original`, once.
   `force: false` keeps a second run from overwriting that backup with the
   generated config.
5. Templates both configs. Each is validated before it is written
   (`haproxy -c`, `keepalived -t`), so a bad template fails the task rather
   than the service.
6. Starts and enables haproxy first, then keepalived, so the VIP never lands on
   a node with nothing listening behind it.

Config changes notify a reload rather than a restart, so established
connections survive a re-run.

## How the two halves fit together

**HAProxy forwards connections.** It runs in TCP mode and never terminates
TLS, which would break client certificate auth. The frontend binds `*:6443`
rather than the VIP, so HAProxy starts and health checks on both nodes whether
or not that node currently holds the address. The idle instance is already warm
when the VIP moves to it.

Backends are checked with `GET /readyz`, expecting a 200. `/readyz` is the
endpoint that fails first when a control plane node shuts down; `/livez` would
keep answering. At `inter 3s fall 3`, a control node is marked down about nine
seconds after it stops answering.

Client and server timeouts are set to four hours. The 50 second default cuts
off `kubectl exec` and `kubectl port-forward` sessions.

**keepalived owns the virtual IP.** The two nodes exchange VRRP advertisements
once a second. If the node holding the VIP stops advertising, the other claims
the address in roughly three and a half seconds.

`check_haproxy.sh` ties the two together. It runs every two seconds and has to
pass twice: `pgrep -x haproxy` finds the process, and `ss` shows something
listening on 6443. Two consecutive failures release the VIP, so HAProxy dying
on the active node moves the address in about four seconds. Two consecutive
passes bring the node back into the running.

## Checking it

Find the VIP. Exactly one node should have it:

    ansible load_balancers -b -a 'ip -brief addr'

Watch VRRP state changes:

    journalctl -u keepalived -f

Read backend health without leaving the shell:

    echo "show stat" | socat /run/haproxy/admin.sock stdio | cut -d, -f1,2,18

Or open `http://<load balancer IP>:8404/stats` in a browser. The stats
listener binds the node's own address, not the VIP, so each node reports on
itself.

Confirm the endpoint answers through the VIP:

    curl -sk https://<vip>:6443/readyz

Test failover by stopping HAProxy on whichever node holds the address, then
looking for the VIP on the other one a few seconds later.
