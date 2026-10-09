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
from .setup import _COLUMNS, _NOT_FOUND, Reason, _Body, _call, _reason, _tx, _update, _visible

router = APIRouter()

_COLUMNS.update({
    "teacher_load_limits": "id, school_id, academic_year_id, staff_id, max_weekly_periods",
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


class LoadLimit(_Body):
    max_weekly_periods: int | None = Field(ge=1, le=100)          # مطلوب صراحةً؛ null = بلا حد (L3)
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


# 3-4 — «شعبي وموادي»: تكليفاتي **الفعّالة** (شروط P5 نفسها — عرض، والقرار في RLS) في السنوات غير المغلقة.
# معرّف الموظف من صف staff المرئي بفرع الذات؛ صفوف التكليف نفسها تحت RLS (staff.read) — بلا المفتاح أو بلا صف موظف ← قائمة فارغة.
_MINE = """
    select t.kind, t.id, t.school_id, sc.name as school_name, t.academic_year_id, y.name as academic_year_name,
           t.section_id, sec.name as section_name, t.grade_level_id, g.name as grade_level_name,
           t.subject_id, sb.subject_code, sb.name as subject_name, t.effective_from
      from (select 'teaching' as kind, id, school_id, academic_year_id, grade_level_id, section_id, subject_id, staff_id, status, effective_from
              from public.teaching_assignments
            union all
            select 'class_teacher', id, school_id, academic_year_id, grade_level_id, section_id, null, staff_id, status, effective_from
              from public.class_teacher_assignments) t
      join public.staff me on me.id = t.staff_id
      join public.profiles p on p.id = me.profile_id and p.auth_user_id = auth.uid()
      join public.academic_years y on y.id = t.academic_year_id
      join public.sections sec on sec.id = t.section_id
      join public.grade_levels g on g.id = t.grade_level_id
      left join public.schools sc on sc.id = t.school_id
      left join public.subjects sb on sb.id = t.subject_id
     where t.status = 'active' and me.status = 'active' and y.status <> 'closed' and sec.status = 'active'
       and exists (select 1 from public.staff_school_assignments a
                    where a.staff_id = t.staff_id and a.school_id = t.school_id and a.status = 'active')
       and (t.kind = 'class_teacher'
            or (sb.status = 'active'
                and exists (select 1 from public.grade_subjects gs
                             where gs.academic_year_id = t.academic_year_id and gs.grade_level_id = t.grade_level_id
                               and gs.subject_id = t.subject_id and gs.status = 'active')))
     order by sc.name, y.start_date desc, g.sequence_no, sec.name, t.kind, sb.subject_code
"""


@router.get("/me/teaching")
def my_teaching(c: dict = Depends(claims), database: Database = Depends(db)) -> dict:
    return _tx(c, database, lambda conn: {"rows": conn.execute(_MINE).fetchall()})


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


# ------------------------------------------------------------------ 3-5 — النصاب (docs/PHASE3_5_WORKLOAD.md)
# النصاب **مشتق غير مخزّن** (L2): Σ weekly_periods لتكليفات التدريس active التي شعبتها ومادتها وربطها active.
#   المنتهي لا يُحتسب؛ «المعلَّق» (شعبة أو مادة أو ربط معطَّل) يُعدّ منفصلاً؛ مربي الفصل بلا حصص؛ الموظف on_leave يُحتسب (تخطيط لا أمان).
# الحد يُقرأ تحت RLS (staff.assign + النطاق، أو صف الفاعل — L5). limit_visible يُشتق من القاعدة نفسها لا من وجود الصف:
#   RLS لا تميّز «مخفي» من «غير موجود»، فمن لا يرى الحد يحصل على null/null لا على «بلا حد».
# over_limit = النصاب > الحد (التساوي ليس تجاوزاً). **عرض فقط — لا مسار كتابة للتكليف يقرأ النصاب** (L7).
_LOAD = """
    with t as (
      select t.staff_id, t.status, gs.weekly_periods,
             (t.status = 'active' and sec.status = 'active' and sb.status = 'active' and gs.status = 'active') as counted
        from public.teaching_assignments t
        join public.sections sec on sec.id = t.section_id
        join public.subjects sb on sb.id = t.subject_id
        join public.grade_subjects gs on gs.academic_year_id = t.academic_year_id
                                     and gs.grade_level_id = t.grade_level_id and gs.subject_id = t.subject_id
       where t.academic_year_id = %(year)s
    ), agg as (
      select staff_id,
             coalesce(sum(weekly_periods) filter (where counted), 0)::int as weekly_periods,
             count(*) filter (where counted)::int as teaching_count,
             count(*) filter (where status = 'active' and not counted)::int as suspended_count
        from t group by staff_id
    ), ct as (
      select c.staff_id, count(*)::int as class_teacher_count
        from public.class_teacher_assignments c
        join public.sections sec on sec.id = c.section_id
       where c.academic_year_id = %(year)s and c.status = 'active' and sec.status = 'active'
       group by c.staff_id
    ), lim as (
      select staff_id, max_weekly_periods from public.teacher_load_limits where academic_year_id = %(year)s
    ), ids as (
      select staff_id from agg where teaching_count + suspended_count > 0
      union select staff_id from ct
      union select staff_id from lim where max_weekly_periods is not null
    )
    select i.staff_id, st.full_name as staff_name, st.employee_code, st.status as staff_status,
           coalesce(a.weekly_periods, 0) as weekly_periods, coalesce(a.teaching_count, 0) as teaching_count,
           coalesce(a.suspended_count, 0) as suspended_count, coalesce(c.class_teacher_count, 0) as class_teacher_count,
           v.limit_visible,
           case when v.limit_visible then l.max_weekly_periods end as max_weekly_periods,
           case when v.limit_visible then coalesce(coalesce(a.weekly_periods, 0) > l.max_weekly_periods, false) end as over_limit
      from ids i
      join public.academic_years y on y.id = %(year)s
      left join public.staff st on st.id = i.staff_id
      left join agg a on a.staff_id = i.staff_id
      left join ct c on c.staff_id = i.staff_id
      left join lim l on l.staff_id = i.staff_id
      cross join lateral (select coalesce((app.can_access_school(y.school_id) and app.has_permission('staff.assign'))
                                          or i.staff_id = app.current_staff_id(), false) as limit_visible) v
     order by st.full_name, i.staff_id
"""


@router.get("/academic-years/{year_id}/teacher-load")
def teacher_load(year_id: uuid.UUID, c: dict = Depends(claims), database: Database = Depends(db)) -> dict:
    def work(conn):
        _visible(conn, "academic_years", year_id)
        return {"rows": conn.execute(_LOAD, {"year": year_id}).fetchall()}
    return _tx(c, database, work)


@router.put("/academic-years/{year_id}/teacher-load-limits/{staff_id}")
def set_load_limit(year_id: uuid.UUID, staff_id: uuid.UUID, body: LoadLimit,
                   c: dict = Depends(claims), database: Database = Depends(db)) -> dict:
    """الحد الاختياري لموظف في سنة (L3): موجود ومرئي ← تعديل؛ وإلا إدراج — والقرار كله في DB (RLS: staff.assign + النطاق؛ T18).
    السنة والموظف أهداف في المسار؛ الـTenant والمدرسة من صف السنة. null = بلا حد (لا حذف)."""
    def work(conn):
        _visible(conn, "academic_years", year_id)
        _visible(conn, "staff", staff_id)
        _reason(conn, body.reason)
        current = conn.execute("select id from public.teacher_load_limits where academic_year_id = %s and staff_id = %s",
                               [year_id, staff_id]).fetchone()
        if current is not None:
            return _update(conn, "teacher_load_limits", current["id"], {"max_weekly_periods": body.max_weekly_periods})
        row = _call(conn, "insert into public.teacher_load_limits (platform_tenant_id, school_id, academic_year_id, staff_id, max_weekly_periods)"
                          " select sc.platform_tenant_id, y.school_id, y.id, %s, %s"
                          "   from public.academic_years y join public.schools sc on sc.id = y.school_id where y.id = %s returning id",
                    [staff_id, body.max_weekly_periods, year_id])
        if row is None:
            raise _NOT_FOUND
        return _visible(conn, "teacher_load_limits", row["id"])
    return _tx(c, database, work)
