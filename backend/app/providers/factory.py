"""Provider selection.

The single place that knows both providers exist. Everything else depends on the abstract base
classes, which is what makes `AI_PROVIDER=mock` a configuration change rather than a code path.
"""

from __future__ import annotations

import logging
from functools import lru_cache

from app.core.config import AiProvider, Settings, get_settings
from app.core.secrets import get_secret_provider
from app.providers.base import AnswerEvaluator, QuestionGenerator
from app.providers.mock_provider import MockAnswerEvaluator, MockQuestionGenerator

logger = logging.getLogger(__name__)


def build_question_generator(settings: Settings) -> QuestionGenerator:
    if settings.ai_provider is AiProvider.OPENAI:
        from app.providers.openai_provider import OpenAiQuestionGenerator  # noqa: PLC0415

        api_key = get_secret_provider().application_secrets().openai_api_key or ""
        logger.info("Question generator: openai (model=%s)", settings.openai_model)
        return OpenAiQuestionGenerator(settings, api_key)

    logger.info("Question generator: mock (deterministic, no network calls)")
    return MockQuestionGenerator()


def build_answer_evaluator(settings: Settings) -> AnswerEvaluator:
    if settings.ai_provider is AiProvider.OPENAI:
        from app.providers.openai_provider import OpenAiAnswerEvaluator  # noqa: PLC0415

        api_key = get_secret_provider().application_secrets().openai_api_key or ""
        logger.info("Answer evaluator: openai (model=%s)", settings.openai_model)
        return OpenAiAnswerEvaluator(settings, api_key)

    logger.info("Answer evaluator: mock (heuristic scoring)")
    return MockAnswerEvaluator()


@lru_cache(maxsize=1)
def get_question_generator() -> QuestionGenerator:
    """Cached so the OpenAI client (and its connection pool) is created once per process."""
    return build_question_generator(get_settings())


@lru_cache(maxsize=1)
def get_answer_evaluator() -> AnswerEvaluator:
    return build_answer_evaluator(get_settings())
