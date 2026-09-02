# Ansible Role: worker_nodes

Joins worker nodes to the cluster.

The role is deliberately small. By the time it runs, `common` has already installed containerd and the kubeadm packages and done the kernel and sysctl work, and `control_nodes` has a control plane answering on the vIP. All that is left is one `kubeadm join`.

## Requirements

- Debian, or a derivative like Ubuntu.
- `become: true`.
- `common` has already run, so containerd, the kubeadm packages, swap and sysctl prep are in place.
- `control_nodes` has already run and the control plane is up.
- A `worker_nodes` inventory group.
- The Ansible controller can reach `primary_control_node`. The join command is generated there, not on the worker.

## Role Variables

### From Inventory

Defined in `group_vars/all.yml`.

| Variable               | Example                   | Use                                  |
| ---------------------- | ------------------------- | ------------------------------------ |
| `primary_control_node` | `d-k8s-cn01.opnsense.lab` | Where join credentials are generated |

### Role Defaults

From `defaults/main.yml`.

| Variable                    | Default | Use                                                   |
| --------------------------- | ------- | ----------------------------------------------------- |
| `worker_nodes_join_token_ttl` | `5m`  | Time to live on the bootstrap token `kubeadm` creates |

The token only has to survive this play, so a short TTL is preferred rather than merely tolerated. A 24-hour token left lying around is a credential that can enrol a machine into the cluster.

## Example Playbook

```yaml
- name: Join worker nodes
  hosts: worker_nodes
  become: true
  roles:
    - worker_nodes
```

In this repo it runs from `playbooks/site.yml` against the whole cluster, guarded by group membership:

```yaml
- name: Run worker node role
  ansible.builtin.include_role:
    name: worker_nodes
  when: "'worker_nodes' in group_names"
```

## What the Role Does

1. Stats `/etc/kubernetes/kubelet.conf`. Its presence means this node has already joined, and the join task is skipped, so a re-run is a no-op.
2. Generates a join command on `primary_control_node` with `kubeadm token create --print-join-command`, using `delegate_to` and `run_once` so one token covers all six workers. The task is `no_log`, because the token is in the output.
3. Runs that command on each worker.

Unlike `control_nodes/tasks/secondaries.yml`, there is no `kubeadm certs certificate-key` and no `upload-certs`. Those exist to hand a *control plane* node an encrypted copy of the cluster CA so it can run its own API server and etcd member. A worker never gets the CA key, never joins etcd, and needs none of it.

There is also no `throttle`. Control plane nodes join one at a time because etcd members have to be added serially; workers have no such constraint and can all join at once.

### On idempotence

The token task runs on every play, whether or not anything is going to join, and reports `changed`. That is one unused bootstrap token per run, expiring five minutes later. Harmless, but it does mean a "no changes" run isn't achievable for this role as written.

## Checking It

```sh
kubectl get nodes -o wide                        # workers registered and Ready
kubectl get pods -A -o wide                      # pods scheduling onto them
kubectl -n kube-system get ds kube-proxy         # desired equals ready
kubectl describe node d-k8s-wn01 | grep -A3 Taints   # workers carry none
```

A freshly joined worker sits `NotReady` for a few seconds until `calico-node` lands on it and writes the CNI configuration into `/etc/cni/net.d/`. That is expected.

Draining and removing a node is covered in the [main README](../../../README.md#removing-one).
