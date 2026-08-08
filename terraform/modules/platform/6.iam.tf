# =============================================================================
# IRSA roles - one per service, so each pod gets only what it needs.
#
# The middleware also reads the database secret; the AI service reads both too,
# because it connects to the same database. Neither role can read anything else
# in the account.
# =============================================================================

locals {
  oidc_url = replace(aws_iam_openid_connect_provider.oidc.url, "https://", "")

  app_secret_arns = [
    aws_secretsmanager_secret.database.arn,
    aws_secretsmanager_secret.application.arn,
  ]
}

# A pod may assume a role only if its ServiceAccount name matches exactly.
# Without the sub condition, ANY pod in the cluster could read these secrets.
data "aws_iam_policy_document" "irsa_assume" {
  for_each = {
    middleware = "system:serviceaccount:ai-interview:middleware"
    ai_service = "system:serviceaccount:ai-interview:ai-service"
  }

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
      values   = [each.value]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_url}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

# Read-only, and only these two secrets.
data "aws_iam_policy_document" "read_secrets" {
  statement {
    actions   = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
    effect    = "Allow"
    resources = local.app_secret_arns
  }
}

resource "aws_iam_role" "middleware" {
  name               = "ai-interview-middleware"
  assume_role_policy = data.aws_iam_policy_document.irsa_assume["middleware"].json
}

resource "aws_iam_role_policy" "middleware" {
  name   = "read-secrets"
  role   = aws_iam_role.middleware.id
  policy = data.aws_iam_policy_document.read_secrets.json
}

resource "aws_iam_role" "ai_service" {
  name               = "ai-interview-ai-service"
  assume_role_policy = data.aws_iam_policy_document.irsa_assume["ai_service"].json
}

resource "aws_iam_role_policy" "ai_service" {
  name   = "read-secrets"
  role   = aws_iam_role.ai_service.id
  policy = data.aws_iam_policy_document.read_secrets.json
}

# -----------------------------------------------------------------------------
# Outputs - annotate each ServiceAccount with the matching ARN
# -----------------------------------------------------------------------------

output "middleware_role_arn" {
  value = aws_iam_role.middleware.arn
}

output "ai_service_role_arn" {
  value = aws_iam_role.ai_service.arn
}
