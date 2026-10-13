# Infrastructure Repository Starter

Infrastructure-as-code and docs for a three-node Proxmox homelab and AWS. Committed files carry placeholders only; real environment details live in gitignored files (see Safety notes).

## Repository layout

- `docs/` — architecture, inventory, security, backup, recovery, and operational documentation.
- `ansible/` — inventory, playbooks, and reusable roles for configuration management.
- `terraform/aws/` — Terraform configuration for AWS resources.
- `services/` — service-specific notes and configuration templates.

## Getting started

1. Document hosts, networks, storage, services, and dependencies in `docs/`.
2. Copy `ansible/inventory/hosts.example.yml` to a local inventory file and replace example values.
3. Keep credentials out of Git. Real values live only in gitignored files (`.env`, `*.tfvars`, `inventory/hosts.yml`, `host_vars/*.yml`, `docs/private/`), each with a committed `.example`. Secrets are never committed, even encrypted.
4. Review Terraform plans before applying changes. Keep state files and credentials out of Git.
5. Test automation against a non-production target first.

## Safety notes

- Enable the hooks once per clone: `git config core.hooksPath .githooks` (needs `gitleaks`). They scan staged changes and commit messages; CI scans full history.

- All example addresses and values are placeholders.
- Never commit passwords, API tokens, private keys, `.tfstate` files, or generated secrets.
- Back up configuration and state securely, and document restore procedures.
