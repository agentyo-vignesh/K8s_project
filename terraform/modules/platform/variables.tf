# Inputs. `project` and `environment` carry the design - everything else derives
# from those two. Values are set in environments/<env>/main.tf.
#
# Almost nothing here has a default, on purpose. Every environment was passing an
# explicit value for all of them anyway, so the defaults were dead: change one
# and nothing happens, change an environment and the default becomes a lie about
# what "normal" is. A variable now either has a default nobody overrides, or it
# has none and the environment must say.

variable "project" {
  description = "Application name. Prefixes every resource and the ECR repository path."
  type        = string

  validation {
    # The intersection of what an RDS identifier, an ECR path and a Kubernetes
    # namespace each allow.
    condition     = can(regex("^[a-z][a-z0-9-]{1,28}[a-z0-9]$", var.project))
    error_message = "project must be lowercase letters, digits and hyphens, starting with a letter."
  }
}

variable "environment" {
  description = "Which copy of the project this is. Part of every name and of the state key."
  type        = string

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment must be one of: dev, staging, prod."
  }
}

variable "region" {
  description = "Every resource lives here."
  type        = string
}

variable "azs" {
  description = "Exactly two. EKS rejects a single-AZ cluster and an RDS subnet group needs two."
  type        = list(string)

  validation {
    condition     = length(var.azs) == 2
    error_message = "azs must contain exactly two availability zones."
  }
}

variable "vpc_cidr" {
  description = "Give each environment its own range if they will ever be peered."
  type        = string
}

variable "node_instance_types" {
  description = "t3.medium is the floor once the observability stack is installed; see 2.eks.tf."
  type        = list(string)
}

variable "node_desired_size" {
  type = number
}

variable "node_min_size" {
  type = number
}

variable "node_max_size" {
  type = number
}

variable "db_instance_class" {
  type = string
}

variable "db_engine_version" {
  description = "16.14 is the newest 16.x orderable for db.t4g.micro in ap-south-1."
  type        = string
}

variable "db_allocated_storage" {
  type = number
}

variable "db_backup_retention_days" {
  description = "0 disables automated backups. Fine for a class, wrong for anything else."
  type        = number
}

variable "db_deletion_protection" {
  description = "When true, terraform destroy refuses to delete the database."
  type        = bool
}

variable "db_skip_final_snapshot" {
  type = bool
}

variable "secret_recovery_window_days" {
  description = "0 frees the name immediately, which a rebuilt-daily environment needs. Raise it in prod."
  type        = number

  validation {
    condition     = var.secret_recovery_window_days == 0 || (var.secret_recovery_window_days >= 7 && var.secret_recovery_window_days <= 30)
    error_message = "secret_recovery_window_days must be 0, or between 7 and 30."
  }
}

variable "ecr_force_delete" {
  description = "Deletes images along with the repository. Never leave this true in prod."
  type        = bool
}

# The two numeric ids cannot be derived - they are facts owned by GitHub, which
# is precisely when a value earns a variable.
#   gh api repos/<owner>/<name> --jq '{owner:.owner.id, repo:.id}'
variable "github_repo" {
  description = "owner/name of the repository allowed to deploy."
  type        = string
}

variable "github_owner_id" {
  type = string
}

variable "github_repo_id" {
  type = string
}

variable "github_oidc_provider_arn" {
  description = "From terraform/global. Account-global - one per URL per account, so an environment cannot own it."
  type        = string
}

# The only two with defaults, because no environment overrides either. Both are
# shape, not policy: how many services exist, and which ServiceAccount may assume
# which role.
variable "services" {
  description = "One ECR repository per entry."
  type        = list(string)
  default     = ["middleware", "ai-service", "frontend"]
}

variable "irsa_service_accounts" {
  description = "Map key is a Terraform identifier; value is the ServiceAccount name in the app namespace."
  type        = map(string)
  default = {
    middleware = "middleware"
    ai_service = "ai-service"
  }
}
