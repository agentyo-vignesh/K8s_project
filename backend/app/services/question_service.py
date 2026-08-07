"""Question generation and retrieval.

Generation is recorded whether it succeeds or fails. The failed row is what turns "the AI was flaky
last Tuesday" into a query, and it is written in its own transaction so a provider outage does not
leave the request with nothing but a log line.
"""

from __future__ import annotations

import logging
import time
import uuid

from sqlalchemy import select
from sqlalchemy.exc import SQLAlchemyError
from sqlalchemy.orm import Session

from app.core.errors import AiProviderError, DatabaseError, NotFoundError
from app.core.logging_config import request_id_var
from app.core.metrics import (
    DATABASE_ERRORS_TOTAL,
    GENERATION_DURATION,
    QUESTIONS_GENERATED_TOTAL,
    TOKENS_CONSUMED_TOTAL,
)
from app.db.models import AiGeneratedQuestion, AiQuestionSet
from app.providers.base import GenerationOutcome, QuestionGenerator
from app.schemas.questions import (
    ExperienceLevel,
    GeneratedQuestion,
    QuestionGenerationRequest,
    QuestionSetResponse,
    TokenUsage,
)

logger = logging.getLogger(__name__)

_STATUS_SUCCEEDED = "SUCCEEDED"
_STATUS_FAILED = "FAILED"


