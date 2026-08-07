"""OpenAI-backed provider.

The only module that imports the OpenAI SDK, and it does so lazily inside `__init__` so a deployment
running with `AI_PROVIDER=mock` never loads it.

Structured output is requested via `response_format={"type": "json_object"}` and the parsed result is
validated against the same Pydantic models the API returns. A model that ignores the schema therefore
produces a clean 502 rather than a malformed row in the database.
"""

from __future__ import annotations

import json
import logging
from decimal import Decimal
from typing import Any

from app.core.config import Settings
from app.core.errors import AiProviderError
from app.providers.base import (
    AnswerEvaluator,
    EvaluationOutcome,
    GenerationOutcome,
    QuestionGenerator,
)
from app.schemas.evaluations import EvaluationRequest, QuestionScore, Recommendation
from app.schemas.questions import (
    Difficulty,
    GeneratedQuestion,
    QuestionGenerationRequest,
)

logger = logging.getLogger(__name__)

_GENERATION_SYSTEM_PROMPT = """\
You are an experienced technical interviewer. Produce interview questions that probe real experience
rather than recall of definitions.

Return ONLY a JSON object of this exact shape:
{
  "questions": [
    {
      "sequenceNo": 1,
      "questionText": "...",
      "category": "<one of the requested skills>",
      "difficulty": "EASY" | "MEDIUM" | "HARD",
      "expectedAnswer": "what a strong answer contains",
      "evaluationHint": "what the interviewer should listen for"
    }
  ]
}

Rules:
- Produce exactly the requested number of questions, numbered from 1 with no gaps.
- Distribute questions across the requested skills.
- Match difficulty to the stated experience level.
- `category` must be one of the requested skills, copied verbatim.
- No markdown, no commentary, no text outside the JSON object.
"""

_EVALUATION_SYSTEM_PROMPT = """\
You are an experienced technical interviewer scoring a candidate's answers.

Return ONLY a JSON object of this exact shape:
{
  "overallScore": 7.5,
  "recommendation": "STRONG_HIRE" | "HIRE" | "HOLD" | "NO_HIRE",
  "summary": "two or three sentences of justification",
  "perQuestion": [
    { "sequenceNo": 1, "score": 8.0, "comment": "..." }
  ]
}

Rules:
- Every score is between 0 and 10 with at most one decimal place.
- Score an empty answer as 0.
- Include one perQuestion entry for every answer supplied, using the same sequenceNo.
- Base the recommendation on the evidence in the answers, not on their length alone.
- No markdown, no commentary, no text outside the JSON object.
"""


class OpenAiClientFactory:
    """Builds the SDK client.

    Separated so both the generator and the evaluator share one client (and therefore one connection
    pool) and so the import stays in a single place.
    """

    @staticmethod
    def create(settings: Settings, api_key: str) -> Any:
        try:
            from openai import OpenAI  # noqa: PLC0415
        except ImportError as exc:  # pragma: no cover - the package is a pinned dependency
            raise AiProviderError(
                "The openai package is not installed but AI_PROVIDER=openai"
            ) from exc

        return OpenAI(
            api_key=api_key,
            timeout=settings.openai_timeout_seconds,
            # The SDK retries idempotent failures itself; kept low because the middleware also
            # retries, and two retry layers multiply worst-case latency.
            max_retries=settings.openai_max_retries,
        )


