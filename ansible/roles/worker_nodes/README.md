# Ansible Role: worker_nodes

Joins worker nodes to the cluster.

> **Status: incomplete.** The task file is a work in progress and the role is commented out in `playbooks/site.yml`. Don't run it yet. The sections below are the shape it will take; see [What Is Left](#what-is-left) for the current state.

## Requirements

- Debian, or a derivative like Ubuntu.
- `become: true`.
- `common` has already run, so containerd, the kubeadm packages, swap and sysctl prep are in place.
- `control_nodes` has already run and the control plane is up.
- A `worker_nodes` inventory group.

## Role Variables

### From Inventory

Defined in `group_vars/all.yml`.

| Variable               | Example                   | Use                                              |
| ---------------------- | ------------------------- | ------------------------------------------------ |
| `primary_control_node` | `d-k8s-cn01.opnsense.lab` | Where join credentials are generated             |

### Role Defaults

None yet. `defaults/main.yml` is empty.

## Example Playbook

```yaml
- name: Join worker nodes
  hosts: worker_nodes
  become: true
  roles:
    - worker_nodes
```

Once the role works, uncomment the block already present in `playbooks/site.yml`:

```yaml
- name: Run worker node role
  ansible.builtin.include_role:
    name: worker_nodes
  when: "'worker_nodes' in group_names"
```

## What the Role Does

Nothing usable yet.

## What Is Left

`tasks/main.yml` currently holds three commands copied from `control_nodes/tasks/secondaries.yml` — generate a certificate key, upload the control plane certs, create a join command — but they run on the worker itself rather than on the control plane node, and nothing consumes their output. There is no join task.

To finish it:

- Generate the join command on `primary_control_node` with `delegate_to` and `run_once`, as `control_nodes` does. Workers don't need `kubeadm certs certificate-key` or `upload-certs`; those exist to share control plane certificates and have no purpose here.
- Run the plain join command, without `--control-plane`.
- Guard the join on `/etc/kubernetes/kubelet.conf` not existing, so a re-run is a no-op.
- Drop the `pull images on NON-primary control nodes` block, or rewrite it as an unconditional `kubeadm config images pull`. The `primary_control_node` comparison is left over from the control plane role and is always true here.

## Checking It

```sh
kubectl get nodes -o wide                    # workers registered and Ready
kubectl get pods -A -o wide                  # pods scheduling onto them
```
