"""Prometheus metrics.

Hand-rolled rather than pulled from an instrumentation library so the cardinality is controlled
explicitly. The `path` label is the *route template* (`/api/v1/questions/sets/{set_id}`), never the
concrete URL: labelling by raw path would create one time series per interview id and eventually take
Prometheus down.
"""

from __future__ import annotations

from prometheus_client import (
    CONTENT_TYPE_LATEST,
    CollectorRegistry,
    Counter,
    Gauge,
    Histogram,
    generate_latest,
)

# A dedicated registry rather than the global default: it keeps test runs isolated and makes it
# impossible for an imported library to silently add series to this service's exposition.
REGISTRY = CollectorRegistry()

HTTP_REQUESTS_TOTAL = Counter(
    "http_requests_total",
    "HTTP requests handled, by method, route template and status class",
    labelnames=("method", "path", "status"),
    registry=REGISTRY,
)

HTTP_REQUEST_DURATION = Histogram(
    "http_request_duration_seconds",
    "HTTP request latency by method and route template",
    labelnames=("method", "path"),
    # Buckets chosen around the SLOs in the Helm chart's alert rules; the default buckets top out
    # too low to see a slow AI generation call.
    buckets=(0.005, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0, 10.0, 30.0, 60.0),
    registry=REGISTRY,
)

HTTP_REQUESTS_IN_PROGRESS = Gauge(
    "http_requests_in_progress",
    "Requests currently being handled",
    registry=REGISTRY,
)

QUESTIONS_GENERATED_TOTAL = Counter(
    "ai_questions_generated_total",
    "Interview questions generated, by provider and outcome",
    labelnames=("provider", "outcome"),
    registry=REGISTRY,
)

GENERATION_DURATION = Histogram(
    "ai_generation_duration_seconds",
    "Time spent inside the question generator, excluding persistence",
    labelnames=("provider",),
    buckets=(0.001, 0.01, 0.05, 0.25, 0.5, 1.0, 2.5, 5.0, 10.0, 20.0, 30.0, 60.0),
    registry=REGISTRY,
)

EVALUATIONS_TOTAL = Counter(
    "ai_evaluations_total",
    "Answer evaluations performed, by provider and outcome",
    labelnames=("provider", "outcome"),
    registry=REGISTRY,
)

TOKENS_CONSUMED_TOTAL = Counter(
    "ai_tokens_consumed_total",
    "Tokens reported by the AI provider, by model and kind",
    labelnames=("model", "kind"),
    registry=REGISTRY,
)

DATABASE_ERRORS_TOTAL = Counter(
    "database_errors_total",
    "Database operations that raised, by operation",
    labelnames=("operation",),
    registry=REGISTRY,
)


def render_metrics() -> tuple[bytes, str]:
    """Serialises the registry for the `/metrics` endpoint.

    The content type must match what `generate_latest` actually produced. This previously paired the
    plain-text serialiser with the OpenMetrics content type, and the mismatch is invisible from the
    outside: the endpoint answers 200 with correct-looking metrics, and Prometheus - trusting the
    header - runs its OpenMetrics parser, which requires a trailing `# EOF` the plain-text format
    never writes. The target goes DOWN with `data does not end with # EOF` and no mention of the
    header that caused it.
    """
    return generate_latest(REGISTRY), CONTENT_TYPE_LATEST


def status_class(status_code: int) -> str:
    """Collapses a status code to its class (`2xx`, `4xx`, ...).

    Keeps the label set at five values instead of one per code, which is enough to alert on and
    keeps `http_requests_total` cheap.
    """
    return f"{status_code // 100}xx"
