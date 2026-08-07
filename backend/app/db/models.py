"""ORM models for the tables this service owns.

Flyway (in the middleware) owns the DDL for the whole database, including these tables; see
`middleware/src/main/resources/db/migration/V2__create_ai_schema.sql`. One migration authority means
two services cannot race to define the same schema.

The constraints declared here are therefore documentation plus something the test suite can enforce:
`create_all()` against in-memory SQLite builds a schema with the same checks, so a test that violates
a production constraint fails locally instead of in staging. `tests/test_schema_parity.py` compares
these column names against the migration and fails if they drift.

`interview_id` intentionally carries no SQLAlchemy `ForeignKey`: the `interviews` table belongs to the
middleware's model, and mirroring it here would mean maintaining a second definition of it. The real
foreign key with `ON DELETE CASCADE` is created by V2 and enforced by PostgreSQL.
"""

from __future__ import annotations

import uuid
from datetime import UTC, datetime
from decimal import Decimal

from sqlalchemy import (
    CheckConstraint,
    DateTime,
    ForeignKey,
    Index,
    Integer,
    Numeric,
    String,
    Text,
    UniqueConstraint,
    func,
)
from sqlalchemy.orm import DeclarativeBase, Mapped, mapped_column, relationship

from app.db.types import Guid, JsonPayload


class Base(DeclarativeBase):
    """Declarative base for this service's models."""


def _new_id() -> uuid.UUID:
    return uuid.uuid4()


def _utc_now() -> datetime:
    return datetime.now(tz=UTC)


class AiQuestionSet(Base):
    """One generation request, recorded whether it succeeded or failed.

    Failures are stored deliberately: the error rate and token spend of the AI dependency are then
    answerable from SQL rather than only from logs that may have rotated away.
    """

    __tablename__ = "ai_question_sets"

    id: Mapped[uuid.UUID] = mapped_column(Guid, primary_key=True, default=_new_id)
    interview_id: Mapped[uuid.UUID | None] = mapped_column(Guid, nullable=True)
    request_id: Mapped[str] = mapped_column(String(64), nullable=False)
    role_title: Mapped[str] = mapped_column(String(150), nullable=False)
    experience_level: Mapped[str] = mapped_column(String(20), nullable=False)
    skills: Mapped[str] = mapped_column(String(500), nullable=False)
    question_count: Mapped[int] = mapped_column(Integer, nullable=False)
    provider: Mapped[str] = mapped_column(String(30), nullable=False)
    model: Mapped[str | None] = mapped_column(String(80), nullable=True)
    status: Mapped[str] = mapped_column(String(20), nullable=False)
    prompt_tokens: Mapped[int | None] = mapped_column(Integer, nullable=True)
    completion_tokens: Mapped[int | None] = mapped_column(Integer, nullable=True)
    latency_ms: Mapped[int | None] = mapped_column(Integer, nullable=True)
    error_message: Mapped[str | None] = mapped_column(Text, nullable=True)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, server_default=func.now(), default=_utc_now
    )

    # selectin loading: one extra query for the whole batch rather than one per set, and no join
    # duplication of the parent row.
    questions: Mapped[list[AiGeneratedQuestion]] = relationship(
        back_populates="question_set",
        cascade="all, delete-orphan",
        order_by="AiGeneratedQuestion.sequence_no",
        lazy="selectin",
    )

    __table_args__ = (
        CheckConstraint("status IN ('SUCCEEDED', 'FAILED')", name="ck_ai_question_sets_status"),
        CheckConstraint("provider IN ('mock', 'openai')", name="ck_ai_question_sets_provider"),
        CheckConstraint(
            "question_count >= 0 AND question_count <= 50", name="ck_ai_question_sets_count"
        ),
        CheckConstraint(
            "experience_level IN ('JUNIOR', 'MID', 'SENIOR', 'LEAD')",
            name="ck_ai_question_sets_level",
        ),
        Index("idx_ai_question_sets_interview_id", "interview_id"),
        Index("idx_ai_question_sets_created_at", "created_at"),
        Index("idx_ai_question_sets_status", "status"),
        # Not unique: a retried generation reuses the inbound correlation id, so one request_id can
        # cover a FAILED attempt followed by a SUCCEEDED one.
        Index("idx_ai_question_sets_request_id", "request_id"),
    )


