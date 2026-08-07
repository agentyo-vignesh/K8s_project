#!/usr/bin/env bash
# =============================================================================
# Generate cryptographically strong secret material.
#
# Exists because the single most common way this platform gets deployed insecurely
# is someone shipping the placeholder values from .env.example. These are read
# from /dev/urandom via openssl, never from a keyboard or a password manager's
# "generate" button with an unknown alphabet.
#
#   ./scripts/generate-secrets.sh            # print values
#   ./scripts/generate-secrets.sh --env      # .env format
#   ./scripts/generate-secrets.sh --aws ai-interview/prod/application
# =============================================================================
set -euo pipefail

command -v openssl >/dev/null 2>&1 || { echo "openssl is required" >&2; exit 1; }

FORMAT="plain"
AWS_SECRET_ID=""

while [ $# -gt 0 ]; do
    case "$1" in
        --env)  FORMAT="env"; shift ;;
        --helm) FORMAT="helm"; shift ;;
        --aws)  FORMAT="aws"; AWS_SECRET_ID="${2:?--aws requires a secret id}"; shift 2 ;;
        -h|--help)
            sed -n '2,12p' "$0" | sed 's/^# \?//'
            exit 0
            ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

# base64 of 48 random bytes: 64 characters, comfortably above the 32-byte
# minimum HS256 requires. `tr -d` strips the newline openssl appends.
JWT_SIGNING_KEY="$(openssl rand -base64 48 | tr -d '\n')"
AI_SERVICE_API_KEY="$(openssl rand -hex 24)"
# Hex for the database password: no character that needs escaping in a JDBC URL,
# a YAML value or a shell command.
DB_PASSWORD="$(openssl rand -hex 20)"

case "${FORMAT}" in
    plain)
        cat <<EOF

Generated secrets. Store them in a secret manager, not in a file in the repo.

  JWT_SIGNING_KEY     ${JWT_SIGNING_KEY}
  AI_SERVICE_API_KEY  ${AI_SERVICE_API_KEY}
  DB_PASSWORD         ${DB_PASSWORD}

Rotating JWT_SIGNING_KEY invalidates every issued token, so every user is
signed out. That is the intended behaviour after a suspected compromise.

EOF
        ;;

    env)
        cat <<EOF
JWT_SIGNING_KEY=${JWT_SIGNING_KEY}
AI_SERVICE_API_KEY=${AI_SERVICE_API_KEY}
POSTGRES_PASSWORD=${DB_PASSWORD}
EOF
        ;;

    helm)
        cat <<EOF
# Pass with -f. Do NOT commit this file.
secrets:
  create: true
  data:
    jwtSigningKey: "${JWT_SIGNING_KEY}"
    aiServiceApiKey: "${AI_SERVICE_API_KEY}"
    dbPassword: "${DB_PASSWORD}"
EOF
        ;;

    aws)
        # Merges into the existing secret rather than overwriting it, so an
        # openaiApiKey already stored there is preserved.
        command -v aws >/dev/null 2>&1 || { echo "aws CLI is required" >&2; exit 1; }
        command -v jq  >/dev/null 2>&1 || { echo "jq is required" >&2; exit 1; }

        existing="$(aws secretsmanager get-secret-value \
            --secret-id "${AWS_SECRET_ID}" \
            --query SecretString --output text 2>/dev/null || echo '{}')"

        updated="$(echo "${existing}" | jq -c \
            --arg jwt "${JWT_SIGNING_KEY}" \
            --arg api "${AI_SERVICE_API_KEY}" \
            '.jwtSigningKey = $jwt | .aiServiceApiKey = $api')"

        aws secretsmanager put-secret-value \
            --secret-id "${AWS_SECRET_ID}" \
            --secret-string "${updated}" >/dev/null

        echo "Rotated jwtSigningKey and aiServiceApiKey in ${AWS_SECRET_ID}."
        echo "Restart the middleware and AI service to pick them up:"
        echo "  kubectl -n <namespace> rollout restart deploy -l app.kubernetes.io/part-of=ai-interview-platform"
        ;;
esac
