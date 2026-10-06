"""Phase 2A / P2-C — إعداد المدرسة: المجموعات، المدارس، السنوات، الفصول، المراحل، الصفوف، الشعب، الجاهزية.

المسار الوحيد للسلطة (F4):  JWT مُتحقَّق منه → معاملة `authenticated` واحدة → RLS ودوال app.* تقرر → النتيجة.
لا تفويض في Python: لا فحص دور ولا مفتاح يقرر السماح. ما يرد من العميل:
  • معرّفات في المسار = **أهداف** فقط؛ RLS تقرر رؤيتها وكتابتها.
  • لا platform_tenant_id ولا school_id في أي جسم (`extra="forbid"`): الـTenant من `app.current_tenant_id()`،
    ومدرسة الصف التابع من صف أبيه المقروء تحت RLS.
قواعد الرد (docs/PHASE2_SCHOOL_SETUP.md §10):
  • غير مرئي = غير موجود ← 404 (لا كشف وجود).
  • مرئي والكتابة مرفوضة ← 403.
  • التفرد 409، التداخل 409، الانتقال/المدخل/القيد 422 (deps._SQLSTATE).
لا DELETE في أي مسار. الانتقالات ونسخ الشعب وتغيير الـslug بدوال M21/M33–M37 المتحكَّم بها.
"""

import datetime
import uuid
from typing import Any, Callable

import psycopg
from fastapi import APIRouter, Depends, HTTPException
from psycopg import sql
from pydantic import BaseModel, ConfigDict, Field

from .db import Database
from .deps import claims, db, http_error

router = APIRouter()

_NOT_FOUND = HTTPException(status_code=404, detail="not_found")
_FORBIDDEN = HTTPException(status_code=403, detail="forbidden")
_EMPTY = HTTPException(status_code=422, detail="invalid_request")


class _Body(BaseModel):
    model_config = ConfigDict(extra="forbid")      # لا سياق ولا سلطة من الجسم


class Reason(_Body):
    reason: str = Field(min_length=1, max_length=500)


class NewGroup(_Body):
    group_code: str = Field(min_length=2, max_length=32)
    name: str = Field(min_length=1, max_length=200)


class GroupPatch(_Body):
    name: str | None = Field(default=None, min_length=1, max_length=200)


class NewSchool(_Body):
    group_id: uuid.UUID | None = None
    school_code: str = Field(min_length=2, max_length=32)
    name: str = Field(min_length=1, max_length=200)
    slug: str = Field(min_length=1, max_length=63)
    timezone: str | None = Field(default=None, max_length=64)


class SchoolPatch(_Body):
    name: str | None = Field(default=None, min_length=1, max_length=200)
    timezone: str | None = Field(default=None, min_length=1, max_length=64)


class SlugChange(Reason):
    slug: str = Field(min_length=1, max_length=63)


class NewYear(_Body):
    name: str = Field(min_length=1, max_length=100)
    start_date: datetime.date
    end_date: datetime.date


class YearPatch(_Body):
    name: str | None = Field(default=None, min_length=1, max_length=100)
    start_date: datetime.date | None = None
    end_date: datetime.date | None = None


class NewTerm(_Body):
    name: str = Field(min_length=1, max_length=100)
    sequence_no: int = Field(gt=0)
    start_date: datetime.date
    end_date: datetime.date


class TermPatch(_Body):
    name: str | None = Field(default=None, min_length=1, max_length=100)
    sequence_no: int | None = Field(default=None, gt=0)
    start_date: datetime.date | None = None
    end_date: datetime.date | None = None


class NewStage(_Body):
    name: str = Field(min_length=1, max_length=100)
    sequence_no: int = Field(gt=0)


class StagePatch(_Body):
    name: str | None = Field(default=None, min_length=1, max_length=100)
    sequence_no: int | None = Field(default=None, gt=0)
    status: str | None = Field(default=None, pattern="^(active|inactive)$")


class NewGradeLevel(NewStage):
    stage_id: uuid.UUID


class GradeLevelPatch(StagePatch):
    stage_id: uuid.UUID | None = None


class NewSection(_Body):
    grade_level_id: uuid.UUID
    name: str = Field(min_length=1, max_length=50)
    capacity: int | None = Field(default=None, gt=0)
    gender_policy: str = Field(default="mixed", pattern="^(mixed|male_only|female_only)$")


class SectionPatch(_Body):
    name: str | None = Field(default=None, min_length=1, max_length=50)
    capacity: int | None = Field(default=None, gt=0)
    gender_policy: str | None = Field(default=None, pattern="^(mixed|male_only|female_only)$")
    status: str | None = Field(default=None, pattern="^(active|inactive)$")


class CopySections(Reason):
    source_year_id: uuid.UUID


class NewSubject(_Body):
    subject_code: str = Field(min_length=2, max_length=32)
    name: str = Field(min_length=1, max_length=200)


class SubjectPatch(_Body):
    name: str | None = Field(default=None, min_length=1, max_length=200)
    status: str | None = Field(default=None, pattern="^(active|inactive)$")


class NewGradeSubject(_Body):
    grade_level_id: uuid.UUID
    subject_id: uuid.UUID
    weekly_periods: int = Field(ge=1, le=60)
    counts_toward_total: bool = True


class GradeSubjectPatch(_Body):
    weekly_periods: int | None = Field(default=None, ge=1, le=60)
    counts_toward_total: bool | None = None
    status: str | None = Field(default=None, pattern="^(active|inactive)$")


