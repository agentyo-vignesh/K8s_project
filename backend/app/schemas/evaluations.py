"""Answer evaluation contract."""

from __future__ import annotations

import uuid
from datetime import datetime
from decimal import Decimal
from enum import StrEnum

from pydantic import Field, field_validator

from app.schemas.questions import CamelModel


class Recommendation(StrEnum):
    """Mirrors the middleware enum and `ck_ai_evaluations_recommendation`."""

    STRONG_HIRE = "STRONG_HIRE"
    HIRE = "HIRE"
    HOLD = "HOLD"
    NO_HIRE = "NO_HIRE"


class SubmittedAnswer(CamelModel):
    """One candidate answer, identified by its position in the question set."""

    sequence_no: int = Field(alias="sequenceNo", ge=1)
    question_text: str = Field(alias="questionText", min_length=1, max_length=4000)
    answer_text: str = Field(alias="answerText", max_length=8000)

    @field_validator("answer_text")
    @classmethod
    def _normalise_answer(cls, value: str) -> str:
        # An empty answer is meaningful (the candidate skipped it) and scores zero, so it is
        # normalised rather than rejected.
        return value.strip()


class EvaluationRequest(CamelModel):
    """What the middleware sends to score a set of answers."""

    interview_id: uuid.UUID | None = Field(default=None, alias="interviewId")
    question_set_id: uuid.UUID | None = Field(
        default=None,
        alias="questionSetId",
        description="Links the evaluation to the generated set it scores",
    )
    role_title: str = Field(alias="roleTitle", min_length=2, max_length=150)
    answers: list[SubmittedAnswer] = Field(min_length=1, max_length=50)

    @field_validator("answers")
    @classmethod
    def _reject_duplicate_sequences(cls, value: list[SubmittedAnswer]) -> list[SubmittedAnswer]:
        """Two answers for one question would make the per-question scores ambiguous."""
        sequences = [answer.sequence_no for answer in value]
        if len(sequences) != len(set(sequences)):
            raise ValueError("answers must have distinct sequenceNo values")
        return value


class QuestionScore(CamelModel):
    """The score for a single answer."""

    sequence_no: int = Field(alias="sequenceNo", ge=1)
    score: Decimal = Field(ge=0, le=10, description="0 to 10")
    comment: str


class EvaluationResponse(CamelModel):
    """A persisted evaluation."""

    evaluation_id: uuid.UUID = Field(alias="evaluationId")
    interview_id: uuid.UUID | None = Field(default=None, alias="interviewId")
    question_set_id: uuid.UUID | None = Field(default=None, alias="questionSetId")
    request_id: str = Field(alias="requestId")
    overall_score: Decimal = Field(alias="overallScore", ge=0, le=10)
    recommendation: Recommendation
    summary: str
    per_question: list[QuestionScore] = Field(alias="perQuestion")
    provider: str
    model: str | None = None
    latency_ms: int = Field(alias="latencyMs", ge=0)
    created_at: datetime = Field(alias="createdAt")