class QuestionService:
    """Generates, persists and reads question sets."""

    def __init__(self, session: Session, generator: QuestionGenerator) -> None:
        self._session = session
        self._generator = generator

    def generate(self, request: QuestionGenerationRequest) -> QuestionSetResponse:
        """Generates a set, stores it, and returns it.

        On provider failure a `FAILED` row is committed before the error propagates, so the audit
        trail records the attempt and its reason.
        """
        request_id = self._request_id()
        provider = self._generator.provider_id
        started = time.perf_counter()

        try:
            with GENERATION_DURATION.labels(provider=provider).time():
                outcome = self._generator.generate(request)
        except AiProviderError as exc:
            QUESTIONS_GENERATED_TOTAL.labels(provider=provider, outcome="failure").inc()
            self._record_failure(request, request_id, provider, exc, started)
            raise

        latency_ms = self._elapsed_ms(started)
        question_set = self._persist(request, request_id, provider, outcome, latency_ms)

        QUESTIONS_GENERATED_TOTAL.labels(provider=provider, outcome="success").inc()
        if outcome.model:
            TOKENS_CONSUMED_TOTAL.labels(model=outcome.model, kind="prompt").inc(
                outcome.prompt_tokens
            )
            TOKENS_CONSUMED_TOTAL.labels(model=outcome.model, kind="completion").inc(
                outcome.completion_tokens
            )

        logger.info(
            "Generated %d question(s) via %s in %dms",
            len(outcome.questions),
            provider,
            latency_ms,
            extra={
                "interviewId": str(request.interview_id) if request.interview_id else None,
                "questionSetId": str(question_set.id),
                "provider": provider,
                "model": outcome.model,
                "latencyMs": latency_ms,
            },
        )
        return self._to_response(question_set)

    def find_by_id(self, set_id: uuid.UUID) -> QuestionSetResponse:
        question_set = self._session.get(AiQuestionSet, set_id)
        if question_set is None or question_set.status != _STATUS_SUCCEEDED:
            # A FAILED set has no questions, so exposing it here would return an empty set that
            # looks like a successful generation.
            raise NotFoundError(f"Question set not found: {set_id}")
        return self._to_response(question_set)

    def find_latest_for_interview(self, interview_id: uuid.UUID) -> QuestionSetResponse:
        """The most recent successful set for an interview.

        Regeneration is normal, so "the questions for this interview" means the newest set rather than
        an error about there being several.
        """
        statement = (
            select(AiQuestionSet)
            .where(
                AiQuestionSet.interview_id == interview_id,
                AiQuestionSet.status == _STATUS_SUCCEEDED,
            )
            .order_by(AiQuestionSet.created_at.desc())
            .limit(1)
        )
        question_set = self._session.execute(statement).scalars().first()
        if question_set is None:
            raise NotFoundError(f"No question set has been generated for interview {interview_id}")
        return self._to_response(question_set)

    # -------------------------------------------------------------------------------- internals

    def _persist(
        self,
        request: QuestionGenerationRequest,
        request_id: str,
        provider: str,
        outcome: GenerationOutcome,
        latency_ms: int,
    ) -> AiQuestionSet:
        question_set = AiQuestionSet(
            interview_id=request.interview_id,
            request_id=request_id,
            role_title=request.role_title,
            experience_level=str(request.experience_level),
            skills=",".join(request.skills)[:500],
            question_count=len(outcome.questions),
            provider=provider,
            model=outcome.model,
            status=_STATUS_SUCCEEDED,
            prompt_tokens=outcome.prompt_tokens,
            completion_tokens=outcome.completion_tokens,
            latency_ms=latency_ms,
        )
        question_set.questions = [
            AiGeneratedQuestion(
                sequence_no=question.sequence_no,
                question_text=question.question_text,
                category=question.category[:60],
                difficulty=str(question.difficulty),
                expected_answer=question.expected_answer,
                evaluation_hint=question.evaluation_hint,
            )
            for question in outcome.questions
        ]

        try:
            self._session.add(question_set)
            # Flush rather than commit: the request-scoped session commits on success, so a later
            # failure in the same request still rolls the whole thing back.
            self._session.flush()
        except SQLAlchemyError as exc:
            DATABASE_ERRORS_TOTAL.labels(operation="insert_question_set").inc()
            logger.exception("Failed to persist question set")
            raise DatabaseError("Could not store the generated question set") from exc
        return question_set

    def _record_failure(
        self,
        request: QuestionGenerationRequest,
        request_id: str,
        provider: str,
        error: Exception,
        started: float,
    ) -> None:
        """Commits a FAILED row in its own transaction.

        The caller's transaction is about to be rolled back by the exception, so this row has to be
        committed independently or the audit trail would be lost along with it.
        """
        try:
            self._session.rollback()
            self._session.add(
                AiQuestionSet(
                    interview_id=request.interview_id,
                    request_id=request_id,
                    role_title=request.role_title,
                    experience_level=str(request.experience_level),
                    skills=",".join(request.skills)[:500],
                    question_count=0,
                    provider=provider,
                    model=None,
                    status=_STATUS_FAILED,
                    latency_ms=self._elapsed_ms(started),
                    error_message=str(error)[:2000],
                )
            )
            self._session.commit()
        except SQLAlchemyError:
            # Never let audit bookkeeping replace the real error the caller needs to see.
            DATABASE_ERRORS_TOTAL.labels(operation="insert_failed_question_set").inc()
            logger.exception("Could not record the failed generation attempt")
            self._session.rollback()

    def _to_response(self, question_set: AiQuestionSet) -> QuestionSetResponse:
        return QuestionSetResponse(
            set_id=question_set.id,
            interview_id=question_set.interview_id,
            request_id=question_set.request_id,
            role_title=question_set.role_title,
            experience_level=ExperienceLevel(question_set.experience_level),
            skills=[skill for skill in question_set.skills.split(",") if skill],
            provider=question_set.provider,
            model=question_set.model,
            latency_ms=question_set.latency_ms or 0,
            usage=TokenUsage(
                prompt_tokens=question_set.prompt_tokens or 0,
                completion_tokens=question_set.completion_tokens or 0,
            ),
            questions=[
                GeneratedQuestion.model_validate(question) for question in question_set.questions
            ],
            created_at=question_set.created_at,
        )

    @staticmethod
    def _elapsed_ms(started: float) -> int:
        return int((time.perf_counter() - started) * 1000)

    @staticmethod
    def _request_id() -> str:
        """Uses the inbound correlation id so a set is traceable to the middleware request."""
        return (request_id_var.get() or str(uuid.uuid4()))[:64]
