"""Engine and session lifecycle.

The engine is built lazily from `SecretProvider`, not from a URL in configuration. That is what lets
the same image run against a local container and against RDS-with-rotating-credentials, with the
switch being `SECRETS_PROVIDER` rather than a code change.
"""

from __future__ import annotations

import logging
from collections.abc import Generator

from sqlalchemy import Engine, create_engine, text
from sqlalchemy.orm import Session, sessionmaker

from app.core.config import Settings, get_settings
from app.core.errors import DatabaseError
from app.core.metrics import DATABASE_ERRORS_TOTAL
from app.core.secrets import SecretProvider, get_secret_provider

logger = logging.getLogger(__name__)

_engine: Engine | None = None
_session_factory: sessionmaker[Session] | None = None


def build_engine(settings: Settings, secret_provider: SecretProvider) -> Engine:
    """Creates the connection pool.

    `pool_pre_ping` costs one cheap round trip per checkout and in exchange turns "connection closed
    by the server" (an RDS failover, an idle timeout on a NAT gateway) into a transparent reconnect
    rather than a failed request.

    `statement_timeout` is set server-side per connection so a pathological query cannot hold a pool
    slot indefinitely; without it, a single slow statement can exhaust the pool and stall the service.
    """
    credentials = secret_provider.database_credentials()
    engine = create_engine(
        credentials.sqlalchemy_url(),
        pool_size=settings.db_pool_size,
        max_overflow=settings.db_max_overflow,
        pool_timeout=settings.db_pool_timeout_seconds,
        pool_recycle=settings.db_pool_recycle_seconds,
        pool_pre_ping=True,
        future=True,
        connect_args={
            "options": f"-c statement_timeout={settings.db_statement_timeout_ms}",
            "application_name": settings.service_name,
        },
    )
    logger.info(
        "Database engine ready via secret provider '%s': target=%s poolSize=%s",
        secret_provider.provider_id,
        credentials.describe(),
        settings.db_pool_size,
    )
    return engine


def init_engine() -> Engine:
    """Builds the engine and session factory once, at startup."""
    global _engine, _session_factory
    if _engine is None:
        settings = get_settings()
        _engine = build_engine(settings, get_secret_provider())
        _session_factory = sessionmaker(
            bind=_engine,
            autoflush=False,
            autocommit=False,
            expire_on_commit=False,
        )
    return _engine


def set_engine(engine: Engine) -> None:
    """Replaces the engine. Used by the test suite to substitute an in-memory database."""
    global _engine, _session_factory
    _engine = engine
    _session_factory = sessionmaker(
        bind=engine, autoflush=False, autocommit=False, expire_on_commit=False
    )


def dispose_engine() -> None:
    """Closes every pooled connection.

    Called during graceful shutdown so PostgreSQL does not accumulate abandoned backends every time a
    pod is replaced.
    """
    global _engine, _session_factory
    if _engine is not None:
        _engine.dispose()
        logger.info("Database engine disposed")
    _engine = None
    _session_factory = None


def get_engine() -> Engine:
    if _engine is None:
        return init_engine()
    return _engine


def get_session() -> Generator[Session, None, None]:
    """FastAPI dependency yielding a transactional session.

    Commit on success, rollback on any exception, always close. Endpoints therefore never have to
    remember to roll back, and a half-applied write cannot escape a failed request.
    """
    if _session_factory is None:
        init_engine()
    assert _session_factory is not None  # init_engine guarantees this

    session = _session_factory()
    try:
        yield session
        session.commit()
    except Exception:
        session.rollback()
        raise
    finally:
        session.close()


def check_database() -> None:
    """Readiness probe check.

    Raises `DatabaseError` so the probe fails while the process stays alive, letting Kubernetes remove
    the pod from the Service and put it back when the database recovers, without a restart loop.
    """
    try:
        with get_engine().connect() as connection:
            connection.execute(text("SELECT 1"))
    except Exception as exc:
        DATABASE_ERRORS_TOTAL.labels(operation="healthcheck").inc()
        logger.warning("Database readiness check failed: %s", exc)
        raise DatabaseError("Database is not reachable") from exc
