# Ansible Role: debian_update

Patches a Debian host, then deals with what the patch might have left behind:
  - Reboots for a new kernel
  - Restarts the services still running old libraries. The decisions come from [needrestart(1)](https://manpages.debian.org/trixie/needrestart/needrestart.1.en.html).

Intended to run first in `playbooks/site.yml`, so everything built afterwards sits on current packages and any reboot happens before the cluster is configured.

### Why Anything Needs Restarting

When apt replaces a shared library, the file on disk changes but every already-running process keeps the old copy mapped into memory. 

Those processes go on using the old code until something restarts them. `needrestart` finds them by scanning `/proc/<pid>/maps` for mappings with a backing file that's been deleted. Then, it matches each process back to the systemd unit that owns it.

The kernel has a similar problem: a new `vmlinuz` in `/boot` changes nothing until the machine boots it.

## References

I went down a bit of a rabbit hole trying to understand certain behaviors related to apt and `needsrestart`. 

Take a look at [NOTES.md](NOTES.md) for my notes and links to upstream documentation for `NEEDRESTART_SUSPEND`, `DEBIAN_FRONTEND`, the batch output fields, and the `$nrconf` config keys, with the exact quotes and links.

## Requirements

- Debian (Should work fine on a derivative, like Ubuntu).
- `become: true`.
- If `debian_update_reboot` is enabled, the play has to wait out a reboot. The task allows 900 seconds.

## Role Variables

Defined in `defaults/main.yml`.

| Variable                         | Default | Use                                                                           |
| -------------------------------- | ------- | ----------------------------------------------------------------------------- |
| `debian_update_reboot`           | `false` | Reboot when `needrestart` says it's necessary in order to apply a new kernel  |
| `debian_update_restart_services` | `true`  | Restart stale services, but only when no reboot happened                      |

The two aren't independent: a reboot restarts everything anyway, so the service restart is skipped when the reboot task ran. In the tasks that reads as `debian_update_rebooted is skipped`, which is Ansible for "the reboot task didn't run on this host."

With `debian_update_reboot: false` and a kernel upgrade pending, nothing happens: the host keeps running the old kernel until someone reboots it, and `needrestart -b` keeps reporting `KSTA: 2` or `3` on every run.

## Example Playbook

  ```yaml
  - name: Patch and reboot
    hosts: all
    become: true
    roles:
      - role: debian_update
        vars:
          debian_update_reboot: true
  ```

## What the Role Does

1. Installs `needrestart`.
2. Writes `/etc/needrestart/conf.d/00-ansible.conf`, validated with `perl -c`. needrestart is written in Perl and its config files are Perl, evaluated at load time, which is why the settings look like `$nrconf{...}` and why `perl -c` can do a basic syntax check. Parsing is a good idea, because a config that fails makes needrestart die, the hook return non-zero, and every `apt` command errors out.
3. Runs [`apt-get dist-upgrade`](https://manpages.debian.org/trixie/apt/apt-get.8.en.html) with `autoremove`, under [`NEEDRESTART_SUSPEND=1`](https://manpages.debian.org/trixie/needrestart/needrestart.1.en.html#NEEDRESTART_SUSPEND) and [`DEBIAN_FRONTEND=noninteractive`](https://manpages.debian.org/trixie/debconf-doc/debconf.7.en.html#DEBIAN_FRONTEND). `lock_timeout: 300` waits out `unattended-upgrades` if it holds the dpkg lock, instead of failing the play.
4. Runs [`needrestart -b`](https://github.com/liske/needrestart/blob/master/README.batch.md) to see what the upgrade left pending.
5. Reboots only if enabled and a kernel change is pending.
6. Otherwise, runs `needrestart -r a` to restart the stale services (if enabled and there are any).

The config file sets 3 things.

| Setting                          | Effect                                                                         |
| -------------------------------- | ------------------------------------------------------------------------------ |
| `$nrconf{restart} = 'l'`         | List what needs restarting instead of prompting. The prompt would hang Ansible |
| `$nrconf{sendnotify} = 0`        | No wall notifications                                                          |
| `$nrconf{override_rc}{qr(^ssh)}` | Never auto-restart sshd, which would cut the connection mid-play               |

- `qr(^ssh)` is a Perl regex, anchored at the start of the unit name. 
- If you're used to RHEL, remember: Debian's unit is `ssh.service`, not `sshd.service`, and the same pattern for `ssh.socket`.
- You can read about the keys in the [upstream example config](https://github.com/liske/needrestart/blob/master/ex/needrestart.conf), since there is no `needrestart.conf(5)` manpage.
- `NEEDRESTART_SUSPEND=1` during the upgrade keeps needrestart from acting inside the apt transaction (has a tendancy to hang Ansible runs).

## Reading needrestart Output

`needrestart -b` prints machine-readable lines (For some reason, documented in [README.batch.md](https://github.com/liske/needrestart/blob/master/README.batch.md) instead the manpage).

The kernel ones drive the reboot decision:

  | Field  | Name            | Meaning                                       |
  | ------ | --------------- | --------------------------------------------- |
  | `VER`  | version         | needrestart's own version, not the kernel's   |
  | `KCUR` | Kernel CURrent  | The running kernel, read from `/proc/version` |
  | `KEXP` | Kernel EXPected | The highest-versioned image found in `/boot`  |
  | `KSTA` | Kernel STAtus   | The result of comparing the two               |

`KSTA` has 4 values, [defined upstream](https://github.com/liske/needrestart/blob/master/README.batch.md):

  | Value | Meaning                        |
  | ----- | ------------------------------ |
  | `0`   | Unknown, or detection failed   |
  | `1`   | No pending upgrade             |
  | `2`   | ABI compatible upgrade pending |
  | `3`   | Version upgrade pending        |

- A `3` means the release string changed, and `uname -r` will report something different after the reboot.
- A `2` means the release string is identical but the build isn't (e.g., Debian reissues a kernel at the same ABI).
- Other lines appear as needed:
  * `NEEDRESTART-SVC:` once per stale unit
  * `NEEDRESTART-SESS:` for user sessions
  * `NEEDRESTART-CONT:` for containers.
  * On a system with *no* `intel-microcode` or `amd64-microcode` installed, the `UCCUR`/`UCEXP`/`UCSTA` microcode trio is omitted, since the *hypervisor owns the microcode*.

## Checking It

  ```sh
  needrestart -b                    # what is still pending
  uname -r                          # running kernel, compare against KEXP
  apt list --upgradable             # what the run left behind
  apt-mark showhold                 # packages deliberately pinned
  ```

- Reminder: k8s nodes are an exception. The `common` role *holds* the kubelet, kubeadm, and kubectl packages, so `apt-get dist-upgrade` here won't move them.
- Because of that, `apt list --upgradable` isn't empty on a k8s node after a successful run. The held packages still show up as upgradable, they just never get upgraded. Cross-check against `apt-mark showhold` before assuming the run failed.


