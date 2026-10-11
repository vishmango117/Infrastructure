# Security

## Access control
- Use individual accounts and least privilege.
- Require MFA for administrative and cloud accounts where available.
- Remove or disable unused accounts and services.

## Secrets management
- Do not commit credentials, private keys, tokens, or unencrypted secret files.
- Use Ansible Vault or a dedicated secrets manager for automation secrets.
- Rotate credentials after suspected exposure.

## Patch management
Record supported versions, update cadence, maintenance windows, and rollback strategy.

## Exposure review
Maintain an inventory of externally reachable services, firewall rules, and the justification for each exposure.
