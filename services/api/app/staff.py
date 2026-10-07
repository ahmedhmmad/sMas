"""Phase 3A / 3-1 — ملف الموظف: الموظفون، تكليفات المدارس، الحالة، التخصصات، المؤهلات.

المسار الوحيد للسلطة (F4) كـsetup.py:  JWT → معاملة `authenticated` واحدة → RLS ودوال app.* تقرر → النتيجة.
  • `staff` [I] يُرى بالعلاقة: `staff.read` + تكليف نشط في نطاق الفاعل (`staff_in_scope` — H2)؛ والتخصصات
    والمؤهلات (M46) تتبعه. لا platform_tenant_id ولا school_id في أي جسم (`extra="forbid"`): المدرسة **هدف**
    في المسار، والـTenant يُقرأ من صف الموظف المرئي.
  • الإنشاء `app.provision_staff` (G4)؛ الحالة `app.set_staff_status`؛ إنهاء التكليف `app.end_staff_assignment` (M21).
  • تكليف مدرسة جديد: INSERT تحت RLS (`staff.assign` + نطاق المدرسة الهدف — خيار b، M17).
قواعد الرد كـsetup.py: غير مرئي 404، مرئي ومرفوض 403، التفرد 409، القيد/الانتقال 422. لا DELETE.
"""

import datetime
import uuid

from fastapi import APIRouter, Depends
from pydantic import Field

from .db import Database
from .deps import claims, db
from .setup import _COLUMNS, _NOT_FOUND, Reason, _Body, _call, _patch, _rows, _tx, _visible

router = APIRouter()

_NAME = Field(min_length=1, max_length=100)
_PHONE = Field(default=None, pattern=r"^\+[1-9][0-9]{7,14}$")

_COLUMNS.update({
    "staff": "id, employee_code, first_name, father_name, grandfather_name, family_name, full_name, national_id, phone_e164,"
             " email, gender, birth_date, hire_date, status, profile_id is not null as has_account",
    "staff_school_assignments": "id, staff_id, school_id, job_title, is_primary, status, effective_from, effective_to",
    "staff_specialties": "id, staff_id, name, status",
    "staff_qualifications": "id, staff_id, degree, field, institution, graduation_year, notes, status",
})


class _Person(_Body):
    first_name: str = _NAME
    father_name: str | None = Field(default=None, min_length=1, max_length=100)
    grandfather_name: str | None = Field(default=None, min_length=1, max_length=100)
    family_name: str = _NAME
    national_id: str | None = Field(default=None, min_length=1, max_length=50)
    phone_e164: str | None = _PHONE
    email: str | None = Field(default=None, min_length=3, max_length=254, pattern=r"^[^@\s]+@[^@\s]+$")
    gender: str | None = Field(default=None, pattern="^(male|female)$")
    birth_date: datetime.date | None = None
    hire_date: datetime.date | None = None


class NewStaff(_Person):
    staff_id: uuid.UUID | None = None          # معرّف يولده العميل للإعادة الآمنة (idempotency — M22)؛ هدف لا سلطة
    employee_code: str = Field(min_length=1, max_length=32)
    job_title: str = Field(min_length=1, max_length=100)
    effective_from: datetime.date


class StaffPatch(_Body):
    first_name: str | None = Field(default=None, min_length=1, max_length=100)
    father_name: str | None = Field(default=None, min_length=1, max_length=100)
    grandfather_name: str | None = Field(default=None, min_length=1, max_length=100)
    family_name: str | None = Field(default=None, min_length=1, max_length=100)
    national_id: str | None = Field(default=None, min_length=1, max_length=50)
    phone_e164: str | None = _PHONE
    email: str | None = Field(default=None, min_length=3, max_length=254, pattern=r"^[^@\s]+@[^@\s]+$")
    gender: str | None = Field(default=None, pattern="^(male|female)$")
    birth_date: datetime.date | None = None
    hire_date: datetime.date | None = None


class StatusChange(Reason):
    status: str = Field(pattern="^(active|on_leave|ended|archived)$")
    effective_to: datetime.date | None = None


class NewAssignment(_Body):
    staff_id: uuid.UUID
    job_title: str = Field(min_length=1, max_length=100)
    is_primary: bool = False
    effective_from: datetime.date


class AssignmentPatch(_Body):
    job_title: str | None = Field(default=None, min_length=1, max_length=100)
    is_primary: bool | None = None


class EndAssignment(Reason):
    effective_to: datetime.date


class NewSpecialty(_Body):
    name: str = Field(min_length=1, max_length=120)


class SpecialtyPatch(_Body):
    name: str | None = Field(default=None, min_length=1, max_length=120)
    status: str | None = Field(default=None, pattern="^(active|inactive)$")


