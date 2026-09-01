# Ansible Role: common

Baseline configuration for every node in the cluster.

- Time, name resolution, logging, and basic packages. 
- Nodes in `control_nodes` or `worker_nodes` also get the container runtime, kernel and sysctl prep, and the kubeadm packages.
- Written for Debian. It installs with `apt` and expects Debian's chrony layout (`/etc/chrony/sources.d/`), so it needs work before it will run on EL.

## Requirements

- Debian (will likely work on a derivative like Ubuntu).
- `become: true`. The role writes to `/etc`, manages services and installs packages.
- Collections: listed in `ansible/requirements.yml` and installed with `ansible-galaxy collection install -r requirements.yml`.
  * `community.general` (`timezone`, `ini_file`)
  * `ansible.utils` (`ipaddr`)
- All three of `load_balancers`, `control_nodes` and `worker_nodes` must exist as inventory groups. `/etc/hosts` is built from all of them, so the template fails if one is missing from the inventory, even when you're only running against one group.
- Outbound reach to `pkgs.k8s.io` and to whatever NTP sources you list.

## Role Variables

### From Inventory

From `group_vars/all.yml`.

| Variable                     | Example           | Use                                                   |
| ---------------------------- | ----------------- | ----------------------------------------------------- |
| `vip_cidr`                   | `172.16.1.103/24` | API endpoint line in `/etc/hosts`. Prefix is stripped |
| `vip_hostname`               | `d-k8s-api`       | Short name for the vIP                                |
| `vip_domain`                 | `opnsense.lab`    | Domain for `vip_hostname`, for the FQDN               |
| `k8s_release`                | `"1.35"`          | `pkgs.k8s.io` repo to add. Minor version, no patch    |
| `ansible_host` on every node | `172.16.1.104`    | Address written into `/etc/hosts` for that node       |

- Note: Make sure to quote `k8s_release`. Unquoted, YAML reads the version as a float, and `1.40` becomes `1.4`.

### Role Defaults

From `defaults/main.yml`.

| Variable                          | Default                                  | Use                                                      |
| --------------------------------- | ---------------------------------------- | -------------------------------------------------------- |
| `common_timezone`                 | `America/Chicago`                        | Passed to `community.general.timezone`                   |
| `common_qemu_guest_agent`         | `true`                                   | Install and start qemu-guest-agent. Set `false` on fe    |
| `common_journald_persistent`      | `true`                                   | Keep journald on disk across reboots                     |
| `common_packages`                 | `tree`, `vim`, `apt-file`, `needrestart` | Convenience packages. `[]` skips the task                |
| `common_ntp_sources`              | 2 on my LAN, then NIST & Cloudflare      | Rendered into `/etc/chrony/sources.d/ansible.sources`    |
| `common_ntp_minsources`           | `2`                                      | Num of chrony sources that must agree.                   |
| `common_ntp_verify`               | `true`                                   | Run the `chronyc waitsync` gate after configuring chrony |
| `common_k8s_prereq_packages`      | `conntrack`, `socat`, `containerd`, etc. | Runtime dependencies. k8s nodes only                     |
| `common_containerd_systemdcgroup` | `true`                                   | `SystemdCgroup` in `/etc/containerd/config.toml`         |
| `common_k8s_hold_packages`        | `kubeadm`, `kubelet`, `kubectl`          | Pinned with `dpkg_selections`. `[]` skips the task       |

- Each entry in `common_ntp_sources` is a dict. `directive` defaults to `server`, `options` to `iburst`:

  ```yaml
  common_ntp_sources:
    - directive: server
      address: 172.16.1.1
      options: iburst maxpoll 8
    - directive: pool
      address: time.nist.gov
      options: iburst maxsources 2
  ```

- Keep `common_ntp_minsources` <= the number of sources you list. Set it higher and chrony never disciplines the clock, and `common_ntp_verify` fails.

