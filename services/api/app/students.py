"""إنشاء طالب بحسابه — Saga §5.4 (D1).

  1. العميل يولّد student_id (مفتاح idempotency)                       ← body
  2. FastAPI يتحقق من JWT المستدعي                                      ← deps.claims
  3. Admin API: حساب id = student_id، بريد اصطناعي، كلمة مرور عشوائية     ← استئناف إن وُجد
  4. app.provision_student بـJWT المستدعي (RLS/T8؛ D1 مفروض في DB)       ← معاملة ذرية
  5. فشل 4 ← حذف الحساب تعويضاً (فقط إن أُنشئ في هذه المحاولة)
  6. كلمة المرور الأولية = معرّف الدخول (Official ID أو Temporary ID المولَّد في 4) — §7.19
  7. app.arm_first_login بـJWT المستدعي: لحظة الإصدار (D2) — الحساب pending منذ 4

فشل 7: الحساب pending بلا لحظة إصدار ⇒ لا تفعيل ممكن (مغلق)؛ إعادة الطلب نفسه تكمل.

فشل 6 بعد نجاح 4: الطالب موجود وحسابه بكلمة مرور عشوائية لا يعرفها أحد (آمن)؛ إعادة الطلب نفسه تكمل.
لا سلطة هنا: FastAPI لا يقرر من يُنشئ طالباً — `provision_student` تقرر.
"""

import datetime
import uuid

import psycopg
from fastapi import APIRouter, Depends, HTTPException, Request
from pydantic import BaseModel, Field

from .auth_admin import AuthAdminError
from .db import Database
from .deps import claims, db, http_error

router = APIRouter()


class NewStudent(BaseModel):
    student_id: uuid.UUID
    section_id: uuid.UUID
    effective_from: datetime.date
    first_name: str = Field(min_length=1, max_length=100)
    family_name: str = Field(min_length=1, max_length=100)
    father_name: str | None = None
    grandfather_name: str | None = None
    official_id: str | None = Field(default=None, max_length=64)
    official_id_type: str | None = None
    gender: str | None = None
    birth_date: datetime.date | None = None
    nationality: str | None = None
    family_id: uuid.UUID | None = None
    new_family_name: str | None = None
    enrollment_no: str | None = None


_PROVISION = """
    select app.provision_student(
      %(student_id)s, %(student_id)s, %(section_id)s, %(effective_from)s, %(first_name)s, %(family_name)s,
      p_father_name => %(father_name)s, p_grandfather_name => %(grandfather_name)s,
      p_official_id => %(official_id)s, p_official_id_type => %(official_id_type)s,
      p_gender => %(gender)s, p_birth_date => %(birth_date)s, p_nationality => %(nationality)s,
      p_family_id => %(family_id)s, p_new_family_name => %(new_family_name)s, p_enrollment_no => %(enrollment_no)s)
"""


@router.post("/students", status_code=201)
def create_student(body: NewStudent, request: Request, c: dict = Depends(claims), database: Database = Depends(db)) -> dict:
    state = request.app.state
    # كلمة المرور الأولية = المعرّف؛ معرّف أقصر من حد Supabase Auth لا يصلح كلمة مرور — يُرفض قبل أي كتابة
    if body.official_id is not None and len(body.official_id.strip()) < state.settings.min_password_length:
        raise HTTPException(status_code=422, detail="identifier_too_short_for_initial_password")

    admin = state.auth_admin
    try:
        created = admin.create_student_account(body.student_id)
    except AuthAdminError as exc:
        raise HTTPException(status_code=502, detail="auth_unavailable") from exc

    try:
        with database.as_user(c) as conn:
            conn.execute(_PROVISION, body.model_dump())
            identifier = conn.execute(
                "select coalesce(official_id, temporary_id) as v from public.students where id = %s", [body.student_id]
            ).fetchone()["v"]
    except psycopg.Error as exc:
        if created:
            admin.delete(body.student_id)
        raise http_error(exc) from exc

    try:
        admin.set_password(body.student_id, identifier)
    except AuthAdminError as exc:
        raise HTTPException(status_code=502, detail="initial_password_pending_retry") from exc
    try:
        with database.as_user(c) as conn:
            conn.execute("select app.arm_first_login(%s)", [body.student_id])
    except psycopg.Error as exc:
        raise http_error(exc) from exc
    return {"student_id": str(body.student_id), "login_identifier": identifier}