class CopyGradeSubjects(CopySections):
    pass


class Weekdays(Reason):
    weekdays: list[int] = Field(min_length=1, max_length=7)


class CopyWeekdays(CopySections):
    pass


class NewCalendarException(_Body):
    kind: str = Field(pattern="^(holiday|study_day)$")
    name: str = Field(min_length=1, max_length=200)
    start_date: datetime.date
    end_date: datetime.date
    reason: str | None = Field(default=None, max_length=500)


class NewBellSchedule(_Body):
    name: str = Field(min_length=1, max_length=100)
    reason: str | None = Field(default=None, max_length=500)


class BellSchedulePatch(_Body):
    name: str | None = Field(default=None, min_length=1, max_length=100)
    status: str | None = Field(default=None, pattern="^(active|inactive)$")
    reason: str | None = Field(default=None, max_length=500)


class NewBellPeriod(_Body):
    weekday: int = Field(ge=0, le=6)
    kind: str = Field(pattern="^(lesson|break)$")
    name: str | None = Field(default=None, min_length=1, max_length=100)
    start_time: datetime.time
    end_time: datetime.time
    reason: str | None = Field(default=None, max_length=500)


class BellPeriodPatch(_Body):
    weekday: int | None = Field(default=None, ge=0, le=6)
    kind: str | None = Field(default=None, pattern="^(lesson|break)$")
    name: str | None = Field(default=None, min_length=1, max_length=100)
    start_time: datetime.time | None = None
    end_time: datetime.time | None = None
    status: str | None = Field(default=None, pattern="^(active|inactive)$")
    reason: str | None = Field(default=None, max_length=500)


class CopyBellDay(Reason):
    from_weekday: int = Field(ge=0, le=6)
    to_weekdays: list[int] = Field(min_length=1, max_length=6)


class GradeBellSchedule(_Body):
    bell_schedule_id: uuid.UUID
    reason: str | None = Field(default=None, max_length=500)


class CopyBellSchedules(CopySections):
    pass


class CalendarExceptionPatch(_Body):
    name: str | None = Field(default=None, min_length=1, max_length=200)
    start_date: datetime.date | None = None
    end_date: datetime.date | None = None
    reason: str | None = Field(default=None, max_length=500)


# الأعمدة المقروءة لكل مورد — والأعمدة التي يقبلها PATCH هي حقول نموذجه وحدها (سجل §4.6 في DB هو الحد الفعلي)
_COLUMNS = {
    "groups": "id, group_code, name, status",
    "schools": "id, group_id, school_code, name, slug, timezone, status, is_standalone, guardian_first_login_mode",
    "academic_years": "id, school_id, name, start_date, end_date, status",
    "terms": "id, academic_year_id, school_id, name, sequence_no, start_date, end_date, status",
    "stages": "id, school_id, name, sequence_no, status",
    "grade_levels": "id, school_id, stage_id, name, sequence_no, status",
    "sections": "id, school_id, academic_year_id, grade_level_id, name, capacity, gender_policy, status",
    "subjects": "id, school_id, subject_code, name, status",
    "grade_subjects": "id, school_id, academic_year_id, grade_level_id, subject_id, weekly_periods, counts_toward_total, status",
    "calendar_weekdays": "id, school_id, academic_year_id, weekday, status",
    "calendar_exceptions": "id, school_id, academic_year_id, kind, name, start_date, end_date, status",
    "bell_schedules": "id, school_id, academic_year_id, name, status",
    "bell_periods": "id, school_id, academic_year_id, bell_schedule_id, weekday, kind, name, start_time, end_time, status",
    "grade_level_bell_schedules": "id, school_id, academic_year_id, grade_level_id, bell_schedule_id",
}


def _tx(c: dict, database: Database, work: Callable[[psycopg.Connection], Any]) -> Any:
    try:
        with database.as_user(c) as conn:
            return work(conn)
    except psycopg.Error as exc:
        raise http_error(exc) from exc


def _row(conn: psycopg.Connection, table: str, row_id: Any) -> dict | None:
    return conn.execute(sql.SQL("select {} from public.{} where id = %s").format(sql.SQL(_COLUMNS[table]), sql.Identifier(table)),
                        [row_id]).fetchone()


def _visible(conn: psycopg.Connection, table: str, row_id: Any) -> dict:
    row = _row(conn, table, row_id)
    if row is None:
        raise _NOT_FOUND
    return row


def _rows(conn: psycopg.Connection, table: str, where: str = "true", params: list | None = None, order: str = "name") -> list[dict]:
    q = sql.SQL("select {} from public.{} where " + where + " order by " + order + ", id").format(
        sql.SQL(_COLUMNS[table]), sql.Identifier(table))
    return conn.execute(q, params or []).fetchall()


def _patch(conn: psycopg.Connection, table: str, row_id: uuid.UUID, body: _Body, exclude: set[str] | None = None) -> dict:
    return _update(conn, table, row_id, body.model_dump(exclude_unset=True, exclude=exclude))


def _reason(conn: psycopg.Connection, reason: str | None) -> None:
    """C3 (2B-2): السبب من الجسم إلى سياق التدقيق في معاملة الكتابة نفسها. ليس سلطة — DB تقرر هل هو مطلوب، وT7 يسجله."""
    conn.execute("select set_config('app.audit_reason', %s, true)", [reason or ""])


