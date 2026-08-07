"""Question generation contract.

Field names are camelCase to match the middleware's Jackson defaults, so neither side needs a naming
strategy override. Python keeps snake_case internally via `alias` plus `populate_by_name`.
"""

from __future__ import annotations

import uuid
from datetime import datetime
from enum import StrEnum

from pydantic import BaseModel, ConfigDict, Field, field_validator


class ExperienceLevel(StrEnum):
    """Mirrors the middleware enum and the `ck_ai_question_sets_level` constraint."""

    JUNIOR = "JUNIOR"
    MID = "MID"
    SENIOR = "SENIOR"
    LEAD = "LEAD"


class Difficulty(StrEnum):
    EASY = "EASY"
    MEDIUM = "MEDIUM"
    HARD = "HARD"


class CamelModel(BaseModel):
    """Serialises with camelCase aliases while accepting either spelling on input."""

    model_config = ConfigDict(populate_by_name=True, from_attributes=True)


class QuestionGenerationRequest(CamelModel):
    """What the middleware sends to generate a question set."""

    interview_id: uuid.UUID | None = Field(
        default=None,
        alias="interviewId",
        description="Links the set to an interview; omit for an ad-hoc generation",
    )
    role_title: str = Field(
        alias="roleTitle", min_length=2, max_length=150, examples=["Senior DevOps Engineer"]
    )
    experience_level: ExperienceLevel = Field(alias="experienceLevel")
    skills: list[str] = Field(
        min_length=1,
        max_length=20,
        examples=[["Kubernetes", "Helm", "EKS"]],
        description="Topics the questions should cover",
    )
    question_count: int = Field(
        default=5, alias="questionCount", ge=1, le=50, description="How many questions to produce"
    )

    @field_validator("skills")
    @classmethod
    def _clean_skills(cls, value: list[str]) -> list[str]:
        """Trims, drops blanks and de-duplicates case-insensitively while keeping the first spelling.

        Prevents `["AWS", "aws", " AWS "]` from being fed to the model as three separate topics and
        wasting a third of the question budget on duplicates.
        """
        seen: set[str] = set()
        cleaned: list[str] = []
        for raw in value:
            skill = raw.strip()
            if not skill:
                continue
            if len(skill) > 60:
                skill = skill[:60]
            key = skill.casefold()
            if key in seen:
                continue
            seen.add(key)
            cleaned.append(skill)
        if not cleaned:
            raise ValueError("skills must contain at least one non-blank value")
        return cleaned

    @field_validator("role_title")
    @classmethod
    def _clean_role_title(cls, value: str) -> str:
        title = value.strip()
        if not title:
            raise ValueError("roleTitle must not be blank")
        return title


class GeneratedQuestion(CamelModel):
    """One question in a generated set."""

    sequence_no: int = Field(alias="sequenceNo", ge=1)
    question_text: str = Field(alias="questionText", min_length=1)
    category: str = Field(max_length=60, examples=["Kubernetes"])
    difficulty: Difficulty
    expected_answer: str | None = Field(default=None, alias="expectedAnswer")
    evaluation_hint: str | None = Field(
        default=None,
        alias="evaluationHint",
        description="What a strong answer demonstrates; interviewer-facing",
    )


class TokenUsage(CamelModel):
    """Provider token accounting. Zero for the mock provider, which makes no API call."""

    prompt_tokens: int = Field(default=0, alias="promptTokens", ge=0)
    completion_tokens: int = Field(default=0, alias="completionTokens", ge=0)

    @property
    def total(self) -> int:
        return self.prompt_tokens + self.completion_tokens


class QuestionSetResponse(CamelModel):
    """A persisted question set."""

    set_id: uuid.UUID = Field(alias="setId")
    interview_id: uuid.UUID | None = Field(default=None, alias="interviewId")
    request_id: str = Field(alias="requestId")
    role_title: str = Field(alias="roleTitle")
    experience_level: ExperienceLevel = Field(alias="experienceLevel")
    skills: list[str]
    provider: str = Field(examples=["mock", "openai"])
    model: str | None = None
    latency_ms: int = Field(alias="latencyMs", ge=0)
    usage: TokenUsage
    questions: list[GeneratedQuestion]
    created_at: datetime = Field(alias="createdAt")
