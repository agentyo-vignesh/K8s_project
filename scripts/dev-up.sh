#!/usr/bin/env bash
# =============================================================================
# Bring up the local stack and wait until it is actually usable.
#
# `docker compose up -d` returns as soon as the containers are created, which is
# well before the middleware has finished its Flyway migrations. This script
# waits for the readiness endpoints, so when it exits the stack is ready.
# =============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

readonly TIMEOUT_SECONDS=300
readonly POLL_INTERVAL=5

info()  { printf '\033[0;34m[+]\033[0m %s\n' "$*"; }
warn()  { printf '\033[0;33m[!]\033[0m %s\n' "$*"; }
error() { printf '\033[0;31m[x]\033[0m %s\n' "$*" >&2; }

# -----------------------------------------------------------------------------
# Preflight
# -----------------------------------------------------------------------------
if ! docker info >/dev/null 2>&1; then
    error "Docker is not running."
    exit 1
fi

# Configuration is one env file per service; there is no shared root .env.
for service_env in database middleware backend frontend; do
    if [ ! -f "${service_env}/.env" ]; then
        warn "${service_env}/.env not found; creating it from ${service_env}/.env.example"
        cp "${service_env}/.env.example" "${service_env}/.env"
    fi
done

# The database credentials and the internal API key legitimately appear in more
# than one file. Nothing in Docker checks they agree, and when they drift the
# symptom is an authentication error from a service whose own config looks fine.
info "Checking the env files agree..."
if ! ./scripts/check-env.sh; then
    error "Env files are inconsistent. Fix them and re-run."
    exit 1
fi

# -----------------------------------------------------------------------------
# Build and start
# -----------------------------------------------------------------------------
info "Building images (this takes a few minutes the first time)..."
docker compose build

info "Starting services..."
docker compose up -d

# -----------------------------------------------------------------------------
# Wait for readiness
# -----------------------------------------------------------------------------
wait_for() {
    local name="$1" url="$2" elapsed=0

    info "Waiting for ${name}..."
    while [ "${elapsed}" -lt "${TIMEOUT_SECONDS}" ]; do
        if curl -fsS --max-time 3 "${url}" >/dev/null 2>&1; then
            info "${name} is ready (${elapsed}s)."
            return 0
        fi

        # Fail fast if the container has exited rather than waiting out the
        # full timeout for something that is never coming back.
        if ! docker compose ps --status running --format '{{.Service}}' | grep -q .; then
            error "No containers are running. Check: docker compose logs"
            return 1
        fi

        sleep "${POLL_INTERVAL}"
        elapsed=$((elapsed + POLL_INTERVAL))
    done

    error "${name} did not become ready within ${TIMEOUT_SECONDS}s."
    error "Logs: docker compose logs ${name}"
    return 1
}

wait_for middleware  "http://localhost:${MIDDLEWARE_PORT:-8080}/actuator/health/readiness"
wait_for ai-service  "http://localhost:${AI_SERVICE_PORT:-8000}/health/readiness"
wait_for frontend    "http://localhost:${FRONTEND_PORT:-3000}/healthz"

# -----------------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------------
cat <<EOF

  The stack is up.

    Frontend      http://localhost:${FRONTEND_PORT:-3000}
    Swagger UI    http://localhost:${MIDDLEWARE_PORT:-8080}/swagger-ui.html
    AI service    http://localhost:${AI_SERVICE_PORT:-8000}/docs
    Metrics       http://localhost:${MIDDLEWARE_PORT:-8080}/actuator/prometheus
    PostgreSQL    localhost:${POSTGRES_PORT:-5432}

  Seed accounts (created by Flyway migration V3):

    admin@aiinterview.local          Admin@12345         ADMIN
    priya.sharma@aiinterview.local   Interviewer@12345   INTERVIEWER
    neha.gupta@example.com           Candidate@12345     CANDIDATE

  Logs:  docker compose logs -f [service]
  Stop:  ./scripts/dev-down.sh

EOF
