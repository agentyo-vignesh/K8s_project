"""Question generation endpoints."""

from __future__ import annotations

import uuid

from fastapi import APIRouter, Depends, Path, status

from app.api.dependencies import question_service
from app.core.config import get_settings
from app.core.errors import BadRequestError
from app.core.security import require_internal_api_key
from app.schemas.common import ErrorResponse
from app.schemas.questions import QuestionGenerationRequest, QuestionSetResponse
from app.services.question_service import QuestionService

router = APIRouter(
    prefix="/questions",
    tags=["Questions"],
    dependencies=[Depends(require_internal_api_key)],
    responses={
        400: {"model": ErrorResponse, "description": "Validation failed"},
        401: {"model": ErrorResponse, "description": "Missing or invalid internal API key"},
        502: {"model": ErrorResponse, "description": "The AI provider failed"},
        503: {"model": ErrorResponse, "description": "The database is unavailable"},
    },
)


@router.post(
    "/generate",
    response_model=QuestionSetResponse,
    status_code=status.HTTP_200_OK,
    summary="Generate a question set",
    description=(
        "Generates interview questions for a role, seniority and skill set, stores the set, and "
        "returns it. Every attempt is recorded, including failures, so provider error rate and token "
        "spend are answerable from SQL."
    ),
)
async def generate_questions(
    request: QuestionGenerationRequest,
    service: QuestionService = Depends(question_service),
) -> QuestionSetResponse:
    # The schema caps this at 50; this is the per-deployment cap, which can be lowered by
    # configuration without a release when a provider's cost or latency demands it.
    limit = get_settings().max_questions_per_request
    if request.question_count > limit:
        raise BadRequestError(
            f"questionCount {request.question_count} exceeds this deployment's limit of {limit}"
        )
    return service.generate(request)


@router.get(
    "/sets/{set_id}",
    response_model=QuestionSetResponse,
    summary="Fetch a generated question set",
    responses={404: {"model": ErrorResponse, "description": "No such set"}},
)
async def find_question_set(
    set_id: uuid.UUID = Path(description="Question set identifier"),
    service: QuestionService = Depends(question_service),
) -> QuestionSetResponse:
    return service.find_by_id(set_id)


@router.get(
    "/interview/{interview_id}",
    response_model=QuestionSetResponse,
    summary="Fetch the latest question set for an interview",
    description="Regeneration is normal, so this returns the most recent successful set.",
    responses={404: {"model": ErrorResponse, "description": "Nothing generated for this interview"}},
)
async def find_latest_for_interview(
    interview_id: uuid.UUID = Path(description="Interview identifier"),
    service: QuestionService = Depends(question_service),
) -> QuestionSetResponse:
    return service.find_latest_for_interview(interview_id)
