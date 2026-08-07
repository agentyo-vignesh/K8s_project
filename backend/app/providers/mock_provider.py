"""Deterministic provider that needs no network and no API key.

This is the default. It exists for three reasons that all matter for a DevOps training platform: the
end-to-end flow works on a laptop with `docker compose up` and nothing else, CI can assert on exact
output because the same input always produces the same questions, and a cluster demo costs nothing to
run repeatedly.

Determinism comes from seeding a local `random.Random` with a hash of the request. It is never seeded
from the global RNG and never uses wall-clock time, so two replicas handling the same request produce
identical output.
"""

from __future__ import annotations

import hashlib
import random
from decimal import Decimal

from app.providers.base import (
    AnswerEvaluator,
    EvaluationOutcome,
    GenerationOutcome,
    QuestionGenerator,
)
from app.schemas.evaluations import EvaluationRequest, QuestionScore, Recommendation
from app.schemas.questions import (
    Difficulty,
    ExperienceLevel,
    GeneratedQuestion,
    QuestionGenerationRequest,
)

MODEL_NAME = "mock-deterministic-v1"

# Difficulty mix per seniority. A junior interview should not open with a hard question, and a lead
# interview that is mostly EASY tells you nothing.
_DIFFICULTY_MIX: dict[ExperienceLevel, tuple[Difficulty, ...]] = {
    ExperienceLevel.JUNIOR: (Difficulty.EASY, Difficulty.EASY, Difficulty.MEDIUM),
    ExperienceLevel.MID: (Difficulty.EASY, Difficulty.MEDIUM, Difficulty.MEDIUM, Difficulty.HARD),
    ExperienceLevel.SENIOR: (Difficulty.MEDIUM, Difficulty.MEDIUM, Difficulty.HARD, Difficulty.HARD),
    ExperienceLevel.LEAD: (Difficulty.MEDIUM, Difficulty.HARD, Difficulty.HARD),
}

# Question templates per difficulty. Each is a (question, expected answer, what-to-listen-for)
# triple; `{skill}` and `{role}` are substituted per question.
_TEMPLATES: dict[Difficulty, tuple[tuple[str, str, str], ...]] = {
    Difficulty.EASY: (
        (
            "Explain what {skill} is used for and where you have applied it.",
            "A clear definition in the candidate's own words plus at least one concrete example from"
            " their own work.",
            "Listen for a real example rather than a textbook definition.",
        ),
        (
            "Walk me through the day-to-day commands or workflows you use with {skill}.",
            "Fluent description of the routine operations, not just the concepts.",
            "Hands-on candidates describe the workflow without hesitating.",
        ),
        (
            "What is the first thing you check when something goes wrong with {skill}?",
            "A specific starting point (logs, status, recent changes) rather than a generic"
            " 'I would investigate'.",
            "A named first step signals real operational experience.",
        ),
    ),
    Difficulty.MEDIUM: (
        (
            "Describe a problem you solved with {skill} as a {role}. What made it difficult?",
            "A concrete situation, the constraints, the approach taken and the outcome.",
            "Look for the reasoning behind the choice, not only the result.",
        ),
        (
            "How would you decide between two competing approaches to {skill} on a production system?",
            "Explicit trade-offs: operational cost, blast radius, reversibility and team familiarity.",
            "Strong answers name the trade-off they accepted, not just the option they picked.",
        ),
        (
            "What does 'done' look like for a {skill} change you are about to ship?",
            "Tests, observability, rollback path and a way to verify in production.",
            "Watch for whether rollback and verification are mentioned unprompted.",
        ),
        (
            "How do you keep a {skill} configuration consistent across environments?",
            "Configuration as code, a single source of truth, and how drift is detected.",
            "Listen for drift detection, which is the part most candidates omit.",
        ),
    ),
    Difficulty.HARD: (
        (
            "A production incident is traced to {skill}. Take me through your diagnosis and mitigation,"
            " in order.",
            "A repeatable loop: observe, isolate, compare against last known good, mitigate, then fix"
            " the root cause.",
            "The order matters: mitigation should come before root-cause analysis.",
        ),
        (
            "How would you design {skill} for a system that must survive the loss of an availability"
            " zone?",
            "Redundancy across zones, state and data replication, failover behaviour, and how the"
            " design is tested.",
            "Ask how they would test it; untested failover is a guess.",
        ),
        (
            "Where does {skill} become the bottleneck as traffic grows tenfold, and what would you"
            " change first?",
            "A specific limit (connections, throughput, lock contention, quota) and a measured"
            " justification for the first change.",
            "Look for a measurement-led answer rather than a list of optimisations.",
        ),
        (
            "What is the most common way teams get {skill} wrong, and how do you prevent it on yours?",
            "A named anti-pattern plus a concrete guardrail: a policy, a CI check, or a default that"
            " makes the wrong thing hard.",
            "Prevention through tooling beats prevention through documentation.",
        ),
    ),
}

