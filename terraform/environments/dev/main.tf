# dev - the training environment. Built and destroyed around each session.
#
#   cd terraform/environments/dev
#   terraform init && terraform plan && terraform apply
#
# This file IS dev: backend and values together, so no -var-file to forget and no
# way to apply these values to another environment's state.
# What gets created is in ../../modules/platform.

terraform {
  required_version = ">= 1.10"

  required_providers {
    aws    = { source = "hashicorp/aws", version = "~> 5.70" }
    random = { source = "hashicorp/random", version = "~> 3.6" }
    tls    = { source = "hashicorp/tls", version = "~> 4.0" }
  }

  backend "s3" {
    bucket       = "ai-interview-tfstate-043083733056"
    key          = "ai-interview/dev/terraform.tfstate"
    region       = "ap-south-1"
    encrypt      = true
    use_lockfile = true
  }
}

provider "aws" {
  region = "ap-south-1"

  # Applied to everything; resource-level tags merge on top.
  default_tags {
    tags = {
      Project     = "ai-interview"
      Environment = "dev"
      ManagedBy   = "terraform"
      Owner       = "training"
      Teardown    = "daily"
    }
  }
}

data "aws_caller_identity" "current" {}

# Created once by ../../global.
data "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"
}

module "platform" {
  source = "../../modules/platform"

  project     = "ai-interview"
  environment = "dev"
  region      = "ap-south-1"
  azs         = ["ap-south-1a", "ap-south-1b"]

  vpc_cidr = "10.0.0.0/16"

  # NOT t3.medium. This account is Free Tier restricted and EC2 refuses it with
  # "not eligible for Free Tier" - which surfaces as a node group stuck in
  # CREATING for half an hour with an EMPTY health.issues[] and no instances at
  # all. The real reason appears only in the ASG scaling activity:
  #   aws autoscaling describe-scaling-activities --auto-scaling-group-name <asg>
  #
  # Three t3.small rather than two 4 GiB nodes. Cheaper, because the only
  # eligible 4 GiB type costs 3.8x a t3.small:
  #   3 x t3.small     USD 0.067/hr
  #   2 x c7i-flex     USD 0.170/hr
  #
  # Measured on the running cluster, not estimated:
  #   1,909 MiB capacity -> 1,433 MiB allocatable per node, 110 pod slots
  #   3 nodes            -> 4,299 MiB and 330 slots
  #
  # Pod slots are NOT the constraint - prefix delegation in 2.eks.tf raises
  # max-pods from 11 to 110, so memory binds first. Requests total ~1,766 MiB
  # with the trimmed observability stack, or ~2,510 MiB with Loki and Alloy
  # added back; both fit.
  #   aws ec2 describe-instance-types --filters Name=free-tier-eligible,Values=true
  node_instance_types = ["t3.small"]
  node_desired_size   = 3
  node_min_size       = 3
  node_max_size       = 4

  cluster_version = "1.36"

  # Demo database. Every one of these is the opposite in prod.
  db_instance_class        = "db.t4g.micro"
  db_engine_version        = "16.14"
  db_allocated_storage     = 20
  db_backup_retention_days = 0
  db_deletion_protection   = false
  db_skip_final_snapshot   = true

  # 0 frees the secret names immediately; anything else and a rebuild fails with
  # "already scheduled for deletion".
  secret_recovery_window_days = 0

  ecr_force_delete = true

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
