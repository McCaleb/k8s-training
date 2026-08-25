# Common

Intent: Complete settings and configuration common to all K8s nodes (e.g. load balancers, control nodes, worker nodes.)

*This role was built for Debian-based nodes, it won't work on EL (e.g. RHEL, AlmaLinux, Rockylinux) with out some additional work.

## Time
- This role removes systemd-timesyncd in favor of chrony.

## Journald Logging

- This role enables persistent logging for the systemd journal, so logs survive reboots.

## Packages

- This role installs packages that we want in all nodes