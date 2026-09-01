# Ansible Role: control_nodes

Brings up the Kubernetes control plane with `kubeadm`. 

It bootstraps one node, joins the rest to it, then installs Calico.

Intended to run after `common`, which installs/configures containerd, the kubeadm packages, swap, sysctl stuff, and `/etc/hosts`.

## Requirements

- `common` has already run on these hosts.
- `load_balancers` has already run and the vIP answers on 6443. `controlPlaneEndpoint` points at the vIP name, so it has to resolve and the endpoint has to be up before any node can join.
- A `control_nodes` inventory group, with one `primary_control_node`.
- Reaches outbound to `registry.k8s.io` for images and `raw.githubusercontent.com` for Calico manifests.

## Role Variables

### From Inventory

Defined in `group_vars/all.yml` (except `ansible_host`, which is per host in the inventory file).

| Variable               | Example                   | Use                                                    |
| ---------------------- | ------------------------- | ------------------------------------------------------ |
| `primary_control_node` | `d-k8s-cn01.opnsense.lab` | Which node gets `kubeadm init`.                        |
| `vip_hostname`         | `d-k8s-api`               | Short name for the vIP                                 |
| `vip_domain`           | `opnsense.lab`            | Domain for `vip_hostname`, for the FQDN                |
| `pod_cidr`             | `10.244.0.0/16`           | `podSubnet` in kubeadm, and the Calico IP pool         |
| `service_cidr`         | `10.96.0.0/12`            | `serviceSubnet` in kubeadm                             |
| `ansible_host`         | `172.16.1.105`            | `--apiserver-advertise-address` when a secondary joins |

### Role Defaults

From `defaults/main.yml`.

| Variable                                     | Default | Use                                                                    |
| -------------------------------------------- | ------- | ---------------------------------------------------------------------- |
| `control_nodes_copy_kubeconfig_to_localhost` | `false` | Fetch `admin.conf` to `~/.kube/config` on the machine running Ansible  |
| `control_nodes_join_token_ttl`               | `5m`    | Join token Time to Live (TTL)                                          |

### Hardcoded Stuff

Not variables. To change one, edit the file it lives in.

| Setting           | Value               | File                                      |
| ----------------- | ------------------- | ----------------------------------------- |
| Calico version    | `v3.32.1`           | `tasks/primary.yml`, on two manifest URLs |
| Cluster name      | `dev-homelab`       | `templates/kubeadm-config.yaml.j2`        |
| Pod encapsulation | VXLAN, BGP disabled | `templates/calico-installation.yaml.j2`   |

## Example Playbook

  ```yaml
  - name: Configure the control plane
    hosts: control_nodes
    become: true
    roles:
      - control_nodes
  ```

- In this repo it runs from `playbooks/site.yml`, guarded by group membership:

  ```yaml
  - name: Run control plane role
    ansible.builtin.include_role:
      name: control_nodes
    when: "'control_nodes' in group_names"
  ```

## What the Role Does

- `tasks/main.yml` splits on `primary_control_node`: 
  * the primary runs `primary.yml`
  * everything else runs `secondaries.yml`
- Both end up with a kubeconfig at `/root/.kube/config`.

### The Primary

1. Checks `GET /healthz` first and skips the bootstrap if the control plane already answers, which is (should) make the role safe to run twice because`kubeadm init` fails against a working cluster.
2. Templates `/root/kubeadm-config.yaml`, pulls the images, and runs `kubeadm init --upload-certs`. 
  * The config points `controlPlaneEndpoint` at the vIP name, lists the vIP and every control node as cert SANs, and pins `cgroupDriver: systemd` to match the containerd setting `common` writes.

### The Secondaries

1. Each node skips the join if `/etc/kubernetes/kubelet.conf` already exists.
2. Join credentials are generated on the primary with `delegate_to` and `run_once` (with `no_log`): a certificate key, a fresh upload of the control plane certs, and a join token. 
  * The token only has to survive this play, so a short TTL is fine. Preferred, actually.
  * `throttle: 1` joins the nodes one at a time. Two nodes joining etcd simultaneously can be a bad idea. It's a small cluster, so minimal time saved, anyway.

### Calico

Runs on the primary after the bootstrap, with `KUBECONFIG` pointed at `admin.conf`. 

The CRDs and the Tigera operator come from the upstream manifests, then an `Installation` resource built from `pod_cidr`.

VXLAN with BGP disabled is fine for a small training lab L2 with no BGP peer to talk to.

Each step waits on the one before it (so the role doesn't return until the CNI is actually up):
  - The CRD to be Established
  - `tigerastatus/calico` to appear
  - Then to go Available 

## Checking It

  ```sh
  kubectl get nodes -o wide                     # all control nodes registered and Ready
  kubectl -n kube-system get pods -l component=etcd
  kubectl get tigerastatus                      # Calico finished rolling out
  kubectl config view --minify \
    -o jsonpath='{.clusters[0].cluster.server}'  # should be the vIP, not a node
  ```

On a re-run, the bootstrap and join tasks should both report `skipped`.
