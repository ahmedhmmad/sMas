"""هيكل FastAPI — Gate F4.

المسار الوحيد للسلطة:  JWT (يُتحقَّق منه) → FastAPI → قاعدة البيانات (RLS + دوال app.*) → البيانات.
FastAPI لا يقرر صلاحية بنفسه: حين يحتاج سؤالاً («هل يملك X على Y؟») يطرحه على دوال قاعدة البيانات القائمة،
ولا يقرأ من الطلب (headers، query، body) أي tenant أو school أو دور يؤثر في السلطة.

نقاط الإثبات (F4):
  /me                                  السياق مشتق من قاعدة البيانات
  /schools/{id}، /schools/{id}/students قراءة تحت RLS
  /schools/{id}/students/export         قناة التصدير منفصلة عن القراءة (P3) + تدقيق
  /platform/tenants/{id}                قراءة Platform Admin لبيانات Tenant + تدقيق (N5)
"""

import uuid
from contextlib import asynccontextmanager
from typing import Any

import psycopg
from fastapi import Depends, FastAPI, HTTPException, Request
from fastapi.responses import JSONResponse

from . import account_login, accounts, first_login, student_login, students
from .audit import write_access_audit
from .auth_admin import AuthAdmin
from .config import load_settings
from .otp_sender import load_sender
from .db import Database
from .deps import claims, db
from .security import TokenVerifier


@asynccontextmanager
async def lifespan(app: FastAPI):
    settings = load_settings()
    app.state.settings = settings
    app.state.auth_admin = AuthAdmin(settings.supabase_url, settings.publishable_key)
    app.state.otp_sender = load_sender()
    app.state.login_limiter = student_login.AttemptLimiter(limit=10, window_s=300)
    app.state.verifier = TokenVerifier.from_jwks(
        settings.jwks_url,
        algorithms=settings.jwt_algorithms,
        audience=settings.jwt_audience,
        issuer=settings.jwt_issuer,
    )
    app.state.db = Database(settings.database_url)
    app.state.db.open()
    try:
        yield
    finally:
        app.state.db.close()
        app.state.auth_admin.close()


app = FastAPI(title="SMas API", lifespan=lifespan)
app.include_router(student_login.router)
app.include_router(students.router)
app.include_router(first_login.router)
app.include_router(account_login.router)
app.include_router(accounts.router)


@app.exception_handler(psycopg.errors.InsufficientPrivilege)
async def _insufficient_privilege(_: Request, __: Exception) -> JSONResponse:
    return JSONResponse(status_code=403, content={"detail": "forbidden"})


_NOT_FOUND = HTTPException(status_code=404, detail="not_found")   # غير موجود = غير مرئي: لا يُكشف وجود ما لا يُرى
_FORBIDDEN = HTTPException(status_code=403, detail="forbidden")

_STUDENTS_OF_SCHOOL = """
    select s.id, s.full_name, s.status, e.status as enrollment_status
    from public.enrollments e
    join public.students s on s.id = e.student_id
    where e.school_id = %s
    order by s.full_name, s.id
"""


@app.get("/health")
def health() -> dict[str, str]:
    return {"status": "ok"}


@app.get("/me")
def me(c: dict = Depends(claims), database: Database = Depends(db)) -> dict[str, Any]:
    with database.as_user(c) as conn:
        ctx = conn.execute(
            "select app.current_profile_id() as profile_id,"
            "       app.current_tenant_id() as tenant_id,"
            "       app.current_system_user_id() as system_user_id"
        ).fetchone()
    return {"auth_user_id": c["sub"], **ctx}


def _visible_school(conn: psycopg.Connection, school_id: uuid.UUID) -> dict[str, Any]:
    row = conn.execute(
        "select id, platform_tenant_id, group_id, school_code, name, status from public.schools where id = %s",
        [school_id],
    ).fetchone()
    if row is None:
        raise _NOT_FOUND
    return row


@app.get("/schools/{school_id}")
def get_school(school_id: uuid.UUID, c: dict = Depends(claims), database: Database = Depends(db)) -> dict[str, Any]:
    with database.as_user(c) as conn:
        return _visible_school(conn, school_id)


@app.get("/schools/{school_id}/students")
def list_students(school_id: uuid.UUID, c: dict = Depends(claims), database: Database = Depends(db)) -> dict[str, Any]:
    with database.as_user(c) as conn:
        _visible_school(conn, school_id)
        return {"rows": conn.execute(_STUDENTS_OF_SCHOOL, [school_id]).fetchall()}


@app.get("/schools/{school_id}/students/export")
def export_students(school_id: uuid.UUID, c: dict = Depends(claims), database: Database = Depends(db)) -> dict[str, Any]:
    with database.as_user(c) as conn:
        # P3: الإذن يُسأل عنه قاعدة البيانات بمفتاح التصدير نفسه — بصيغة السياسات (صلاحية + نطاق)، لا يُستنتج من القراءة
        allowed = conn.execute(
            "select app.has_permission('student.export') and app.can_access_school(%s) as ok", [school_id]
        ).fetchone()["ok"]
        if not allowed:
            raise _FORBIDDEN
        school = _visible_school(conn, school_id)
        rows = conn.execute(_STUDENTS_OF_SCHOOL, [school_id]).fetchall()   # الصفوف نفسها تحت RLS
        # صف لكل طالب مُصدَّر: رؤية الصف تتبع رؤية الطالب/المدرسة (M18) ولا تصل إلى Platform Admin (F11)
        write_access_audit(
            conn,
            action="export",
            entity_type="students",
            entity_ids=[r["id"] for r in rows],
            platform_tenant_id=school["platform_tenant_id"],
            school_id=school_id,
            details={"channel": "api", "resource": "school_students", "export_id": str(uuid.uuid4()), "row_count": len(rows)},
        )
        return {"rows": rows}


@app.get("/platform/tenants/{tenant_id}")
def platform_get_tenant(tenant_id: uuid.UUID, c: dict = Depends(claims), database: Database = Depends(db)) -> dict[str, Any]:
    with database.as_user(c) as conn:
        # سياق المنصة تقرره قاعدة البيانات (G10)؛ مستخدم Tenant لا يدخل مسار المنصة
        if conn.execute("select app.current_system_user_id() as id").fetchone()["id"] is None:
            raise _FORBIDDEN
        # الصف يظهر فقط بسياسة platform_tenants_admin_select = has_platform_permission('tenant.read')
        row = conn.execute(
            "select id, tenant_code, name, status, suspended_at from public.platform_tenants where id = %s", [tenant_id]
        ).fetchone()
        if row is None:
            raise _NOT_FOUND
        write_access_audit(                                               # N5 — قبل الإرجاع، في المعاملة نفسها
            conn,
            action="read",
            entity_type="platform_tenants",
            entity_ids=[row["id"]],
            platform_tenant_id=row["id"],
            details={"channel": "api", "resource": "platform_tenant"},
        )
        return row