_DEGREE = "^(diploma|bachelor|higher_diploma|master|doctorate|other)$"


class NewQualification(_Body):
    degree: str = Field(pattern=_DEGREE)
    field: str = Field(min_length=1, max_length=200)
    institution: str | None = Field(default=None, min_length=1, max_length=200)
    graduation_year: int | None = Field(default=None, ge=1900, le=2100)
    notes: str | None = Field(default=None, min_length=1, max_length=1000)


class QualificationPatch(_Body):
    degree: str | None = Field(default=None, pattern=_DEGREE)
    field: str | None = Field(default=None, min_length=1, max_length=200)
    institution: str | None = Field(default=None, min_length=1, max_length=200)
    graduation_year: int | None = Field(default=None, ge=1900, le=2100)
    notes: str | None = Field(default=None, min_length=1, max_length=1000)
    status: str | None = Field(default=None, pattern="^(active|inactive)$")


# ------------------------------------------------------------------ staff
@router.get("/schools/{school_id}/staff")
def list_school_staff(school_id: uuid.UUID, c: dict = Depends(claims), database: Database = Depends(db)) -> dict:
    """موظفو المدرسة بتكليف نشط فيها — الصفان (التكليف والموظف) كلاهما تحت RLS."""
    def work(conn):
        _visible(conn, "schools", school_id)
        rows = conn.execute(
            "select s.id, s.employee_code, s.full_name, s.status, s.profile_id is not null as has_account,"
            "       a.id as assignment_id, a.job_title, a.is_primary, a.effective_from"
            "  from public.staff_school_assignments a join public.staff s on s.id = a.staff_id"
            " where a.school_id = %s and a.status = 'active'"
            " order by s.full_name, s.id", [school_id]).fetchall()
        return {"rows": rows}
    return _tx(c, database, work)


@router.post("/schools/{school_id}/staff", status_code=201)
def create_staff(school_id: uuid.UUID, body: NewStaff, c: dict = Depends(claims), database: Database = Depends(db)) -> dict:
    """G4: الهوية تُنشأ بدالة الإنشاء وحدها (staff + أول تكليف في المدرسة الهدف)."""
    staff_id = body.staff_id or uuid.uuid4()

    def work(conn):
        # المدرسة غير المرئية ← provision_staff ترفع P0002 ← 404 (الدالة تقرر — لا فحص مسبق مكرر)
        _call(conn,
              "select app.provision_staff(%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s)",
              [staff_id, school_id, body.employee_code, body.first_name, body.family_name, body.job_title, body.effective_from,
               body.father_name, body.grandfather_name, body.national_id, body.phone_e164, body.email,
               body.gender, body.birth_date, body.hire_date])
        return _visible(conn, "staff", staff_id)
    return _tx(c, database, work)


@router.get("/staff/{staff_id}")
def get_staff(staff_id: uuid.UUID, c: dict = Depends(claims), database: Database = Depends(db)) -> dict:
    return _tx(c, database, lambda conn: _visible(conn, "staff", staff_id))


@router.patch("/staff/{staff_id}")
def update_staff(staff_id: uuid.UUID, body: StaffPatch, c: dict = Depends(claims), database: Database = Depends(db)) -> dict:
    return _tx(c, database, lambda conn: _patch(conn, "staff", staff_id, body))


@router.post("/staff/{staff_id}/status")
def change_staff_status(staff_id: uuid.UUID, body: StatusChange, c: dict = Depends(claims), database: Database = Depends(db)) -> dict:
    """M21: الانتقالات والصلاحية (staff.update / staff.archive) والنطاق في DB. بعد `ended` قد لا يبقى الصف مرئياً (H2)."""
    def work(conn):
        # بلا فحص رؤية مسبق: الموظف المنتهي غير مرئي (H2) لكن أرشفته بنطاق الـTenant مشروعة (M21) — الدالة تقرر، P0002 ← 404
        _call(conn, "select app.set_staff_status(%s, %s, %s, %s)", [staff_id, body.status, body.reason, body.effective_to])
        row = conn.execute("select id, status from public.staff where id = %s", [staff_id]).fetchone()
        return row or {"id": staff_id, "status": body.status, "visible": False}
    return _tx(c, database, work)


# ------------------------------------------------------------------ school assignments
@router.get("/staff/{staff_id}/school-assignments")
def list_staff_assignments(staff_id: uuid.UUID, c: dict = Depends(claims), database: Database = Depends(db)) -> dict:
    """التكليفات المرئية للفاعل (School-level: تكليفات مدارس نطاقه، ومنها المنتهية — سجلها هي)."""
    def work(conn):
        _visible(conn, "staff", staff_id)
        return {"rows": _rows(conn, "staff_school_assignments", "staff_id = %s", [staff_id], order="effective_from desc")}
    return _tx(c, database, work)