def _update(conn: psycopg.Connection, table: str, row_id: uuid.UUID, changes: dict) -> dict:
    if not changes:
        raise _EMPTY
    q = sql.SQL("update public.{} set {} where id = %s returning id").format(
        sql.Identifier(table),
        sql.SQL(", ").join(sql.SQL("{} = %s").format(sql.Identifier(k)) for k in changes))
    if conn.execute(q, [*changes.values(), row_id]).fetchone() is None:
        # لا صف أصابه UPDATE: مرئي ⇒ الكتابة مرفوضة (403)، وإلا غير موجود (404)
        raise _FORBIDDEN if _row(conn, table, row_id) is not None else _NOT_FOUND
    return _visible(conn, table, row_id)


def _call(conn: psycopg.Connection, statement: str, params: list) -> Any:
    return conn.execute(statement, params).fetchone()


# ------------------------------------------------------------------ groups
@router.get("/groups")
def list_groups(c: dict = Depends(claims), database: Database = Depends(db)) -> dict:
    return {"rows": _tx(c, database, lambda conn: _rows(conn, "groups"))}


@router.post("/groups", status_code=201)
def create_group(body: NewGroup, c: dict = Depends(claims), database: Database = Depends(db)) -> dict:
    def work(conn):
        # بلا RETURNING: سياسة SELECT تقرأ الجدول بلقطة العبارة فلا ترى الصف الجاري إدراجه (§10 من الوثيقة)
        conn.execute("insert into public.groups (platform_tenant_id, group_code, name) values ((select app.current_tenant_id()), %s, %s)",
                     [body.group_code, body.name])
        return _rows(conn, "groups", "platform_tenant_id = (select app.current_tenant_id()) and group_code = %s", [body.group_code])[0]
    return _tx(c, database, work)


@router.patch("/groups/{group_id}")
def update_group(group_id: uuid.UUID, body: GroupPatch, c: dict = Depends(claims), database: Database = Depends(db)) -> dict:
    return _tx(c, database, lambda conn: _patch(conn, "groups", group_id, body))


@router.post("/groups/{group_id}/archive")
def archive_group(group_id: uuid.UUID, body: Reason, c: dict = Depends(claims), database: Database = Depends(db)) -> dict:
    def work(conn):
        _call(conn, "select app.archive_group(%s, %s)", [group_id, body.reason])
        return _visible(conn, "groups", group_id)
    return _tx(c, database, work)


# ------------------------------------------------------------------ schools
@router.get("/schools")
def list_schools(c: dict = Depends(claims), database: Database = Depends(db)) -> dict:
    return {"rows": _tx(c, database, lambda conn: _rows(conn, "schools"))}


@router.post("/schools", status_code=201)
def create_school(body: NewSchool, c: dict = Depends(claims), database: Database = Depends(db)) -> dict:
    def work(conn):
        conn.execute(
            "insert into public.schools (platform_tenant_id, group_id, school_code, name, slug, timezone)"
            " values ((select app.current_tenant_id()), %s, %s, %s, %s, coalesce(%s, 'Africa/Cairo'))",
            [body.group_id, body.school_code, body.name, body.slug, body.timezone])
        return _rows(conn, "schools", "platform_tenant_id = (select app.current_tenant_id()) and school_code = %s", [body.school_code])[0]
    return _tx(c, database, work)


@router.patch("/schools/{school_id}")
def update_school(school_id: uuid.UUID, body: SchoolPatch, c: dict = Depends(claims), database: Database = Depends(db)) -> dict:
    return _tx(c, database, lambda conn: _patch(conn, "schools", school_id, body))


@router.post("/schools/{school_id}/slug")
def change_slug(school_id: uuid.UUID, body: SlugChange, c: dict = Depends(claims), database: Database = Depends(db)) -> dict:
    def work(conn):
        _call(conn, "select app.set_school_slug(%s, %s, %s)", [school_id, body.slug, body.reason])
        return _visible(conn, "schools", school_id)
    return _tx(c, database, work)


@router.post("/schools/{school_id}/archive")
def archive_school(school_id: uuid.UUID, body: Reason, c: dict = Depends(claims), database: Database = Depends(db)) -> dict:
    def work(conn):
        _call(conn, "select app.archive_school(%s, %s)", [school_id, body.reason])
        return _visible(conn, "schools", school_id)
    return _tx(c, database, work)


_READINESS = """
    select s.status = 'active' as school_active,
           exists (select 1 from public.academic_years y where y.school_id = s.id and y.status = 'active') as active_year,
           exists (select 1 from public.sections x join public.academic_years y on y.id = x.academic_year_id
                    where x.school_id = s.id and x.status = 'active' and y.status = 'active') as active_section
    from public.schools s where s.id = %s
"""


@router.get("/schools/{school_id}/readiness")
def readiness(school_id: uuid.UUID, c: dict = Depends(claims), database: Database = Depends(db)) -> dict:
    """ready_for_enrollment مشتقة غير مخزنة (§3). تُقرأ تحت RLS، فتُطلب صلاحيتا قراءة السنة والشعبة من قاعدة البيانات
    — بدونهما تكون الشروط «غير مرئية» لا «غير متحققة»."""
    def work(conn):
        _visible(conn, "schools", school_id)
        if not conn.execute("select app.has_permission('academic_year.read') and app.has_permission('section.read') as ok").fetchone()["ok"]:
            raise _FORBIDDEN
        checks = conn.execute(_READINESS, [school_id]).fetchone()
        return {"ready": all(checks.values()), "checks": checks}
    return _tx(c, database, work)