class _OpenAiBase:
    """Shared completion call and JSON handling."""

    def __init__(self, settings: Settings, api_key: str, client: Any | None = None) -> None:
        if not api_key:
            raise AiProviderError(
                "OPENAI_API_KEY (or openaiApiKey in the application secret) is required when "
                "AI_PROVIDER=openai"
            )
        self._settings = settings
        self._model = settings.openai_model
        self._client = client or OpenAiClientFactory.create(settings, api_key)

    @property
    def provider_id(self) -> str:
        return "openai"

    def _complete(self, system_prompt: str, user_prompt: str) -> tuple[dict[str, Any], int, int]:
        """Runs one chat completion and returns the parsed object plus token usage."""
        try:
            response = self._client.chat.completions.create(
                model=self._model,
                temperature=self._settings.openai_temperature,
                response_format={"type": "json_object"},
                messages=[
                    {"role": "system", "content": system_prompt},
                    {"role": "user", "content": user_prompt},
                ],
            )
        except Exception as exc:
            # Covers rate limits, timeouts, auth failures and connection errors alike. The message
            # is included because it is operationally useful and contains no secret; the API key
            # never appears in SDK exception text.
            logger.warning("OpenAI request failed: %s", exc)
            raise AiProviderError(f"OpenAI request failed: {exc}") from exc

        content = self._extract_content(response)
        prompt_tokens, completion_tokens = self._extract_usage(response)

        try:
            parsed = json.loads(content)
        except json.JSONDecodeError as exc:
            logger.warning("OpenAI returned non-JSON content despite json_object response format")
            raise AiProviderError("OpenAI returned a response that was not valid JSON") from exc

        if not isinstance(parsed, dict):
            raise AiProviderError("OpenAI returned JSON that was not an object")
        return parsed, prompt_tokens, completion_tokens

    @staticmethod
    def _extract_content(response: Any) -> str:
        choices = getattr(response, "choices", None)
        if not choices:
            raise AiProviderError("OpenAI returned no choices")
        message = getattr(choices[0], "message", None)
        content = getattr(message, "content", None) if message is not None else None
        if not content:
            # A refusal or a length-truncated response lands here.
            finish_reason = getattr(choices[0], "finish_reason", "unknown")
            raise AiProviderError(
                f"OpenAI returned an empty message (finish_reason={finish_reason})"
            )
        return str(content)

    @staticmethod
    def _extract_usage(response: Any) -> tuple[int, int]:
        usage = getattr(response, "usage", None)
        if usage is None:
            return 0, 0
        return int(getattr(usage, "prompt_tokens", 0) or 0), int(
            getattr(usage, "completion_tokens", 0) or 0
        )


class OpenAiQuestionGenerator(_OpenAiBase, QuestionGenerator):
    """Generates questions with a chat completion."""

    def generate(self, request: QuestionGenerationRequest) -> GenerationOutcome:
        user_prompt = (
            f"Role: {request.role_title}\n"
            f"Experience level: {request.experience_level}\n"
            f"Skills to cover: {', '.join(request.skills)}\n"
            f"Number of questions: {request.question_count}\n"
        )
        payload, prompt_tokens, completion_tokens = self._complete(
            _GENERATION_SYSTEM_PROMPT, user_prompt
        )

        raw_questions = payload.get("questions")
        if not isinstance(raw_questions, list) or not raw_questions:
            raise AiProviderError("OpenAI response contained no questions array")

        questions: list[GeneratedQuestion] = []
        for index, raw in enumerate(raw_questions, start=1):
            if not isinstance(raw, dict):
                continue
            text = str(raw.get("questionText") or "").strip()
            if not text:
                # Skip rather than fail: a partially usable set is still worth returning, and the
                # count mismatch is logged below.
                continue
            questions.append(
                GeneratedQuestion(
                    # Renumbered from the position kept, so the sequence has no gaps even if the
                    # model numbered them badly or repeated a number.
                    sequence_no=len(questions) + 1,
                    question_text=text,
                    category=self._resolve_category(raw.get("category"), request.skills, index),
                    difficulty=self._parse_difficulty(raw.get("difficulty")),
                    expected_answer=self._clean_optional(raw.get("expectedAnswer")),
                    evaluation_hint=self._clean_optional(raw.get("evaluationHint")),
                )
            )

        if not questions:
            raise AiProviderError("OpenAI returned no usable questions")
        if len(questions) != request.question_count:
            logger.warning(
                "OpenAI returned %d usable questions but %d were requested",
                len(questions),
                request.question_count,
            )

        return GenerationOutcome(
            questions=questions,
            model=self._model,
            prompt_tokens=prompt_tokens,
            completion_tokens=completion_tokens,
        )

    @staticmethod
    def _resolve_category(value: Any, skills: list[str], index: int) -> str:
        """Keeps `category` inside the requested skills.

        The prompt asks for a verbatim skill, but a model may invent one. Constraining it here keeps
        the field usable as a filter instead of becoming free text.
        """
        if isinstance(value, str) and value.strip():
            candidate = value.strip()
            for skill in skills:
                if skill.casefold() == candidate.casefold():
                    return skill
        return skills[(index - 1) % len(skills)]

    @staticmethod
    def _parse_difficulty(value: Any) -> Difficulty:
        if isinstance(value, str):
            try:
                return Difficulty(value.strip().upper())
            except ValueError:
                logger.debug("Unrecognised difficulty %r from OpenAI; defaulting to MEDIUM", value)
        return Difficulty.MEDIUM

    @staticmethod
    def _clean_optional(value: Any) -> str | None:
        if isinstance(value, str) and value.strip():
            return value.strip()
        return None


