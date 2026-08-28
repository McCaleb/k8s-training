Role Name
=========

A brief description of the role goes here.

Requirements
------------

Any pre-requisites that may not be covered by Ansible itself or the role should be mentioned here. For instance, if the role uses the EC2 module, it may be a good idea to mention in this section that the boto package is required.

Role Variables
--------------

A description of the settable variables for this role should go here, including any variables that are in defaults/main.yml, vars/main.yml, and any variables that can/should be set via parameters to the role. Any variables that are read from other roles and/or the global scope (ie. hostvars, group vars, etc.) should be mentioned here as well.

Dependencies
------------

A list of other roles hosted on Galaxy should go here, plus any details in regards to parameters that may need to be set for other roles, or variables that are used from other roles.

Example Playbook
----------------

Including an example of how to use your role (for instance, with variables passed in as parameters) is always nice for users too:

    - hosts: servers
      roles:
         - { role: username.rolename, x: 42 }




```
root@d-k8s-cn01:~# kubeadm init phase upload-certs --upload-certs
I0828 16:50:07.313959   11042 version.go:260] remote version is much newer: v1.37.0; falling back to: stable-1.35
[upload-certs] Storing the certificates in Secret "kubeadm-certs" in the "kube-system" Namespace
[upload-certs] Using certificate key:
1a44b14b3856a07a96e65b9b60a61cd921dbda575d0c322958167b6461faaace
```

```
root@d-k8s-cn01:~# kubeadm token create --print-join-command
kubeadm join d-k8s-api.opnsense.lab:6443 --token jksc4g.zkvk38oruf9suy2v --discovery-token-ca-cert-hash sha256:9f960c17cea57c7be0411f1996ee0b63ecd322e0a67fb217328953a6823b18ca
```


```
kubeadm join d-k8s-api.opnsense.lab:6443 \
--token jksc4g.zkvk38oruf9suy2v \
--discovery-token-ca-cert-hash sha256:9f960c17cea57c7be0411f1996ee0b63ecd322e0a67fb217328953a6823b18ca \
--control-plane \
--certificate-key 1a44b14b3856a07a96e65b9b60a61cd921dbda575d0c322958167b6461faaace \
--apiserver-advertise-address 172.16.1.105
```
