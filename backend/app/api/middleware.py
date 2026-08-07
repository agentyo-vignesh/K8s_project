"""Request-scoped correlation, access logging and metrics."""

from __future__ import annotations

import logging
import re
import time
import uuid
from collections.abc import Awaitable, Callable

from starlette.middleware.base import BaseHTTPMiddleware
from starlette.requests import Request
from starlette.responses import Response
from starlette.types import ASGIApp

from app.core.logging_config import request_id_var
from app.core.metrics import (
    HTTP_REQUEST_DURATION,
    HTTP_REQUESTS_IN_PROGRESS,
    HTTP_REQUESTS_TOTAL,
    status_class,
)

logger = logging.getLogger(__name__)

REQUEST_ID_HEADER = "X-Request-Id"
_MAX_REQUEST_ID_LENGTH = 64
# The id reaches both the logs and a response header, so it is sanitised as untrusted input;
# stripping everything else prevents header and log injection.
_REQUEST_ID_PATTERN = re.compile(r"[^A-Za-z0-9._:-]")

# Probe and scrape traffic arrives every few seconds and would drown out real requests.
_QUIET_PATHS = frozenset(
    {"/health", "/health/liveness", "/health/readiness", "/health/startup", "/metrics"}
)


class RequestContextMiddleware(BaseHTTPMiddleware):
    """Establishes the request id, logs the request, and records metrics.

    The id is taken from the inbound header when present so a trace started at the ingress or in the
    middleware spans both services, and is echoed back so a client can quote it.
    """

    def __init__(self, app: ASGIApp) -> None:
        super().__init__(app)

    async def dispatch(
        self, request: Request, call_next: Callable[[Request], Awaitable[Response]]
    ) -> Response:
        request_id = self._resolve_request_id(request)
        token = request_id_var.set(request_id)
        started = time.perf_counter()
        quiet = request.url.path in _QUIET_PATHS

        HTTP_REQUESTS_IN_PROGRESS.inc()
        try:
            response = await call_next(request)
            status_code = response.status_code
        except Exception:
            # The exception handler will produce the 500 body; this records the metric so a burst of
            # unhandled errors is visible even before anyone reads the logs.
            self._record(request, 500, started)
            logger.exception("Request failed: %s %s", request.method, request.url.path)
            raise
        finally:
            HTTP_REQUESTS_IN_PROGRESS.dec()
            request_id_var.reset(token)

        self._record(request, status_code, started)
        response.headers[REQUEST_ID_HEADER] = request_id

        if not quiet:
            duration_ms = (time.perf_counter() - started) * 1000
            logger.info(
                "%s %s -> %d in %.1fms",
                request.method,
                request.url.path,
                status_code,
                duration_ms,
                extra={
                    "httpMethod": request.method,
                    "httpPath": request.url.path,
                    "httpStatus": status_code,
                    "durationMs": round(duration_ms, 1),
                    # Set by the request-id resolution above; repeated as a field so a JSON log line
                    # is self-contained.
                    "requestId": request_id,
                },
            )
        return response

    def _record(self, request: Request, status_code: int, started: float) -> None:
        path = self._route_template(request)
        HTTP_REQUESTS_TOTAL.labels(
            method=request.method, path=path, status=status_class(status_code)
        ).inc()
        HTTP_REQUEST_DURATION.labels(method=request.method, path=path).observe(
            time.perf_counter() - started
        )

    @staticmethod
    def _route_template(request: Request) -> str:
        """The matched route template, never the concrete URL.

        Labelling by raw path would create a time series per interview id and eventually exhaust
        Prometheus. An unmatched path collapses to a single `unmatched` label for the same reason:
        a scanner probing random URLs must not be able to inflate cardinality.
        """
        route = request.scope.get("route")
        template = getattr(route, "path", None)
        if template:
            return str(template)
        return "unmatched"

    @staticmethod
    def _resolve_request_id(request: Request) -> str:
        inbound = request.headers.get(REQUEST_ID_HEADER)
        if not inbound:
            return str(uuid.uuid4())
        sanitised = _REQUEST_ID_PATTERN.sub("", inbound)[:_MAX_REQUEST_ID_LENGTH]
        return sanitised or str(uuid.uuid4())
