# # =============================================================================
# # Provider and backend configuration.
# #
# # Versions are constrained with `~>` so a patch release is picked up
# # automatically but a minor or major bump is a deliberate change. Terraform
# # providers do introduce breaking behaviour in minor releases; an unpinned
# # provider means `terraform apply` can behave differently tomorrow with no code
# # change.
# # =============================================================================

# terraform {
#   required_version = "~> 1.9"

#   required_providers {
#     aws = {
#       source  = "hashicorp/aws"
#       version = "~> 5.70"
#     }
#     kubernetes = {
#       source  = "hashicorp/kubernetes"
#       version = "~> 2.33"
#     }
#     random = {
#       source  = "hashicorp/random"
#       version = "~> 3.6"
#     }
#     tls = {
#       source  = "hashicorp/tls"
#       version = "~> 4.0"
#     }
#   }

#   # -----------------------------------------------------------------------------
#   # Remote state.
#   #
#   # Commented out because it cannot be created by the configuration it stores:
#   # the bucket and lock table must exist first. Create them once (see
#   # docs/DEPLOYMENT.md), then uncomment and run `terraform init -migrate-state`.
#   #
#   # Local state is fine for one engineer experimenting and unacceptable for a
#   # shared environment: it has no locking, so two concurrent applies corrupt it.
#   # -----------------------------------------------------------------------------
#   # backend "s3" {
#   #   bucket       = "ai-interview-terraform-state"
#   #   key          = "eks/terraform.tfstate"
#   #   region       = "ap-south-1"
#   #   encrypt      = true
#   #   use_lockfile = true
#   # }
# }

# provider "aws" {
#   region = var.aws_region

#   default_tags {
#     tags = local.common_tags
#   }
# }

# # The Kubernetes provider authenticates with a token minted by the AWS CLI at
# # apply time rather than a long-lived kubeconfig, so nothing credential-shaped is
# # written to state.
# provider "kubernetes" {
#   host                   = module.eks.cluster_endpoint
#   cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

#   exec {
#     api_version = "client.authentication.k8s.io/v1beta1"
#     command     = "aws"
#     args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name, "--region", var.aws_region]
#   }
# }
