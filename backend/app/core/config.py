"""Typed application configuration.

Every value comes from an environment variable, so the same image runs on Docker Compose and on
Kubernetes with only its ConfigMap and Secret changing. Validation happens at import time: a bad
value means the process exits immediately instead of failing on the first request.
"""

from __future__ import annotations

from enum import StrEnum
from functools import lru_cache

from pydantic import Field, field_validator
from pydantic_settings import BaseSettings, SettingsConfigDict


class Environment(StrEnum):
    """Deployment environment. Drives log format and documentation exposure."""

    DEV = "dev"
    TEST = "test"
    PROD = "prod"


class SecretsProvider(StrEnum):
    """Where secrets come from. `aws` uses Secrets Manager via the default credential chain."""

    ENV = "env"
    AWS = "aws"


class AiProvider(StrEnum):
    """Which question generator to use."""

    MOCK = "mock"
    OPENAI = "openai"


class Settings(BaseSettings):
    """Runtime configuration, bound from the process environment."""

    model_config = SettingsConfigDict(
        env_file=None,
        case_sensitive=False,
        extra="ignore",
    )

    # ---------------------------------------------------------------- application
    app_env: Environment = Field(default=Environment.DEV, alias="APP_ENV")
    service_name: str = Field(default="ai-interview-ai-service", alias="SERVICE_NAME")
    server_port: int = Field(default=8000, ge=1, le=65535, alias="SERVER_PORT")
    log_level: str = Field(default="INFO", alias="LOG_LEVEL")
    api_prefix: str = Field(default="/api/v1", alias="API_PREFIX")

    # ---------------------------------------------------------------- secrets
    secrets_provider: SecretsProvider = Field(
        default=SecretsProvider.ENV, alias="SECRETS_PROVIDER"
    )
    aws_region: str | None = Field(default=None, alias="AWS_REGION")
    aws_database_secret_id: str | None = Field(default=None, alias="AWS_DATABASE_SECRET_ID")
    aws_application_secret_id: str | None = Field(default=None, alias="AWS_APPLICATION_SECRET_ID")
    secrets_cache_ttl_seconds: int = Field(
        default=600, ge=0, alias="SECRETS_CACHE_TTL_SECONDS"
    )

    # ---------------------------------------------------------------- database (env provider)
    db_host: str = Field(default="localhost", alias="DB_HOST")
    db_port: int = Field(default=5432, ge=1, le=65535, alias="DB_PORT")
    db_name: str = Field(default="ai_interview", alias="DB_NAME")
    db_username: str = Field(default="ai_interview_app", alias="DB_USERNAME")
    db_password: str = Field(default="change-me-locally", alias="DB_PASSWORD")
    db_sslmode: str = Field(default="prefer", alias="DB_SSLMODE")
    db_pool_size: int = Field(default=5, ge=1, le=50, alias="DB_POOL_SIZE")
    db_max_overflow: int = Field(default=5, ge=0, le=50, alias="DB_MAX_OVERFLOW")
    db_pool_timeout_seconds: int = Field(default=10, ge=1, alias="DB_POOL_TIMEOUT_SECONDS")
    db_pool_recycle_seconds: int = Field(default=1800, ge=60, alias="DB_POOL_RECYCLE_SECONDS")
    db_statement_timeout_ms: int = Field(
        default=15000, ge=1000, alias="DB_STATEMENT_TIMEOUT_MS"
    )

    # ---------------------------------------------------------------- service-to-service auth
    internal_api_key: str = Field(
        default="local-dev-internal-api-key", alias="INTERNAL_API_KEY"
    )

    # ---------------------------------------------------------------- AI provider
    ai_provider: AiProvider = Field(default=AiProvider.MOCK, alias="AI_PROVIDER")
    openai_api_key: str | None = Field(default=None, alias="OPENAI_API_KEY")
    openai_model: str = Field(default="gpt-4o-mini", alias="OPENAI_MODEL")
    openai_timeout_seconds: float = Field(default=30.0, gt=0, alias="OPENAI_TIMEOUT_SECONDS")
    openai_max_retries: int = Field(default=1, ge=0, le=5, alias="OPENAI_MAX_RETRIES")
    openai_temperature: float = Field(default=0.4, ge=0.0, le=2.0, alias="OPENAI_TEMPERATURE")

    # ---------------------------------------------------------------- limits
    max_questions_per_request: int = Field(
        default=20, ge=1, le=50, alias="MAX_QUESTIONS_PER_REQUEST"
    )

    # ---------------------------------------------------------------- schema management
    # Flyway in the middleware owns the schema. This exists only so the test suite can build
    # tables in an in-memory database; enabling it against PostgreSQL would put two services in
    # charge of DDL.
    create_schema_on_startup: bool = Field(default=False, alias="CREATE_SCHEMA_ON_STARTUP")

    @field_validator("log_level")
    @classmethod
    def _normalise_log_level(cls, value: str) -> str:
        level = value.strip().upper()
        allowed = {"CRITICAL", "ERROR", "WARNING", "INFO", "DEBUG"}
        if level not in allowed:
            raise ValueError(f"LOG_LEVEL must be one of {sorted(allowed)}, got {value!r}")
        return level

    @field_validator("api_prefix")
    @classmethod
    def _normalise_prefix(cls, value: str) -> str:
        prefix = "/" + value.strip().strip("/")
        return prefix

    @property
    def is_production(self) -> bool:
        return self.app_env is Environment.PROD

    @property
    def docs_enabled(self) -> bool:
        """Interactive docs are for developers; production exposes the schema but not the UI."""
        return self.app_env is not Environment.PROD

    @property
    def json_logging(self) -> bool:
        """Human-readable logs on a laptop, structured JSON everywhere a log shipper reads them."""
        return self.app_env is not Environment.DEV


@lru_cache(maxsize=1)
def get_settings() -> Settings:
    """Process-wide settings.

    Cached so configuration is parsed and validated exactly once. Tests clear the cache after
    changing the environment via `get_settings.cache_clear()`.
    """
    return Settings()
