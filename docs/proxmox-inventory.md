# Proxmox Inventory

The real inventory (nodes, VM IDs, addresses, MACs) is the private Masterlist in `docs/private/`, which is never committed. This public page records only the shape of the estate, by Role.

| Role | Kind | Managed by Terraform | Notes |
|---|---|---|---|
| coreservices | Standard VM (Live) | import | |
| gameservices | Standard VM (Live) | import | |
| dns | Standard VM pair | import or rebuild | |
| media | Standard VM | new | |
| k3s-main | 3 Standard VMs | rebuild | one per node |
| firewall | Appliance VM | no | fog |
