"""Answer evaluation endpoints."""

from __future__ import annotations

import uuid

from fastapi import APIRouter, Depends, Path, status

from app.api.dependencies import evaluation_service
from app.core.security import require_internal_api_key
from app.schemas.common import ErrorResponse
from app.schemas.evaluations import EvaluationRequest, EvaluationResponse
from app.services.evaluation_service import EvaluationService

router = APIRouter(
    prefix="/evaluations",
    tags=["Evaluations"],
    dependencies=[Depends(require_internal_api_key)],
    responses={
        400: {"model": ErrorResponse, "description": "Validation failed"},
        401: {"model": ErrorResponse, "description": "Missing or invalid internal API key"},
        502: {"model": ErrorResponse, "description": "The AI provider failed"},
        503: {"model": ErrorResponse, "description": "The database is unavailable"},
    },
)


@router.post(
    "",
    response_model=EvaluationResponse,
    status_code=status.HTTP_200_OK,
    summary="Score a candidate's answers",
    description=(
        "Produces per-question scores, an overall score and a recommendation, and stores the result. "
        "This is advisory: the interviewer still submits the authoritative result through the "
        "middleware, so an AI score never becomes a hiring decision on its own."
    ),
)
async def evaluate_answers(
    request: EvaluationRequest,
    service: EvaluationService = Depends(evaluation_service),
) -> EvaluationResponse:
    return service.evaluate(request)


@router.get(
    "/interview/{interview_id}",
    response_model=EvaluationResponse,
    summary="Fetch the latest evaluation for an interview",
    responses={404: {"model": ErrorResponse, "description": "Nothing evaluated for this interview"}},
)
async def find_latest_for_interview(
    interview_id: uuid.UUID = Path(description="Interview identifier"),
    service: EvaluationService = Depends(evaluation_service),
) -> EvaluationResponse:
    return service.find_latest_for_interview(interview_id)
