"""إنشاء حساب لولي أمر أو موظف قائم — Saga بنمط §5.4 (D3/I2).

  1. Admin API: حساب id = معرّف الكيان، بريد اصطناعي، كلمة مرور عشوائية   ← استئناف إن وُجد
  2. app.provision_account بـJWT المستدعي (RLS/T8؛ I2 مفروض في DB)
  3. فشل 2 ← حذف الحساب تعويضاً (فقط إن أُنشئ في هذه المحاولة)

لا كلمة مرور أولية هنا: الدخول بـOTP؛ أنماط أول دخول ولي الأمر (A/B/C) في D4.
"""

import uuid

import psycopg
from fastapi import APIRouter, Depends, HTTPException, Request
from pydantic import BaseModel, Field

from .auth_admin import AuthAdminError
from .db import Database
from .deps import claims, db, http_error

router = APIRouter()


class NewAccount(BaseModel):
    kind: str = Field(pattern="^(guardian|staff)$")
    target_id: uuid.UUID


@router.post("/accounts", status_code=201)
def create_account(body: NewAccount, request: Request, c: dict = Depends(claims), database: Database = Depends(db)) -> dict:
    admin = request.app.state.auth_admin
    try:
        created = admin.create_account(body.kind, body.target_id)
    except AuthAdminError as exc:
        raise HTTPException(status_code=502, detail="auth_unavailable") from exc
    try:
        with database.as_user(c) as conn:
            conn.execute("select app.provision_account(%s, %s, %s)", [body.kind, body.target_id, body.target_id])
    except psycopg.Error as exc:
        if created:
            admin.delete(body.target_id)
        raise http_error(exc) from exc
    return {"account_id": str(body.target_id)}
