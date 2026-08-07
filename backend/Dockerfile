# =============================================================================
# AI service (Python 3.12 / FastAPI) - multi-stage production image
#
# Stage 1 builds wheels so the runtime image needs no compiler and no build
# headers. Stage 2 installs those wheels into a slim base and runs unprivileged.
# =============================================================================

# ---------- Stage 1: build wheels ----------
FROM python:3.12.13-slim AS build

ENV PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

# build-essential is needed by some sdists; it stays in this stage only.
RUN apt-get update \
    && apt-get install -y --no-install-recommends build-essential \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build
COPY requirements.txt ./
RUN pip wheel --wheel-dir /wheels -r requirements.txt

# ---------- Stage 2: runtime ----------
FROM python:3.12.13-slim AS runtime

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    APP_ENV=prod \
    SERVER_PORT=8000

# curl is required by the container and Kubernetes health probes.
RUN apt-get update \
    && apt-get install -y --no-install-recommends curl \
    && rm -rf /var/lib/apt/lists/* \
    && groupadd --gid 10001 appgroup \
    && useradd --uid 10001 --gid appgroup --no-create-home --shell /usr/sbin/nologin appuser

COPY --from=build /wheels /wheels
COPY requirements.txt ./
RUN pip install --no-index --find-links=/wheels -r requirements.txt \
    && rm -rf /wheels requirements.txt

WORKDIR /app
COPY --chown=appuser:appgroup app ./app

USER 10001:10001

EXPOSE 8000

HEALTHCHECK --interval=15s --timeout=5s --start-period=20s --retries=5 \
    CMD curl -fsS "http://localhost:${SERVER_PORT}/health/readiness" || exit 1

# Exec form so uvicorn is PID 1 and receives SIGTERM directly, which starts its
# graceful shutdown (stop accepting, drain in-flight, close the DB pool).
# Single worker per container: replicas are a Deployment concern, not a
# process-manager concern, and one process per container keeps metrics and logs
# attributable to one pod.
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000", "--workers", "1", "--no-server-header", "--timeout-graceful-shutdown", "25"]