# ------------------------------------------------------------------ setup progress (Phase 2B / 2B-5 — W1–W6)
# المعالج طبقة orchestration/visibility فقط: هذا المسار قراءة مشتقة تحت RLS بصلاحيات المستخدم الفعلية — لا تخزين ولا كتابة،
# ولا يغيّر ready_for_enrollment (يُحسب باستعلام _READINESS نفسه، تعريف 2A حرفياً).
_PROGRESS_KEYS = ("school.read", "academic_year.read", "term.read", "stage.read", "grade_level.read", "section.read", "subject.read")

# W2: الصفوف «المعنية» = الصفوف النشطة التي لها شعب نشطة في سنة الإعداد؛ المواد والدوام شرط شامل عليها كلها.
_PROGRESS = """
    with graded as (
      select distinct g.id from public.grade_levels g join public.sections x on x.grade_level_id = g.id
       where g.school_id = %(school)s and g.status = 'active' and x.academic_year_id = %(year)s and x.status = 'active')
    select
      exists (select 1 from public.school_profiles p where p.school_id = %(school)s and p.address is not null and p.phone_e164 is not null) as profile,
      %(year)s::uuid is not null and exists (select 1 from public.terms t where t.academic_year_id = %(year)s) as year,
      exists (select 1 from public.calendar_weekdays w where w.academic_year_id = %(year)s and w.status = 'active') as calendar,
      exists (select 1 from public.stages st where st.school_id = %(school)s and st.status = 'active')
        and exists (select 1 from public.grade_levels g where g.school_id = %(school)s and g.status = 'active')
        and exists (select 1 from graded) as structure,
      (select count(*) from graded) as graded,
      (select count(*) from graded g where not exists (
         select 1 from public.grade_subjects gs where gs.academic_year_id = %(year)s and gs.grade_level_id = g.id and gs.status = 'active')) as subjects_missing,
      (select count(*) from graded g where not exists (
         select 1 from public.grade_level_bell_schedules a
           join public.bell_schedules b on b.id = a.bell_schedule_id and b.status = 'active'
          where a.academic_year_id = %(year)s and a.grade_level_id = g.id
            and exists (select 1 from public.bell_periods bp where bp.bell_schedule_id = b.id and bp.kind = 'lesson' and bp.status = 'active'))) as bell_missing,
      exists (select 1 from public.school_assets a where a.school_id = %(school)s and a.kind = 'logo' and a.status = 'active') as assets
"""


@router.get("/schools/{school_id}/setup-progress")
def setup_progress(school_id: uuid.UUID, year_id: uuid.UUID | None = None, c: dict = Depends(claims), database: Database = Depends(db)) -> dict:
    """W1: سنة القياس = year_id المختارة صراحةً (غير مغلقة ومرئية)، وإلا النشطة، وإلا أقرب planned — لا تُخزَّن.
    W4: المدرسة غير مرئية ← 404؛ نقص أي مفتاح قراءة ← 403 (الشروط «غير مرئية» لا «غير مكتملة»)."""
    def work(conn):
        _visible(conn, "schools", school_id)
        keys = conn.execute("select bool_and(app.has_permission(k)) as ok from unnest(%s::text[]) k", [list(_PROGRESS_KEYS)]).fetchone()
        if not keys["ok"]:
            raise _FORBIDDEN
        if year_id is not None:
            year = conn.execute("select id, name, status from public.academic_years where id = %s and school_id = %s and status <> 'closed'",
                                [year_id, school_id]).fetchone()
            if year is None:
                raise _NOT_FOUND
        else:
            year = conn.execute("select id, name, status from public.academic_years where school_id = %s and status in ('active', 'planned')"
                                " order by (status = 'active') desc, start_date limit 1", [school_id]).fetchone()
        r = conn.execute(_PROGRESS, {"school": school_id, "year": year["id"] if year else None}).fetchone()
        subjects = r["graded"] > 0 and r["subjects_missing"] == 0
        bell = r["graded"] > 0 and r["bell_missing"] == 0
        steps = [
            {"key": "profile", "done": r["profile"]},
            {"key": "year", "done": bool(r["year"])},
            {"key": "calendar", "done": r["calendar"]},
            {"key": "structure", "done": r["structure"]},
            {"key": "subjects", "done": subjects, "missing": r["subjects_missing"]},
            {"key": "bell", "done": bell, "missing": r["bell_missing"]},
            {"key": "assets", "done": r["assets"], "optional": True},
        ]
        ready = conn.execute(_READINESS, [school_id]).fetchone()
        return {
            "year": year,
            "steps": steps,
            # W3: الخطوات 1–6 وحدها — لا الأصول ولا الجاهزية
            "setup_complete": all(s["done"] for s in steps if not s.get("optional")),
            "ready_for_enrollment": all(ready.values()),
        }
    return _tx(c, database, work)


# ------------------------------------------------------------------ academic years
@router.get("/schools/{school_id}/academic-years")
def list_years(school_id: uuid.UUID, c: dict = Depends(claims), database: Database = Depends(db)) -> dict:
    def work(conn):
        _visible(conn, "schools", school_id)
        return {"rows": _rows(conn, "academic_years", "school_id = %s", [school_id], order="start_date")}
    return _tx(c, database, work)


