"""Tests for the deterministic provider.

Determinism is the property the rest of the test suite and every demo depends on, so it is asserted
directly rather than assumed.
"""

from __future__ import annotations

import pytest
from app.providers.mock_provider import MockAnswerEvaluator, MockQuestionGenerator
from app.schemas.evaluations import EvaluationRequest, Recommendation, SubmittedAnswer
from app.schemas.questions import Difficulty, ExperienceLevel, QuestionGenerationRequest


def _request(count: int = 5, level: ExperienceLevel = ExperienceLevel.SENIOR) -> QuestionGenerationRequest:
    return QuestionGenerationRequest(
        interviewId=None,
        roleTitle="Senior DevOps Engineer",
        experienceLevel=level,
        skills=["Kubernetes", "Helm", "Terraform"],
        questionCount=count,
    )


class TestMockQuestionGenerator:
    def test_produces_the_requested_number_of_questions(self) -> None:
        outcome = MockQuestionGenerator().generate(_request(count=7))
        assert len(outcome.questions) == 7

    def test_sequence_numbers_are_contiguous_from_one(self) -> None:
        outcome = MockQuestionGenerator().generate(_request(count=6))
        assert [q.sequence_no for q in outcome.questions] == [1, 2, 3, 4, 5, 6]

    def test_same_request_yields_identical_output(self) -> None:
        """Two replicas handling the same request must agree.

        This is why the seed is derived with hashlib rather than hash(), whose per-process
        randomisation would break it.
        """
        first = MockQuestionGenerator().generate(_request())
        second = MockQuestionGenerator().generate(_request())
        assert [q.question_text for q in first.questions] == [q.question_text for q in second.questions]

    def test_different_skills_yield_different_output(self) -> None:
        baseline = MockQuestionGenerator().generate(_request())
        other = QuestionGenerationRequest(
            roleTitle="Senior DevOps Engineer",
            experienceLevel=ExperienceLevel.SENIOR,
            skills=["Prometheus", "Grafana"],
            questionCount=5,
        )
        assert [q.question_text for q in baseline.questions] != [
            q.question_text for q in MockQuestionGenerator().generate(other).questions
        ]

    def test_every_requested_skill_is_covered_before_repeating(self) -> None:
        outcome = MockQuestionGenerator().generate(_request(count=3))
        assert {q.category for q in outcome.questions} == {"Kubernetes", "Helm", "Terraform"}

    def test_junior_interviews_avoid_hard_questions(self) -> None:
        outcome = MockQuestionGenerator().generate(_request(count=6, level=ExperienceLevel.JUNIOR))
        assert Difficulty.HARD not in {q.difficulty for q in outcome.questions}

    def test_lead_interviews_avoid_easy_questions(self) -> None:
        outcome = MockQuestionGenerator().generate(_request(count=6, level=ExperienceLevel.LEAD))
        assert Difficulty.EASY not in {q.difficulty for q in outcome.questions}

    def test_reports_no_token_usage(self) -> None:
        outcome = MockQuestionGenerator().generate(_request())
        assert (outcome.prompt_tokens, outcome.completion_tokens) == (0, 0)

    def test_questions_reference_the_skill_and_are_non_empty(self) -> None:
        outcome = MockQuestionGenerator().generate(_request(count=3))
        for question in outcome.questions:
            assert question.question_text.strip()
            assert question.category in question.question_text
            assert question.expected_answer
            assert question.evaluation_hint


class TestMockAnswerEvaluator:
    def _evaluation_request(self, *answers: str) -> EvaluationRequest:
        return EvaluationRequest(
            roleTitle="Platform Engineer",
            answers=[
                SubmittedAnswer(
                    sequenceNo=index,
                    questionText=f"Question {index}",
                    answerText=answer,
                )
                for index, answer in enumerate(answers, start=1)
            ],
        )

    def test_empty_answer_scores_zero(self) -> None:
        outcome = MockAnswerEvaluator().evaluate(self._evaluation_request(""))
        assert float(outcome.per_question[0].score) == 0.0
        assert outcome.recommendation is Recommendation.NO_HIRE

    def test_detailed_answer_outscores_a_terse_one(self) -> None:
        detailed = (
            "We measured the p99 latency first because the mean looked fine. I isolated one replica, "
            "found connection pool exhaustion, and shipped a rollback before fixing the root cause. "
            "The trade-off we accepted was a brief drop in throughput during the incident."
        )
        terse_score = float(
            MockAnswerEvaluator().evaluate(self._evaluation_request("Yes")).per_question[0].score
        )
        detailed_score = float(
            MockAnswerEvaluator().evaluate(self._evaluation_request(detailed)).per_question[0].score
        )
        assert detailed_score > terse_score

    def test_scores_stay_within_range(self) -> None:
        very_long = "because we measured the rollback trade-off in the incident metric test " * 50
        outcome = MockAnswerEvaluator().evaluate(self._evaluation_request(very_long))
        assert 0.0 <= float(outcome.per_question[0].score) <= 10.0
        assert 0.0 <= outcome.overall_score <= 10.0

    def test_one_score_per_submitted_answer(self) -> None:
        outcome = MockAnswerEvaluator().evaluate(
            self._evaluation_request("first answer", "second answer", "third answer")
        )
        assert [entry.sequence_no for entry in outcome.per_question] == [1, 2, 3]

    @pytest.mark.parametrize(
        ("overall", "expected"),
        [
            (9.0, Recommendation.STRONG_HIRE),
            (7.5, Recommendation.HIRE),
            (5.5, Recommendation.HOLD),
            (2.0, Recommendation.NO_HIRE),
        ],
    )
    def test_recommendation_follows_the_score_band(
        self, overall: float, expected: Recommendation
    ) -> None:
        # Exercises the banding directly: driving these four outcomes through generated answer text
        # would couple the test to the length heuristic rather than to the band boundaries.
        recommendation, _ = MockAnswerEvaluator()._band(overall)
        assert recommendation is expected
