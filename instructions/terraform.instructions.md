---
description: Terraform infrastructure-as-code standards for the Petry Projects organization
applyTo: "**/*.tf,**/*.tfvars,**/*.tftest.hcl"
---

# Terraform Development Standards

These rules extend the org-level `copilot-instructions.md` and are based on the
[Terraform Style Guide](https://developer.hashicorp.com/terraform/language/style) and the
[github/awesome-copilot Terraform template](https://github.com/github/awesome-copilot/blob/main/instructions/terraform.instructions.md).
Terraform is used for GitHub infrastructure and cloud resource management in this org.

## General Principles

- Use Terraform for infrastructure provisioning and management. Keep configurations in version
  control.
- Always use the **latest stable version** of Terraform and its providers. Update regularly for
  security patches.
- Prioritize readability, clarity, and maintainability over brevity.

## Security

- **Never commit sensitive information** — API keys, credentials, passwords, certificates, or
  Terraform state files — to version control. Use `.gitignore` to exclude them.
- Store secrets in GitHub Actions secrets, AWS Secrets Manager, SSM Parameter Store, or a
  comparable secret manager. Reference them via environment variables.
- **Always mark sensitive variables** with `sensitive = true` to prevent them from appearing in
  `plan` / `apply` output.
- Follow the principle of least privilege for all IAM roles and policies.
- Deploy resources in private subnets whenever possible. Use public subnets only for resources
  that genuinely require direct internet access (load balancers, NAT gateways).
- Enable encryption for data at rest (EBS, S3, RDS) and in transit (TLS).
- Run security scanning on every PR:
  - `trivy config .` — vulnerability and misconfiguration scanning
  - `tfsec .` — Terraform-specific security checks
  - `checkov -d .` — policy-as-code compliance

## Modularity

- **Separate projects for each major infrastructure component** — reduces `plan`/`apply` scope,
  enables independent deployment, and limits blast radius.
- Use modules to encapsulate related resources. Avoid modules for single resources — only use
  them for groups of related resources that are reused.
- Keep module nesting shallow. Avoid circular dependencies between modules.
- Use `output` blocks to expose information needed by other modules or users. Mark outputs
  `sensitive = true` if they contain sensitive values.

## Maintainability

- Use variables for all configuration values. Avoid hard-coded strings and numbers.
- Set default values for variables where appropriate.
- Use `data` sources to retrieve existing resource information rather than requiring manual
  configuration. Remove unused data sources — they slow down `plan`/`apply`.
- Use `locals` for values referenced multiple times to ensure consistency and avoid duplication.
- Use comments to explain complex configurations and non-obvious design decisions.

## Style and Formatting

- Follow the Terraform Style Guide: 2-space indentation, consistent naming.
- Run `terraform fmt` before every commit. This is non-negotiable.
- Run `terraform validate` to check for syntax errors.
- Run `tflint` to check for style violations and best-practice compliance.
- Resource naming: use descriptive, consistent names. Use underscores as word separators
  (`my_security_group`, not `my-security-group`).
- **File organization within a project:**
  - `providers.tf` — provider configurations and version constraints
  - `variables.tf` — all input variable declarations
  - `outputs.tf` — all output declarations
  - `main.tf` — root-level resources or module calls
  - Named files for logical groups (`network.tf`, `ecs.tf`, `rds.tf`)

- **Within resource blocks, order attributes as:**
  1. `depends_on` (if present)
  2. `for_each` or `count` (if present)
  3. Required attributes (alphabetized within each section)
  4. Optional attributes (alphabetized within each section)
  5. `lifecycle` block (always last)

- Alphabetize providers, variables, data sources, resources, and outputs within each file.
- Use blank lines to separate logical sections. Group related attributes; separate sections with
  blank lines.

## Documentation

- **Every variable and output MUST include `description` and `type` attributes.**

  ```hcl
  variable "environment" {
    description = "Deployment environment name (e.g., staging, production)"
    type        = string
  }

  output "cluster_endpoint" {
    description = "EKS cluster API server endpoint"
    value       = aws_eks_cluster.main.endpoint
    sensitive   = false
  }
  ```

- Include a `README.md` in each Terraform project with: purpose, prerequisites, usage examples,
  and a description of all inputs/outputs.
- Use `terraform-docs` to generate variable/output documentation automatically.

## Testing

- Write tests using the native `.tftest.hcl` format:

  ```hcl
  run "creates_security_group_with_correct_ingress" {
    command = plan

    assert {
      condition     = aws_security_group.app.ingress[0].from_port == 443
      error_message = "Ingress rule must allow port 443"
    }
  }
  ```

- Cover both positive (resources created with expected values) and negative (invalid inputs
  rejected) scenarios.
- Tests must be idempotent — running them multiple times produces the same result.

## State Management

- Never commit `.tfstate` or `.tfstate.backup` files to version control.
- Use remote state backends (S3 + DynamoDB for locking, or Terraform Cloud) for all shared
  environments.
- Use separate state files per environment (dev, staging, production) and per major component.

## Version Pinning

- Pin provider versions in `required_providers` blocks using `~>` (pessimistic constraint) or
  exact versions for stability:

  ```hcl
  terraform {
    required_version = ">= 1.9"
    required_providers {
      aws = {
        source  = "hashicorp/aws"
        version = "~> 5.0"
      }
    }
  }
  ```

- Update provider versions regularly for security patches. Use Dependabot for automated updates
  (see `standards/dependabot-policy.md` for the Terraform ecosystem template).