@router.post("/schools/{school_id}/academic-years", status_code=201)
def create_year(school_id: uuid.UUID, body: NewYear, c: dict = Depends(claims), database: Database = Depends(db)) -> dict:
    def work(conn):
        _visible(conn, "schools", school_id)
        row = _call(conn, "insert into public.academic_years (school_id, name, start_date, end_date) values (%s, %s, %s, %s) returning id",
                    [school_id, body.name, body.start_date, body.end_date])
        return _visible(conn, "academic_years", row["id"])
    return _tx(c, database, work)


@router.patch("/academic-years/{year_id}")
def update_year(year_id: uuid.UUID, body: YearPatch, c: dict = Depends(claims), database: Database = Depends(db)) -> dict:
    return _tx(c, database, lambda conn: _patch(conn, "academic_years", year_id, body))


def _year_transition(function: str):
    def endpoint(year_id: uuid.UUID, body: Reason, c: dict = Depends(claims), database: Database = Depends(db)) -> dict:
        def work(conn):
            _call(conn, f"select app.{function}(%s, %s)", [year_id, body.reason])
            return _visible(conn, "academic_years", year_id)
        return _tx(c, database, work)
    return endpoint


router.post("/academic-years/{year_id}/activate")(_year_transition("activate_academic_year"))
router.post("/academic-years/{year_id}/close")(_year_transition("close_academic_year"))


@router.post("/academic-years/{year_id}/copy-sections")
def copy_sections(year_id: uuid.UUID, body: CopySections, c: dict = Depends(claims), database: Database = Depends(db)) -> dict:
    """M37: عملية domain واحدة ذرية — لا loop هنا؛ year_id هو الهدف."""
    def work(conn):
        created = _call(conn, "select app.copy_sections(%s, %s, %s) as n", [body.source_year_id, year_id, body.reason])["n"]
        return {"created": created}
    return _tx(c, database, work)


# ------------------------------------------------------------------ terms
@router.get("/academic-years/{year_id}/terms")
def list_terms(year_id: uuid.UUID, c: dict = Depends(claims), database: Database = Depends(db)) -> dict:
    def work(conn):
        _visible(conn, "academic_years", year_id)
        return {"rows": _rows(conn, "terms", "academic_year_id = %s", [year_id], order="sequence_no")}
    return _tx(c, database, work)


@router.post("/academic-years/{year_id}/terms", status_code=201)
def create_term(year_id: uuid.UUID, body: NewTerm, c: dict = Depends(claims), database: Database = Depends(db)) -> dict:
    def work(conn):
        _visible(conn, "academic_years", year_id)
        # المدرسة وحدود السنة من صف السنة المقروء تحت RLS — لا من العميل
        row = _call(conn,
                    "insert into public.terms (academic_year_id, school_id, year_start_date, year_end_date, name, sequence_no, start_date, end_date)"
                    " select y.id, y.school_id, y.start_date, y.end_date, %s, %s, %s, %s from public.academic_years y where y.id = %s returning id",
                    [body.name, body.sequence_no, body.start_date, body.end_date, year_id])
        return _visible(conn, "terms", row["id"])
    return _tx(c, database, work)


@router.patch("/terms/{term_id}")
def update_term(term_id: uuid.UUID, body: TermPatch, c: dict = Depends(claims), database: Database = Depends(db)) -> dict:
    return _tx(c, database, lambda conn: _patch(conn, "terms", term_id, body))


def _term_transition(function: str):
    def endpoint(term_id: uuid.UUID, body: Reason, c: dict = Depends(claims), database: Database = Depends(db)) -> dict:
        def work(conn):
            _call(conn, f"select app.{function}(%s, %s)", [term_id, body.reason])
            return _visible(conn, "terms", term_id)
        return _tx(c, database, work)
    return endpoint


router.post("/terms/{term_id}/activate")(_term_transition("activate_term"))
router.post("/terms/{term_id}/close")(_term_transition("close_term"))


# ------------------------------------------------------------------ stages / grade levels
@router.get("/schools/{school_id}/stages")
def list_stages(school_id: uuid.UUID, c: dict = Depends(claims), database: Database = Depends(db)) -> dict:
    def work(conn):
        _visible(conn, "schools", school_id)
        return {"rows": _rows(conn, "stages", "school_id = %s", [school_id], order="sequence_no")}
    return _tx(c, database, work)


@router.post("/schools/{school_id}/stages", status_code=201)
def create_stage(school_id: uuid.UUID, body: NewStage, c: dict = Depends(claims), database: Database = Depends(db)) -> dict:
    def work(conn):
        _visible(conn, "schools", school_id)
        row = _call(conn, "insert into public.stages (school_id, name, sequence_no) values (%s, %s, %s) returning id",
                    [school_id, body.name, body.sequence_no])
        return _visible(conn, "stages", row["id"])
    return _tx(c, database, work)


@router.patch("/stages/{stage_id}")
def update_stage(stage_id: uuid.UUID, body: StagePatch, c: dict = Depends(claims), database: Database = Depends(db)) -> dict:
    return _tx(c, database, lambda conn: _patch(conn, "stages", stage_id, body))


@router.get("/schools/{school_id}/grade-levels")
def list_grade_levels(school_id: uuid.UUID, c: dict = Depends(claims), database: Database = Depends(db)) -> dict:
    def work(conn):
        _visible(conn, "schools", school_id)
        return {"rows": _rows(conn, "grade_levels", "school_id = %s", [school_id], order="sequence_no")}
    return _tx(c, database, work)


