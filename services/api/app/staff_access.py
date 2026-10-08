"""Phase 3A / 3-2 — حساب الموظف ودوره ونطاق مدرسته (docs/PHASE3_2_ACCOUNT_ACCESS.md).

لا migration ولا دالة ولا سياسة جديدة: كل قرار في القائم —
  • الحساب: Saga `auth_admin.create_account` (هوية اصطناعية، I2) ثم `app.provision_account` (membership.create + staff_in_scope).
  • أول دور/نطاق: RLS على membership_roles/membership_scopes بـ`can_manage_membership` (M12 + **M47**) ثم T8 (M19).
  • السحب: G2 (حذف صف الربط) تحت RLS و T8، والسبب إلى التدقيق (T7 يحفظ الصف القديم والفاعل والسبب).
المدرسة والموظف والدور **أهداف في المسار**؛ لا platform_tenant_id ولا school_id ولا membership_id في أي جسم.
العضوية تُشتق من `staff.profile_id` المقروء تحت RLS — غير المرئي غير موجود (404)، ولا مسار قراءة يتجاوز RLS (A1، H2).
فحصا `email_required` و`staff_not_assigned` رسالتان لا أمن: DB (M47، سياسة النطاق، T8) تقرر على أي حال (Q3).
"""

import uuid

import psycopg
from fastapi import APIRouter, Depends, HTTPException, Request, Response

from .auth_admin import AuthAdminError
from .db import Database
from .deps import claims, db, http_error
from .setup import _FORBIDDEN, _NOT_FOUND, Reason, _Body, _reason, _tx, _visible
from . import staff as _staff  # noqa: F401  — يسجّل أعمدة staff في _COLUMNS

router = APIRouter()


class RoleChoice(_Body):
    role_id: uuid.UUID


def _refusal(exc: psycopg.Error) -> HTTPException:
    """T8 يرفض بـ42501 كـRLS؛ رسالته تبدأ بـ«T8:» — يُعرض رمز مستقل **بلا** سرد المفاتيح التي ذكرها."""
    if exc.sqlstate == "42501" and (exc.diag.message_primary or "").startswith("T8:"):
        return HTTPException(status_code=403, detail="role_exceeds_authority")
    return http_error(exc)


def _run(c: dict, database: Database, work):
    try:
        with database.as_user(c) as conn:
            return work(conn)
    except psycopg.Error as exc:
        raise _refusal(exc) from exc


def _membership(conn, staff_id: uuid.UUID) -> dict | None:
    """عضوية حساب الموظف كما تراها الجلسة (membership.read + can_see_membership) — None إن لا حساب أو غير مرئية."""
    return conn.execute(
        "select m.id, m.platform_tenant_id, m.status from public.memberships m"
        " join public.staff s on s.profile_id = m.profile_id where s.id = %s", [staff_id]).fetchone()


def _access(conn, staff_id: uuid.UUID) -> dict:
    staff = _visible(conn, "staff", staff_id)
    if not conn.execute("select app.has_permission('membership.read') as ok").fetchone()["ok"]:
        raise _FORBIDDEN
    m = _membership(conn, staff_id)
    roles = scopes = []
    if m is not None:
        roles = conn.execute(
            "select r.id, r.code, r.name from public.membership_roles mr join public.roles r on r.id = mr.role_id"
            " where mr.membership_id = %s order by r.code", [m["id"]]).fetchall()
        scopes = conn.execute(
            "select ms.scope_type, ms.school_id, sc.school_code, sc.name from public.membership_scopes ms"
            " left join public.schools sc on sc.id = ms.school_id where ms.membership_id = %s"
            " order by ms.scope_type, sc.school_code", [m["id"]]).fetchall()
    return {
        "staff_id": staff["id"], "email": staff["email"], "has_account": staff["has_account"],
        "membership_status": m["status"] if m else None,
        # عرض فقط: شروط الدخول الفعلية في دوال D3 (موظف active، حساب، بريد)
        "can_login": bool(staff["has_account"] and staff["email"] and staff["status"] == "active" and m and m["status"] == "active"),
        "roles": roles, "scopes": scopes,
    }


def _managed_membership(conn, staff_id: uuid.UUID) -> dict:
    _visible(conn, "staff", staff_id)
    m = _membership(conn, staff_id)
    if m is None:
        raise _NOT_FOUND
    return m


def _grant_role(conn, membership: dict, role_id: uuid.UUID) -> None:
    # الدور يُقرأ تحت RLS (role.read)؛ غير المرئي غير موجود. RLS تقرر الإدراج، ثم T8.
    done = conn.execute(
        "insert into public.membership_roles (membership_id, role_id, platform_tenant_id, role_owner_key)"
        " select %s, r.id, %s, r.owner_key from public.roles r where r.id = %s and r.status = 'active'"
        " on conflict do nothing", [membership["id"], membership["platform_tenant_id"], role_id])
    if done.rowcount == 0 and conn.execute(
            "select 1 from public.membership_roles where membership_id = %s and role_id = %s", [membership["id"], role_id]).fetchone() is None:
        raise _NOT_FOUND


def _grant_school_scope(conn, membership: dict, school_id: uuid.UUID) -> None:
    conn.execute(
        "insert into public.membership_scopes (membership_id, platform_tenant_id, scope_type, school_id)"
        " values (%s, %s, 'school', %s) on conflict do nothing", [membership["id"], membership["platform_tenant_id"], school_id])


