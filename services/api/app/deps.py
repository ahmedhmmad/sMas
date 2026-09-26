"""اعتماديات مشتركة للمسارات: الـclaims بعد التحقق، وقاعدة البيانات، وتحويل أخطاء قاعدة البيانات."""

from typing import Any

import psycopg
from fastapi import HTTPException, Request

from .db import Database
from .security import bearer_token


def claims(request: Request) -> dict[str, Any]:
    return request.app.state.verifier.verify(bearer_token(request))


def db(request: Request) -> Database:
    return request.app.state.db


# رموز الأخطاء التي ترفعها الدوال المتحكَّم بها (§5.0.2) ← HTTP؛ الرسالة رمز آلة لا نص معروض
_SQLSTATE = {
    "42501": (403, "forbidden"),
    "P0002": (404, "not_found"),
    "23505": (409, "conflict"),
    "22023": (422, "invalid_request"),
    "23514": (422, "invariant_violation"),
    "23503": (422, "invalid_reference"),
}


def http_error(exc: psycopg.Error) -> HTTPException:
    status, detail = _SQLSTATE.get(exc.sqlstate or "", (500, "internal_error"))
    return HTTPException(status_code=status, detail=detail)
