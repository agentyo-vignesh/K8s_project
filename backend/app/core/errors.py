"""Error types and the single error response shape.

The JSON body matches the middleware's `ErrorResponse` field for field, so a client sees one error
contract regardless of which service answered.
"""

from __future__ import annotations

from datetime import UTC, datetime
from typing import Any

from fastapi import Request, status
from fastapi.encoders import jsonable_encoder
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
from starlette.exceptions import HTTPException as StarletteHTTPException

from app.core.logging_config import request_id_var


class ErrorCode:
    """Stable machine-readable tokens. Clients branch on these, not on message text."""

    VALIDATION_FAILED = "VALIDATION_FAILED"
    BAD_REQUEST = "BAD_REQUEST"
    RESOURCE_NOT_FOUND = "RESOURCE_NOT_FOUND"
    AUTHENTICATION_FAILED = "AUTHENTICATION_FAILED"
    AI_PROVIDER_ERROR = "AI_PROVIDER_ERROR"
    DATABASE_ERROR = "DATABASE_ERROR"
    INTERNAL_ERROR = "INTERNAL_ERROR"


class ServiceError(Exception):
    """Base for failures that map to a deliberate HTTP response."""

    status_code: int = status.HTTP_500_INTERNAL_SERVER_ERROR
    code: str = ErrorCode.INTERNAL_ERROR

    def __init__(self, message: str) -> None:
        super().__init__(message)
        self.message = message


class NotFoundError(ServiceError):
    status_code = status.HTTP_404_NOT_FOUND
    code = ErrorCode.RESOURCE_NOT_FOUND


class BadRequestError(ServiceError):
    status_code = status.HTTP_400_BAD_REQUEST
    code = ErrorCode.BAD_REQUEST


class UnauthorizedError(ServiceError):
    status_code = status.HTTP_401_UNAUTHORIZED
    code = ErrorCode.AUTHENTICATION_FAILED


class AiProviderError(ServiceError):
    """The upstream model provider failed.

    502 rather than 500: the fault is upstream, and the distinction lets the middleware's retry
    policy and any alert rule tell a provider outage from a bug in this service.
    """

    status_code = status.HTTP_502_BAD_GATEWAY
    code = ErrorCode.AI_PROVIDER_ERROR


class DatabaseError(ServiceError):
    status_code = status.HTTP_503_SERVICE_UNAVAILABLE
    code = ErrorCode.DATABASE_ERROR


def error_body(
    request: Request,
    status_code: int,
    code: str,
    message: str,
    field_errors: list[dict[str, Any]] | None = None,
) -> dict[str, Any]:
    """Builds the response body. Shape matches the middleware's `ErrorResponse`."""
    body: dict[str, Any] = {
        "timestamp": datetime.now(tz=UTC).isoformat(),
        "status": status_code,
        "error": _reason_phrase(status_code),
        "code": code,
        "message": message,
        "path": request.url.path,
        "requestId": request_id_var.get(),
    }
    if field_errors:
        body["fieldErrors"] = field_errors
    return body


def _reason_phrase(status_code: int) -> str:
    return _PHRASES.get(status_code, "Error")


_PHRASES = {
    400: "Bad Request",
    401: "Unauthorized",
    403: "Forbidden",
    404: "Not Found",
    405: "Method Not Allowed",
    409: "Conflict",
    413: "Payload Too Large",
    422: "Unprocessable Entity",
    500: "Internal Server Error",
    502: "Bad Gateway",
    503: "Service Unavailable",
}


async def service_error_handler(request: Request, exc: Exception) -> JSONResponse:
    """Renders a `ServiceError` using the status and code carried on the exception."""
    assert isinstance(exc, ServiceError)
    return JSONResponse(
        status_code=exc.status_code,
        content=error_body(request, exc.status_code, exc.code, exc.message),
    )


async def http_exception_handler(request: Request, exc: Exception) -> JSONResponse:
    """Renders Starlette's own 404s and 405s in the same shape as everything else."""
    assert isinstance(exc, StarletteHTTPException)
    detail = exc.detail if isinstance(exc.detail, str) else "Request could not be completed"
    code = (
        ErrorCode.RESOURCE_NOT_FOUND
        if exc.status_code == status.HTTP_404_NOT_FOUND
        else ErrorCode.BAD_REQUEST
    )
    return JSONResponse(
        status_code=exc.status_code,
        content=error_body(request, exc.status_code, code, detail),
        headers=getattr(exc, "headers", None),
    )


async def validation_error_handler(request: Request, exc: Exception) -> JSONResponse:
    """Turns Pydantic's validation report into `fieldErrors`.

    Returns 400 rather than FastAPI's default 422 so that a malformed request has the same status
    here as it does in the middleware.
    """
    assert isinstance(exc, RequestValidationError)
    field_errors = [
        {
            # Drop the leading "body"/"query" location segment: the caller cares about the field.
            "field": ".".join(str(part) for part in error["loc"][1:]) or str(error["loc"][0]),
            "message": error["msg"],
            "rejectedValue": jsonable_encoder(error.get("input")),
        }
        for error in exc.errors()
    ]
    return JSONResponse(
        status_code=status.HTTP_400_BAD_REQUEST,
        content=error_body(
            request,
            status.HTTP_400_BAD_REQUEST,
            ErrorCode.VALIDATION_FAILED,
            "Request validation failed",
            field_errors,
        ),
    )


async def unhandled_exception_handler(request: Request, exc: Exception) -> JSONResponse:
    """Last resort.

    The traceback is logged (with the request id) but never returned, so an internal detail cannot
    leak to a caller.
    """
    import logging

    logging.getLogger(__name__).exception(
        "Unhandled %s at %s %s", type(exc).__name__, request.method, request.url.path
    )
    return JSONResponse(
        status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
        content=error_body(
            request,
            status.HTTP_500_INTERNAL_SERVER_ERROR,
            ErrorCode.INTERNAL_ERROR,
            "An unexpected error occurred. Quote the requestId when reporting this.",
        ),
    )
