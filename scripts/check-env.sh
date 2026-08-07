#!/usr/bin/env bash
# =============================================================================
# Verify the per-service env files agree with each other.
#
# Configuration is split one file per service, which keeps each component's
# settings self-contained. The cost is that a few values legitimately appear in
# more than one file, and nothing in Docker or Kubernetes checks that they match.
#
# When they drift you get "password authentication failed for user" from a
# service whose own env file looks perfectly correct — one of the more annoying
# hours you can spend. This script turns that into a one-line failure.
#
#   ./scripts/check-env.sh
#
# Run it after editing any .env, and from dev-up.sh before the stack starts.
# =============================================================================
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

readonly DB_ENV="database/.env"
readonly MW_ENV="middleware/.env"
readonly AI_ENV="backend/.env"
readonly FE_ENV="frontend/.env"

PROBLEMS=0

ok()   { printf '\033[0;32m  ok  \033[0m %s\n' "$*"; }
bad()  { printf '\033[0;31m FAIL \033[0m %s\n' "$*"; PROBLEMS=$((PROBLEMS + 1)); }
warn() { printf '\033[0;33m warn \033[0m %s\n' "$*"; }

# Reads KEY=value from a file without sourcing it. Sourcing would execute
# whatever is in there and would also leak every variable into this shell.
read_var() {
    local file="$1" key="$2"
    [ -f "${file}" ] || return 1
    sed -n "s/^[[:space:]]*${key}=//p" "${file}" | tail -n1 | sed -e 's/^"//' -e 's/"$//'
}

compare() {
    local description="$1" file_a="$2" key_a="$3" file_b="$4" key_b="$5"
    local value_a value_b
    value_a="$(read_var "${file_a}" "${key_a}")"
    value_b="$(read_var "${file_b}" "${key_b}")"

    if [ -z "${value_a}" ]; then
        bad "${key_a} is missing or empty in ${file_a}"
        return
    fi
    if [ -z "${value_b}" ]; then
        bad "${key_b} is missing or empty in ${file_b}"
        return
    fi
    if [ "${value_a}" = "${value_b}" ]; then
        ok "${description}"
    else
        bad "${description}"
        printf '        %-22s %s = %s\n' "${file_a}" "${key_a}" "${value_a}"
        printf '        %-22s %s = %s\n' "${file_b}" "${key_b}" "${value_b}"
    fi
}

# -----------------------------------------------------------------------------
echo "Checking per-service env files..."
echo

missing=0
for f in "${DB_ENV}" "${MW_ENV}" "${AI_ENV}" "${FE_ENV}"; do
    if [ ! -f "${f}" ]; then
        bad "${f} does not exist — create it with: cp ${f}.example ${f}"
        missing=1
    fi
done
[ "${missing}" -eq 1 ] && { echo; echo "Create the missing files, then re-run."; exit 1; }

# -----------------------------------------------------------------------------
echo "Database credentials (postgres <-> middleware <-> ai-service)"
# -----------------------------------------------------------------------------
compare "database name matches"     "${DB_ENV}" POSTGRES_DB       "${MW_ENV}" DB_NAME
compare "database name matches"     "${DB_ENV}" POSTGRES_DB       "${AI_ENV}" DB_NAME
compare "database user matches"     "${DB_ENV}" POSTGRES_USER     "${MW_ENV}" DB_USERNAME
compare "database user matches"     "${DB_ENV}" POSTGRES_USER     "${AI_ENV}" DB_USERNAME
compare "database password matches" "${DB_ENV}" POSTGRES_PASSWORD "${MW_ENV}" DB_PASSWORD
compare "database password matches" "${DB_ENV}" POSTGRES_PASSWORD "${AI_ENV}" DB_PASSWORD

echo
# -----------------------------------------------------------------------------
echo "Service-to-service auth (middleware -> ai-service)"
# -----------------------------------------------------------------------------
compare "internal API key matches" "${MW_ENV}" AI_SERVICE_API_KEY "${AI_ENV}" INTERNAL_API_KEY

echo
# -----------------------------------------------------------------------------
echo "Values that must be safe on their own"
# -----------------------------------------------------------------------------

# HS256 with a key shorter than its own output is a genuine weakness, and the
# middleware refuses to start rather than accept one. Catch it here instead.
jwt_key="$(read_var "${MW_ENV}" JWT_SIGNING_KEY)"
jwt_bytes=${#jwt_key}
if [ "${jwt_bytes}" -ge 32 ]; then
    ok "JWT_SIGNING_KEY is ${jwt_bytes} bytes (minimum 32)"
else
    bad "JWT_SIGNING_KEY is ${jwt_bytes} bytes; HS256 needs at least 32. The middleware will refuse to start."
    printf '        Generate one: ./scripts/generate-secrets.sh\n'
fi

# The frontend URL is used by the BROWSER, so a compose-internal hostname can
# never work there. This mistake produces a silent network error in devtools
# with nothing in any container log.
api_base="$(read_var "${FE_ENV}" API_BASE_URL)"
case "${api_base}" in
    *"//middleware:"*|*"//ai-service:"*)
        bad "API_BASE_URL in ${FE_ENV} is '${api_base}'"
        printf '        That hostname only resolves inside the compose network. The browser\n'
        printf '        runs on your machine, so use http://localhost:8080 (or leave it empty\n'
        printf '        on Kubernetes, where the Ingress serves the UI and /api on one host).\n'
        ;;
    "")
        warn "API_BASE_URL in ${FE_ENV} is empty — correct on Kubernetes, but for compose it should be http://localhost:8080"
        ;;
    *)
        ok "API_BASE_URL is browser-reachable (${api_base})"
        ;;
esac

# Placeholders are fine locally and must never reach a shared environment.
for f in "${DB_ENV}" "${MW_ENV}" "${AI_ENV}"; do
    if grep -qE 'change-me|local-dev-only|dev-only-' "${f}" 2>/dev/null; then
        warn "${f} still contains development placeholders — fine locally, never for a shared cluster"
    fi
done

echo
# -----------------------------------------------------------------------------
if [ "${PROBLEMS}" -eq 0 ]; then
    printf '\033[0;32mAll env files agree.\033[0m\n'
    exit 0
fi

printf '\033[0;31m%d problem(s) found.\033[0m\n' "${PROBLEMS}"
exit 1
