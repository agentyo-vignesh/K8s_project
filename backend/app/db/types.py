"""Portable column types.

PostgreSQL is the only production target, but the test suite runs against in-memory SQLite so it needs
no container. These decorators let one set of models serve both: native `uuid`/`jsonb` on PostgreSQL,
and a string/JSON fallback elsewhere.
"""

from __future__ import annotations

import uuid
from typing import Any

from sqlalchemy import CHAR, JSON, TypeDecorator
from sqlalchemy.dialects.postgresql import JSONB
from sqlalchemy.dialects.postgresql import UUID as PostgresUUID
from sqlalchemy.engine import Dialect
from sqlalchemy.types import TypeEngine


class Guid(TypeDecorator[uuid.UUID]):
    """UUID column: native `uuid` on PostgreSQL, 36-character CHAR elsewhere.

    Values are always `uuid.UUID` in Python, so application code never has to care which backend it
    is talking to.
    """

    impl = CHAR
    cache_ok = True

    def load_dialect_impl(self, dialect: Dialect) -> TypeEngine[Any]:
        if dialect.name == "postgresql":
            return dialect.type_descriptor(PostgresUUID(as_uuid=True))
        return dialect.type_descriptor(CHAR(36))

    def process_bind_param(self, value: Any, dialect: Dialect) -> Any:
        if value is None:
            return None
        parsed = value if isinstance(value, uuid.UUID) else uuid.UUID(str(value))
        if dialect.name == "postgresql":
            return parsed
        return str(parsed)

    def process_result_value(self, value: Any, dialect: Dialect) -> uuid.UUID | None:
        if value is None:
            return None
        return value if isinstance(value, uuid.UUID) else uuid.UUID(str(value))


# JSONB on PostgreSQL (indexable, no re-parse on read), plain JSON on SQLite.
JsonPayload = JSON().with_variant(JSONB(), "postgresql")
