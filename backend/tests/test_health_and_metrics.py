"""Tests for the operational endpoints.

These back the Kubernetes probes and the Prometheus scrape, so their shape is a deployment contract:
if the readiness status code or the metric names change, the chart's probes and alert rules break.
"""

from __future__ import annotations

from fastapi.testclient import TestClient


class TestHealthEndpoints:
    def test_liveness_reports_up(self, client: TestClient) -> None:
        response = client.get("/health/liveness")

        assert response.status_code == 200
        assert response.json()["status"] == "UP"

    def test_liveness_does_not_report_dependency_checks(self, client: TestClient) -> None:
        """Liveness must not depend on the database, or a blip restarts every pod."""
        assert client.get("/health/liveness").json()["checks"] == {}

    def test_readiness_checks_the_database(self, client: TestClient) -> None:
        body = client.get("/health/readiness").json()

        assert body["status"] == "UP"
        assert body["checks"]["database"] == "UP"

    def test_readiness_reports_503_when_the_database_is_gone(self, client: TestClient) -> None:
        """Kubernetes must pull the pod from the Service, not restart it."""
        from app.db.session import get_engine

        get_engine().dispose()
        # Point the engine at a database that cannot be reached so the check genuinely fails.
        from app.db.session import set_engine
        from sqlalchemy import create_engine

        set_engine(create_engine("postgresql+psycopg://nobody@127.0.0.1:1/none", connect_args={}))

        response = client.get("/health/readiness")

        assert response.status_code == 503
        assert response.json()["checks"]["database"] == "DOWN"

    def test_health_alias_matches_readiness(self, client: TestClient) -> None:
        assert client.get("/health").json()["checks"] == client.get("/health/readiness").json()["checks"]


class TestMetrics:
    def test_exposes_prometheus_metrics(self, client: TestClient) -> None:
        response = client.get("/metrics")

        assert response.status_code == 200
        assert "http_requests_total" in response.text

    def test_content_type_matches_the_body_format(self, client: TestClient) -> None:
        """Prometheus picks its parser from the header, not from the body.

        This shipped broken once: the plain-text serialiser paired with the OpenMetrics content
        type. Nothing visible from outside was wrong - 200, correct metrics - and Prometheus
        marked the target DOWN with `data does not end with # EOF`, an error that never mentions
        the header that caused it. Only OpenMetrics writes that terminator.
        """
        response = client.get("/metrics")
        content_type = response.headers["content-type"]

        if "openmetrics" in content_type:
            assert response.text.endswith("# EOF\n"), "openmetrics content type without # EOF"
        else:
            assert content_type.startswith("text/plain"), content_type
            assert not response.text.endswith("# EOF\n"), "text/plain must not end with # EOF"

    def test_records_generation_metrics(self, client: TestClient) -> None:
        client.post(
            "/api/v1/questions/generate",
            json={
                "roleTitle": "SRE",
                "experienceLevel": "MID",
                "skills": ["Prometheus"],
                "questionCount": 2,
            },
        )

        body = client.get("/metrics").text

        assert "ai_questions_generated_total" in body
        assert 'provider="mock"' in body

    def test_labels_by_route_template_not_by_concrete_path(self, client: TestClient) -> None:
        """Labelling by raw path would create one time series per interview id."""
        client.get("/api/v1/questions/sets/11111111-1111-1111-1111-111111111111")

        body = client.get("/metrics").text

        assert "/api/v1/questions/sets/{set_id}" in body
        assert "11111111-1111-1111-1111-111111111111" not in body


class TestServiceInfo:
    def test_reports_the_active_providers(self, client: TestClient) -> None:
        body = client.get("/api/v1/info").json()

        assert body["secretsProvider"] == "env"
        assert body["aiProvider"] == "mock"
        assert body["environment"] == "test"

    def test_never_exposes_secret_material(self, client: TestClient) -> None:
        body = client.get("/api/v1/info").text

        assert "test-internal-api-key-value" not in body

    def test_requires_the_internal_api_key(self, unauthenticated_client: TestClient) -> None:
        assert unauthenticated_client.get("/api/v1/info").status_code == 401
