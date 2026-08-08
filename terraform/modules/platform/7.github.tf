# The role GitHub Actions assumes to deploy. Same mechanism as IRSA with a
# different issuer: a pod's token is signed by the cluster, a workflow's by
# GitHub. Neither needs an access key.
#
# The OIDC provider itself is account-global, so it is created once by
# terraform/global and passed in as var.github_oidc_provider_arn.

# The sub condition is the whole control. It pins the repository the way IRSA
# pins a ServiceAccount; any other repo with a valid GitHub token is refused.
#
# Two shapes are allowed because which one GitHub sends depends on an org
# setting: repo:owner/name:* and repo:owner@<ownerId>/name@<repoId>:*. The
# numeric ids survive a rename, so trust cannot follow a repository renamed away.
#   gh api repos/<owner>/<name> --jq '{owner:.owner.id, repo:.id}'
data "aws_iam_policy_document" "github_assume" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    effect  = "Allow"

    principals {
      type        = "Federated"
      identifiers = [var.github_oidc_provider_arn]
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

# One role per environment: a dev deploy must not reach prod's cluster.
resource "aws_iam_role" "github_deploy" {
  name               = "${local.name}-github-deploy"
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

# IAM alone is not enough. Without an access entry, kubectl and helm fail with
# "You must be logged in to the server" even though the AWS login succeeded.
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
    namespaces = [local.namespace]
  }
}

output "github_deploy_role_arn" {
  description = "Set this as the AWS_DEPLOY_ROLE_ARN secret for this environment"
  value       = aws_iam_role.github_deploy.arn
}
