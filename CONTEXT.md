# Infrastructure

Everything needed to provision, configure and run self-hosted services across a three-node Proxmox homelab and AWS. Draft glossary: terms below are provisional and open to amendment.

## Language

### Places

**Category**:
A top-level area of the repository: AWS, Homelab, Docs, or Labs.
_Avoid_: section, area, zone

**Homelab**:
The three-node Proxmox cluster and every VM it hosts. Public text may name the node `pve` (Proxmox's default name); the other node names live in the private Masterlist.
_Avoid_: home server, Cluster A, Cluster B

**AWS**:
Services hosted on EC2 or ECS-on-EC2, separate from the Homelab.
_Avoid_: cloud

**Labs**:
Learning material and experiments that are not part of the running estate.
_Avoid_: learning, sandbox

### Building VMs

**Role**:
The function a VM performs, e.g. coreservices, media, gameservices, dns, firewall.
_Avoid_: function, type, service (for a VM)

**Profile**:
A named size of compute resources (cores, memory, disk) a Role is provisioned with.
_Avoid_: tier, flavour, template (for sizing)

**Golden image**:
The Ubuntu LTS Proxmox template every standard VM is cloned from.
_Avoid_: template (unqualified), base image

**Standard VM**:
A VM cloned from the Golden image and configured by the common Ansible layers.
_Avoid_: Docker VM, generic VM

**Appliance VM**:
A VM running a vendor OS that cannot use the Golden image, e.g. the OPNsense firewall.
_Avoid_: standard VM (for these)

**Stack**:
One independently applied unit of infrastructure-as-code with its own state.
_Avoid_: root, workspace, project

**Live VM**:
A VM that is running today and was built by hand before this repository managed it.
_Avoid_: legacy VM, existing VM

**Masterlist**:
The private, never-committed record of every VM, node, address and identifier in the Homelab, pulled from Proxmox.
_Avoid_: inventory (for this document), vmlist

**Controller**:
The single machine Ansible runs from and that holds the per-Role SSH keys.
_Avoid_: Ansible host, jump box

**Admin user**:
The `administrator` account every VM is managed and runs Services under, reached with its Role's SSH key.
_Avoid_: personal user accounts, `ubuntu`

### Configuring VMs

**Baseline**:
The configuration every Standard VM receives: updates, common packages, and hardening (admin user with SSH keys, key-only SSH, firewall, fail2ban).
_Avoid_: common, bootstrap, init

**Installation**:
The runtime layered on a VM after Baseline according to its Role, e.g. Docker, k3s, or network-share mounts.
_Avoid_: setup, provisioning

**Service**:
One containerised application deployed onto a VM, e.g. Jellyfin or Sonarr.
_Avoid_: app, container

**Compose project**:
A group of Services deployed together from one compose file, e.g. `photo` holds the Immich Services.
_Avoid_: stack (reserved for infrastructure-as-code)

**Media share**:
A network share from the NAS mounted into a VM for Services to read, e.g. Movies, TV, Photos.
_Avoid_: volume, Volumes folder

_Which Live VM holds which Role is recorded privately in `docs/private/live-vm-mapping.md`._