@router.post("/schools/{school_id}/grade-levels", status_code=201)
def create_grade_level(school_id: uuid.UUID, body: NewGradeLevel, c: dict = Depends(claims), database: Database = Depends(db)) -> dict:
    def work(conn):
        _visible(conn, "schools", school_id)
        row = _call(conn, "insert into public.grade_levels (school_id, stage_id, name, sequence_no) values (%s, %s, %s, %s) returning id",
                    [school_id, body.stage_id, body.name, body.sequence_no])
        return _visible(conn, "grade_levels", row["id"])
    return _tx(c, database, work)


@router.patch("/grade-levels/{grade_level_id}")
def update_grade_level(grade_level_id: uuid.UUID, body: GradeLevelPatch, c: dict = Depends(claims), database: Database = Depends(db)) -> dict:
    return _tx(c, database, lambda conn: _patch(conn, "grade_levels", grade_level_id, body))


# ------------------------------------------------------------------ sections
@router.get("/academic-years/{year_id}/sections")
def list_sections(year_id: uuid.UUID, c: dict = Depends(claims), database: Database = Depends(db)) -> dict:
    def work(conn):
        _visible(conn, "academic_years", year_id)
        return {"rows": _rows(conn, "sections", "academic_year_id = %s", [year_id], order="grade_level_id, name")}
    return _tx(c, database, work)


@router.post("/academic-years/{year_id}/sections", status_code=201)
def create_section(year_id: uuid.UUID, body: NewSection, c: dict = Depends(claims), database: Database = Depends(db)) -> dict:
    def work(conn):
        _visible(conn, "academic_years", year_id)
        row = _call(conn,
                    "insert into public.sections (school_id, academic_year_id, grade_level_id, name, capacity, gender_policy)"
                    " select y.school_id, y.id, %s, %s, %s, %s from public.academic_years y where y.id = %s returning id",
                    [body.grade_level_id, body.name, body.capacity, body.gender_policy, year_id])
        return _visible(conn, "sections", row["id"])
    return _tx(c, database, work)


@router.patch("/sections/{section_id}")
def update_section(section_id: uuid.UUID, body: SectionPatch, c: dict = Depends(claims), database: Database = Depends(db)) -> dict:
    return _tx(c, database, lambda conn: _patch(conn, "sections", section_id, body))


# ------------------------------------------------------------------ subjects / grade subjects (Phase 2B / 2B-1 — M38–M40)
@router.get("/schools/{school_id}/subjects")
def list_subjects(school_id: uuid.UUID, c: dict = Depends(claims), database: Database = Depends(db)) -> dict:
    def work(conn):
        _visible(conn, "schools", school_id)
        return {"rows": _rows(conn, "subjects", "school_id = %s", [school_id], order="subject_code")}
    return _tx(c, database, work)


@router.post("/schools/{school_id}/subjects", status_code=201)
def create_subject(school_id: uuid.UUID, body: NewSubject, c: dict = Depends(claims), database: Database = Depends(db)) -> dict:
    def work(conn):
        _visible(conn, "schools", school_id)
        row = _call(conn, "insert into public.subjects (school_id, subject_code, name) values (%s, %s, %s) returning id",
                    [school_id, body.subject_code, body.name])
        return _visible(conn, "subjects", row["id"])
    return _tx(c, database, work)


@router.patch("/subjects/{subject_id}")
def update_subject(subject_id: uuid.UUID, body: SubjectPatch, c: dict = Depends(claims), database: Database = Depends(db)) -> dict:
    return _tx(c, database, lambda conn: _patch(conn, "subjects", subject_id, body))


@router.get("/academic-years/{year_id}/grade-subjects")
def list_grade_subjects(year_id: uuid.UUID, c: dict = Depends(claims), database: Database = Depends(db)) -> dict:
    def work(conn):
        _visible(conn, "academic_years", year_id)
        return {"rows": _rows(conn, "grade_subjects", "academic_year_id = %s", [year_id], order="grade_level_id, subject_id")}
    return _tx(c, database, work)


@router.post("/academic-years/{year_id}/grade-subjects", status_code=201)
def create_grade_subject(year_id: uuid.UUID, body: NewGradeSubject, c: dict = Depends(claims), database: Database = Depends(db)) -> dict:
    def work(conn):
        _visible(conn, "academic_years", year_id)
        # المدرسة من صف السنة المقروء تحت RLS؛ الـFKs المركّبة ترفض صفاً أو مادة من مدرسة أخرى
        row = _call(conn,
                    "insert into public.grade_subjects (school_id, academic_year_id, grade_level_id, subject_id, weekly_periods, counts_toward_total)"
                    " select y.school_id, y.id, %s, %s, %s, %s from public.academic_years y where y.id = %s returning id",
                    [body.grade_level_id, body.subject_id, body.weekly_periods, body.counts_toward_total, year_id])
        return _visible(conn, "grade_subjects", row["id"])
    return _tx(c, database, work)


@router.patch("/grade-subjects/{grade_subject_id}")
def update_grade_subject(grade_subject_id: uuid.UUID, body: GradeSubjectPatch, c: dict = Depends(claims), database: Database = Depends(db)) -> dict:
    return _tx(c, database, lambda conn: _patch(conn, "grade_subjects", grade_subject_id, body))


@router.post("/academic-years/{year_id}/copy-grade-subjects")
def copy_grade_subjects(year_id: uuid.UUID, body: CopyGradeSubjects, c: dict = Depends(claims), database: Database = Depends(db)) -> dict:
    """M40: عملية domain واحدة ذرية — لا loop هنا؛ year_id هو الهدف."""
    def work(conn):
        created = _call(conn, "select app.copy_grade_subjects(%s, %s, %s) as n", [body.source_year_id, year_id, body.reason])["n"]
        return {"created": created}
    return _tx(c, database, work)


