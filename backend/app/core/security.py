"""Service-to-service authentication.

This service is reachable only from the middleware over a ClusterIP Service; it is never exposed
through the Ingress. The shared key is a second line of defence so that a compromised pod elsewhere in
the namespace cannot generate questions (and spend tokens) just by reaching the port.
"""

from __future__ import annotations

import hmac
import logging

from fastapi import Header

from app.core.errors import UnauthorizedError
from app.core.secrets import get_secret_provider

logger = logging.getLogger(__name__)

INTERNAL_API_KEY_HEADER = "X-Internal-Api-Key"


async def require_internal_api_key(
    x_internal_api_key: str | None = Header(
        default=None,
        alias=INTERNAL_API_KEY_HEADER,
        description="Shared key issued to the middleware",
    ),
) -> None:
    """FastAPI dependency guarding every business endpoint.

    Health and metrics endpoints deliberately do not use it: a kubelet probe and a Prometheus scrape
    have no way to present a secret.
    """
    if not x_internal_api_key:
        raise UnauthorizedError(f"{INTERNAL_API_KEY_HEADER} header is required")

    expected = get_secret_provider().application_secrets().internal_api_key

    # Constant-time comparison: a plain `==` short-circuits on the first differing byte, which leaks
    # a timing signal an attacker can use to recover the key one character at a time.
    if not hmac.compare_digest(x_internal_api_key, expected):
        logger.warning("Rejected a request with an invalid internal API key")
        raise UnauthorizedError("Invalid internal API key")
