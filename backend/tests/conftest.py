"""Shared test fixtures.

Everything runs against in-memory SQLite with no container and no network, so `pytest` works on a
laptop and in CI identically. The portable column types in `app/db/types.py` are what make the
PostgreSQL models usable here.
"""

from __future__ import annotations

import os
from collections.abc import Generator

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import create_engine
from sqlalchemy.orm import Session, sessionmaker
from sqlalchemy.pool import StaticPool

TEST_API_KEY = "test-internal-api-key-value"


@pytest.fixture(autouse=True, scope="session")
def _test_environment() -> Generator[None, None, None]:
    """Sets configuration before anything imports `app.core.config`."""
    os.environ.update(
        {
            "APP_ENV": "test",
            "LOG_LEVEL": "WARNING",
            "SECRETS_PROVIDER": "env",
            "AI_PROVIDER": "mock",
            "INTERNAL_API_KEY": TEST_API_KEY,
            "CREATE_SCHEMA_ON_STARTUP": "false",
        }
    )
    yield


@pytest.fixture()
def session_factory() -> Generator[sessionmaker[Session], None, None]:
    """A fresh in-memory schema per test.

    `StaticPool` with a single shared connection is required: the default pool would give each
    checkout its own `:memory:` database, so a table created in one would be missing in the next.
    """
    from app.db.models import Base

    engine = create_engine(
        "sqlite://",
        connect_args={"check_same_thread": False},
        poolclass=StaticPool,
        future=True,
    )
    Base.metadata.create_all(bind=engine)
    factory = sessionmaker(bind=engine, autoflush=False, expire_on_commit=False)
    try:
        yield factory
    finally:
        Base.metadata.drop_all(bind=engine)
        engine.dispose()


@pytest.fixture()
def db_session(session_factory: sessionmaker[Session]) -> Generator[Session, None, None]:
    session = session_factory()
    try:
        yield session
    finally:
        session.rollback()
        session.close()


@pytest.fixture()
def client(session_factory: sessionmaker[Session]) -> Generator[TestClient, None, None]:
    """A `TestClient` whose session dependency is bound to the in-memory database.

    The dependency is overridden rather than the engine replaced, so the app's own startup path is
    still exercised without it trying to reach PostgreSQL.
    """
    from app.api.dependencies import session_dependency
    from app.db.session import set_engine
    from app.main import create_app

    # The readiness probe and the lifespan both call get_engine(); point them at SQLite too.
    set_engine(session_factory.kw["bind"])

    def override_session() -> Generator[Session, None, None]:
        session = session_factory()
        try:
            yield session
            session.commit()
        except Exception:
            session.rollback()
            raise
        finally:
            session.close()

    application = create_app()
    application.dependency_overrides[session_dependency] = override_session

    with TestClient(application) as test_client:
        test_client.headers.update({"X-Internal-Api-Key": TEST_API_KEY})
        yield test_client

    application.dependency_overrides.clear()


@pytest.fixture()
def unauthenticated_client(client: TestClient) -> TestClient:
    """The same app with the internal API key stripped, for authorization tests."""
    client.headers.pop("X-Internal-Api-Key", None)
    return client
