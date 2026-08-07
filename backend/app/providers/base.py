"""The provider interface.

Everything above this package talks to `QuestionGenerator` and `AnswerEvaluator`, never to the OpenAI
SDK. Three things fall out of that: the test suite runs with no network and no API key, a demo or
training environment can run the full flow for free with the mock provider, and swapping in Bedrock or
a self-hosted model is a new file here rather than a change to the service layer.
"""

from __future__ import annotations

from abc import ABC, abstractmethod
from dataclasses import dataclass, field

from app.schemas.evaluations import EvaluationRequest, QuestionScore, Recommendation
from app.schemas.questions import GeneratedQuestion, QuestionGenerationRequest


@dataclass(frozen=True)
class GenerationOutcome:
    """What a generator returns: the questions plus what it cost.

    Token counts are part of the contract rather than an OpenAI detail, because the mock provider
    reports zero and callers should not need to know which provider ran to read the metric.
    """

    questions: list[GeneratedQuestion]
    model: str | None
    prompt_tokens: int = 0
    completion_tokens: int = 0


@dataclass(frozen=True)
class EvaluationOutcome:
    """What an evaluator returns."""

    overall_score: float
    recommendation: Recommendation
    summary: str
    per_question: list[QuestionScore] = field(default_factory=list)
    model: str | None = None
    prompt_tokens: int = 0
    completion_tokens: int = 0


class QuestionGenerator(ABC):
    """Produces interview questions for a role, level and skill set."""

    @property
    @abstractmethod
    def provider_id(self) -> str:
        """`mock` or `openai`; recorded on every persisted set and used as a metric label."""

    @abstractmethod
    def generate(self, request: QuestionGenerationRequest) -> GenerationOutcome:
        """Raise `AiProviderError` if the upstream provider fails or returns unusable output."""


class AnswerEvaluator(ABC):
    """Scores a candidate's answers."""

    @property
    @abstractmethod
    def provider_id(self) -> str:
        """`mock` or `openai`."""

    @abstractmethod
    def evaluate(self, request: EvaluationRequest) -> EvaluationOutcome:
        """Raise `AiProviderError` if the upstream provider fails or returns unusable output."""