# ------------------------------------------------------------------ calendar (Phase 2B / 2B-2 — M41، M42؛ C1–C5)
@router.get("/academic-years/{year_id}/weekdays")
def list_weekdays(year_id: uuid.UUID, c: dict = Depends(claims), database: Database = Depends(db)) -> dict:
    def work(conn):
        _visible(conn, "academic_years", year_id)
        return {"rows": _rows(conn, "calendar_weekdays", "academic_year_id = %s", [year_id], order="weekday")}
    return _tx(c, database, work)


@router.put("/academic-years/{year_id}/weekdays")
def set_weekdays(year_id: uuid.UUID, body: Weekdays, c: dict = Depends(claims), database: Database = Depends(db)) -> dict:
    """عملية مجموعة ذرية في DB (set_calendar_weekdays) — لا loop هنا؛ قواعد B8/C2 في الدالة."""
    def work(conn):
        changed = _call(conn, "select app.set_calendar_weekdays(%s, %s::smallint[], %s) as n", [year_id, body.weekdays, body.reason])["n"]
        return {"changed": changed, "rows": _rows(conn, "calendar_weekdays", "academic_year_id = %s", [year_id], order="weekday")}
    return _tx(c, database, work)


@router.post("/academic-years/{year_id}/copy-weekdays")
def copy_weekdays(year_id: uuid.UUID, body: CopyWeekdays, c: dict = Depends(claims), database: Database = Depends(db)) -> dict:
    """M42: عملية domain واحدة ذرية؛ year_id هو الهدف؛ الاستثناءات المؤرخة لا تُنسخ."""
    def work(conn):
        created = _call(conn, "select app.copy_calendar_weekdays(%s, %s, %s) as n", [body.source_year_id, year_id, body.reason])["n"]
        return {"created": created}
    return _tx(c, database, work)


@router.get("/academic-years/{year_id}/calendar-exceptions")
def list_calendar_exceptions(year_id: uuid.UUID, c: dict = Depends(claims), database: Database = Depends(db)) -> dict:
    def work(conn):
        _visible(conn, "academic_years", year_id)
        return {"rows": _rows(conn, "calendar_exceptions", "academic_year_id = %s", [year_id], order="start_date")}
    return _tx(c, database, work)


@router.post("/academic-years/{year_id}/calendar-exceptions", status_code=201)
def create_calendar_exception(year_id: uuid.UUID, body: NewCalendarException, c: dict = Depends(claims), database: Database = Depends(db)) -> dict:
    def work(conn):
        _visible(conn, "academic_years", year_id)
        _reason(conn, body.reason)
        # المدرسة وحدود السنة من صف السنة المقروء تحت RLS — لا من العميل
        row = _call(conn,
                    "insert into public.calendar_exceptions (school_id, academic_year_id, year_start_date, year_end_date, kind, name, start_date, end_date)"
                    " select y.school_id, y.id, y.start_date, y.end_date, %s, %s, %s, %s from public.academic_years y where y.id = %s returning id",
                    [body.kind, body.name, body.start_date, body.end_date, year_id])
        return _visible(conn, "calendar_exceptions", row["id"])
    return _tx(c, database, work)


@router.patch("/calendar-exceptions/{exception_id}")
def update_calendar_exception(exception_id: uuid.UUID, body: CalendarExceptionPatch, c: dict = Depends(claims), database: Database = Depends(db)) -> dict:
    def work(conn):
        _reason(conn, body.reason)
        return _patch(conn, "calendar_exceptions", exception_id, body, exclude={"reason"})
    return _tx(c, database, work)


@router.post("/calendar-exceptions/{exception_id}/cancel")
def cancel_calendar_exception(exception_id: uuid.UUID, body: Reason, c: dict = Depends(claims), database: Database = Depends(db)) -> dict:
    def work(conn):
        _reason(conn, body.reason)
        return _update(conn, "calendar_exceptions", exception_id, {"status": "cancelled"})
    return _tx(c, database, work)


# ------------------------------------------------------------------ bell schedules (Phase 2B / 2B-3 — M43، M44؛ D1–D7)
# رقم الحصة الظاهر مشتق لا مخزن (D5): ترتيب start_time للحصص النشطة من نوع lesson في اليوم؛ id هو المعرّف الثابت للفتحة.
_PERIODS = """
    select p.id, p.school_id, p.academic_year_id, p.bell_schedule_id, p.weekday, p.kind, p.name, p.start_time, p.end_time, p.status,
           case when p.kind = 'lesson' and p.status = 'active'
                then row_number() over (partition by p.weekday, (p.kind = 'lesson' and p.status = 'active') order by p.start_time) end as lesson_no
      from public.bell_periods p where p.bell_schedule_id = %s order by p.weekday, p.start_time, p.id
"""


@router.get("/academic-years/{year_id}/bell-schedules")
def list_bell_schedules(year_id: uuid.UUID, c: dict = Depends(claims), database: Database = Depends(db)) -> dict:
    def work(conn):
        _visible(conn, "academic_years", year_id)
        return {"rows": _rows(conn, "bell_schedules", "academic_year_id = %s", [year_id])}
    return _tx(c, database, work)


