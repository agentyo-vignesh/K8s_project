# Two secrets, because the apps read two. Pods read them directly over IRSA -
# there is no Kubernetes Secret.
#
# Field names are fixed by AwsSecretsManagerSecretService.java and
# backend/app/core/secrets.py, and match what RDS managed rotation writes.
# Note "dbname", not "dbName".

resource "random_password" "jwt" {
  length  = 48
  special = false
}

resource "random_password" "internal_api" {
  length  = 32
  special = false
}

resource "aws_secretsmanager_secret" "database" {
  name                    = local.database_secret_name
  description             = "Read by middleware and ai-service over IRSA"
  recovery_window_in_days = var.secret_recovery_window_days
}

# host and password in ONE secret so they cannot drift apart and leave the app
# pointing at one database with another's password.
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

resource "aws_secretsmanager_secret" "application" {
  name                    = local.application_secret_name
  description             = "JWT signing key and the internal service API key"
  recovery_window_in_days = var.secret_recovery_window_days
}

resource "aws_secretsmanager_secret_version" "application" {
  secret_id = aws_secretsmanager_secret.application.id

  secret_string = jsonencode({
    # At least 32 bytes, or the middleware refuses to start.
    jwtSigningKey = random_password.jwt.result
    # Middleware sends it, ai-service checks it.
    aiServiceApiKey = random_password.internal_api.result
    # Empty means the AI service uses its mock provider.
    openaiApiKey = ""
  })
}

output "database_secret_id" {
  value = aws_secretsmanager_secret.database.name
}

output "application_secret_id" {
  value = aws_secretsmanager_secret.application.name
}
