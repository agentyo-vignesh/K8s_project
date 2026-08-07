"""Health, readiness and metrics endpoints.

Unauthenticated by necessity: a kubelet probe and a Prometheus scrape cannot present a secret. They
expose no business data, and on Kubernetes the port is reachable only from inside the cluster.

The liveness/readiness split is the important part. Liveness answers "is this process wedged?" and
must not touch a dependency, or a database blip would restart every pod and turn a recoverable outage
into a crash loop. Readiness answers "can this pod serve traffic right now?" and does check the
database, so an affected pod is removed from the Service and returns on its own once the database is
back, with no restart.
"""

from __future__ import annotations

import logging

from fastapi import APIRouter, Response, status

from app import __version__
from app.core.config import get_settings
from app.core.errors import DatabaseError
from app.core.metrics import render_metrics
from app.db.session import check_database
from app.schemas.common import HealthResponse

logger = logging.getLogger(__name__)

router = APIRouter(tags=["Health"])


@router.get(
    "/health/liveness",
    response_model=HealthResponse,
    summary="Liveness probe",
    description="Process-only check. Never touches the database, so a database outage cannot "
    "trigger a restart loop.",
)
async def liveness() -> HealthResponse:
    settings = get_settings()
    return HealthResponse(status="UP", service=settings.service_name, version=__version__)


@router.get(
    "/health/readiness",
    response_model=HealthResponse,
    summary="Readiness probe",
    description="Checks the database. A failure returns 503 so Kubernetes removes this pod from the "
    "Service without restarting it.",
    responses={503: {"description": "A dependency is unavailable"}},
)
async def readiness(response: Response) -> HealthResponse:
    settings = get_settings()
    checks: dict[str, str] = {}
    healthy = True

    try:
        check_database()
        checks["database"] = "UP"
    except DatabaseError:
        checks["database"] = "DOWN"
        healthy = False

    if not healthy:
        response.status_code = status.HTTP_503_SERVICE_UNAVAILABLE

    return HealthResponse(
        status="UP" if healthy else "DOWN",
        service=settings.service_name,
        version=__version__,
        checks=checks,
    )


@router.get(
    "/health",
    response_model=HealthResponse,
    summary="Aggregate health",
    description="Alias of the readiness check, for humans and for uptime monitors.",
    responses={503: {"description": "A dependency is unavailable"}},
)
async def health(response: Response) -> HealthResponse:
    return await readiness(response)


@router.get(
    "/metrics",
    summary="Prometheus metrics",
    description="OpenMetrics exposition scraped by Prometheus (see the chart's ServiceMonitor).",
    response_class=Response,
    responses={200: {"content": {"text/plain": {}}, "description": "Metrics exposition"}},
)
async def metrics() -> Response:
    payload, content_type = render_metrics()
    return Response(content=payload, media_type=content_type)
