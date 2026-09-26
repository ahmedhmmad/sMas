"""D4 — onboarding ولي الأمر: نمط المدرسة، وكلمة المرور المؤقتة (النمط C).

  POST /schools/{id}/guardian-first-login-mode {mode, reason}   ← security.manage + نطاق المدرسة (قاعدة البيانات تقرر)
  POST /guardians/{id}/temporary-password                      ← security.manage + ولي الأمر في النطاق، حساب غير مُستكمل

الكلمة المؤقتة (C): begin (يغلق الإصدار) ← Admin API يكتبها ← arm (لحظة الإصدار من ساعة Supabase Auth) ← تُعاد
للموظف مرة واحدة ليسلّمها. فشل بين الخطوات ⇒ الحساب مغلق (pending بلا إصدار) وإعادة الطلب تكمل. ولي الأمر
يدخل بها ثم يغيّرها ثم يفعّل (D2).
"""

import secrets
import uuid

import psycopg
from fastapi import APIRouter, Depends, HTTPException, Request
from pydantic import BaseModel, Field

from .auth_admin import AuthAdminError
from .db import Database
from .deps import claims, db, http_error

router = APIRouter()

_ALPHABET = "ABCDEFGHJKMNPQRSTUVWXYZabcdefghjkmnpqrstuvwxyz23456789"   # بلا أحرف ملتبسة


class ModeChange(BaseModel):
    mode: str = Field(pattern="^[ABC]$")
    reason: str = Field(min_length=1, max_length=500)


@router.post("/schools/{school_id}/guardian-first-login-mode")
def set_mode(school_id: uuid.UUID, body: ModeChange, c: dict = Depends(claims), database: Database = Depends(db)) -> dict:
    try:
        with database.as_user(c) as conn:
            mode = conn.execute("select app.set_guardian_first_login_mode(%s, %s, %s) as m",
                                [school_id, body.mode, body.reason]).fetchone()["m"]
    except psycopg.Error as exc:
        raise http_error(exc) from exc
    return {"mode": mode}


@router.post("/guardians/{guardian_id}/temporary-password", status_code=201)
def temporary_password(guardian_id: uuid.UUID, request: Request, c: dict = Depends(claims),
                       database: Database = Depends(db)) -> dict:
    try:
        with database.as_user(c) as conn:
            account = conn.execute("select app.begin_guardian_temporary_password(%s) as a", [guardian_id]).fetchone()["a"]
    except psycopg.Error as exc:
        raise http_error(exc) from exc
    password = "".join(secrets.choice(_ALPHABET) for _ in range(12))
    try:
        request.app.state.auth_admin.set_password(account, password)
    except AuthAdminError as exc:
        raise HTTPException(status_code=502, detail="auth_unavailable") from exc
    try:
        with database.as_user(c) as conn:
            conn.execute("select app.arm_guardian_temporary_password(%s)", [guardian_id])
    except psycopg.Error as exc:
        raise http_error(exc) from exc
    return {"temporary_password": password}
