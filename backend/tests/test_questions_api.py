"""End-to-end tests for the question generation API, through the real FastAPI app."""

from __future__ import annotations

import uuid

from fastapi.testclient import TestClient

GENERATE_URL = "/api/v1/questions/generate"


def _payload(**overrides: object) -> dict[str, object]:
    payload: dict[str, object] = {
        "roleTitle": "Senior DevOps Engineer",
        "experienceLevel": "SENIOR",
        "skills": ["Kubernetes", "Helm"],
        "questionCount": 4,
    }
    payload.update(overrides)
    return payload


class TestGenerateQuestions:
    def test_returns_a_persisted_question_set(self, client: TestClient) -> None:
        response = client.post(GENERATE_URL, json=_payload())

        assert response.status_code == 200
        body = response.json()
        assert body["provider"] == "mock"
        assert len(body["questions"]) == 4
        assert [q["sequenceNo"] for q in body["questions"]] == [1, 2, 3, 4]
        # The set id proves it was stored, not just computed.
        assert uuid.UUID(body["setId"])

    def test_response_uses_camel_case_to_match_the_middleware(self, client: TestClient) -> None:
        body = client.post(GENERATE_URL, json=_payload()).json()

        assert {"setId", "requestId", "roleTitle", "experienceLevel", "latencyMs"} <= body.keys()
        assert {"sequenceNo", "questionText", "expectedAnswer"} <= body["questions"][0].keys()

    def test_generated_set_is_retrievable_by_id(self, client: TestClient) -> None:
        set_id = client.post(GENERATE_URL, json=_payload()).json()["setId"]

        response = client.get(f"/api/v1/questions/sets/{set_id}")

        assert response.status_code == 200
        assert response.json()["setId"] == set_id

    def test_latest_set_for_an_interview_is_the_most_recent(self, client: TestClient) -> None:
        interview_id = str(uuid.uuid4())
        client.post(GENERATE_URL, json=_payload(interviewId=interview_id, questionCount=3))
        second = client.post(
            GENERATE_URL, json=_payload(interviewId=interview_id, questionCount=6)
        ).json()

        response = client.get(f"/api/v1/questions/interview/{interview_id}")

        assert response.status_code == 200
        assert response.json()["setId"] == second["setId"]
        assert len(response.json()["questions"]) == 6

    def test_echoes_the_inbound_request_id(self, client: TestClient) -> None:
        """Correlation must survive the hop from the middleware."""
        response = client.post(
            GENERATE_URL, json=_payload(), headers={"X-Request-Id": "trace-abc-123"}
        )

        assert response.headers["X-Request-Id"] == "trace-abc-123"
        assert response.json()["requestId"] == "trace-abc-123"

    def test_strips_unsafe_characters_from_an_inbound_request_id(self, client: TestClient) -> None:
        """The id reaches a response header, so CR/LF must not survive."""
        response = client.post(
            GENERATE_URL, json=_payload(), headers={"X-Request-Id": "abc\r\nX-Injected: 1"}
        )

        assert "\r" not in response.headers["X-Request-Id"]
        assert "X-Injected" not in response.headers


class TestGenerateQuestionsValidation:
    def test_rejects_an_empty_skill_list(self, client: TestClient) -> None:
        response = client.post(GENERATE_URL, json=_payload(skills=[]))

        assert response.status_code == 400
        assert response.json()["code"] == "VALIDATION_FAILED"

    def test_rejects_skills_that_are_only_whitespace(self, client: TestClient) -> None:
        response = client.post(GENERATE_URL, json=_payload(skills=["   ", ""]))

        assert response.status_code == 400

    def test_deduplicates_skills_case_insensitively(self, client: TestClient) -> None:
        body = client.post(
            GENERATE_URL, json=_payload(skills=["AWS", "aws", " AWS "], questionCount=3)
        ).json()

        assert body["skills"] == ["AWS"]

    def test_rejects_an_unknown_experience_level(self, client: TestClient) -> None:
        response = client.post(GENERATE_URL, json=_payload(experienceLevel="PRINCIPAL"))

        assert response.status_code == 400
        assert response.json()["code"] == "VALIDATION_FAILED"

    def test_rejects_a_question_count_above_the_schema_limit(self, client: TestClient) -> None:
        response = client.post(GENERATE_URL, json=_payload(questionCount=99))

        assert response.status_code == 400

    def test_rejects_a_question_count_below_one(self, client: TestClient) -> None:
        response = client.post(GENERATE_URL, json=_payload(questionCount=0))

        assert response.status_code == 400

    def test_validation_errors_name_the_offending_field(self, client: TestClient) -> None:
        body = client.post(GENERATE_URL, json=_payload(roleTitle="")).json()

        assert body["fieldErrors"]
        assert any("roleTitle" in error["field"] for error in body["fieldErrors"])

    def test_error_body_matches_the_shared_shape(self, client: TestClient) -> None:
        body = client.post(GENERATE_URL, json=_payload(questionCount=0)).json()

        assert {"timestamp", "status", "error", "code", "message", "path", "requestId"} <= body.keys()


class TestQuestionSetLookup:
    def test_unknown_set_returns_404(self, client: TestClient) -> None:
        response = client.get(f"/api/v1/questions/sets/{uuid.uuid4()}")

        assert response.status_code == 404
        assert response.json()["code"] == "RESOURCE_NOT_FOUND"

    def test_malformed_uuid_returns_400(self, client: TestClient) -> None:
        response = client.get("/api/v1/questions/sets/not-a-uuid")

        assert response.status_code == 400

    def test_interview_with_no_generated_set_returns_404(self, client: TestClient) -> None:
        response = client.get(f"/api/v1/questions/interview/{uuid.uuid4()}")

        assert response.status_code == 404


class TestInternalApiKey:
    def test_missing_key_is_rejected(self, unauthenticated_client: TestClient) -> None:
        response = unauthenticated_client.post(GENERATE_URL, json=_payload())

        assert response.status_code == 401
        assert response.json()["code"] == "AUTHENTICATION_FAILED"

    def test_wrong_key_is_rejected(self, client: TestClient) -> None:
        response = client.post(
            GENERATE_URL, json=_payload(), headers={"X-Internal-Api-Key": "wrong-key"}
        )

        assert response.status_code == 401

    def test_health_endpoints_need_no_key(self, unauthenticated_client: TestClient) -> None:
        """A kubelet probe cannot present a secret, so probes must stay open."""
        assert unauthenticated_client.get("/health/liveness").status_code == 200
        assert unauthenticated_client.get("/health/readiness").status_code == 200

    def test_metrics_needs_no_key(self, unauthenticated_client: TestClient) -> None:
        assert unauthenticated_client.get("/metrics").status_code == 200
