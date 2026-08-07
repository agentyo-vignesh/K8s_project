"""Secret resolution.

Mirrors the middleware's `SecretService`: one implementation reads environment variables, the other
reads AWS Secrets Manager through boto3's default credential chain. That chain is what makes IRSA
work in-cluster (it finds `AWS_WEB_IDENTITY_TOKEN_FILE` and `AWS_ROLE_ARN` projected by the
ServiceAccount annotation and calls `sts:AssumeRoleWithWebIdentity`), and it finds a developer's SSO
profile locally. No access key appears in this module, in configuration, or in the image.
"""

from __future__ import annotations

import json
import logging
import time
from abc import ABC, abstractmethod
from dataclasses import dataclass
from functools import lru_cache
from typing import Any
from urllib.parse import quote_plus

from app.core.config import SecretsProvider, Settings, get_settings

logger = logging.getLogger(__name__)

_MIN_INTERNAL_KEY_LENGTH = 16


class SecretResolutionError(RuntimeError):
    """Raised when secret material cannot be resolved.

    Deliberately fatal at startup: a misconfigured IRSA role should surface as a pod that never
    becomes ready, not as a service that accepts traffic and then fails every request.
    """


@dataclass(frozen=True)
class DatabaseCredentials:
    """Everything needed to connect, resolved from a single source so the parts cannot mismatch."""

    host: str
    port: int
    database: str
    username: str
    password: str
    sslmode: str = "prefer"

    def sqlalchemy_url(self) -> str:
        """psycopg 3 URL with credentials percent-encoded.

        Quoting matters: a rotated password containing `@`, `/` or `:` would otherwise silently
        corrupt the URL and produce a connection error that looks like a wrong host.
        """
        user = quote_plus(self.username)
        secret = quote_plus(self.password)
        return (
            f"postgresql+psycopg://{user}:{secret}@{self.host}:{self.port}/{self.database}"
            f"?sslmode={self.sslmode}"
        )

    def describe(self) -> str:
        """Safe for logs."""
        return f"{self.username}@{self.host}:{self.port}/{self.database}"

    def __repr__(self) -> str:  # pragma: no cover - defensive against accidental logging
        return f"DatabaseCredentials({self.describe()}, password=***)"


@dataclass(frozen=True)
class ApplicationSecrets:
    """Non-database secret material."""

    internal_api_key: str
    openai_api_key: str | None = None

    def __repr__(self) -> str:  # pragma: no cover - defensive against accidental logging
        return "ApplicationSecrets(internal_api_key=***, openai_api_key=***)"


class SecretProvider(ABC):
    """Source of secret material. Selected by `SECRETS_PROVIDER`; callers never branch on it."""

    @property
    @abstractmethod
    def provider_id(self) -> str:
        """Identifier for logs and `/api/v1/info`."""

    @abstractmethod
    def database_credentials(self) -> DatabaseCredentials:
        """Raise `SecretResolutionError` if unavailable or incomplete."""

    @abstractmethod
    def application_secrets(self) -> ApplicationSecrets:
        """Raise `SecretResolutionError` if unavailable or incomplete."""


class EnvironmentSecretProvider(SecretProvider):
    """Reads secrets from the process environment.

    For local development, Docker Compose and CI. In production this would put credentials in the
    pod spec, which is why `values-prod.yaml` selects the AWS provider instead.
    """

    def __init__(self, settings: Settings) -> None:
        self._settings = settings
        logger.info(
            "Secret provider 'env' active; database target %s:%s/%s",
            settings.db_host,
            settings.db_port,
            settings.db_name,
        )

    @property
    def provider_id(self) -> str:
        return "env"

    def database_credentials(self) -> DatabaseCredentials:
        return DatabaseCredentials(
            host=self._settings.db_host,
            port=self._settings.db_port,
            database=self._settings.db_name,
            username=self._settings.db_username,
            password=self._settings.db_password,
            sslmode=self._settings.db_sslmode,
        )

    def application_secrets(self) -> ApplicationSecrets:
        key = self._settings.internal_api_key
        if len(key) < _MIN_INTERNAL_KEY_LENGTH:
            raise SecretResolutionError(
                f"INTERNAL_API_KEY must be at least {_MIN_INTERNAL_KEY_LENGTH} characters"
            )
        return ApplicationSecrets(
            internal_api_key=key,
            openai_api_key=self._settings.openai_api_key,
        )


