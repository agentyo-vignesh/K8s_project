"""Answer evaluation.

Scores a candidate's answers and stores the result. The middleware uses this to pre-fill an
interviewer's scorecard; the interviewer remains the one who submits the final result, which is why
this service writes to `ai_evaluations` and never to `interview_results`.
"""

from __future__ import annotations

import logging
import time
import uuid
from decimal import Decimal

from sqlalchemy import select
from sqlalchemy.exc import SQLAlchemyError
from sqlalchemy.orm import Session

from app.core.errors import DatabaseError, NotFoundError
from app.core.logging_config import request_id_var
from app.core.metrics import (
    DATABASE_ERRORS_TOTAL,
    EVALUATIONS_TOTAL,
    TOKENS_CONSUMED_TOTAL,
)
from app.db.models import AiEvaluation
from app.providers.base import AnswerEvaluator
from app.schemas.evaluations import (
    EvaluationRequest,
    EvaluationResponse,
    QuestionScore,
    Recommendation,
)

logger = logging.getLogger(__name__)


class EvaluationService:
    """Evaluates answers and persists the outcome."""

    def __init__(self, session: Session, evaluator: AnswerEvaluator) -> None:
        self._session = session
        self._evaluator = evaluator

    def evaluate(self, request: EvaluationRequest) -> EvaluationResponse:
        request_id = (request_id_var.get() or str(uuid.uuid4()))[:64]
        provider = self._evaluator.provider_id
        started = time.perf_counter()

        try:
            outcome = self._evaluator.evaluate(request)
        except Exception:
            EVALUATIONS_TOTAL.labels(provider=provider, outcome="failure").inc()
            raise

        latency_ms = int((time.perf_counter() - started) * 1000)

        evaluation = AiEvaluation(
            interview_id=request.interview_id,
            question_set_id=request.question_set_id,
            request_id=request_id,
            # Stored as submitted so a disputed score can be re-examined against the exact input.
            answers=[
                {
                    "sequenceNo": answer.sequence_no,
                    "questionText": answer.question_text,
                    "answerText": answer.answer_text,
                }
                for answer in request.answers
            ],
            per_question=[
                {
                    "sequenceNo": score.sequence_no,
                    "score": float(score.score),
                    "comment": score.comment,
                }
                for score in outcome.per_question
            ],
            overall_score=Decimal(str(outcome.overall_score)),
            recommendation=str(outcome.recommendation),
            summary=outcome.summary,
            provider=provider,
            model=outcome.model,
            latency_ms=latency_ms,
        )

        try:
            self._session.add(evaluation)
            self._session.flush()
        except SQLAlchemyError as exc:
            DATABASE_ERRORS_TOTAL.labels(operation="insert_evaluation").inc()
            logger.exception("Failed to persist evaluation")
            raise DatabaseError("Could not store the evaluation") from exc

        EVALUATIONS_TOTAL.labels(provider=provider, outcome="success").inc()
        if outcome.model:
            TOKENS_CONSUMED_TOTAL.labels(model=outcome.model, kind="prompt").inc(
                outcome.prompt_tokens
            )
            TOKENS_CONSUMED_TOTAL.labels(model=outcome.model, kind="completion").inc(
                outcome.completion_tokens
            )

        logger.info(
            "Evaluated %d answer(s) via %s: overall %.1f (%s)",
            len(request.answers),
            provider,
            outcome.overall_score,
            outcome.recommendation,
            extra={
                "interviewId": str(request.interview_id) if request.interview_id else None,
                "evaluationId": str(evaluation.id),
                "provider": provider,
                "latencyMs": latency_ms,
            },
        )
        return self._to_response(evaluation)

    def find_latest_for_interview(self, interview_id: uuid.UUID) -> EvaluationResponse:
        statement = (
            select(AiEvaluation)
            .where(AiEvaluation.interview_id == interview_id)
            .order_by(AiEvaluation.created_at.desc())
            .limit(1)
        )
        evaluation = self._session.execute(statement).scalars().first()
        if evaluation is None:
            raise NotFoundError(f"No evaluation has been recorded for interview {interview_id}")
        return self._to_response(evaluation)

    def _to_response(self, evaluation: AiEvaluation) -> EvaluationResponse:
        return EvaluationResponse(
            evaluation_id=evaluation.id,
            interview_id=evaluation.interview_id,
            question_set_id=evaluation.question_set_id,
            request_id=evaluation.request_id,
            overall_score=evaluation.overall_score,
            recommendation=Recommendation(evaluation.recommendation),
            summary=evaluation.summary,
            per_question=[self._score_from_row(entry) for entry in evaluation.per_question],
            provider=evaluation.provider,
            model=evaluation.model,
            latency_ms=evaluation.latency_ms or 0,
            created_at=evaluation.created_at,
        )

    @staticmethod
    def _score_from_row(entry: dict[str, object]) -> QuestionScore:
        """Rebuilds a `QuestionScore` from a stored JSONB entry.

        The values are typed `object` because JSONB is schemaless, so each one is narrowed rather
        than blindly coerced. This service wrote the row itself, so a shape mismatch means the data
        was corrupted or hand-edited: that is a `DatabaseError` (503) with a message naming the
        field, not an opaque 500 from `int(None)`.
        """
        raw_sequence = entry.get("sequenceNo")
        # bool is a subclass of int, so it would pass an isinstance(int) check while being nonsense
        # for a sequence number.
        if isinstance(raw_sequence, bool) or not isinstance(raw_sequence, int):
            raise DatabaseError(
                f"Stored evaluation has a non-integer 'sequenceNo' ({type(raw_sequence).__name__})"
            )

        raw_score = entry.get("score")
        if isinstance(raw_score, bool) or not isinstance(raw_score, int | float | str):
            raise DatabaseError(
                f"Stored evaluation has a non-numeric 'score' ({type(raw_score).__name__})"
            )
        try:
            # Via str() so a float such as 7.7 becomes Decimal("7.7") rather than the binary
            # approximation Decimal(7.7) would produce.
            score = Decimal(str(raw_score))
        except ArithmeticError as exc:
            raise DatabaseError(f"Stored evaluation has an unparseable 'score': {raw_score!r}") from exc

        raw_comment = entry.get("comment")
        comment = raw_comment if isinstance(raw_comment, str) else ""

        return QuestionScore(sequence_no=raw_sequence, score=score, comment=comment)