_SUMMARY_BY_BAND = (
    (8.5, Recommendation.STRONG_HIRE, "Answers were specific, well structured and backed by examples."),
    (7.0, Recommendation.HIRE, "Solid answers with good practical grounding; a few areas to probe further."),
    (5.0, Recommendation.HOLD, "Mixed answers: some areas were strong, others needed prompting."),
    (0.0, Recommendation.NO_HIRE, "Answers lacked the depth and specificity the role requires."),
)


def _seed_from(*parts: str) -> int:
    """Stable integer seed from the request.

    `hashlib` rather than `hash()`: Python randomises string hashing per process, so `hash()` would
    give different questions on every pod.
    """
    digest = hashlib.sha256("|".join(parts).encode("utf-8")).digest()
    return int.from_bytes(digest[:8], byteorder="big", signed=False)


class MockQuestionGenerator(QuestionGenerator):
    """Builds a question set by rotating skills through difficulty-appropriate templates."""

    @property
    def provider_id(self) -> str:
        return "mock"

    def generate(self, request: QuestionGenerationRequest) -> GenerationOutcome:
        rng = random.Random(
            _seed_from(
                request.role_title,
                str(request.experience_level),
                ",".join(request.skills),
                str(request.question_count),
            )
        )

        mix = _DIFFICULTY_MIX[request.experience_level]
        questions: list[GeneratedQuestion] = []

        for index in range(request.question_count):
            # Round-robin over skills so every requested topic is covered before any is repeated.
            skill = request.skills[index % len(request.skills)]
            difficulty = mix[index % len(mix)]

            # Offset the template choice by the index so consecutive questions on the same skill do
            # not reuse one template.
            pool = _TEMPLATES[difficulty]
            template, expected, hint = pool[(rng.randrange(len(pool)) + index) % len(pool)]

            questions.append(
                GeneratedQuestion(
                    sequence_no=index + 1,
                    question_text=template.format(skill=skill, role=request.role_title),
                    category=skill[:60],
                    difficulty=difficulty,
                    expected_answer=expected,
                    evaluation_hint=hint,
                )
            )

        return GenerationOutcome(questions=questions, model=MODEL_NAME)


class MockAnswerEvaluator(AnswerEvaluator):
    """Scores answers with a transparent heuristic.

    It is not pretending to judge quality; it rewards length and specificity so the scoring pipeline,
    persistence and dashboards can be exercised end to end without an API key. Real judgement needs
    the OpenAI provider.
    """

    # Words that suggest the candidate gave a concrete account rather than a generality.
    _SPECIFICITY_MARKERS = (
        "because",
        "for example",
        "we ",
        "i ",
        "measured",
        "rollback",
        "trade-off",
        "tradeoff",
        "incident",
        "metric",
        "test",
    )

    @property
    def provider_id(self) -> str:
        return "mock"

    def evaluate(self, request: EvaluationRequest) -> EvaluationOutcome:
        per_question: list[QuestionScore] = []
        total = 0.0

        for answer in request.answers:
            score, comment = self._score_answer(answer.answer_text)
            total += score
            per_question.append(
                QuestionScore(
                    sequence_no=answer.sequence_no,
                    score=Decimal(str(score)),
                    comment=comment,
                )
            )

        overall = round(total / len(request.answers), 1)
        recommendation, summary = self._band(overall)

        return EvaluationOutcome(
            overall_score=overall,
            recommendation=recommendation,
            summary=f"{summary} Evaluated {len(request.answers)} answer(s) for {request.role_title}.",
            per_question=per_question,
            model=MODEL_NAME,
        )

    def _score_answer(self, answer: str) -> tuple[float, str]:
        if not answer:
            return 0.0, "No answer was given."

        words = len(answer.split())
        lowered = answer.lower()
        markers = sum(1 for marker in self._SPECIFICITY_MARKERS if marker in lowered)

        # Length up to 6 points (saturating at ~120 words) plus up to 4 for specificity markers.
        length_score = min(6.0, words / 20.0)
        specificity_score = min(4.0, markers * 1.0)
        score = round(min(10.0, length_score + specificity_score), 1)

        if score >= 8.0:
            comment = "Detailed answer with concrete supporting evidence."
        elif score >= 6.0:
            comment = "Reasonable answer; would benefit from a specific example."
        elif score >= 3.0:
            comment = "Answer was brief and stayed at a high level."
        else:
            comment = "Answer was too short to assess."
        return score, comment

    def _band(self, overall: float) -> tuple[Recommendation, str]:
        for threshold, recommendation, summary in _SUMMARY_BY_BAND:
            if overall >= threshold:
                return recommendation, summary
        # Unreachable: the final band has a threshold of 0.0 and scores cannot be negative.
        return Recommendation.NO_HIRE, "Insufficient evidence to recommend."
