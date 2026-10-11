# Terraform — AWS

Add AWS infrastructure configuration here. Before using Terraform:

- Configure authentication through the AWS CLI profile or an approved role; do not hardcode credentials.
- Configure remote state with locking and encryption for shared environments.
- Pin provider versions and review `.terraform.lock.hcl` into version control.
- Keep `.tfstate` and `.tfvars` files out of Git.
- Run `terraform fmt`, `terraform validate`, and review `terraform plan` before applying.
