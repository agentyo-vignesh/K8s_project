"""Effective configuration.

Answers "which providers is this pod actually using?" with one call, which is the first question during
an incident and otherwise requires shelling into the container. Only non-secret facts are exposed: the
provider ids and the model name, never a key or a connection string.
"""

from __future__ import annotations

from fastapi import APIRouter, Depends

from app import __version__
from app.core.config import get_settings
from app.core.secrets import get_secret_provider
from app.core.security import require_internal_api_key
from app.providers.factory import get_question_generator
from app.schemas.common import ServiceInfoResponse

router = APIRouter(tags=["Info"])


@router.get(
    "/info",
    response_model=ServiceInfoResponse,
    dependencies=[Depends(require_internal_api_key)],
    summary="Effective non-secret configuration",
)
async def service_info() -> ServiceInfoResponse:
    settings = get_settings()
    generator = get_question_generator()
    return ServiceInfoResponse(
        service=settings.service_name,
        version=__version__,
        environment=str(settings.app_env),
        secrets_provider=get_secret_provider().provider_id,
        ai_provider=generator.provider_id,
        # Only meaningful for the OpenAI provider; the mock reports its own deterministic label.
        model=settings.openai_model if generator.provider_id == "openai" else None,
        max_questions_per_request=settings.max_questions_per_request,
    )
