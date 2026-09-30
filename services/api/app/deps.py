"""اعتماديات مشتركة للمسارات: الـclaims بعد التحقق، وقاعدة البيانات، وتحويل أخطاء قاعدة البيانات."""

from typing import Any

import psycopg
from fastapi import HTTPException, Request

from .db import Database
from .host_context import HostContext
from .security import bearer_token


def claims(request: Request) -> dict[str, Any]:
    return request.app.state.verifier.verify(bearer_token(request))


def db(request: Request) -> Database:
    return request.app.state.db


def login_context(request: Request) -> HostContext | None:
    """F3: سياق الدخول من `Origin` وحده — «أين يُبحث عن الحساب»، لا سلطة. سياق Tenant أو مدرسة، وإلا None
    (غائب، خارج الأصل الأساسي، أو host المنصة) ← فشل عام من المسار نفسه، بلا كشف وجود."""
    ctx = request.app.state.settings.origin_base.context(request.headers.get("origin"))
    return ctx if ctx is not None and ctx.kind in ("tenant", "school") else None


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
