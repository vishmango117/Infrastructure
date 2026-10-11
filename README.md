# Infrastructure Repository Starter

A structured starting point for documenting and managing a homelab or small infrastructure environment. Replace examples and placeholders with your actual environment details before using automation.

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

- Enable the pre-commit hook once per clone: `git config core.hooksPath .githooks` (needs `gitleaks`).

- All example addresses and values are placeholders.
- Never commit passwords, API tokens, private keys, `.tfstate` files, or generated secrets.
- Back up configuration and state securely, and document restore procedures.
