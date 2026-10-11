# Minimal Terraform layout for ECS on EC2

Research for [#5](https://github.com/vishmango117/HomeServer/issues/5), part of map [#1](https://github.com/vishmango117/HomeServer/issues/1).

**Question.** For a skeleton `aws/` Category (no services chosen yet), what is the current recommended minimal Terraform layout for Amazon ECS with EC2 capacity? How should it split into Stacks with separate local state, and what goes in a "how to add a service" guide?

**Constraints from the map.** Terraform state stays local, one state per Stack, gitignored. AWS state is separate from the Homelab. Remote state is out of scope. Choosing which services run on AWS is out of scope. The map already names `aws/terraform` and `aws/services/<name>` plus a how-to-add-a-service README.

Researched 2026-10-11. Versions current at that date: Terraform v1.16.5, AWS provider v6.68.0, `terraform-aws-modules/ecs` v7.6.1, `terraform-aws-modules/vpc` v6.7.3, `terraform-aws-modules/autoscaling` v9.3.2 (from each project's GitHub releases).

---

## TL;DR

1. **Networking: public subnets, no NAT gateway.** Put the container instances in public subnets with a public IPv4 address. Use the `bridge` (or `host`) network mode, not `awsvpc`: on EC2, `awsvpc` task ENIs never get a public IP and can only reach the internet through a NAT gateway. A NAT gateway would cost more than the instance itself.
2. **Capacity: one Auto Scaling group behind one ECS capacity provider.** Use a launch template with the ECS-optimised Amazon Linux 2023 AMI, read from the public SSM parameter. User data writes `ECS_CLUSTER=<name>` to `/etc/ecs/ecs.config`. Turn on managed scaling and managed termination protection, add the `AmazonECSManaged` tag and set `protect_from_scale_in = true`.
3. **IAM: three role types.** The container instance role (`AmazonEC2ContainerServiceforEC2Role`) belongs to the cluster Stack. The task execution role (`AmazonECSTaskExecutionRolePolicy`) and the task role belong to each service.
4. **Use raw `aws_*` resources, not terraform-aws-modules.** The whole skeleton is about 25 resources. The community modules are good and current, but their interfaces are far larger than this setup needs. Use their `ec2-autoscaling` example as a checked reference.
5. **Three kinds of Stack, each with its own local state:** `aws/terraform/network`, `aws/terraform/cluster` and one `aws/services/<name>` per service. A small local module, `aws/terraform/modules/ecs-service`, keeps each service Stack short.
6. **Stacks read each other with provider data sources looked up by name or tag** (`aws_vpc`, `aws_subnets`, `aws_ecs_cluster`, `aws_security_group`). `terraform_remote_state` with `backend = "local"` also works and is the documented fallback. Both are compared below.
7. **Cost (us-east-1 list prices):** about **$18/month** for one `t4g.small` with a public IPv4 address and a 30 GiB gp3 root volume. ECS itself has no charge. A NAT gateway would add about $33/month plus data. Setting the ASG to 0 instances stops almost all of the cost.

---

## 1. Components and how to build each one

### 1.1 VPC and networking

**Recommendation:** a dedicated VPC with two public subnets in two AZs, an internet gateway and one public route table. No NAT gateway and no private subnets in the skeleton.

Why:

- AWS documents two outbound designs for ECS: a public subnet with an internet gateway, or a private subnet with a NAT gateway. For EC2 in a public subnet, *"any containers that are running on the instances can use the underlying public IP address of the host for outbound networking. This applies to both the host and bridge network modes. However, the awsvpc network mode doesn't provide task ENIs with public IP addresses. Therefore, they can't make direct use of an internet gateway."* ([ECS: Connect applications to the internet](https://docs.aws.amazon.com/AmazonECS/latest/developerguide/networking-outbound.html))
- The awsvpc page says the same: *"When hosting tasks that use the awsvpc network mode on Amazon EC2 Linux instances, your task ENIs aren't given public IP addresses. To access the internet, tasks must be launched in a private subnet that's configured to use a NAT gateway."* ([ECS: awsvpc network mode](https://docs.aws.amazon.com/AmazonECS/latest/developerguide/task-networking-awsvpc.html))
- So the choice of network mode is also a cost choice. **`bridge` in public subnets needs no NAT.** **`awsvpc` on EC2 needs NAT**, or VPC endpoints for every AWS API it calls.
- A NAT gateway costs $0.045/hour (about $32.85/month) plus $0.045/GB processed in the reference region ([VPC pricing](https://aws.amazon.com/vpc/pricing/)). AWS recommends one NAT gateway per AZ for redundancy (networking-outbound page above), which doubles that.
- Replacing NAT with interface VPC endpoints is not cheaper here. ECS on EC2 needs `ecs`, `ecs-agent` and `ecs-telemetry` ([ECS VPC endpoints](https://docs.aws.amazon.com/AmazonECS/latest/developerguide/vpc-endpoints.html)). ECR pulls need `ecr.api`, `ecr.dkr`, an S3 gateway endpoint and `logs` for awslogs ([ECR VPC endpoints](https://docs.aws.amazon.com/AmazonECR/latest/userguide/vpc-endpoints.html)). Each interface endpoint is billed per hour per AZ plus per GB ([PrivateLink pricing](https://aws.amazon.com/privatelink/pricing/)).
- The trade-off is that public-subnet instances are reachable from the internet. AWS's advice is to keep security groups tight and never open port 22 (networking-outbound page). For shell access, use SSM Session Manager or ECS Exec instead of SSH (see 1.6).

Network mode trade-off inside `bridge`: dynamic host ports let several copies of a task share an instance. However, AWS notes that *"it's difficult to lock down service to service communications"* because ports are random ([ECS: bridge network mode](https://docs.aws.amazon.com/AmazonECS/latest/developerguide/networking-networkmode-bridge.html)). Without a load balancer, a skeleton service that must be reachable uses a **static `hostPort`**, so only one copy of it runs per instance. Adding an ALB is a per-service decision for the guide, not part of the skeleton.

Raw resources: `aws_vpc`, `aws_internet_gateway`, `aws_subnet` ×2 (`map_public_ip_on_launch = true`), `aws_route_table`, `aws_route` (0.0.0.0/0 to IGW), `aws_route_table_association` ×2. Optional: `aws_vpc_endpoint` for S3. *"There is no additional charge for using gateway endpoints"* ([Gateway endpoints](https://docs.aws.amazon.com/vpc/latest/privatelink/gateway-endpoints.html)).

### 1.2 ECS cluster

`aws_ecs_cluster` plus `aws_ecs_cluster_capacity_providers`, which attaches the capacity provider and sets it as the default strategy. ECS orchestration has no charge: *"There is no additional charge for Amazon ECS orchestration… Amazon EC2: There is no additional charge for Amazon EC2 compute. You pay for AWS resources (such as Amazon EC2 instances, Amazon EBS volumes, or public IPv4 addresses)"* ([ECS pricing](https://aws.amazon.com/ecs/pricing/)). Leave Container Insights off in the skeleton. It *"ingests performance events as CloudWatch Logs"*, which are billed as CloudWatch usage ([CloudWatch pricing](https://aws.amazon.com/cloudwatch/pricing/)).

### 1.3 Capacity provider, Auto Scaling group, launch template, AMI

**AMI.** AWS: *"We recommend that you use the Amazon ECS-optimized Amazon Linux 2023 AMI"* ([ECS-optimised AMIs](https://docs.aws.amazon.com/AmazonECS/latest/developerguide/ecs-optimized_AMI.html)). Read the image ID from the public SSM parameter ([Retrieving ECS-optimised AMI metadata](https://docs.aws.amazon.com/AmazonECS/latest/developerguide/retrieve-ecs-optimized_AMI.html)):

| Architecture | SSM parameter |
|---|---|
| x86_64 | `/aws/service/ecs/optimized-ami/amazon-linux-2023/recommended/image_id` |
| arm64 (Graviton, e.g. `t4g`) | `/aws/service/ecs/optimized-ami/amazon-linux-2023/arm64/recommended/image_id` |

```hcl
data "aws_ssm_parameter" "ecs_ami" {
  name = "/aws/service/ecs/optimized-ami/amazon-linux-2023/arm64/recommended/image_id"
}
```

The official module example reads the parent `.../recommended` parameter and runs `jsondecode(...)["image_id"]` on it ([terraform-aws-ecs `examples/ec2-autoscaling/main.tf`](https://github.com/terraform-aws-modules/terraform-aws-ecs/blob/master/examples/ec2-autoscaling/main.tf)). Both forms are valid. Note that each new AMI release shows up as a launch template diff on the next `plan`. That is the intended way to pick up patched AMIs. If you want stable plans, pin the AMI with a variable. Running instances only change after an instance refresh or replacement (`instance_refresh` block on `aws_autoscaling_group`, [provider docs](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/autoscaling_group)).

The AL2023 ECS AMI ships *"a single 30-GiB root volume"* (ECS-optimised AMIs page). That volume is the EBS cost line below.

**Launch template** (`aws_launch_template`): the image ID from SSM, the instance type, an IAM instance profile, the instance security group, and user data that registers the instance with the cluster ([Launching a container instance](https://docs.aws.amazon.com/AmazonECS/latest/developerguide/launch_container_instance.html)):

```bash
#!/bin/bash
cat <<'EOF' >> /etc/ecs/ecs.config
ECS_CLUSTER=<cluster-name>
EOF
```

The official example also sets `ECS_ENABLE_TASK_IAM_ROLE=true` and `ECS_CONTAINER_INSTANCE_TAGS` (module example above). The task-role docs say that `ECS_ENABLE_TASK_IAM_ROLE=true` enables task roles for the `bridge` and `default` network modes ([Task IAM role](https://docs.aws.amazon.com/AmazonECS/latest/developerguide/task-iam-roles.html)). Since this design uses `bridge`, **include it**.

**Auto Scaling group** (`aws_autoscaling_group`): the two public subnets, `min_size = 0`, `max_size = 1` or 2. Required details:

- Tag `AmazonECSManaged = true` with `propagate_at_launch = true`. The provider docs say ECS adds this tag itself, and it must also be in the Terraform config *"to prevent Terraform from removing it in subsequent executions"* ([`aws_ecs_capacity_provider`](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/ecs_capacity_provider)).
- `protect_from_scale_in = true`. AWS: *"You must turn on Auto Scaling instance scale-in protection on the Auto Scaling group to use the managed termination protection feature"* ([Managed termination protection](https://docs.aws.amazon.com/AmazonECS/latest/developerguide/managed-termination-protection.html)).
- Ignore `desired_capacity` (`lifecycle { ignore_changes = [desired_capacity] }`), because ECS managed scaling owns it. The module example does the same with `ignore_desired_capacity_changes = true`.
- `force_delete = true` lets `terraform destroy` remove the group without waiting for its instances to terminate (`aws_autoscaling_group` docs). This matters because scale-in protection otherwise blocks the teardown.

**Capacity provider** (`aws_ecs_capacity_provider` with an `auto_scaling_group_provider` block): `managed_scaling { status = "ENABLED", target_capacity = 100 }`, `managed_termination_protection = "ENABLED"`, `managed_draining = "ENABLED"` (the default). Do **not** set `cluster` for ASG providers (provider docs). Cluster auto scaling *"doesn't modify the MinimumCapacity or MaximumCapacity… For the group to scale out, the value for MaximumCapacity must be greater than zero"*. It also creates CloudWatch alarms and a target-tracking policy on the ASG for you ([Cluster auto scaling](https://docs.aws.amazon.com/AmazonECS/latest/developerguide/cluster-auto-scaling.html)). With `target_capacity = 100`, new tasks wait in `PENDING` until an instance registers (same page).

Out of scope: **ECS Managed Instances** (`managed_instances_provider`) is a newer, AWS-managed EC2 capacity option with its own pricing ([ECS Managed Instances](https://docs.aws.amazon.com/AmazonECS/latest/developerguide/ManagedInstances.html), [ECS pricing](https://aws.amazon.com/ecs/pricing/)). The ticket asks for an ASG plus a capacity provider, so it is not used here. It is worth a later look if running the ASG becomes a chore.

### 1.4 Task definition and service

Per service:

- `aws_ecs_task_definition`: `requires_compatibilities = ["EC2"]`, `network_mode = "bridge"`, task-level or container-level `cpu`/`memory`, `execution_role_arn`, `task_role_arn`, and `container_definitions` (JSON via `jsonencode`) with `portMappings` and `logConfiguration` (awslogs, see 1.7).
- `aws_ecs_service`: `cluster`, `task_definition`, `desired_count`, and a `capacity_provider_strategy` that points at the cluster's capacity provider. Optional: `deployment_circuit_breaker { enable = true, rollback = true }` and `enable_execute_command` ([`aws_ecs_service`](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/ecs_service)). For a single instance with a static host port, set `deployment_minimum_healthy_percent = 0` and `deployment_maximum_percent = 100`. Otherwise a rolling deployment cannot place the new task, because the port is already taken.

### 1.5 ECR

Per service that builds its own image: `aws_ecr_repository` plus `aws_ecr_lifecycle_policy` that keeps the last N images ([ECR lifecycle policies](https://docs.aws.amazon.com/AmazonECR/latest/userguide/LifecyclePolicies.html)). Private storage costs $0.10/GB-month. New customers get 500 MB/month free for one year ([ECR pricing](https://aws.amazon.com/ecr/pricing/)). Services that run a third-party image can pull it from its public registry and skip ECR. In a public subnet, pulls go over the instance's public IP with no NAT and no endpoints.

**First-deploy ordering.** The service cannot become stable before an image exists in its repository. The guide should say: first apply with `desired_count = 0`, push the image, then set `desired_count = 1` and apply again.

### 1.6 IAM roles

| Role | Trust principal | Policy | Lives in |
|---|---|---|---|
| Container instance role plus `aws_iam_instance_profile` | `ec2.amazonaws.com` | `AmazonEC2ContainerServiceforEC2Role` ([docs](https://docs.aws.amazon.com/AmazonECS/latest/developerguide/instance_IAM_role.html)). Optional: `AmazonSSMManagedInstanceCore` for Session Manager instead of SSH, as the official module example attaches | cluster Stack |
| Task execution role | `ecs-tasks.amazonaws.com` | `AmazonECSTaskExecutionRolePolicy` ([docs](https://docs.aws.amazon.com/AmazonECS/latest/developerguide/task_execution_IAM_role.html)), plus inline read access to any Secrets Manager or SSM Parameter Store secrets the service uses | each service |
| Task role | `ecs-tasks.amazonaws.com` | Only what the application itself calls. Empty is fine. Add the SSM Session Manager permissions only if ECS Exec is turned on. Without a task role, EC2 tasks fall back to the instance role ([ECS Exec](https://docs.aws.amazon.com/AmazonECS/latest/developerguide/ecs-exec.html), [Task IAM role](https://docs.aws.amazon.com/AmazonECS/latest/developerguide/task-iam-roles.html)) | each service |

A nuance specific to EC2: the execution-role docs list ECR pulls and awslogs as execution-role use cases only for *"Fargate, Amazon ECS Managed Instances, or an external instance"*. On EC2 those calls can also be made with the container instance role. The awslogs page says container instances *"also require logs:CreateLogStream and logs:PutLogEvents"* on the instance role, which the managed instance policy already grants ([Send ECS logs to CloudWatch](https://docs.aws.amazon.com/AmazonECS/latest/developerguide/using_awslogs.html)). The execution role is still **required** on EC2 for secrets and private registry auth, so give every service its own execution role anyway. That way each service carries its own permissions and the guide does not depend on what the instance role happens to allow.

### 1.7 Logging

One `aws_cloudwatch_log_group` per service (for example `/ecs/<service>`), with `retention_in_days` set explicitly. The provider default is to keep logs forever ([`aws_cloudwatch_log_group`](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_log_group)). The container definition uses `logDriver = "awslogs"` with `awslogs-group`, `awslogs-region` and `awslogs-stream-prefix` ([Send ECS logs to CloudWatch](https://docs.aws.amazon.com/AmazonECS/latest/developerguide/using_awslogs.html)). The CloudWatch free tier includes 5 GB of log data (ingestion, archive storage and Logs Insights scanning). Above that, ingestion is billed per GB ([CloudWatch pricing](https://aws.amazon.com/cloudwatch/pricing/)). Creating the log group in Terraform instead of using `awslogs-create-group` keeps retention under Terraform's control.

---

## 2. terraform-aws-modules or raw resources?

**Recommendation: raw resources, plus one small local `ecs-service` module.**

| | terraform-aws-modules | Raw resources |
|---|---|---|
| State of the project | Active. `ecs` v7.6.1, `vpc` v6.7.3, `autoscaling` v9.3.2, all released 2026-09-18. `ecs` needs Terraform >= 1.5.7 and AWS provider >= 6.41 ([ecs README](https://github.com/terraform-aws-modules/terraform-aws-ecs)) | Provider v6.68.0 |
| EC2 capacity support | Yes. The cluster module's `capacity_providers` map takes `auto_scaling_group_provider`. The ASG itself comes from the separate `autoscaling` module ([`ec2-autoscaling` example](https://github.com/terraform-aws-modules/terraform-aws-ecs/tree/master/examples/ec2-autoscaling)) | Yes |
| Size of the interface | Very large. The `services` input alone is several hundred lines of nested object types | About 25 resources across the whole skeleton, each documented on its own provider page |
| Defaults | The official example uses private subnets with `enable_nat_gateway = true` and `single_nat_gateway = true`. That is the cost this design avoids | You choose |
| Fit with the repo | Three module dependencies to pin and upgrade per Stack | Matches the Homelab, where the repo defines its own module interface |

The community modules are the right choice for larger estates. For a skeleton that someone has to read and learn from, raw resources make every ECS requirement visible: the `AmazonECSManaged` tag, scale-in protection, `ECS_CLUSTER` in user data, and the SSM AMI parameter. Use the `ec2-autoscaling` example to check settings. If the AWS side grows (ALB, several capacity providers, Spot), adopting `terraform-aws-modules/vpc` for the network Stack is a cheap first step.

The local `aws/terraform/modules/ecs-service` module wraps the per-service resources: ECR (optional), log group, execution role, task role, task definition and service. Each `aws/services/<name>` Stack then becomes one short module call.

---

## 3. Splitting into Stacks with local state

### 3.1 Stacks

| Stack | Path | Contains | Change frequency |
|---|---|---|---|
| network | `aws/terraform/network` | VPC, IGW, public subnets, route table, optional S3 gateway endpoint | Rarely |
| cluster | `aws/terraform/cluster` | ECS cluster, instance role and profile, instance security group, launch template, ASG, capacity provider, cluster capacity providers | Occasionally (AMI, instance type) |
| service | `aws/services/<name>` | One call to the `ecs-service` module, plus any service-specific resources (security group rule for its port, secrets) | Per deploy |

Apply order: network, then cluster, then services. Destroy order is the reverse.

Terminology clash: Terraform now has its own **Stacks** feature, configured with Stack blocks in HCP Terraform ([Terraform Stacks](https://developer.hashicorp.com/terraform/language/stacks)). The repo's "Stack" (from `CONTEXT.md`) means a plain root module with its own state. **Don't use Terraform Stacks.** The `aws/README.md` should say so in one line.

### 3.2 Local state per Stack

Each Stack declares its backend explicitly. The [local backend docs](https://developer.hashicorp.com/terraform/language/backend/local) say `path` defaults to `terraform.tfstate` in the root module:

```hcl
terraform {
  backend "local" {}   # state stays in ./terraform.tfstate, gitignored
}
```

Gitignore `*.tfstate`, `*.tfstate.*`, `.terraform/`, `*.tfvars` (commit a `terraform.tfvars.example` instead) and crash logs. **Commit `.terraform.lock.hcl`.** HashiCorp: *"You should include this file in your version control repository"* ([Dependency lock file](https://developer.hashicorp.com/terraform/language/files/dependency-lock)). AWS states are separate from Homelab states because they sit in separate directories. No shared backend is needed.

Put provider `default_tags` in every Stack (for example `Category = "aws"` and `Stack = "<stack-name>"`). That gives each resource an owner tag, and the tag-based lookups below depend on it.

### 3.3 How Stacks read each other's outputs without a remote backend

**Option A: `terraform_remote_state` with the local backend.** This is documented and supported:

```hcl
data "terraform_remote_state" "network" {
  backend = "local"
  config = {
    path = "${path.module}/../network/terraform.tfstate"
  }
}
# data.terraform_remote_state.network.outputs.public_subnet_ids
```

(Syntax from the [local backend page](https://developer.hashicorp.com/terraform/language/backend/local) and the [`terraform_remote_state` page](https://developer.hashicorp.com/terraform/language/state/remote-state-data).) Only root-level outputs are exposed. Downsides: it ties each Stack to the other Stack's state file path on the same disk, so services under `aws/services/<name>` would need `../../terraform/cluster/terraform.tfstate`. It also breaks if a Stack is ever run from another checkout. HashiCorp's own caveat: *"its user must have access to the entire state snapshot, which often includes some sensitive information. When possible, we recommend explicitly publishing data for external consumption to a separate location"* (same page). That matters less when all state is local on one machine anyway.

**Option B: provider data sources by name or tag (recommended).** HashiCorp's recommended alternative is to publish and read data through provider resources and data sources (same page). AWS resources can already be looked up directly, so nothing needs to be published:

```hcl
data "aws_vpc" "this" {
  tags = { Category = "aws", Stack = "network" }
}
data "aws_subnets" "public" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.this.id]
  }
  tags = { Tier = "public" }
}
data "aws_ecs_cluster" "this" {
  cluster_name = var.cluster_name
}
```

Data sources used: [`aws_vpc`](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/vpc), [`aws_subnets`](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/subnets), [`aws_ecs_cluster`](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/ecs_cluster), [`aws_security_group`](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/security_group), [`aws_iam_role`](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_role).

Why B: no file-path coupling, it keeps working if a state file is moved or rebuilt, and the lookups read like the AWS console. Cost: a naming and tagging convention that must be followed. Write it down in `aws/README.md`, for example the cluster name, the `Category`/`Stack` tags, and `Tier = public` on subnets. If B ever feels like too much ceremony, A is the documented fallback.

Option C is to publish values to SSM Parameter Store (`aws_ssm_parameter` resource and data source; listed by HashiCorp on the same page). It is useful when values have no natural lookup key. The skeleton doesn't need it.

---

## 4. Cost of the smallest viable setup

On-demand list prices in us-east-1 (N. Virginia), used as a reference only. Prices vary by region. Monthly figures assume 730 hours.

| Item | Rate | ~Monthly | Source |
|---|---|---|---|
| ECS control plane | no charge | $0 | [ECS pricing](https://aws.amazon.com/ecs/pricing/) |
| 1× `t4g.small` (2 vCPU, 2 GiB, arm64) | $0.0168/h | $12.26 | [EC2 on-demand pricing](https://aws.amazon.com/ec2/pricing/on-demand/) |
| Public IPv4 on the instance | $0.005/h | $3.65 | [VPC pricing](https://aws.amazon.com/vpc/pricing/) |
| 30 GiB gp3 root volume (AMI default) | $0.08/GB-month | $2.40 | [EBS pricing](https://aws.amazon.com/ebs/pricing/) |
| CloudWatch Logs | 5 GB/month free tier | ~$0 for light use | [CloudWatch pricing](https://aws.amazon.com/cloudwatch/pricing/) |
| ECR private storage | $0.10/GB-month (500 MB free first year for new customers) | <$1 | [ECR pricing](https://aws.amazon.com/ecr/pricing/) |
| **Total** | | **~$18–19** | |

Alternatives and add-ons:

- `t4g.micro` (1 GiB) at $0.0084/h is about $6.13/month, so about $12/month in total. 1 GiB leaves little memory after the OS and ECS agent. `t3.micro` (x86, 1 GiB) is $0.0104/h and `t3.small` (x86, 2 GiB) is $0.0208/h (EC2 pricing page). Graviton (`t4g`) is cheapest but needs arm64 or multi-arch images and the arm64 AMI parameter.
- **A NAT gateway adds about $32.85/month per gateway plus $0.045/GB**, which is more than the rest of the setup combined (VPC pricing).
- An ALB, if a service needs one later, has its own hourly and LCU charges. That is a per-service decision.
- Managed scaling creates CloudWatch alarms on the ASG (cluster auto scaling page). They are billed as standard CloudWatch alarms.
- **Parking:** setting the ASG's `max_size = 0` (or service `desired_count = 0` with `min_size = 0`) removes the instance, its public IPv4 address and its root volume. What remains is ECR storage and log storage. Not running a NAT gateway is what makes this cheap.
- Free tier: since 15 July 2025, new accounts get up to $200 in credits, usable for up to 6 months on the Free plan ([AWS Free Tier](https://aws.amazon.com/free/), [EBS pricing](https://aws.amazon.com/ebs/pricing/)). Check which offer applies to the account in use.

---

## 5. Proposed `aws/` directory tree

```text
aws/
├── README.md                         # layout, Stack apply/destroy order, naming & tag convention,
│                                     # "Stack ≠ Terraform Stacks", cost note, how to park
├── terraform/
│   ├── network/                      # Stack: VPC, IGW, 2 public subnets, routes
│   │   ├── versions.tf               # required_version, aws provider pin, backend "local" {}
│   │   ├── providers.tf              # region var, default_tags { Category, Stack }
│   │   ├── main.tf
│   │   ├── variables.tf
│   │   ├── outputs.tf
│   │   ├── terraform.tfvars.example
│   │   └── .terraform.lock.hcl       # committed
│   ├── cluster/                      # Stack: cluster, instance role/profile, SG,
│   │   ├── versions.tf               #   launch template (SSM AMI), ASG, capacity provider
│   │   ├── providers.tf
│   │   ├── main.tf
│   │   ├── iam.tf
│   │   ├── user_data.sh.tftpl        # ECS_CLUSTER=…, ECS_ENABLE_TASK_IAM_ROLE=true
│   │   ├── variables.tf              # instance_type, arch, min/max size
│   │   ├── outputs.tf
│   │   ├── terraform.tfvars.example
│   │   └── .terraform.lock.hcl
│   └── modules/
│       └── ecs-service/              # module (no state): ECR (optional), log group,
│           ├── main.tf               #   exec role, task role, task definition, service
│           ├── iam.tf
│           ├── variables.tf          # name, image, cpu, memory, port_mappings, env,
│           │                         # secrets, desired_count, create_ecr_repository, log_retention_days
│           └── outputs.tf
└── services/
    ├── README.md                     # "How to add a service" guide (section 6)
    ├── _template/                    # copy-me Stack: versions.tf, providers.tf, main.tf
    │   └── …                         # (data lookups + one module call), tfvars example
    └── <name>/                       # one Stack per service, added later; none in the skeleton
```

`.gitignore` additions (repo root or `aws/.gitignore`): `**/.terraform/`, `*.tfstate`, `*.tfstate.*`, `*.tfvars`, `!*.tfvars.example`, `crash.log`, `crash.*.log`.

---

## 6. Outline for the "How to add a service" guide (`aws/services/README.md`)

1. **Prerequisites.** The network and cluster Stacks are applied. AWS credentials are configured locally (never committed). The image architecture matches the cluster's instance architecture (arm64 for `t4g`).
2. **Decide the basics.** Service name (lowercase, used for the directory, ECR repo, log group and roles); image source (own image in ECR, or a public registry); CPU and memory (they must fit the instance, so check what the instance registers in the ECS console); container port; whether it must be reachable from the internet; secrets.
3. **Copy the template.** `cp -r aws/services/_template aws/services/<name>`, then fill in `terraform.tfvars` from the example. Never commit the real `.tfvars`.
4. **Fill in the module call.** Set image, port mappings (static `hostPort` while there is no ALB), env vars, secret ARNs (`valueFrom`), `desired_count`, and log retention.
5. **Networking.** If the service is public, add one `aws_vpc_security_group_ingress_rule` on the cluster instance security group (looked up by tag) for its host port, and restrict the source CIDR as far as possible. Never open port 22. Use SSM Session Manager or ECS Exec instead.
6. **IAM.** Add any AWS permissions the app needs to the task role. Add secret read permissions to the execution role. Nothing else.
7. **First deploy (own image).** Run `terraform init` and `terraform apply` with `desired_count = 0`. This creates the ECR repo, log group and roles. Log in to ECR and push the image. Then set `desired_count = 1` and apply again.
8. **Verify.** Check that the service is stable in ECS, that the logs appear in `/ecs/<name>`, and that the endpoint answers on the instance's public IP and host port.
9. **Update and redeploy.** Push a new image tag, update `image`, and apply. For single-instance services, make sure `deployment_minimum_healthy_percent = 0` (see 1.4).
10. **Remove a service.** Run `terraform destroy` in `aws/services/<name>`. ECR repositories that still contain images need `force_delete`, or must be emptied first. Then delete the directory.
11. **Checklist before committing.** No account IDs, ARNs with account IDs, IPs, hostnames or domains in committed files. Only `*.tfvars.example` is committed. `.terraform.lock.hcl` is committed. `terraform fmt` and `terraform validate` pass.

---

## Sources

AWS documentation
- ECS-optimised AMIs: https://docs.aws.amazon.com/AmazonECS/latest/developerguide/ecs-optimized_AMI.html
- Retrieving ECS-optimised AMI metadata (SSM parameters): https://docs.aws.amazon.com/AmazonECS/latest/developerguide/retrieve-ecs-optimized_AMI.html
- Launching a container instance (user data, `ECS_CLUSTER`): https://docs.aws.amazon.com/AmazonECS/latest/developerguide/launch_container_instance.html
- Auto Scaling group capacity providers: https://docs.aws.amazon.com/AmazonECS/latest/developerguide/asg-capacity-providers.html
- Cluster auto scaling: https://docs.aws.amazon.com/AmazonECS/latest/developerguide/cluster-auto-scaling.html
- Managed termination protection: https://docs.aws.amazon.com/AmazonECS/latest/developerguide/managed-termination-protection.html
- ECS Managed Instances: https://docs.aws.amazon.com/AmazonECS/latest/developerguide/ManagedInstances.html
- Connect applications to the internet (public subnet vs NAT): https://docs.aws.amazon.com/AmazonECS/latest/developerguide/networking-outbound.html
- awsvpc network mode: https://docs.aws.amazon.com/AmazonECS/latest/developerguide/task-networking-awsvpc.html
- bridge network mode: https://docs.aws.amazon.com/AmazonECS/latest/developerguide/networking-networkmode-bridge.html
- ECS interface VPC endpoints: https://docs.aws.amazon.com/AmazonECS/latest/developerguide/vpc-endpoints.html
- ECR interface VPC endpoints: https://docs.aws.amazon.com/AmazonECR/latest/userguide/vpc-endpoints.html
- ECR lifecycle policies: https://docs.aws.amazon.com/AmazonECR/latest/userguide/LifecyclePolicies.html
- Container instance IAM role: https://docs.aws.amazon.com/AmazonECS/latest/developerguide/instance_IAM_role.html
- Task execution IAM role: https://docs.aws.amazon.com/AmazonECS/latest/developerguide/task_execution_IAM_role.html
- Task IAM role: https://docs.aws.amazon.com/AmazonECS/latest/developerguide/task-iam-roles.html
- ECS Exec: https://docs.aws.amazon.com/AmazonECS/latest/developerguide/ecs-exec.html
- Send ECS logs to CloudWatch (awslogs): https://docs.aws.amazon.com/AmazonECS/latest/developerguide/using_awslogs.html

AWS pricing
- ECS: https://aws.amazon.com/ecs/pricing/
- EC2 on-demand: https://aws.amazon.com/ec2/pricing/on-demand/
- VPC (NAT gateway, public IPv4): https://aws.amazon.com/vpc/pricing/
- PrivateLink (interface endpoints): https://aws.amazon.com/privatelink/pricing/
- Gateway endpoints (no charge): https://docs.aws.amazon.com/vpc/latest/privatelink/gateway-endpoints.html
- EBS: https://aws.amazon.com/ebs/pricing/
- ECR: https://aws.amazon.com/ecr/pricing/
- CloudWatch: https://aws.amazon.com/cloudwatch/pricing/
- Free Tier: https://aws.amazon.com/free/

Terraform and the AWS provider
- `aws_ecs_capacity_provider`: https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/ecs_capacity_provider
- `aws_ecs_cluster_capacity_providers`: https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/ecs_cluster_capacity_providers
- `aws_ecs_service`: https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/ecs_service
- `aws_autoscaling_group`: https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/autoscaling_group
- `aws_cloudwatch_log_group`: https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_log_group
- `aws_ssm_parameter` (data source): https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/ssm_parameter
- `terraform_remote_state`: https://developer.hashicorp.com/terraform/language/state/remote-state-data
- Local backend: https://developer.hashicorp.com/terraform/language/backend/local
- Dependency lock file: https://developer.hashicorp.com/terraform/language/files/dependency-lock
- Terraform Stacks (the HCP feature, for the terminology note): https://developer.hashicorp.com/terraform/language/stacks

terraform-aws-modules
- terraform-aws-ecs (README, v7.6.1): https://github.com/terraform-aws-modules/terraform-aws-ecs
- `ec2-autoscaling` example: https://github.com/terraform-aws-modules/terraform-aws-ecs/tree/master/examples/ec2-autoscaling
- terraform-aws-vpc (v6.7.3): https://github.com/terraform-aws-modules/terraform-aws-vpc
- terraform-aws-autoscaling (v9.3.2): https://github.com/terraform-aws-modules/terraform-aws-autoscaling
