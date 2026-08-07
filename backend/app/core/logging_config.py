"""Structured logging with request correlation.

The request id lives in a `ContextVar`, which is the only mechanism that survives `await` boundaries
correctly: a module-level global would be shared across concurrently handled requests, and
`threading.local` does not follow asyncio tasks.
"""

from __future__ import annotations

import json
import logging
import sys
from contextvars import ContextVar
from datetime import UTC, datetime
from typing import Any

from app.core.config import Settings

request_id_var: ContextVar[str | None] = ContextVar("request_id", default=None)

# Attributes LogRecord always carries; anything else was added by the caller and is worth emitting.
_RESERVED_LOG_ATTRS = frozenset(
    {
        "args",
        "asctime",
        "created",
        "exc_info",
        "exc_text",
        "filename",
        "funcName",
        "levelname",
        "levelno",
        "lineno",
        "module",
        "msecs",
        "message",
        "msg",
        "name",
        "pathname",
        "process",
        "processName",
        "relativeCreated",
        "stack_info",
        "taskName",
        "thread",
        "threadName",
    }
)


class JsonLogFormatter(logging.Formatter):
    """One JSON object per line, ready for Promtail/Loki or the CloudWatch agent."""

    def __init__(self, service_name: str, environment: str, version: str) -> None:
        super().__init__()
        self._service_name = service_name
        self._environment = environment
        self._version = version

    def format(self, record: logging.LogRecord) -> str:
        payload: dict[str, Any] = {
            "timestamp": datetime.fromtimestamp(record.created, tz=UTC).isoformat(),
            "level": record.levelname,
            "logger": record.name,
            "message": record.getMessage(),
            "service": self._service_name,
            "component": "ai-service",
            "environment": self._environment,
            "version": self._version,
        }

        request_id = request_id_var.get()
        if request_id:
            payload["requestId"] = request_id

        if record.exc_info:
            payload["exception"] = self.formatException(record.exc_info)
        if record.stack_info:
            payload["stack"] = self.formatStack(record.stack_info)

        # Promote `logger.info("...", extra={"interviewId": ...})` to top-level fields so they are
        # directly queryable rather than buried in the message string.
        for key, value in record.__dict__.items():
            if key not in _RESERVED_LOG_ATTRS and not key.startswith("_"):
                payload[key] = value

        return json.dumps(payload, default=str, separators=(",", ":"))


class PlainLogFormatter(logging.Formatter):
    """Readable single-line output for local development, with the request id inline."""

    def __init__(self) -> None:
        super().__init__(
            fmt="%(asctime)s %(levelname)-8s %(name)s rid=%(request_id)s - %(message)s",
            datefmt="%H:%M:%S",
        )

    def format(self, record: logging.LogRecord) -> str:
        record.request_id = request_id_var.get() or "none"
        return super().format(record)


def configure_logging(settings: Settings, version: str) -> None:
    """Installs a single stdout handler and silences duplicate access logs.

    Called once during application startup. Existing handlers are replaced rather than appended to,
    which is what stops uvicorn's own configuration from producing every line twice.
    """
    formatter: logging.Formatter
    if settings.json_logging:
        formatter = JsonLogFormatter(
            service_name=settings.service_name,
            environment=str(settings.app_env),
            version=version,
        )
    else:
        formatter = PlainLogFormatter()

    handler = logging.StreamHandler(stream=sys.stdout)
    handler.setFormatter(formatter)

    root = logging.getLogger()
    root.handlers = [handler]
    root.setLevel(settings.log_level)

    for name in ("uvicorn", "uvicorn.error", "uvicorn.access", "fastapi"):
        uvicorn_logger = logging.getLogger(name)
        uvicorn_logger.handlers = []
        uvicorn_logger.propagate = True

    # uvicorn.access duplicates what RequestContextMiddleware already logs, with none of the
    # correlation context, so it is turned off rather than reformatted.
    logging.getLogger("uvicorn.access").disabled = True

    # SQLAlchemy echoes every statement at INFO, which is far too noisy outside debugging.
    logging.getLogger("sqlalchemy.engine").setLevel(logging.WARNING)
    # botocore logs credential-chain resolution at DEBUG; useful when diagnosing IRSA, noise
    # otherwise, so it follows the app level only when that level is DEBUG.
    logging.getLogger("botocore").setLevel(
        logging.DEBUG if settings.log_level == "DEBUG" else logging.WARNING
    )