@router.post("/academic-years/{year_id}/bell-schedules", status_code=201)
def create_bell_schedule(year_id: uuid.UUID, body: NewBellSchedule, c: dict = Depends(claims), database: Database = Depends(db)) -> dict:
    def work(conn):
        _visible(conn, "academic_years", year_id)
        _reason(conn, body.reason)
        row = _call(conn, "insert into public.bell_schedules (school_id, academic_year_id, name)"
                          " select y.school_id, y.id, %s from public.academic_years y where y.id = %s returning id", [body.name, year_id])
        return _visible(conn, "bell_schedules", row["id"])
    return _tx(c, database, work)


@router.patch("/bell-schedules/{schedule_id}")
def update_bell_schedule(schedule_id: uuid.UUID, body: BellSchedulePatch, c: dict = Depends(claims), database: Database = Depends(db)) -> dict:
    def work(conn):
        _reason(conn, body.reason)
        return _patch(conn, "bell_schedules", schedule_id, body, exclude={"reason"})
    return _tx(c, database, work)


@router.get("/bell-schedules/{schedule_id}/periods")
def list_bell_periods(schedule_id: uuid.UUID, c: dict = Depends(claims), database: Database = Depends(db)) -> dict:
    def work(conn):
        _visible(conn, "bell_schedules", schedule_id)
        return {"rows": conn.execute(_PERIODS, [schedule_id]).fetchall()}
    return _tx(c, database, work)


@router.post("/bell-schedules/{schedule_id}/periods", status_code=201)
def create_bell_period(schedule_id: uuid.UUID, body: NewBellPeriod, c: dict = Depends(claims), database: Database = Depends(db)) -> dict:
    def work(conn):
        _visible(conn, "bell_schedules", schedule_id)
        _reason(conn, body.reason)
        # المدرسة والسنة من صف الجدول المقروء تحت RLS — لا من العميل
        row = _call(conn, "insert into public.bell_periods (school_id, academic_year_id, bell_schedule_id, weekday, kind, name, start_time, end_time)"
                          " select s.school_id, s.academic_year_id, s.id, %s, %s, %s, %s, %s from public.bell_schedules s where s.id = %s returning id",
                    [body.weekday, body.kind, body.name, body.start_time, body.end_time, schedule_id])
        return _visible(conn, "bell_periods", row["id"])
    return _tx(c, database, work)


@router.patch("/bell-periods/{period_id}")
def update_bell_period(period_id: uuid.UUID, body: BellPeriodPatch, c: dict = Depends(claims), database: Database = Depends(db)) -> dict:
    def work(conn):
        _reason(conn, body.reason)
        return _patch(conn, "bell_periods", period_id, body, exclude={"reason"})
    return _tx(c, database, work)


@router.post("/bell-schedules/{schedule_id}/copy-day")
def copy_bell_day(schedule_id: uuid.UUID, body: CopyBellDay, c: dict = Depends(claims), database: Database = Depends(db)) -> dict:
    """عملية واحدة في DB (copy_bell_day) — لا loop هنا؛ لا دمج صامت في يوم له حصص."""
    def work(conn):
        created = _call(conn, "select app.copy_bell_day(%s, %s::smallint, %s::smallint[], %s) as n",
                        [schedule_id, body.from_weekday, body.to_weekdays, body.reason])["n"]
        return {"created": created}
    return _tx(c, database, work)


@router.get("/academic-years/{year_id}/grade-bell-schedules")
def list_grade_bell_schedules(year_id: uuid.UUID, c: dict = Depends(claims), database: Database = Depends(db)) -> dict:
    def work(conn):
        _visible(conn, "academic_years", year_id)
        return {"rows": _rows(conn, "grade_level_bell_schedules", "academic_year_id = %s", [year_id], order="grade_level_id")}
    return _tx(c, database, work)


@router.put("/academic-years/{year_id}/grade-bell-schedules/{grade_level_id}")
def assign_grade_bell_schedule(year_id: uuid.UUID, grade_level_id: uuid.UUID, body: GradeBellSchedule,
                               c: dict = Depends(claims), database: Database = Depends(db)) -> dict:
    """D2: الصف ← جدول واحد في السنة. موجود (مرئي تحت RLS) ← تغيير الجدول؛ وإلا إنشاء — والقرار كله في DB."""
    def work(conn):
        _visible(conn, "academic_years", year_id)
        _reason(conn, body.reason)
        current = conn.execute("select id from public.grade_level_bell_schedules where academic_year_id = %s and grade_level_id = %s",
                               [year_id, grade_level_id]).fetchone()
        if current is not None:
            return _update(conn, "grade_level_bell_schedules", current["id"], {"bell_schedule_id": body.bell_schedule_id})
        row = _call(conn, "insert into public.grade_level_bell_schedules (school_id, academic_year_id, grade_level_id, bell_schedule_id)"
                          " select y.school_id, y.id, %s, %s from public.academic_years y where y.id = %s returning id",
                    [grade_level_id, body.bell_schedule_id, year_id])
        return _visible(conn, "grade_level_bell_schedules", row["id"])
    return _tx(c, database, work)


@router.post("/academic-years/{year_id}/copy-bell-schedules")
def copy_bell_schedules(year_id: uuid.UUID, body: CopyBellSchedules, c: dict = Depends(claims), database: Database = Depends(db)) -> dict:
    """M44: الجداول والحصص والإسناد ذرياً؛ year_id هو الهدف."""
    def work(conn):
        created = _call(conn, "select app.copy_bell_schedules(%s, %s, %s) as n", [body.source_year_id, year_id, body.reason])["n"]
        return {"created": created}
    return _tx(c, database, work)
