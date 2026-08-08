# IRSA roles - one per service. Driven by var.irsa_service_accounts, so a fourth
# service is one map entry rather than a copied block.

locals {
  oidc_url = replace(aws_iam_openid_connect_provider.oidc.url, "https://", "")

  app_secret_arns = [
    aws_secretsmanager_secret.database.arn,
    aws_secretsmanager_secret.application.arn,
  ]
}

# The sub condition is the security boundary: without it any pod in the cluster
# could read these secrets. The namespace is part of it, so a dev pod cannot
# reach prod's secrets.
data "aws_iam_policy_document" "irsa_assume" {
  for_each = var.irsa_service_accounts

  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    effect  = "Allow"

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.oidc.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_url}:sub"
      values   = ["system:serviceaccount:${local.namespace}:${each.value}"]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_url}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

# Read-only, these two secrets only. The ARNs already carry the random suffix AWS
# appends; a wildcard would widen this to every secret with the same prefix.
data "aws_iam_policy_document" "read_secrets" {
  statement {
    actions   = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
    effect    = "Allow"
    resources = local.app_secret_arns
  }
}

resource "aws_iam_role" "service" {
  for_each = var.irsa_service_accounts

  # The environment is in the name because IAM is account-wide.
  name               = "${local.name}-${each.value}"
  assume_role_policy = data.aws_iam_policy_document.irsa_assume[each.key].json
}

resource "aws_iam_role_policy" "service" {
  for_each = var.irsa_service_accounts

  name   = "read-secrets"
  role   = aws_iam_role.service[each.key].id
  policy = data.aws_iam_policy_document.read_secrets.json
}

output "service_role_arns" {
  description = "Keyed by the map key in var.irsa_service_accounts."
  value       = { for k, r in aws_iam_role.service : k => r.arn }
}

# Named individually too: a script cannot `terraform output -raw` one map key.
output "middleware_role_arn" {
  value = aws_iam_role.service["middleware"].arn
}

output "ai_service_role_arn" {
  value = aws_iam_role.service["ai_service"].arn
}
