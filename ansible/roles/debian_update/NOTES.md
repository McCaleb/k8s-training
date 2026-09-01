# Notes and References

Things I ended up chasing while creating this role. 

Two of the answers turned out not to be in a manpage at all. Everything below is quoted from upstream. Debian links are pinned to Trixie.

## The Map

From the [needrestart package file list](https://packages.debian.org/trixie/all/needrestart/filelist):

| Path                                | What it is                                                    |
| ----------------------------------- | ------------------------------------------------------------- |
| `/etc/dpkg/dpkg.cfg.d/needrestart`  | Registers dpkg's `status-logger`                              |
| `/usr/lib/needrestart/dpkg-status`  | Reads that status stream and drops the marker files           |
| `/etc/apt/apt.conf.d/99needrestart` | Registers apt's `DPkg::Post-Invoke` hook                      |
| `/usr/lib/needrestart/apt-pinvoke`  | The hook. Reads the markers and decides whether to run        |
| `/etc/needrestart/needrestart.conf` | Annotated default config. Every key is documented in comments |
| `/etc/needrestart/conf.d/`          | Drop-in directory. The role writes `00-ansible.conf` here     |

- `status-logger` is a [dpkg(1)](https://manpages.debian.org/trixie/dpkg/dpkg.1.en.html) option that pipes every package status line to a command. 
  * needrestart points it at [`dpkg-status`](https://github.com/liske/needrestart/blob/master/ex/apt/dpkg-status), which touches `/run/needrestart/unpacked` on the first `unpacked` status and `/run/needrestart/errored` on the first error. 
  * apt then fires `apt-pinvoke`, which reads those two files.

- Don't forget that `/run` is a tmpfs. So both markers are cleared by a reboot. Which is correct. After a reboot there is nothing left to restart.

- The hook is registered as `DPkg::Post-Invoke`, not `Post-Invoke-Success`, so it runs after a failed transaction too. The `errored` marker is how it knows to stay quiet.

## What `NEEDRESTART_SUSPEND` Actually Suspends

[needrestart(1), ENVIRONMENT --> NEEDRESTART_SUSPEND](https://manpages.debian.org/trixie/needrestart/needrestart.1.en.html#NEEDRESTART_SUSPEND):

> If set to a non-empty value the apt-get(8) hook will not run needrestart after installing or updating packages.

- The hook, not the program. Setting it on the upgrade task leaves the role's own `needrestart -b` and `needrestart -r a` untouched.
- The manpage stops there...more info at [the hook](https://github.com/liske/needrestart/blob/master/ex/apt/apt-pinvoke). It quits early on four conditions, in order:
  1. dpkg errored.
  2. Nothing was unpacked.
  3. The system is shutting down ([Debian bug #914753](https://bugs.debian.org/cgi-bin/bugreport.cgi?bug=914753)).
  4. `NEEDRESTART_SUSPEND` is set.

- The fourth branch logs `packages have been installed but needrestart is suspended` and exits 0 **before** the line that removes `/run/needrestart/unpacked`. 
  * The marker survives, so suspending defers the check instead of discarding it: apt stays quiet during the upgrade, and the role decides once it can see the whole transaction.

## Where `KSTA` Is Documented

*Not* in the manpage, which describes the flag as

> enable batch mode: don't restart anything and produce machine-readable output

...and never lists the fields. 

The only reference I can find is [README.batch.md](https://github.com/liske/needrestart/blob/master/README.batch.md). Upstream issue [#230, "batch mode documentation unclear"](https://github.com/liske/needrestart/issues/230), is still open.

**`NEEDRESTART-KSTA`:**

  | Value | Meaning                        |
  | ----- | ------------------------------ |
  | `0`   | unknown or failed to detect    |
  | `1`   | no pending upgrade             |
  | `2`   | ABI compatible upgrade pending |
  | `3`   | version upgrade pending        |

- Application Binary Interface (ABI) in this case likely means the kernel's binary interface to its modules. 
- Debian can ship a rebuilt kernel that keeps the same ABI, so out-of-tree modules still load and `uname -r` reads the same, while the binary underneath has changed.
- That's a `2`, and it's the one that looks like nothing happened. A `3` changes the release string outright.
- The same file defines `VER`, `KCUR`, `KEXP`, `SVC`, `CONT` and `SESS`, and notes the format follows the apt-dater protocol, a convention from the apt-dater fleet-patching tool (?)rather than anything Debian defines.

## Where the `$nrconf` Keys Are Documented

Also not in a manpage. There is no `needrestart.conf(5)`. 

The shipped config is the documentation, so `/etc/needrestart/needrestart.conf` (Upstream copy: [`ex/needrestart.conf`](https://github.com/liske/needrestart/blob/master/ex/needrestart.conf)).

  | Key                    | Upstream comment                                                                                                                   |
  | ---------------------- | ---------------------------------------------------------------------------------------------------------------------------------- |
  | `$nrconf{restart}`     | "Restart mode: (l)ist only, (i)nteractive or (a)utomatically."                                                                     |
  | `$nrconf{sendnotify}`  | "Disable sending notifications to user sessions running obsolete binaries..."                                                      |
  | `$nrconf{override_rc}` | "Override service default selection (hash of regex). Regexes are checked in lexical order; the first matching regex will be used." |

- The `restart` comment adds that interactive mode "will fallback to list only mode" when run non-interactively, which makes `'l'` redundant in theory. I set it anyway rather than bet an unattended play on needrestart working out that it's unattended.

- The upstream example replaces `override_rc` wholesale with a hash of `qr(...) => 0` pairs. I assign one key instead. Same result for sshd, and the shipped defaults for dbus and the display managers stay in place.

## What `DEBIAN_FRONTEND` Doesn't Cover

I had this backwards: it isn't an apt variable. 

It's documented in [debconf(7), ENVIRONMENT](https://manpages.debian.org/trixie/debconf-doc/debconf.7.en.html#DEBIAN_FRONTEND), from the `debconf-doc` package, and appears nowhere in `apt(8)` or `apt-get(8)`. *apt passes the environment to maintainer scripts and debconf reads it there.*

> Used to temporarily change the frontend debconf uses.

The frontend itself is described separately, here: [Frontends](https://manpages.debian.org/trixie/debconf-doc/debconf.7.en.html#noninteractive).

> This is the anti-frontend. It never interacts with you at all, and makes the default answers be used for all questions.

It covers debconf questions only. dpkg's conffile prompt, the "modified configuration file, keep or replace?" one, is a separate mechanism controlled by `Dpkg::Options`, and `DEBIAN_FRONTEND` has no effect on it. 

A conffile is a config file dpkg tracks and compares against your edits...That prompt only appears when you have modified one *and* the package ships a new version.

The role is covered by accident: [`ansible.builtin.apt`](https://docs.ansible.com/ansible/latest/collections/ansible/builtin/apt_module.html) defaults `dpkg_options` to `force-confdef,force-confold`. 

Per [dpkg(1)](https://manpages.debian.org/trixie/dpkg/dpkg.1.en.html), that pair means take the package's default action, and where there is no default, keep the file already on disk. Not simply "keep the old file", which is what I assumed at first. Porting these tasks to raw `apt-get` means passing both flags myself.

[`DEBIAN_PRIORITY`](https://manpages.debian.org/trixie/debconf-doc/debconf.7.en.html#DEBIAN_PRIORITY) is in the same section and controls which questions get asked at all, rather than how they're presented. I don't set it.
