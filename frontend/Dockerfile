# =============================================================================
# Frontend (React + Vite, served by nginx) - multi-stage production image
#
# Stage 1 installs dependencies from the lockfile and builds the static bundle.
# Stage 2 is nginx serving that bundle as an unprivileged user on port 3000.
#
# The final image contains no Node runtime, no node_modules and no source: only
# static assets and nginx.
# =============================================================================

# ---------- Stage 1: build ----------
FROM node:22.12.0-alpine AS build
WORKDIR /build

# `npm ci` against the lockfile only: reproducible, and it fails rather than
# silently resolving a new version. Copied separately so a source-only change
# reuses the cached dependency layer.
COPY package.json package-lock.json ./
RUN npm ci --no-audit --no-fund

COPY vite.config.js index.html ./
COPY src ./src
RUN npm run build

# ---------- Stage 2: runtime ----------
FROM nginx:1.31.2-alpine AS runtime

# Every directory nginx writes to must be owned by the unprivileged user, and
# the default config is removed so only ours is served.
RUN rm -f /etc/nginx/conf.d/default.conf /etc/nginx/nginx.conf \
    && mkdir -p /tmp/client_temp /tmp/proxy_temp /tmp/fastcgi_temp /tmp/uwsgi_temp /tmp/scgi_temp \
    && chown -R nginx:nginx /tmp/client_temp /tmp/proxy_temp /tmp/fastcgi_temp \
        /tmp/uwsgi_temp /tmp/scgi_temp /usr/share/nginx/html /var/cache/nginx

COPY nginx.conf /etc/nginx/nginx.conf
COPY --from=build --chown=nginx:nginx /build/dist /usr/share/nginx/html
COPY --chmod=0755 docker-entrypoint.sh /docker-entrypoint-aip.sh

# nginx:alpine ships the `nginx` user as uid 101.
USER 101:101

ENV API_BASE_URL="" \
    APP_ENV=prod

EXPOSE 3000

HEALTHCHECK --interval=15s --timeout=5s --start-period=10s --retries=5 \
    CMD wget --quiet --tries=1 --spider http://localhost:3000/healthz || exit 1

ENTRYPOINT ["/docker-entrypoint-aip.sh"]
CMD ["nginx", "-g", "daemon off;"]