@router.post("/schools/{school_id}/staff-assignments", status_code=201)
def create_staff_assignment(school_id: uuid.UUID, body: NewAssignment, c: dict = Depends(claims), database: Database = Depends(db)) -> dict:
    """خيار b (M17): تكليف جديد في المدرسة الهدف — RLS: staff.assign + نطاقها. الموظف يجب أن يكون مرئياً للفاعل."""
    def work(conn):
        _visible(conn, "schools", school_id)
        _visible(conn, "staff", body.staff_id)
        row = _call(conn,
                    "insert into public.staff_school_assignments (staff_id, school_id, platform_tenant_id, job_title, is_primary, effective_from)"
                    " select s.id, %s, s.platform_tenant_id, %s, %s, %s from public.staff s where s.id = %s returning id",
                    [school_id, body.job_title, body.is_primary, body.effective_from, body.staff_id])
        return _visible(conn, "staff_school_assignments", row["id"])
    return _tx(c, database, work)


@router.patch("/staff-assignments/{assignment_id}")
def update_staff_assignment(assignment_id: uuid.UUID, body: AssignmentPatch, c: dict = Depends(claims), database: Database = Depends(db)) -> dict:
    return _tx(c, database, lambda conn: _patch(conn, "staff_school_assignments", assignment_id, body))


@router.post("/staff-assignments/{assignment_id}/end")
def end_staff_assignment(assignment_id: uuid.UUID, body: EndAssignment, c: dict = Depends(claims), database: Database = Depends(db)) -> dict:
    def work(conn):
        _visible(conn, "staff_school_assignments", assignment_id)
        _call(conn, "select app.end_staff_assignment(%s, %s, %s)", [assignment_id, body.effective_to, body.reason])
        return _visible(conn, "staff_school_assignments", assignment_id)
    return _tx(c, database, work)


# ------------------------------------------------------------------ specialties / qualifications (M46)
def _child_list(table: str, order: str):
    def endpoint(staff_id: uuid.UUID, c: dict = Depends(claims), database: Database = Depends(db)) -> dict:
        def work(conn):
            _visible(conn, "staff", staff_id)
            return {"rows": _rows(conn, table, "staff_id = %s", [staff_id], order=order)}
        return _tx(c, database, work)
    return endpoint


router.get("/staff/{staff_id}/specialties")(_child_list("staff_specialties", "name"))
router.get("/staff/{staff_id}/qualifications")(_child_list("staff_qualifications", "graduation_year desc nulls last, degree"))


def _insert_child(conn, table: str, staff_id: uuid.UUID, values: dict) -> dict:
    """الـTenant من صف الموظف المرئي تحت RLS — لا من العميل؛ RLS (staff.update + العلاقة) تقرر الكتابة.
    موظف غير مرئي ← لا صف يُدرج ← 404 (لا فحص مسبق مكرر)."""
    cols = list(values)
    row = conn.execute(
        f"insert into public.{table} (platform_tenant_id, staff_id, {', '.join(cols)})"
        f" select s.platform_tenant_id, s.id, {', '.join(['%s'] * len(cols))} from public.staff s where s.id = %s returning id",
        [*values.values(), staff_id]).fetchone()
    if row is None:
        raise _NOT_FOUND
    return _visible(conn, table, row["id"])


@router.post("/staff/{staff_id}/specialties", status_code=201)
def create_specialty(staff_id: uuid.UUID, body: NewSpecialty, c: dict = Depends(claims), database: Database = Depends(db)) -> dict:
    return _tx(c, database, lambda conn: _insert_child(conn, "staff_specialties", staff_id, {"name": body.name.strip()}))


@router.patch("/staff-specialties/{specialty_id}")
def update_specialty(specialty_id: uuid.UUID, body: SpecialtyPatch, c: dict = Depends(claims), database: Database = Depends(db)) -> dict:
    if body.name is not None:
        body.name = body.name.strip()
    return _tx(c, database, lambda conn: _patch(conn, "staff_specialties", specialty_id, body))


@router.post("/staff/{staff_id}/qualifications", status_code=201)
def create_qualification(staff_id: uuid.UUID, body: NewQualification, c: dict = Depends(claims), database: Database = Depends(db)) -> dict:
    return _tx(c, database, lambda conn: _insert_child(conn, "staff_qualifications", staff_id, body.model_dump()))


@router.patch("/staff-qualifications/{qualification_id}")
def update_qualification(qualification_id: uuid.UUID, body: QualificationPatch, c: dict = Depends(claims), database: Database = Depends(db)) -> dict:
    return _tx(c, database, lambda conn: _patch(conn, "staff_qualifications", qualification_id, body))
