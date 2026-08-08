# prod - not currently deployed.
#
#   cd terraform/environments/prod
#   terraform init && terraform plan     # read it, then apply
#
# Read this beside ../dev/main.tf: same module, and every line that differs is a
# decision somebody made. Nothing is shared with dev except the account-wide
# GitHub OIDC provider from ../../global, because AWS permits one per account.

terraform {
  required_version = ">= 1.10"

  required_providers {
    aws    = { source = "hashicorp/aws", version = "~> 5.70" }
    random = { source = "hashicorp/random", version = "~> 3.6" }
    tls    = { source = "hashicorp/tls", version = "~> 4.0" }
  }

  backend "s3" {
    bucket       = "ai-interview-tfstate-043083733056"
    key          = "ai-interview/prod/terraform.tfstate"
    region       = "ap-south-1"
    encrypt      = true
    use_lockfile = true
  }
}

provider "aws" {
  region = "ap-south-1"

  default_tags {
    tags = {
      Project     = "ai-interview"
      Environment = "prod"
      ManagedBy   = "terraform"
      Owner       = "platform"
      Compliance  = "review-before-destroy"
    }
  }
}

data "aws_caller_identity" "current" {}

data "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"
}

module "platform" {
  source = "../../modules/platform"

  project     = "ai-interview"
  environment = "prod"
  region      = "ap-south-1"
  azs         = ["ap-south-1a", "ap-south-1b"]

  # Different from dev. Separate VPCs, so overlapping works today and makes
  # peering impossible later - at the point where renumbering means rebuilding.
  vpc_cidr = "10.1.0.0/16"

  # Free Tier restricted account - see the note in ../dev/main.tf. Larger than
  # dev because prod runs three nodes of real traffic, not one class.
  node_instance_types = ["m7i-flex.large"]
  node_desired_size   = 3
  node_min_size       = 3
  node_max_size       = 6

  # Upgrades are proven in dev first, which only works if the two can differ.
  cluster_version = "1.36"

  db_instance_class        = "db.t3.medium"
  db_engine_version        = "16.14"
  db_allocated_storage     = 100
  db_backup_retention_days = 7
  db_deletion_protection   = true
  db_skip_final_snapshot   = false

  # Losing the JWT signing key with no way back is worse here than a name being
  # reserved for 30 days.
  secret_recovery_window_days = 30

  ecr_force_delete = false

  github_repo              = "agentyo-vignesh/K8s_project"
  github_owner_id          = "236602875"
  github_repo_id           = "1326182266"
  github_oidc_provider_arn = data.aws_iam_openid_connect_provider.github.arn
}

# A module's outputs are not visible from here unless re-exposed. The first ten
# are the contract scripts/bootstrap.sh reads; the rest are what you actually
# want when something is wrong. project, environment and region were here too -
# literals typed forty lines above in this same file.
output "cluster_name" { value = module.platform.cluster_name }
output "namespace" { value = module.platform.namespace }
output "vpc_id" { value = module.platform.vpc_id }
output "image_registry" { value = module.platform.image_registry }
output "ecr_prefix" { value = module.platform.ecr_prefix }
output "database_secret_id" { value = module.platform.database_secret_id }
output "application_secret_id" { value = module.platform.application_secret_id }
output "middleware_role_arn" { value = module.platform.middleware_role_arn }
output "ai_service_role_arn" { value = module.platform.ai_service_role_arn }
output "github_deploy_role_arn" { value = module.platform.github_deploy_role_arn }

# Full pull URL per service. terraform output -json ecr_repository_urls
output "ecr_repository_urls" { value = module.platform.ecr_repository_urls }

# Which account this actually applied to.
output "account_id" { value = data.aws_caller_identity.current.account_id }

# terraform output -raw db_password
output "db_password" {
  value     = module.platform.db_password
  sensitive = true
}
