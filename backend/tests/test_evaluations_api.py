"""End-to-end tests for the evaluation API."""

from __future__ import annotations

import uuid

from fastapi.testclient import TestClient

EVALUATE_URL = "/api/v1/evaluations"

_DETAILED_ANSWER = (
    "We measured p99 latency first because the mean looked healthy. I isolated a single replica, "
    "found connection pool exhaustion, and rolled back before fixing the root cause. The trade-off "
    "we accepted was reduced throughput during the incident."
)


def _payload(**overrides: object) -> dict[str, object]:
    payload: dict[str, object] = {
        "roleTitle": "Platform Engineer",
        "answers": [
            {"sequenceNo": 1, "questionText": "Describe a production incident.", "answerText": _DETAILED_ANSWER},
            {"sequenceNo": 2, "questionText": "How do you detect drift?", "answerText": "Terraform plan in CI."},
        ],
    }
    payload.update(overrides)
    return payload


class TestEvaluateAnswers:
    def test_returns_scores_for_every_answer(self, client: TestClient) -> None:
        response = client.post(EVALUATE_URL, json=_payload())

        assert response.status_code == 200
        body = response.json()
        assert [entry["sequenceNo"] for entry in body["perQuestion"]] == [1, 2]
        assert 0 <= float(body["overallScore"]) <= 10
        assert body["recommendation"] in {"STRONG_HIRE", "HIRE", "HOLD", "NO_HIRE"}

    def test_persists_and_returns_the_latest_evaluation(self, client: TestClient) -> None:
        interview_id = str(uuid.uuid4())
        created = client.post(EVALUATE_URL, json=_payload(interviewId=interview_id)).json()

        response = client.get(f"/api/v1/evaluations/interview/{interview_id}")

        assert response.status_code == 200
        assert response.json()["evaluationId"] == created["evaluationId"]

    def test_stores_the_answers_as_submitted(self, client: TestClient) -> None:
        """A disputed score has to be re-checkable against the exact input."""
        interview_id = str(uuid.uuid4())
        client.post(EVALUATE_URL, json=_payload(interviewId=interview_id))

        body = client.get(f"/api/v1/evaluations/interview/{interview_id}").json()

        assert body["perQuestion"][0]["comment"]
        assert body["summary"]

    def test_a_more_detailed_answer_scores_higher(self, client: TestClient) -> None:
        body = client.post(EVALUATE_URL, json=_payload()).json()
        scores = {entry["sequenceNo"]: float(entry["score"]) for entry in body["perQuestion"]}

        assert scores[1] > scores[2]


class TestEvaluateValidation:
    def test_rejects_an_empty_answer_list(self, client: TestClient) -> None:
        response = client.post(EVALUATE_URL, json=_payload(answers=[]))

        assert response.status_code == 400
        assert response.json()["code"] == "VALIDATION_FAILED"

    def test_rejects_duplicate_sequence_numbers(self, client: TestClient) -> None:
        """Two answers for one question would make the per-question scores ambiguous."""
        response = client.post(
            EVALUATE_URL,
            json=_payload(
                answers=[
                    {"sequenceNo": 1, "questionText": "First", "answerText": "a"},
                    {"sequenceNo": 1, "questionText": "Second", "answerText": "b"},
                ]
            ),
        )

        assert response.status_code == 400

    def test_accepts_a_blank_answer_as_a_skipped_question(self, client: TestClient) -> None:
        response = client.post(
            EVALUATE_URL,
            json=_payload(
                answers=[{"sequenceNo": 1, "questionText": "Skipped?", "answerText": "   "}]
            ),
        )

        assert response.status_code == 200
        assert float(response.json()["perQuestion"][0]["score"]) == 0.0

    def test_unknown_interview_returns_404(self, client: TestClient) -> None:
        response = client.get(f"/api/v1/evaluations/interview/{uuid.uuid4()}")

        assert response.status_code == 404

    def test_requires_the_internal_api_key(self, unauthenticated_client: TestClient) -> None:
        response = unauthenticated_client.post(EVALUATE_URL, json=_payload())

        assert response.status_code == 401
