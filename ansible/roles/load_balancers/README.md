# Load Balancers

**Intent:** Complete settings and configuration for Kubernetes load balancers, in order to provide a highly available endpoint for API servers.

*This role was built for Debian-based nodes, it won't work on EL (e.g. RHEL, AlmaLinux, Rockylinux) with out some additional work.

## HAProxy

Forwards connections. 

- It listens on 6443 and relays to control plane nodes, 
- It skips any that fail `GET /readyz`. 
- It runs on both nodes regardless of which holds the vIP, so the idle instance is already health
checking and ready the moment the address moves to it.

## Keepalived

Manages the virtual IP. 

- The two load balancer nodes exchange Virtual Router Redundancy Protocol (VRRP) advertisements every second, and the higher-priority healthy node adds the vIP to its interface. 

- If it stops advertising, the other node claims the address in ~ 3.5 seconds.

### Health check script

- A script made available to keepalived that checks the health of HAproxy.
- The script checks the HAProxy process and uses `ss` to check that its listening on port 6443.