#!/bin/sh
# =============================================================================
# Renders runtime configuration, then starts nginx.
#
# The API base URL cannot be baked into the bundle at build time: doing so would
# mean one image per environment, which defeats the point of promoting a tested
# artifact from dev to prod. Instead the browser reads window.__APP_CONFIG__,
# which this script writes from environment variables on every container start.
# =============================================================================
set -eu

CONFIG_FILE="/usr/share/nginx/html/runtime-config.js"

: "${API_BASE_URL:=}"
: "${APP_ENV:=prod}"

# Escaped so a value containing a quote or backslash cannot break out of the
# JavaScript string literal and inject code into every page load.
escape_js() {
    printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

cat > "${CONFIG_FILE}" <<EOF
// Generated at container start by docker-entrypoint.sh. Do not edit.
window.__APP_CONFIG__ = {
  apiBaseUrl: "$(escape_js "${API_BASE_URL}")",
  appEnv: "$(escape_js "${APP_ENV}")"
};
EOF

echo "runtime-config.js rendered: apiBaseUrl='${API_BASE_URL}' appEnv='${APP_ENV}'"

# exec so nginx replaces this shell as PID 1 and receives SIGTERM directly,
# which is what makes `nginx -g 'daemon off;'` shut down gracefully.
exec "$@"