class OpenAiAnswerEvaluator(_OpenAiBase, AnswerEvaluator):
    """Scores answers with a chat completion."""

    def evaluate(self, request: EvaluationRequest) -> EvaluationOutcome:
        answers_block = "\n\n".join(
            f"Q{answer.sequence_no}: {answer.question_text}\n"
            f"A{answer.sequence_no}: {answer.answer_text or '(no answer given)'}"
            for answer in request.answers
        )
        user_prompt = f"Role: {request.role_title}\n\n{answers_block}\n"

        payload, prompt_tokens, completion_tokens = self._complete(
            _EVALUATION_SYSTEM_PROMPT, user_prompt
        )

        per_question = self._parse_per_question(payload.get("perQuestion"), request)
        overall = self._parse_overall(payload.get("overallScore"), per_question)
        recommendation = self._parse_recommendation(payload.get("recommendation"), overall)
        summary = str(payload.get("summary") or "").strip() or "No summary was provided."

        return EvaluationOutcome(
            overall_score=overall,
            recommendation=recommendation,
            summary=summary,
            per_question=per_question,
            model=self._model,
            prompt_tokens=prompt_tokens,
            completion_tokens=completion_tokens,
        )

    @staticmethod
    def _parse_per_question(
        value: Any, request: EvaluationRequest
    ) -> list[QuestionScore]:
        submitted = {answer.sequence_no for answer in request.answers}
        scores: list[QuestionScore] = []
        if isinstance(value, list):
            for raw in value:
                if not isinstance(raw, dict):
                    continue
                raw_sequence = raw.get("sequenceNo")
                raw_score = raw.get("score")
                # A model can omit a key entirely, so None is checked before coercion rather than
                # relying on int(None) raising: that keeps the except clause about genuinely
                # unparseable values ("high", "7/10") instead of doubling as a presence check.
                if raw_sequence is None or raw_score is None:
                    continue
                try:
                    sequence_no = int(raw_sequence)
                    score = float(raw_score)
                except (TypeError, ValueError):
                    continue
                # Ignore scores for questions that were not submitted: the model occasionally
                # invents an extra entry, and storing it would corrupt the per-question view.
                if sequence_no not in submitted:
                    continue
                scores.append(
                    QuestionScore(
                        sequence_no=sequence_no,
                        score=Decimal(str(round(min(max(score, 0.0), 10.0), 1))),
                        comment=str(raw.get("comment") or "").strip() or "No comment provided.",
                    )
                )
        if not scores:
            raise AiProviderError("OpenAI returned no usable per-question scores")
        return sorted(scores, key=lambda entry: entry.sequence_no)

    @staticmethod
    def _parse_overall(value: Any, per_question: list[QuestionScore]) -> float:
        try:
            overall = float(value)
        except (TypeError, ValueError):
            # Fall back to the mean of the per-question scores rather than failing: the breakdown is
            # the more trustworthy number anyway.
            overall = sum(float(entry.score) for entry in per_question) / len(per_question)
        return round(min(max(overall, 0.0), 10.0), 1)

    @staticmethod
    def _parse_recommendation(value: Any, overall: float) -> Recommendation:
        if isinstance(value, str):
            try:
                return Recommendation(value.strip().upper())
            except ValueError:
                logger.debug("Unrecognised recommendation %r from OpenAI; deriving from score", value)
        if overall >= 8.5:
            return Recommendation.STRONG_HIRE
        if overall >= 7.0:
            return Recommendation.HIRE
        if overall >= 5.0:
            return Recommendation.HOLD
        return Recommendation.NO_HIRE
