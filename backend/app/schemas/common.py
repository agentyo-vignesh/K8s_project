"""Shared response models for health, info and errors."""

from __future__ import annotations

from typing import Any

from pydantic import Field

from app.schemas.questions import CamelModel


class HealthResponse(CamelModel):
    """Probe response. `checks` is empty for liveness, populated for readiness."""

    status: str = Field(examples=["UP", "DOWN"])
    service: str
    version: str
    checks: dict[str, str] = Field(default_factory=dict)


class ServiceInfoResponse(CamelModel):
    """Effective non-secret configuration.

    Exists so "which provider is this pod actually using?" is answerable with one curl during an
    incident, without shelling into the container to read environment variables.
    """

    service: str
    version: str
    environment: str
    secrets_provider: str = Field(alias="secretsProvider")
    ai_provider: str = Field(alias="aiProvider")
    model: str | None = None
    max_questions_per_request: int = Field(alias="maxQuestionsPerRequest")


class ErrorResponse(CamelModel):
    """Documents the error shape in OpenAPI; the handlers build the body directly."""

    timestamp: str
    status: int
    error: str
    code: str
    message: str
    path: str
    request_id: str | None = Field(default=None, alias="requestId")
    field_errors: list[dict[str, Any]] | None = Field(default=None, alias="fieldErrors")
