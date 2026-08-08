# =============================================================================
# The role GitHub Actions assumes to deploy.
#
# Same idea as IRSA, different identity provider. A pod proves who it is with a
# token signed by the cluster; a workflow proves it with a token signed by
# GitHub. Neither needs an access key.
# =============================================================================

variable "github_repo" {
  description = "owner/name of the repository allowed to deploy"
  type        = string
  default     = "agentyo-vignesh/K8s_project"
}

# GitHub can send the sub claim in two shapes:
#
#   repo:owner/name:ref:refs/heads/main                       classic
#   repo:owner@<ownerId>/name@<repoId>:ref:refs/heads/main    immutable ids
#
# The second is what this repository actually sends. The numeric ids survive a
# rename, so trust cannot follow a repository that was renamed away and cannot
# be inherited by a new repository that takes the old name.
#
# Both patterns are allowed, because which one arrives depends on an
# organisation setting that can change. Find yours with:
#   gh api repos/<owner>/<name> --jq '{owner:.owner.id, repo:.id}'
variable "github_owner_id" {
  description = "Numeric GitHub owner id"
  type        = string
  default     = "236602875"
}

variable "github_repo_id" {
  description = "Numeric GitHub repository id"
  type        = string
  default     = "1326182266"
}

# -----------------------------------------------------------------------------
# Trust GitHub as a token issuer
# -----------------------------------------------------------------------------
data "tls_certificate" "github" {
  url = "https://token.actions.githubusercontent.com"
}

resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.github.certificates[0].sha1_fingerprint]
}

# -----------------------------------------------------------------------------
# The role
# -----------------------------------------------------------------------------

# The sub condition is the whole control, exactly as with IRSA. Here it pins the
# repository instead of a ServiceAccount - any other repo presenting a valid
# GitHub token is still refused.
data "aws_iam_policy_document" "github_assume" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    effect  = "Allow"

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values = [
        "repo:${var.github_repo}:*",
        "repo:${split("/", var.github_repo)[0]}@${var.github_owner_id}/${split("/", var.github_repo)[1]}@${var.github_repo_id}:*",
      ]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "github_deploy" {
  name               = "ai-interview-github-deploy"
  assume_role_policy = data.aws_iam_policy_document.github_assume.json
}

# Push images, and read enough about the cluster to write a kubeconfig.
# It cannot read any secret - the pods do that themselves.
data "aws_iam_policy_document" "github_deploy" {
  statement {
    sid       = "EcrLogin"
    actions   = ["ecr:GetAuthorizationToken"]
    effect    = "Allow"
    resources = ["*"] # this action does not support resource scoping
  }

  statement {
    sid    = "EcrPush"
    effect = "Allow"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:CompleteLayerUpload",
      "ecr:InitiateLayerUpload",
      "ecr:PutImage",
      "ecr:UploadLayerPart",
      "ecr:BatchGetImage",
      "ecr:GetDownloadUrlForLayer",
    ]
    resources = [for r in aws_ecr_repository.app : r.arn]
  }

  statement {
    sid       = "EksKubeconfig"
    actions   = ["eks:DescribeCluster"]
    effect    = "Allow"
    resources = [aws_eks_cluster.main.arn]
  }
}

resource "aws_iam_role_policy" "github_deploy" {
  name   = "deploy"
  role   = aws_iam_role.github_deploy.id
  policy = data.aws_iam_policy_document.github_deploy.json
}

# -----------------------------------------------------------------------------
# Let that role talk to the Kubernetes API
# -----------------------------------------------------------------------------

# IAM alone is not enough. Without an access entry, kubectl and helm fail with
# "You must be logged in to the server", even though the AWS login succeeded.
resource "aws_eks_access_entry" "github_deploy" {
  cluster_name  = aws_eks_cluster.main.name
  principal_arn = aws_iam_role.github_deploy.arn
  type          = "STANDARD"
}

# Edit, not admin, and only in the application namespace. Enough to run
# helm upgrade; not enough to touch the rest of the cluster.
resource "aws_eks_access_policy_association" "github_deploy" {
  cluster_name  = aws_eks_cluster.main.name
  principal_arn = aws_iam_role.github_deploy.arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSEditPolicy"

  access_scope {
    type       = "namespace"
    namespaces = ["ai-interview"]
  }
}

output "github_deploy_role_arn" {
  description = "Set this as the AWS_DEPLOY_ROLE_ARN repository secret"
  value       = aws_iam_role.github_deploy.arn
}
