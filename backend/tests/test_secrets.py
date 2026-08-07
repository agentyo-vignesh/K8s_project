"""Tests for secret resolution.

The AWS provider is exercised with a stubbed boto3 client. That is deliberate: the point of these
tests is the contract between this service and the shape of a Secrets Manager payload, and the
credential chain that makes IRSA work is boto3's job, not ours to re-test.
"""

from __future__ import annotations

import json
from typing import Any

import pytest
from app.core.config import Settings
from app.core.secrets import (
    AwsSecretsManagerProvider,
    DatabaseCredentials,
    EnvironmentSecretProvider,
    SecretResolutionError,
    build_secret_provider,
)


def _settings(**overrides: Any) -> Settings:
    base: dict[str, Any] = {
        "APP_ENV": "test",
        "SECRETS_PROVIDER": "env",
        "DB_HOST": "db.internal",
        "DB_PORT": 5432,
        "DB_NAME": "ai_interview",
        "DB_USERNAME": "app_user",
        "DB_PASSWORD": "s3cret",
        "INTERNAL_API_KEY": "a-sufficiently-long-key",
    }
    base.update(overrides)
    return Settings(**base)


class TestDatabaseCredentials:
    def test_builds_a_psycopg_url(self) -> None:
        url = DatabaseCredentials("db.internal", 5432, "ai_interview", "app_user", "s3cret").sqlalchemy_url()

        assert url.startswith("postgresql+psycopg://app_user:s3cret@db.internal:5432/ai_interview")

    def test_percent_encodes_special_characters_in_the_password(self) -> None:
        """A rotated password containing @ or / would otherwise corrupt the URL."""
        url = DatabaseCredentials(
            "db.internal", 5432, "ai_interview", "app_user", "p@ss/w:rd"
        ).sqlalchemy_url()

        assert "p%40ss%2Fw%3Ard" in url
        assert "@db.internal" in url

    def test_repr_does_not_leak_the_password(self) -> None:
        credentials = DatabaseCredentials("db.internal", 5432, "db", "user", "topsecret")

        assert "topsecret" not in repr(credentials)
        assert "topsecret" not in credentials.describe()


class TestEnvironmentSecretProvider:
    def test_reads_database_credentials_from_configuration(self) -> None:
        provider = EnvironmentSecretProvider(_settings())

        credentials = provider.database_credentials()

        assert credentials.host == "db.internal"
        assert credentials.username == "app_user"
        assert provider.provider_id == "env"

    def test_rejects_a_short_internal_api_key(self) -> None:
        provider = EnvironmentSecretProvider(_settings(INTERNAL_API_KEY="short"))

        with pytest.raises(SecretResolutionError, match="at least"):
            provider.application_secrets()

    def test_is_the_default_provider(self) -> None:
        assert build_secret_provider(_settings()).provider_id == "env"


class _StubSecretsManager:
    """Minimal stand-in for the boto3 Secrets Manager client."""

    def __init__(self, secrets: dict[str, str]) -> None:
        self._secrets = secrets
        self.call_count = 0

    def get_secret_value(self, SecretId: str) -> dict[str, str]:  # noqa: N803 - boto3 API casing
        self.call_count += 1
        if SecretId not in self._secrets:
            raise RuntimeError("ResourceNotFoundException")
        return {"SecretString": self._secrets[SecretId]}


@pytest.fixture()
def aws_provider(monkeypatch: pytest.MonkeyPatch) -> tuple[AwsSecretsManagerProvider, _StubSecretsManager]:
    stub = _StubSecretsManager(
        {
            "ai-interview/test/database": json.dumps(
                {
                    "username": "rds_user",
                    "password": "rotated-secret",
                    "host": "aip.abc123.ap-south-1.rds.amazonaws.com",
                    "port": 5432,
                    "dbname": "ai_interview",
                    "engine": "postgres",
                }
            ),
            "ai-interview/test/application": json.dumps(
                {"jwtSigningKey": "x" * 48, "aiServiceApiKey": "internal-key-from-secrets-manager"}
            ),
        }
    )

    settings = _settings(
        SECRETS_PROVIDER="aws",
        AWS_DATABASE_SECRET_ID="ai-interview/test/database",
        AWS_APPLICATION_SECRET_ID="ai-interview/test/application",
        AWS_REGION="ap-south-1",
    )

    import boto3

    monkeypatch.setattr(boto3, "client", lambda *args, **kwargs: stub)
    return AwsSecretsManagerProvider(settings), stub


class TestAwsSecretsManagerProvider:
    def test_parses_the_rds_managed_secret_shape(
        self, aws_provider: tuple[AwsSecretsManagerProvider, _StubSecretsManager]
    ) -> None:
        """A secret created by `--manage-master-user-password` must work unmodified."""
        provider, _ = aws_provider

        credentials = provider.database_credentials()

        assert credentials.host == "aip.abc123.ap-south-1.rds.amazonaws.com"
        assert credentials.username == "rds_user"
        assert credentials.password == "rotated-secret"
        assert credentials.database == "ai_interview"
        assert credentials.port == 5432

    def test_reads_the_internal_api_key(
        self, aws_provider: tuple[AwsSecretsManagerProvider, _StubSecretsManager]
    ) -> None:
        provider, _ = aws_provider

        secrets = provider.application_secrets()

        assert secrets.internal_api_key == "internal-key-from-secrets-manager"

    def test_caches_within_the_ttl(
        self, aws_provider: tuple[AwsSecretsManagerProvider, _StubSecretsManager]
    ) -> None:
        """A hot path must not turn into a Secrets Manager API call."""
        provider, stub = aws_provider

        provider.database_credentials()
        provider.database_credentials()
        provider.database_credentials()

        assert stub.call_count == 1

    def test_missing_secret_id_fails_at_construction(self) -> None:
        """A misconfiguration should stop the pod, not surface on the first request."""
        with pytest.raises(SecretResolutionError, match="AWS_DATABASE_SECRET_ID"):
            AwsSecretsManagerProvider(_settings(SECRETS_PROVIDER="aws"))

    def test_unreadable_secret_names_irsa_as_the_likely_cause(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        stub = _StubSecretsManager({})
        import boto3

        monkeypatch.setattr(boto3, "client", lambda *args, **kwargs: stub)
        provider = AwsSecretsManagerProvider(
            _settings(
                SECRETS_PROVIDER="aws",
                AWS_DATABASE_SECRET_ID="missing",
                AWS_APPLICATION_SECRET_ID="also-missing",
            )
        )

        with pytest.raises(SecretResolutionError, match="IRSA"):
            provider.database_credentials()

    def test_malformed_json_does_not_echo_the_payload(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        stub = _StubSecretsManager({"broken": "this-is-not-json{{{"})
        import boto3

        monkeypatch.setattr(boto3, "client", lambda *args, **kwargs: stub)
        provider = AwsSecretsManagerProvider(
            _settings(
                SECRETS_PROVIDER="aws",
                AWS_DATABASE_SECRET_ID="broken",
                AWS_APPLICATION_SECRET_ID="broken",
            )
        )

        with pytest.raises(SecretResolutionError) as exc_info:
            provider.database_credentials()

        assert "this-is-not-json" not in str(exc_info.value)
