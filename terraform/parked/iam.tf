# # =============================================================================
# # IRSA roles for the application.
# #
# # This file is the whole "no AWS access keys" story on the infrastructure side.
# #
# # How it works:
# #   1. `enable_irsa` on the EKS module registers the cluster's OIDC issuer as an
# #      IAM identity provider.
# #   2. Each role below trusts that provider, but only for one specific
# #      `system:serviceaccount:<namespace>:<name>` subject.
# #   3. The Helm chart annotates the ServiceAccount with the role ARN.
# #   4. EKS projects a signed token into the pod; the AWS SDK's default credential
# #      provider chain exchanges it via sts:AssumeRoleWithWebIdentity.
# #
# # The application never sees a credential. Both services already build their AWS
# # clients with the default chain, so nothing in the code changes between a laptop
# # (SSO profile) and the cluster (IRSA).
# #
# # The `sub` condition is what makes this safe. Without it, *any* pod in the
# # cluster could assume the role. With it, only the named ServiceAccount in the
# # named namespace can.
# # =============================================================================

# locals {
#   oidc_provider_url = replace(module.eks.cluster_oidc_issuer_url, "https://", "")

#   middleware_service_account = "${var.kubernetes_namespace}:${local.name_prefix}-middleware"
#   ai_service_account         = "${var.kubernetes_namespace}:${local.name_prefix}-ai-service"
# }

# # -----------------------------------------------------------------------------
# # Trust policies
# # -----------------------------------------------------------------------------
# data "aws_iam_policy_document" "middleware_assume_role" {
#   statement {
#     effect  = "Allow"
#     actions = ["sts:AssumeRoleWithWebIdentity"]

#     principals {
#       type        = "Federated"
#       identifiers = [module.eks.oidc_provider_arn]
#     }

#     # Scopes the role to exactly one ServiceAccount.
#     condition {
#       test     = "StringEquals"
#       variable = "${local.oidc_provider_url}:sub"
#       values   = ["system:serviceaccount:${local.middleware_service_account}"]
#     }

#     # Without this, a token minted for a different audience could be replayed.
#     condition {
#       test     = "StringEquals"
#       variable = "${local.oidc_provider_url}:aud"
#       values   = ["sts.amazonaws.com"]
#     }
#   }
# }

# data "aws_iam_policy_document" "ai_service_assume_role" {
#   statement {
#     effect  = "Allow"
#     actions = ["sts:AssumeRoleWithWebIdentity"]

#     principals {
#       type        = "Federated"
#       identifiers = [module.eks.oidc_provider_arn]
#     }

#     condition {
#       test     = "StringEquals"
#       variable = "${local.oidc_provider_url}:sub"
#       values   = ["system:serviceaccount:${local.ai_service_account}"]
#     }

#     condition {
#       test     = "StringEquals"
#       variable = "${local.oidc_provider_url}:aud"
#       values   = ["sts.amazonaws.com"]
#     }
#   }
# }

# # -----------------------------------------------------------------------------
# # Permission policies.
# #
# # Resource-scoped to the exact secrets and bucket this platform owns. A wildcard
# # on secretsmanager:GetSecretValue would let a compromised pod read every secret
# # in the account.
# # -----------------------------------------------------------------------------
# data "aws_iam_policy_document" "middleware_permissions" {
#   statement {
#     sid    = "ReadPlatformSecrets"
#     effect = "Allow"
#     actions = [
#       "secretsmanager:GetSecretValue",
#       "secretsmanager:DescribeSecret",
#     ]
#     resources = [
#       aws_secretsmanager_secret.database.arn,
#       aws_secretsmanager_secret.application.arn,
#     ]
#   }

#   statement {
#     sid    = "ManageResumeObjects"
#     effect = "Allow"
#     actions = [
#       "s3:GetObject",
#       "s3:PutObject",
#       "s3:DeleteObject",
#     ]
#     # Objects under the bucket, not the bucket itself.
#     resources = ["${aws_s3_bucket.resumes.arn}/*"]
#   }

#   statement {
#     sid       = "ListResumeBucket"
#     effect    = "Allow"
#     actions   = ["s3:ListBucket", "s3:GetBucketLocation"]
#     resources = [aws_s3_bucket.resumes.arn]
#   }
# }

# data "aws_iam_policy_document" "ai_service_permissions" {
#   statement {
#     sid    = "ReadPlatformSecrets"
#     effect = "Allow"
#     actions = [
#       "secretsmanager:GetSecretValue",
#       "secretsmanager:DescribeSecret",
#     ]
#     resources = [
#       aws_secretsmanager_secret.database.arn,
#       aws_secretsmanager_secret.application.arn,
#     ]
#   }

#   # No S3 access at all: the AI service never touches resume files.
# }

# # -----------------------------------------------------------------------------
# # Roles
# # -----------------------------------------------------------------------------
# resource "aws_iam_role" "middleware" {
#   name               = "${local.name_prefix}-middleware"
#   description        = "IRSA role for the middleware service"
#   assume_role_policy = data.aws_iam_policy_document.middleware_assume_role.json

