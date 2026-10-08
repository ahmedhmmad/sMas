"""Phase 3A / 3-3 — التكليفات: تدريس مادة في شعبة، ومربي الفصل (docs/PHASE3_3_ASSIGNMENTS.md).

المسار الوحيد للسلطة (F4): JWT → معاملة `authenticated` واحدة → RLS (staff.read / staff.assign + نطاق المدرسة) و T17 والدالتان تقرر.
  • الشعبة/التكليف **أهداف في المسار**؛ `subject_id` و`staff_id` أهداف في الجسم. لا Tenant ولا مدرسة ولا سنة ولا صف من العميل:
    كلها من صف الشعبة المقروء تحت RLS (T12)، والـFKs المركّبة ترفض أي تركيب آخر.
  • «نشط واحد» يحسمه الفهرس الفريد الجزئي (T3): المتزامن الخاسر ← 23505 ← 409.
  • الإنهاء بالدالة المتحكَّم بها؛ **الاستبدال** = إنهاء ثم إدراج في المعاملة نفسها (T5) — أي فشل ← لا شيء.
  • السبب من الجسم إلى `app.audit_reason` (C3): DB تقرر هل هو مطلوب (السنة النشطة).
لا UPDATE ولا DELETE. الحقل `operational` عرض فقط (T7، T8): التكليف «معلَّق» حين تتعطل شعبته أو ربط مادته أو يغيب نشاط موظفه أو تُغلق سنته.
"""

import datetime
import uuid

from fastapi import APIRouter, Depends
from pydantic import Field

from .db import Database
from .deps import claims, db
from .setup import _COLUMNS, _NOT_FOUND, Reason, _Body, _call, _reason, _tx, _visible

router = APIRouter()

_COLUMNS.update({
    "teaching_assignments": "id, school_id, academic_year_id, grade_level_id, section_id, subject_id, staff_id, status, effective_from, effective_to",
    "class_teacher_assignments": "id, school_id, academic_year_id, grade_level_id, section_id, staff_id, status, effective_from, effective_to",
})


class NewTeaching(_Body):
    subject_id: uuid.UUID
    staff_id: uuid.UUID
    effective_from: datetime.date | None = None
    reason: str | None = Field(default=None, min_length=1, max_length=500)


class NewClassTeacher(_Body):
    staff_id: uuid.UUID
    effective_from: datetime.date | None = None
    reason: str | None = Field(default=None, min_length=1, max_length=500)


class EndAssignment(Reason):
    effective_to: datetime.date


class Replacement(Reason):
    staff_id: uuid.UUID
    effective_from: datetime.date


# عرض: الأسماء كلٌّ بسياسته (left join — غير المرئي يعود NULL)، و«operational» مشتق
_LIST = """
    select t.id, t.section_id, sec.name as section_name, t.grade_level_id, g.name as grade_level_name,
           {subject_cols}
           t.staff_id, st.full_name as staff_name, st.employee_code,
           t.status, t.effective_from, t.effective_to,
           (t.status = 'active' and y.status <> 'closed' and sec.status = 'active' and coalesce(st.status, '') = 'active'
            {subject_ok}
            and exists (select 1 from public.staff_school_assignments a
                         where a.staff_id = t.staff_id and a.school_id = t.school_id and a.status = 'active')) as operational
      from public.{table} t
      join public.academic_years y on y.id = t.academic_year_id
      join public.sections sec on sec.id = t.section_id
      join public.grade_levels g on g.id = t.grade_level_id
      {subject_join}
      left join public.staff st on st.id = t.staff_id
     where t.academic_year_id = %(year)s
       and (%(section)s::uuid is null or t.section_id = %(section)s)
       and (%(staff)s::uuid is null or t.staff_id = %(staff)s)
       and (%(status)s::text is null or t.status = %(status)s)
     order by g.sequence_no, sec.name, {order} t.effective_from desc, t.id
"""
_TEACHING = _LIST.format(
    table="teaching_assignments",
    subject_cols="t.subject_id, sb.subject_code, sb.name as subject_name,",
    subject_ok="and sb.status = 'active' and gs.status = 'active'",
    subject_join="join public.subjects sb on sb.id = t.subject_id"
                 " join public.grade_subjects gs on gs.academic_year_id = t.academic_year_id"
                 " and gs.grade_level_id = t.grade_level_id and gs.subject_id = t.subject_id",
    order="sb.subject_code,")
_CLASS = _LIST.format(table="class_teacher_assignments", subject_cols="", subject_ok="", subject_join="", order="")


