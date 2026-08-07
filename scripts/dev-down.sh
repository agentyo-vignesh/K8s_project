#!/usr/bin/env bash
# =============================================================================
# Stop the local stack.
#
# Without arguments, containers are removed but volumes are kept, so the database
# and uploaded resumes survive. Pass --volumes to wipe them and force Flyway to
# re-run from scratch on the next start.
# =============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

info() { printf '\033[0;34m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[0;33m[!]\033[0m %s\n' "$*"; }

REMOVE_VOLUMES=false

while [ $# -gt 0 ]; do
    case "$1" in
        -v|--volumes)
            REMOVE_VOLUMES=true
            shift
            ;;
        -h|--help)
            cat <<'EOF'
Usage: dev-down.sh [--volumes]

  --volumes   Also delete the PostgreSQL and resume volumes. Destroys all local
              data; the next dev-up.sh re-runs every Flyway migration.
EOF
            exit 0
            ;;
        *)
            warn "Unknown option: $1"
            exit 1
            ;;
    esac
done

if [ "${REMOVE_VOLUMES}" = true ]; then
    warn "This deletes the local database and every uploaded resume."
    read -r -p "Continue? [y/N] " reply
    case "${reply}" in
        [yY]|[yY][eE][sS])
            info "Stopping and removing volumes..."
            docker compose down --volumes --remove-orphans
            info "Done. The next dev-up.sh starts from an empty database."
            ;;
        *)
            info "Cancelled."
            exit 0
            ;;
    esac
else
    info "Stopping (volumes preserved)..."
    docker compose down --remove-orphans
    info "Done. Use --volumes to also discard the database."
fi
