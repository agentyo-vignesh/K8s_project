"""Guards against drift between the ORM models and the Flyway migration.

Flyway owns the DDL, so these models are a second description of the same tables. Without a check,
adding a column to one and not the other produces a runtime failure in whichever environment happens
to exercise that column first. This parses the migration rather than connecting to a database, so it
runs offline in CI.
"""

from __future__ import annotations

import re
from pathlib import Path

import pytest
from app.db.models import AiEvaluation, AiGeneratedQuestion, AiQuestionSet, Base

MIGRATION = (
    Path(__file__).resolve().parents[2]
    / "middleware"
    / "src"
    / "main"
    / "resources"
    / "db"
    / "migration"
    / "V2__create_ai_schema.sql"
)

# Words that begin a table-level constraint clause rather than a column definition.
_CONSTRAINT_KEYWORDS = frozenset(
    {"constraint", "primary", "unique", "check", "foreign", "references", "exclude", "like"}
)


def _strip_comments(sql: str) -> str:
    """Removes `--` comments so their punctuation cannot confuse the splitter."""
    return "\n".join(re.sub(r"--.*$", "", line) for line in sql.splitlines())


def _split_top_level(body: str) -> list[str]:
    """Splits a CREATE TABLE body on commas that are not inside parentheses.

    Splitting on newlines instead would break a multi-line clause into fragments, and the
    continuation of a CHECK list such as `('STRONG_HIRE', 'HIRE', ...)` would then look like a column
    definition.
    """
    fragments: list[str] = []
    depth = 0
    current: list[str] = []
    for character in body:
        if character == "(":
            depth += 1
        elif character == ")":
            depth -= 1
        if character == "," and depth == 0:
            fragments.append("".join(current))
            current = []
        else:
            current.append(character)
    if current:
        fragments.append("".join(current))
    return fragments


def _columns_in_migration(table_name: str) -> set[str]:
    """Extracts the column names from a CREATE TABLE block."""
    sql = _strip_comments(MIGRATION.read_text(encoding="utf-8"))
    match = re.search(
        rf"CREATE\s+TABLE\s+{table_name}\s*\((.*?)\n\s*\);",
        sql,
        flags=re.IGNORECASE | re.DOTALL,
    )
    if match is None:
        pytest.fail(f"No CREATE TABLE block for {table_name!r} in {MIGRATION.name}")

    columns: set[str] = set()
    for fragment in _split_top_level(match.group(1)):
        tokens = fragment.split()
        if not tokens:
            continue
        first_token = tokens[0].lower()
        if first_token in _CONSTRAINT_KEYWORDS:
            continue
        columns.add(first_token)
    return columns


class TestSchemaParity:
    def test_migration_file_exists(self) -> None:
        assert MIGRATION.is_file(), f"Expected the migration at {MIGRATION}"

    @pytest.mark.parametrize(
        "model",
        [AiQuestionSet, AiGeneratedQuestion, AiEvaluation],
        ids=lambda model: model.__tablename__,
    )
    def test_model_columns_match_the_migration(self, model: type[Base]) -> None:
        model_columns = {column.name for column in model.__table__.columns}
        migration_columns = _columns_in_migration(model.__tablename__)

        missing_in_migration = model_columns - migration_columns
        missing_in_model = migration_columns - model_columns

        assert not missing_in_migration, (
            f"{model.__tablename__}: columns in the ORM model but not in V2: "
            f"{sorted(missing_in_migration)}"
        )
        assert not missing_in_model, (
            f"{model.__tablename__}: columns in V2 but not in the ORM model: "
            f"{sorted(missing_in_model)}"
        )

    def test_every_model_table_is_created_by_the_migration(self) -> None:
        sql = MIGRATION.read_text(encoding="utf-8").lower()
        for table_name in Base.metadata.tables:
            assert f"create table {table_name}" in sql, (
                f"{table_name} has an ORM model but no CREATE TABLE in {MIGRATION.name}"
            )