def _require_assignment(conn, staff_id: uuid.UUID, school_id: uuid.UUID) -> None:
    """A4: رسالة واضحة لا حدّ أمان — أول منح يحسمه M47 في DB، وكل منح تحسمه سياسة النطاق و T8."""
    if conn.execute("select 1 from public.staff_school_assignments where staff_id = %s and school_id = %s and status = 'active'",
                    [staff_id, school_id]).fetchone() is None:
        raise HTTPException(status_code=422, detail="staff_not_assigned")


# ------------------------------------------------------------------ قراءة
@router.get("/staff/{staff_id}/access")
def get_access(staff_id: uuid.UUID, c: dict = Depends(claims), database: Database = Depends(db)) -> dict:
    return _tx(c, database, lambda conn: _access(conn, staff_id))


@router.get("/staff/{staff_id}/access/assignable-roles")
def assignable_roles(staff_id: uuid.UUID, c: dict = Depends(claims), database: Database = Depends(db)) -> dict:
    """A5: `assignable` عرض فقط (صلاحيات الدور ⊆ صلاحيات الجلسة) — T8 هو الحكم عند المنح."""
    def work(conn):
        _visible(conn, "staff", staff_id)
        rows = conn.execute(
            "select r.id, r.code, r.name, r.is_system,"
            "       not exists (select 1 from public.role_permissions rp join public.permissions p on p.id = rp.permission_id"
            "                    where rp.role_id = r.id and not app.has_permission(p.code)) as assignable"
            "  from public.roles r where r.status = 'active' and r.code not in ('guardian', 'student')"
            " order by r.is_system desc, r.code").fetchall()
        return {"rows": rows}
    return _tx(c, database, work)


# ------------------------------------------------------------------ التفعيل الأول (A2)
@router.post("/schools/{school_id}/staff/{staff_id}/account")
def activate_account(school_id: uuid.UUID, staff_id: uuid.UUID, body: RoleChoice, request: Request, response: Response,
                     c: dict = Depends(claims), database: Database = Depends(db)) -> dict:
    """حساب Auth (Saga) ثم معاملة DB واحدة: provision_account + نطاق المدرسة + الدور. فشل DB ← لا شيء منها، وتعويض الحساب إن أُنشئ هنا."""
    def precheck(conn):
        _visible(conn, "schools", school_id)
        staff = _visible(conn, "staff", staff_id)
        if not staff["email"]:
            raise HTTPException(status_code=422, detail="email_required")     # A6: الدخول OTP على البريد
        _require_assignment(conn, staff_id, school_id)
    _tx(c, database, precheck)

    admin = request.app.state.auth_admin
    try:
        created = admin.create_account("staff", staff_id)
    except AuthAdminError as exc:
        raise HTTPException(status_code=502, detail="auth_unavailable") from exc

    def work(conn):
        conn.execute("select app.provision_account('staff', %s, %s)", [staff_id, staff_id])
        m = _managed_membership(conn, staff_id)
        _grant_school_scope(conn, m, school_id)
        _grant_role(conn, m, body.role_id)
        return _access(conn, staff_id)
    try:
        result = _run(c, database, work)
    except HTTPException:
        if created:
            admin.delete(staff_id)
        raise
    response.status_code = 201 if created else 200
    return result


# ------------------------------------------------------------------ منح وسحب لاحقان
@router.post("/staff/{staff_id}/access/roles/{role_id}")
def grant_role(staff_id: uuid.UUID, role_id: uuid.UUID, c: dict = Depends(claims), database: Database = Depends(db)) -> dict:
    def work(conn):
        _grant_role(conn, _managed_membership(conn, staff_id), role_id)
        return _access(conn, staff_id)
    return _run(c, database, work)


@router.post("/staff/{staff_id}/access/roles/{role_id}/revoke")
def revoke_role(staff_id: uuid.UUID, role_id: uuid.UUID, body: Reason, c: dict = Depends(claims), database: Database = Depends(db)) -> dict:
    def work(conn):
        m = _managed_membership(conn, staff_id)
        _reason(conn, body.reason)
        if conn.execute("delete from public.membership_roles where membership_id = %s and role_id = %s", [m["id"], role_id]).rowcount == 0:
            visible = conn.execute("select 1 from public.membership_roles where membership_id = %s and role_id = %s", [m["id"], role_id]).fetchone()
            raise _FORBIDDEN if visible else _NOT_FOUND
        return _access(conn, staff_id)
    return _run(c, database, work)


@router.post("/schools/{school_id}/staff/{staff_id}/access-scope")
def grant_school_scope(school_id: uuid.UUID, staff_id: uuid.UUID, c: dict = Depends(claims), database: Database = Depends(db)) -> dict:
    def work(conn):
        _visible(conn, "schools", school_id)
        m = _managed_membership(conn, staff_id)
        _require_assignment(conn, staff_id, school_id)
        _grant_school_scope(conn, m, school_id)
        return _access(conn, staff_id)
    return _run(c, database, work)


@router.post("/schools/{school_id}/staff/{staff_id}/access-scope/revoke")
def revoke_school_scope(school_id: uuid.UUID, staff_id: uuid.UUID, body: Reason, c: dict = Depends(claims), database: Database = Depends(db)) -> dict:
    def work(conn):
        _visible(conn, "schools", school_id)
        m = _managed_membership(conn, staff_id)
        _reason(conn, body.reason)
        where = "membership_id = %s and scope_type = 'school' and school_id = %s"
        if conn.execute(f"delete from public.membership_scopes where {where}", [m["id"], school_id]).rowcount == 0:
            visible = conn.execute(f"select 1 from public.membership_scopes where {where}", [m["id"], school_id]).fetchone()
            raise _FORBIDDEN if visible else _NOT_FOUND
        return _access(conn, staff_id)
    return _run(c, database, work)
