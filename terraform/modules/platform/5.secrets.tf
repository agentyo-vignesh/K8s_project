# =============================================================================
# AWS Secrets Manager.
#
# Two secrets, because the apps read two: one for the database, one for
# everything else. The field names are fixed by the application code -
# AwsSecretsManagerSecretService.java and backend/app/core/secrets.py - and by
# what RDS managed rotation writes, so switching to rotation later needs no
# code change. Note "dbname", not "dbName".
#
# The pods read these directly over IRSA. There is no Kubernetes Secret.
# =============================================================================

resource "random_password" "jwt" {
  length  = 48
  special = false
}

resource "random_password" "internal_api" {
  length  = 32
  special = false
}

# recovery_window 0 so destroy/apply can reuse the name. The default 7 days
# keeps it reserved and the next apply fails with "scheduled for deletion".

# -----------------------------------------------------------------------------
# Database credentials
# -----------------------------------------------------------------------------
resource "aws_secretsmanager_secret" "database" {
  name                    = "ai-interview/prod/database"
  description             = "Read by middleware and ai-service over IRSA"
  recovery_window_in_days = 0
}

# host and password in ONE secret, on purpose: they can never drift apart and
# leave the app pointing at one database with another's password.
resource "aws_secretsmanager_secret_version" "database" {
  secret_id = aws_secretsmanager_secret.database.id

  secret_string = jsonencode({
    engine   = "postgres"
    host     = aws_db_instance.main.address
    port     = aws_db_instance.main.port
    dbname   = aws_db_instance.main.db_name
    username = aws_db_instance.main.username
    password = random_password.db.result
  })
}

# -----------------------------------------------------------------------------
# Application credentials
# -----------------------------------------------------------------------------
resource "aws_secretsmanager_secret" "application" {
  name                    = "ai-interview/prod/application"
  description             = "JWT signing key and the internal service API key"
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "application" {
  secret_id = aws_secretsmanager_secret.application.id

  secret_string = jsonencode({
    # At least 32 bytes, or the middleware refuses to start.
    jwtSigningKey = random_password.jwt.result
    # Middleware sends it, ai-service checks it. One value, one place.
    aiServiceApiKey = random_password.internal_api.result
    # Empty means the AI service uses its mock provider.
    openaiApiKey = ""
  })
}

# -----------------------------------------------------------------------------
# Outputs
# -----------------------------------------------------------------------------

output "database_secret_id" {
  value = aws_secretsmanager_secret.database.name
}

output "application_secret_id" {
  value = aws_secretsmanager_secret.application.name
}