#   # Caps the session length regardless of what the SDK requests.
#   max_session_duration = 3600

#   tags = merge(local.common_tags, { Component = "middleware" })
# }

# resource "aws_iam_role_policy" "middleware" {
#   name   = "${local.name_prefix}-middleware"
#   role   = aws_iam_role.middleware.id
#   policy = data.aws_iam_policy_document.middleware_permissions.json
# }

# resource "aws_iam_role" "ai_service" {
#   name               = "${local.name_prefix}-ai-service"
#   description        = "IRSA role for the AI service"
#   assume_role_policy = data.aws_iam_policy_document.ai_service_assume_role.json

#   max_session_duration = 3600

#   tags = merge(local.common_tags, { Component = "ai-service" })
# }

# resource "aws_iam_role_policy" "ai_service" {
#   name   = "${local.name_prefix}-ai-service"
#   role   = aws_iam_role.ai_service.id
#   policy = data.aws_iam_policy_document.ai_service_permissions.json
# }

# # =============================================================================
# # GitHub Actions deployment role.
# #
# # Also OIDC: GitHub presents a signed token and AWS exchanges it for short-lived
# # credentials. No AWS_ACCESS_KEY_ID is stored in GitHub secrets.
# #
# # The `sub` condition restricts this to one repository. Omitting it would let any
# # GitHub repository in the world assume the role.
# # =============================================================================

# variable "github_repository" {
#   description = "owner/repo allowed to assume the deployment role via OIDC"
#   type        = string
#   default     = "your-org/ai-interview-platform"
# }

# variable "create_github_oidc_provider" {
#   description = <<-EOT
#     Create the GitHub OIDC provider.

#     An account can hold only one provider per URL. Set false if another stack in
#     this account already created token.actions.githubusercontent.com.
#   EOT
#   type        = bool
#   default     = true
# }

# resource "aws_iam_openid_connect_provider" "github" {
#   count = var.create_github_oidc_provider ? 1 : 0

#   url            = "https://token.actions.githubusercontent.com"
#   client_id_list = ["sts.amazonaws.com"]
#   # AWS validates the GitHub certificate chain natively; this thumbprint is
#   # retained because the API still requires the field.
#   thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]

#   tags = local.common_tags
# }

# data "aws_iam_openid_connect_provider" "github_existing" {
#   count = var.create_github_oidc_provider ? 0 : 1
#   url   = "https://token.actions.githubusercontent.com"
# }

# locals {
#   github_oidc_provider_arn = var.create_github_oidc_provider ? aws_iam_openid_connect_provider.github[0].arn : data.aws_iam_openid_connect_provider.github_existing[0].arn
# }

# data "aws_iam_policy_document" "github_actions_assume_role" {
#   statement {
#     effect  = "Allow"
#     actions = ["sts:AssumeRoleWithWebIdentity"]

#     principals {
#       type        = "Federated"
#       identifiers = [local.github_oidc_provider_arn]
#     }

#     condition {
#       test     = "StringEquals"
#       variable = "token.actions.githubusercontent.com:aud"
#       values   = ["sts.amazonaws.com"]
#     }

#     # StringLike with a repo-scoped prefix. `repo:owner/repo:*` covers every
#     # branch and tag of this repository and nothing else.
#     condition {
#       test     = "StringLike"
#       variable = "token.actions.githubusercontent.com:sub"
#       values   = ["repo:${var.github_repository}:*"]
#     }
#   }
# }

# data "aws_iam_policy_document" "github_actions_permissions" {
#   # ECR authorisation is account-wide by design: GetAuthorizationToken takes no
#   # resource. The push permissions below are scoped to this platform's repos.
#   statement {
#     sid       = "EcrAuth"
#     effect    = "Allow"
#     actions   = ["ecr:GetAuthorizationToken"]
#     resources = ["*"]
#   }

#   statement {
#     sid    = "EcrPush"
#     effect = "Allow"
#     actions = [
#       "ecr:BatchCheckLayerAvailability",
#       "ecr:CompleteLayerUpload",
#       "ecr:InitiateLayerUpload",
#       "ecr:PutImage",
#       "ecr:UploadLayerPart",
#       "ecr:BatchGetImage",
#       "ecr:DescribeImages",
#       "ecr:ListImages",
#     ]
#     resources = [for repo in aws_ecr_repository.this : repo.arn]
#   }
# }

# resource "aws_iam_role" "github_actions" {
#   name               = "${local.name_prefix}-github-actions"
#   description        = "Assumed by GitHub Actions via OIDC to push images to ECR"
#   assume_role_policy = data.aws_iam_policy_document.github_actions_assume_role.json

#   max_session_duration = 3600

#   tags = local.common_tags
# }

# resource "aws_iam_role_policy" "github_actions" {
#   name   = "${local.name_prefix}-github-actions"
#   role   = aws_iam_role.github_actions.id
#   policy = data.aws_iam_policy_document.github_actions_permissions.json
# }
