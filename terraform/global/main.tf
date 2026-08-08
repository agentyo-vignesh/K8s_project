# Account-level resources. Applied once, before any environment.
#
#   cd terraform/global && terraform init && terraform apply
#
# One resource lives here, and that is the point: an IAM OIDC provider is keyed
# by URL and an account may hold exactly one per URL, so it cannot belong to dev
# or to prod. Everything else is per-environment.

terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.70" }
    tls = { source = "hashicorp/tls", version = "~> 4.0" }
  }

  # Written out in full. `terraform init` needs no flags, so this directory
  # cannot be pointed at the wrong state.
  backend "s3" {
    bucket       = "ai-interview-tfstate-043083733056"
    key          = "ai-interview/global/terraform.tfstate"
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
      Environment = "global"
      ManagedBy   = "terraform"
    }
  }
}

data "aws_caller_identity" "current" {}

# Registers GitHub as a token issuer. Grants nothing on its own - each
# environment's role pins its own repository in its own trust policy.
data "tls_certificate" "github" {
  url = "https://token.actions.githubusercontent.com"
}

resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.github.certificates[0].sha1_fingerprint]
}

output "account_id" {
  value = data.aws_caller_identity.current.account_id
}

output "github_oidc_provider_arn" {
  value = aws_iam_openid_connect_provider.github.arn
}