class AwsSecretsManagerProvider(SecretProvider):
    """Reads secrets from AWS Secrets Manager.

    Values are cached for `SECRETS_CACHE_TTL_SECONDS` so a rotation is picked up without a restart
    while no request path turns into an AWS API call.
    """

    def __init__(self, settings: Settings) -> None:
        # Imported lazily so the dev path never pays boto3's import cost and a missing boto3
        # cannot break local development.
        import boto3  # noqa: PLC0415

        if not settings.aws_database_secret_id:
            raise SecretResolutionError(
                "AWS_DATABASE_SECRET_ID is required when SECRETS_PROVIDER=aws"
            )
        if not settings.aws_application_secret_id:
            raise SecretResolutionError(
                "AWS_APPLICATION_SECRET_ID is required when SECRETS_PROVIDER=aws"
            )

        client_kwargs: dict[str, Any] = {}
        if settings.aws_region:
            client_kwargs["region_name"] = settings.aws_region

        # No credentials passed: boto3's default chain resolves IRSA in-cluster.
        self._client = boto3.client("secretsmanager", **client_kwargs)
        self._settings = settings
        self._cache: dict[str, tuple[float, dict[str, Any]]] = {}
        logger.info(
            "Secret provider 'aws' active; databaseSecretId=%s applicationSecretId=%s ttl=%ss",
            settings.aws_database_secret_id,
            settings.aws_application_secret_id,
            settings.secrets_cache_ttl_seconds,
        )

    @property
    def provider_id(self) -> str:
        return "aws"

    def database_credentials(self) -> DatabaseCredentials:
        secret_id = self._settings.aws_database_secret_id
        assert secret_id is not None  # guaranteed by __init__
        payload = self._fetch(secret_id)

        # Field names match what RDS-managed rotation writes, so a secret created by
        # `--manage-master-user-password` works unmodified.
        host = payload.get("host")
        port = payload.get("port")
        database = payload.get("dbname")
        username = payload.get("username")
        password = payload.get("password")

        for field, value in (
            ("host", host),
            ("dbname", database),
            ("username", username),
            ("password", password),
        ):
            if not value:
                raise SecretResolutionError(
                    f"Secret {secret_id!r} is missing required field {field!r}"
                )
        try:
            port_number = int(port) if port is not None else 5432
        except (TypeError, ValueError) as exc:
            raise SecretResolutionError(
                f"Secret {secret_id!r} has a non-numeric 'port' value"
            ) from exc

        credentials = DatabaseCredentials(
            host=str(host),
            port=port_number,
            database=str(database),
            username=str(username),
            password=str(password),
            sslmode=self._settings.db_sslmode,
        )
        logger.info("Resolved database credentials from Secrets Manager: %s", credentials.describe())
        return credentials

    def application_secrets(self) -> ApplicationSecrets:
        secret_id = self._settings.aws_application_secret_id
        assert secret_id is not None  # guaranteed by __init__
        payload = self._fetch(secret_id)

        internal_key = payload.get("aiServiceApiKey") or payload.get("internalApiKey")
        if not internal_key:
            raise SecretResolutionError(
                f"Secret {secret_id!r} must contain 'aiServiceApiKey'"
            )
        # Optional: only required when AI_PROVIDER=openai, which is checked by the generator.
        openai_key = payload.get("openaiApiKey") or self._settings.openai_api_key
        return ApplicationSecrets(internal_api_key=str(internal_key), openai_api_key=openai_key)

    def _fetch(self, secret_id: str) -> dict[str, Any]:
        cached = self._cache.get(secret_id)
        if cached and time.monotonic() < cached[0]:
            return cached[1]

        try:
            response = self._client.get_secret_value(SecretId=secret_id)
        except Exception as exc:  # boto3 raises client-specific subclasses
            # An AccessDenied here is almost always a wrong IRSA trust policy or a missing
            # secretsmanager:GetSecretValue permission. Say so, because the raw boto3 message sends
            # people hunting for missing access keys instead.
            raise SecretResolutionError(
                f"Failed to read secret {secret_id!r} from Secrets Manager. Verify the IRSA role "
                "annotation on the ServiceAccount and that the role allows "
                "secretsmanager:GetSecretValue on this secret."
            ) from exc

        raw = response.get("SecretString")
        if not raw:
            raise SecretResolutionError(
                f"Secret {secret_id!r} has no SecretString (binary secrets are not supported)"
            )
        try:
            payload = json.loads(raw)
        except json.JSONDecodeError as exc:
            # The payload is never included in the message so a malformed secret is not logged.
            raise SecretResolutionError(f"Secret {secret_id!r} is not valid JSON") from exc
        if not isinstance(payload, dict):
            raise SecretResolutionError(f"Secret {secret_id!r} must be a JSON object")

        expiry = time.monotonic() + self._settings.secrets_cache_ttl_seconds
        self._cache[secret_id] = (expiry, payload)
        return payload


def build_secret_provider(settings: Settings) -> SecretProvider:
    """Selects the provider. The only place in the codebase that knows both exist."""
    if settings.secrets_provider is SecretsProvider.AWS:
        return AwsSecretsManagerProvider(settings)
    return EnvironmentSecretProvider(settings)


@lru_cache(maxsize=1)
def get_secret_provider() -> SecretProvider:
    """Process-wide provider; built once so the AWS client and its cache are shared."""
    return build_secret_provider(get_settings())
