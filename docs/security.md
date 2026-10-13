# Security

## Access control
- Manage every VM through the Admin user (`administrator`) with its Role's SSH key; no personal accounts on VMs. Least privilege everywhere else.
- Require MFA for administrative and cloud accounts where available.
- Remove or disable unused accounts and services.

## Secrets management
- Never commit credentials, private keys or tokens, even encrypted. Real values live only in gitignored files (`.env`, `*.tfvars`, `inventory/hosts.yml`, `host_vars/*.yml`, `docs/private/`), each with a committed `.example`.
- The pre-commit and commit-msg hooks and CI run gitleaks; run `scripts/scan-text.sh` on issue and comment text before posting.
- Rotate credentials after suspected exposure.

## Patch management
Record supported versions, update cadence, maintenance windows, and rollback strategy.

## Exposure review
Maintain an inventory of externally reachable services, firewall rules, and the justification for each exposure.