## Example Playbook

  ```yaml
  - name: Configure all cluster nodes
    hosts: all
    become: true
    roles:
      - common
  ```

- In this repo it runs from `playbooks/site.yml`, after `debian_update` and ahead of the per-node-type roles:

  ```yaml
  - name: Run common role
    ansible.builtin.import_role:
      name: common
  ```

## What the Role Does

On every node:

1. Installs and starts `qemu-guest-agent`, so Proxmox can use it.
2. Installs `common_packages`.
3. Replaces systemd-timesyncd with chrony.
4. Sets the timezone.
5. Writes `/etc/hosts` from a template, after removing `update_etc_hosts` from `/etc/cloud/cloud.cfg` (Left in place, cloud-init may rewrite the file on the next boot and the entries disappear).
6. Sets `Storage=persistent` in `journald.conf`, then restarts and flushes journald.
7. Drops an `ll` alias into `/etc/profile.d/`. Just an idiosyncrasy of mine.
8. Hands off to `k8s_nodes.yml` for `control_nodes` and `worker_nodes`. See [Kubernetes Node Prep](#kubernetes-node-prep).

## Time

- This role is opinionated when it comes to time. systemd-timesyncd is stopped and purged, chronyd is installed. 

- Chrony's default `pool` and `server` lines are commented out and the sources from `common_ntp_sources` are used.

- At the default `minsources 2`, *chrony won't step the clock until two sources agree*, so one wrong server can't drag a node off on its own.

- Handlers are flushed early, then `chronyc waitsync 30 0.1 0.0 1` [blocks until the clock settles](https://chrony-project.org/doc/4.8/chronyc.html), giving up after 30 tries. A node with a bad clock might issue certificates that aren't valid, and etcd doesn't put up with much drift between members. So the play fails here rather than somewhere less obvious later. It's gotta be pretty far off, but still good practice. 
  * Set `common_ntp_verify: false` to skip the gate. The `waitsync` thresholds themselves are literals in `chrony.yml`.
  * `waitsync [max-tries [max-correction [max-skew [interval]]]]`

## Hosts File

- Every node gets the whole cluster in `/etc/hosts`, with the vIP under `vip_hostname`. Node-to-node name resolution doesn't depend on DNS being up.
- The file is rebuilt on every run, so adding a node to the inventory and re-running updates all of them.

## Kubernetes Node Prep

Hosts in `control_nodes` or `worker_nodes` only.

1. Installs `common_k8s_prereq_packages`. What the kubelet and kube-proxy need at runtime, plus containerd.
2. Loads `overlay` and `br_netfilter`, persisted in `/etc/modules-load.d/`.
3. Turns swap off and comments out the swap lines in `/etc/fstab`. The kubelet (probably) won't start with swap on.
4. Writes `/etc/sysctl.d/99-kubernetes.conf` and reloads. The `99-` prefix keeps it last, so nothing else in `sysctl.d` overrides it.
5. Writes `/etc/containerd/config.toml` and `/etc/crictl.yaml`. `SystemdCgroup` has to match the kubelet's cgroup driver, which `control_nodes` sets to `systemd`.
6. Adds the `pkgs.k8s.io` repo for `k8s_release`, installs kubelet, kubeadm, kubectl and cri-tools, then holds `common_k8s_hold_packages`. Held packages shouldn't get messed with during an unattended upgrade or a `debian_update` run. I prefer to upgrade this cluster one minor version at a time.

## Checking It

  ```sh
  chronyc tracking && chronyc sources -v      # clock, sources, and current offset
  systemctl status systemd-timesyncd          # should be gone
  ls -d /var/log/journal                      # journal is on disk, not tmpfs
  getent hosts d-k8s-api d-k8s-cn01           # names resolve without DNS
  crictl version && swapon --show             # k8s nodes: runtime up, swap empty
  apt-mark showhold                           # k8s nodes: the three holds took
  ```