def _list(statement: str):
    def endpoint(year_id: uuid.UUID, section_id: uuid.UUID | None = None, staff_id: uuid.UUID | None = None,
                 status: str | None = None, c: dict = Depends(claims), database: Database = Depends(db)) -> dict:
        def work(conn):
            _visible(conn, "academic_years", year_id)
            return {"rows": conn.execute(statement, {"year": year_id, "section": section_id, "staff": staff_id, "status": status}).fetchall()}
        return _tx(c, database, work)
    return endpoint


router.get("/academic-years/{year_id}/teaching-assignments")(_list(_TEACHING))
router.get("/academic-years/{year_id}/class-teachers")(_list(_CLASS))


def _insert(conn, table: str, section_id: uuid.UUID, staff_id: uuid.UUID, effective_from: datetime.date | None,
            subject_id: uuid.UUID | None = None) -> dict:
    """السياق كله من صف الشعبة المرئي؛ «اليوم» بتوقيت المدرسة حين لا يُحدَّد تاريخ."""
    subject_col = "subject_id, " if subject_id is not None else ""
    subject_val = "%(subject)s, " if subject_id is not None else ""
    row = conn.execute(
        f"insert into public.{table} (platform_tenant_id, school_id, academic_year_id, grade_level_id, section_id, {subject_col}staff_id, effective_from)"
        f" select sc.platform_tenant_id, s.school_id, s.academic_year_id, s.grade_level_id, s.id, {subject_val}%(staff)s,"
        "        coalesce(%(from)s::date, (now() at time zone sc.timezone)::date)"
        "   from public.sections s join public.schools sc on sc.id = s.school_id where s.id = %(section)s returning id",
        {"section": section_id, "subject": subject_id, "staff": staff_id, "from": effective_from}).fetchone()
    if row is None:
        raise _NOT_FOUND
    return _visible(conn, table, row["id"])


@router.post("/sections/{section_id}/teaching-assignments", status_code=201)
def assign_teacher(section_id: uuid.UUID, body: NewTeaching, c: dict = Depends(claims), database: Database = Depends(db)) -> dict:
    def work(conn):
        _visible(conn, "sections", section_id)
        _reason(conn, body.reason)
        return _insert(conn, "teaching_assignments", section_id, body.staff_id, body.effective_from, body.subject_id)
    return _tx(c, database, work)


@router.post("/sections/{section_id}/class-teacher", status_code=201)
def assign_class_teacher(section_id: uuid.UUID, body: NewClassTeacher, c: dict = Depends(claims), database: Database = Depends(db)) -> dict:
    def work(conn):
        _visible(conn, "sections", section_id)
        _reason(conn, body.reason)
        return _insert(conn, "class_teacher_assignments", section_id, body.staff_id, body.effective_from)
    return _tx(c, database, work)


def _end(table: str, function: str):
    def endpoint(assignment_id: uuid.UUID, body: EndAssignment, c: dict = Depends(claims), database: Database = Depends(db)) -> dict:
        def work(conn):
            _visible(conn, table, assignment_id)
            _call(conn, f"select app.{function}(%s, %s, %s)", [assignment_id, body.effective_to, body.reason])
            return _visible(conn, table, assignment_id)
        return _tx(c, database, work)
    return endpoint


def _replace(table: str, function: str):
    def endpoint(assignment_id: uuid.UUID, body: Replacement, c: dict = Depends(claims), database: Database = Depends(db)) -> dict:
        """T5: إنهاء القديم (في يوم بداية الجديد) ثم إدراج الجديد للشعبة — والمادة — نفسيهما، في معاملة واحدة."""
        def work(conn):
            old = _visible(conn, table, assignment_id)
            _call(conn, f"select app.{function}(%s, %s, %s)", [assignment_id, body.effective_from, body.reason])
            _reason(conn, body.reason)                      # الدالة تمسح سياق التدقيق؛ الإدراج في سنة نشطة يحتاجه (C3)
            return _insert(conn, table, old["section_id"], body.staff_id, body.effective_from, old.get("subject_id"))
        return _tx(c, database, work)
    return endpoint


router.post("/teaching-assignments/{assignment_id}/end")(_end("teaching_assignments", "end_teaching_assignment"))
router.post("/teaching-assignments/{assignment_id}/replace", status_code=201)(_replace("teaching_assignments", "end_teaching_assignment"))
router.post("/class-teacher-assignments/{assignment_id}/end")(_end("class_teacher_assignments", "end_class_teacher_assignment"))
router.post("/class-teacher-assignments/{assignment_id}/replace", status_code=201)(_replace("class_teacher_assignments", "end_class_teacher_assignment"))
