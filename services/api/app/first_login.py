"""تفعيل الحساب بعد تغيير كلمة المرور الأولى (D2 — الخيار B).

الطالب يغيّر كلمته عبر Supabase Auth بجلسته (`PUT /auth/v1/user`)، ثم يستدعي هذا المسار بالجلسة نفسها.
القرار كله في `app.activate_first_login()`: الحساب = auth.uid()، حدث `user_updated_password` بفاعل الحساب نفسه
بعد لحظة إصدار الكلمة المؤقتة. FastAPI لا يقرر ولا يمرر قيمة يثق بها قاعدة البيانات.

  200 {"state": "active"}                 ← فُعّل الآن أو كان مفعّلاً
  409 password_change_required            ← ما زال pending (fail closed؛ يُعاد بعد التغيير)
"""

from fastapi import APIRouter, Depends, HTTPException

import psycopg

from .db import Database
from .deps import claims, db, http_error

router = APIRouter()


@router.post("/auth/activate")
def activate(c: dict = Depends(claims), database: Database = Depends(db)) -> dict:
    try:
        with database.as_user(c) as conn:
            state = conn.execute("select app.activate_first_login() as s").fetchone()["s"]
    except psycopg.Error as exc:
        raise http_error(exc) from exc
    if state != "active":
        raise HTTPException(status_code=409, detail="password_change_required")
    return {"state": state}
