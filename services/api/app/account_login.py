"""دخول حسابات Tenant — ولي الأمر (بالهاتف) والموظف (بالبريد): OTP وكلمة المرور (D3).

  POST /auth/otp/request   {tenant, kind, contact}          ← 202 {"status":"sent"} دائماً
  POST /auth/otp/verify    {tenant, kind, contact, code}    ← الجلسة أو 401 invalid_credentials
  POST /auth/password/login {tenant, kind, contact, password} ← الجلسة أو 401 invalid_credentials

- **قاعدة البيانات تقرر** أي حساب ومتى يُقبل الرمز/الكلمة (M26: otp_issue، otp_verify، password_login_*)؛
  I1: الحساب الموقوف لا يبدأ مصادقة أصلاً. FastAPI يرسل الرمز ويصدر الجلسة عبر Supabase Auth — لا JWT هنا.
- **لا كشف:** الرد نفسه لكل حالة (غير موجود، موجود في Tenant آخر فقط، موقوف، مقفل، رمز خاطئ)؛ ولا رسالة
  تُرسل لحساب غير موجود في هذا الـTenant.
- الـtenant يحدد **أين يُبحث** فقط (F3: من الـsubdomain) — الجلسة هوية الحساب وحده.
- ثالث موضع يبدّل إلى دور `service_role` (بعد audit.py و student_login.py) — لاستدعاء دوال M26 وحدها.
"""

import uuid

import httpx
from fastapi import APIRouter, Depends, HTTPException, Request
from pydantic import BaseModel, Field

from .auth_admin import SESSION_FIELDS, account_email
from .db import Database
from .deps import db

router = APIRouter()

_INVALID = HTTPException(status_code=401, detail="invalid_credentials")
_TOO_MANY = HTTPException(status_code=429, detail="too_many_attempts")
_NO_CHANNEL = HTTPException(status_code=503, detail="otp_channel_unavailable")


class _Base(BaseModel):
    tenant: str = Field(min_length=1, max_length=32)
    kind: str = Field(pattern="^(guardian|staff)$")
    contact: str = Field(min_length=3, max_length=254)


class OtpRequest(_Base):
    pass


class OtpVerify(_Base):
    code: str = Field(min_length=1, max_length=12)


class PasswordLogin(_Base):
    password: str = Field(min_length=1, max_length=128)


def _limit(request: Request, body: _Base) -> None:
    ip = request.client.host if request.client else "-"
    key = f"acct:{body.tenant.strip().upper()}|{body.kind}|{body.contact.strip().lower()}"
    if not request.app.state.login_limiter.hit(key, f"ip:{ip}"):
        raise _TOO_MANY


def _call(database: Database, sql: str, params: list):
    with database.transaction() as conn:
        conn.execute("select set_config('role', 'service_role', true)")
        return conn.execute(sql, params).fetchone()["v"]


@router.post("/auth/otp/request", status_code=202)
def otp_request(body: OtpRequest, request: Request, database: Database = Depends(db)) -> dict:
    sender = request.app.state.otp_sender
    if sender is None:
        raise _NO_CHANNEL
    _limit(request, body)
    code = _call(database, "select app.otp_issue(%s, %s, %s) as v", [body.tenant, body.kind, body.contact])
    if code is not None:
        sender.send(body.kind, body.contact.strip(), code)
    return {"status": "sent"}


@router.post("/auth/otp/verify")
def otp_verify(body: OtpVerify, request: Request, database: Database = Depends(db)) -> dict:
    if request.app.state.otp_sender is None:
        raise _NO_CHANNEL
    _limit(request, body)
    account = _call(database, "select app.otp_verify(%s, %s, %s, %s) as v", [body.tenant, body.kind, body.contact, body.code])
    session = request.app.state.auth_admin.issue_session(body.kind, account) if account is not None else None
    if session is None:
        raise _INVALID
    return session


@router.post("/auth/password/login")
def password_login(body: PasswordLogin, request: Request, database: Database = Depends(db)) -> dict:
    state = request.app.state
    _limit(request, body)
    account = _call(database, "select app.password_login_account(%s, %s, %s) as v", [body.tenant, body.kind, body.contact])
    r = httpx.post(f"{state.settings.jwt_issuer}/token?grant_type=password",
                   headers={"apikey": state.settings.publishable_key}, timeout=10,
                   json={"email": account_email(body.kind, account if account is not None else uuid.uuid4()),
                         "password": body.password})
    if account is None:
        raise _INVALID
    ok = r.status_code == 200
    with database.transaction() as conn:
        conn.execute("select set_config('role', 'service_role', true)")
        conn.execute("select app.password_login_result(%s, %s, %s, %s)", [body.tenant, body.kind, body.contact, ok])
    if not ok:
        raise _INVALID
    session = r.json()
    return {k: session[k] for k in SESSION_FIELDS}
