"""Application entrypoint.

Startup resolves configuration and secrets and opens the connection pool. Anything wrong there raises
before the server binds, so a bad ConfigMap or a broken IRSA role is a pod that never passes its
startup probe rather than a service that accepts traffic and fails every request.

Shutdown disposes the pool. uvicorn receives SIGTERM directly (the Dockerfile uses exec form), stops
accepting, drains in-flight requests, then runs the lifespan teardown, which is what makes a rollout
free of dropped connections.
"""

from __future__ import annotations

import logging
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager

from fastapi import FastAPI
from fastapi.exceptions import RequestValidationError
from starlette.exceptions import HTTPException as StarletteHTTPException

from app import __version__
from app.api.middleware import RequestContextMiddleware
from app.api.routers import evaluations, health, info, questions
from app.core.config import get_settings
from app.core.errors import (
    ServiceError,
    http_exception_handler,
    service_error_handler,
    unhandled_exception_handler,
    validation_error_handler,
)
from app.core.logging_config import configure_logging
from app.core.secrets import get_secret_provider
from app.db.session import dispose_engine, init_engine
from app.providers.factory import get_answer_evaluator, get_question_generator

logger = logging.getLogger(__name__)


@asynccontextmanager
async def lifespan(app: FastAPI) -> AsyncIterator[None]:
    """Startup and shutdown."""
    settings = get_settings()
    configure_logging(settings, __version__)

    logger.info(
        "Starting %s %s (env=%s, secrets=%s, ai=%s)",
        settings.service_name,
        __version__,
        settings.app_env,
        settings.secrets_provider,
        settings.ai_provider,
    )

    # Resolve secrets before anything else: a failure here should stop the pod, and the message
    # names the misconfiguration.
    get_secret_provider()

    init_engine()

    if settings.create_schema_on_startup:
        # Only for the test suite's in-memory database. Against PostgreSQL, Flyway in the middleware
        # owns the schema; two services issuing DDL is how migration history gets corrupted.
        from app.db.models import Base  # noqa: PLC0415
        from app.db.session import get_engine  # noqa: PLC0415

        logger.warning("CREATE_SCHEMA_ON_STARTUP is enabled; creating tables from ORM metadata")
        Base.metadata.create_all(bind=get_engine())

    # Build the providers now so a missing OPENAI_API_KEY fails at startup rather than on the first
    # generation request.
    get_question_generator()
    get_answer_evaluator()

    logger.info("Startup complete; listening on port %s", settings.server_port)
    try:
        yield
    finally:
        logger.info("Shutting down; disposing the database engine")
        dispose_engine()


def create_app() -> FastAPI:
    """Builds the ASGI application. A factory so tests can construct an isolated instance."""
    settings = get_settings()

    application = FastAPI(
        title="AI Interview Platform - AI Service",
        version=__version__,
        description=(
            "Generates interview questions and scores candidate answers.\n\n"
            "Called only by the middleware, over a ClusterIP Service, authenticated with the "
            "`X-Internal-Api-Key` header. It is never exposed through the Ingress.\n\n"
            "`AI_PROVIDER=mock` (the default) produces deterministic questions with no network "
            "calls, so the whole platform runs locally without an API key."
        ),
        lifespan=lifespan,
        # Interactive docs are for developers; production serves the schema but not the UI.
        docs_url="/docs" if settings.docs_enabled else None,
        redoc_url="/redoc" if settings.docs_enabled else None,
        openapi_url="/openapi.json",
    )

    application.add_middleware(RequestContextMiddleware)

    # Registered most-specific first. ServiceError carries its own status and code; the bare
    # Exception handler is the backstop that guarantees a JSON body for anything unforeseen.
    application.add_exception_handler(ServiceError, service_error_handler)
    application.add_exception_handler(RequestValidationError, validation_error_handler)
    application.add_exception_handler(StarletteHTTPException, http_exception_handler)
    application.add_exception_handler(Exception, unhandled_exception_handler)

    # Probes and metrics live at the root: a kubelet probe should not have to know the API version,
    # and moving /metrics would mean re-pointing every ServiceMonitor.
    application.include_router(health.router)
    application.include_router(info.router, prefix=settings.api_prefix)
    application.include_router(questions.router, prefix=settings.api_prefix)
    application.include_router(evaluations.router, prefix=settings.api_prefix)

    return application


app = create_app()
