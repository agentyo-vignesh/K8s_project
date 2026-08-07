"""FastAPI dependency providers.

Services are constructed per request around the request-scoped session; the providers they wrap are
process-wide singletons, so no client or connection pool is rebuilt per call.
"""

from __future__ import annotations

from collections.abc import Generator

from fastapi import Depends
from sqlalchemy.orm import Session

from app.db.session import get_session
from app.providers.factory import get_answer_evaluator, get_question_generator
from app.services.evaluation_service import EvaluationService
from app.services.question_service import QuestionService


def session_dependency() -> Generator[Session, None, None]:
    """Wraps `get_session` so tests can override this one symbol."""
    yield from get_session()


def question_service(session: Session = Depends(session_dependency)) -> QuestionService:
    return QuestionService(session=session, generator=get_question_generator())


def evaluation_service(session: Session = Depends(session_dependency)) -> EvaluationService:
    return EvaluationService(session=session, evaluator=get_answer_evaluator())