class AiGeneratedQuestion(Base):
    """A single generated question belonging to a set."""

    __tablename__ = "ai_generated_questions"

    id: Mapped[uuid.UUID] = mapped_column(Guid, primary_key=True, default=_new_id)
    question_set_id: Mapped[uuid.UUID] = mapped_column(
        Guid, ForeignKey("ai_question_sets.id", ondelete="CASCADE"), nullable=False
    )
    sequence_no: Mapped[int] = mapped_column(Integer, nullable=False)
    question_text: Mapped[str] = mapped_column(Text, nullable=False)
    category: Mapped[str] = mapped_column(String(60), nullable=False)
    difficulty: Mapped[str] = mapped_column(String(20), nullable=False)
    expected_answer: Mapped[str | None] = mapped_column(Text, nullable=True)
    evaluation_hint: Mapped[str | None] = mapped_column(Text, nullable=True)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, server_default=func.now(), default=_utc_now
    )

    question_set: Mapped[AiQuestionSet] = relationship(back_populates="questions")

    __table_args__ = (
        UniqueConstraint(
            "question_set_id", "sequence_no", name="uq_ai_generated_questions_sequence"
        ),
        CheckConstraint(
            "difficulty IN ('EASY', 'MEDIUM', 'HARD')", name="ck_ai_generated_questions_difficulty"
        ),
        CheckConstraint("sequence_no > 0", name="ck_ai_generated_questions_sequence"),
        Index("idx_ai_generated_questions_set_id", "question_set_id"),
    )


class AiEvaluation(Base):
    """AI-assisted scoring of a candidate's answers.

    `answers` and `per_question` are JSONB because their shape follows the question set, which varies
    per interview; normalising them would create a table whose rows are only ever read together with
    their parent.
    """

    __tablename__ = "ai_evaluations"

    id: Mapped[uuid.UUID] = mapped_column(Guid, primary_key=True, default=_new_id)
    interview_id: Mapped[uuid.UUID | None] = mapped_column(Guid, nullable=True)
    question_set_id: Mapped[uuid.UUID | None] = mapped_column(
        Guid, ForeignKey("ai_question_sets.id", ondelete="SET NULL"), nullable=True
    )
    request_id: Mapped[str] = mapped_column(String(64), nullable=False)
    answers: Mapped[list[dict[str, object]]] = mapped_column(JsonPayload, nullable=False)
    per_question: Mapped[list[dict[str, object]]] = mapped_column(JsonPayload, nullable=False)
    overall_score: Mapped[Decimal] = mapped_column(Numeric(4, 1), nullable=False)
    recommendation: Mapped[str] = mapped_column(String(20), nullable=False)
    summary: Mapped[str] = mapped_column(Text, nullable=False)
    provider: Mapped[str] = mapped_column(String(30), nullable=False)
    model: Mapped[str | None] = mapped_column(String(80), nullable=True)
    latency_ms: Mapped[int | None] = mapped_column(Integer, nullable=True)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, server_default=func.now(), default=_utc_now
    )

    __table_args__ = (
        CheckConstraint("overall_score BETWEEN 0 AND 10", name="ck_ai_evaluations_overall"),
        CheckConstraint(
            "recommendation IN ('STRONG_HIRE', 'HIRE', 'HOLD', 'NO_HIRE')",
            name="ck_ai_evaluations_recommendation",
        ),
        Index("idx_ai_evaluations_interview_id", "interview_id"),
        Index("idx_ai_evaluations_created_at", "created_at"),
    )
