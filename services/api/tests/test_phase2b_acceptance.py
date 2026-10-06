"""Phase 2B / 2B-6 — اختبار القبول النهائي للمرحلة 2 (اختبارات فقط: لا migration ولا مفتاح ولا endpoint ولا قاعدة جديدة).

معيارا PLAN §5 للمرحلة 2:
  (1) «إعداد مدرسة كاملة من الصفر عبر الواجهة فقط» — مساره في المتصفح `e2e/wizard.spec.ts`؛ هنا المسار نفسه عبر الـAPI
      بالترتيب: ملف ← سنة وفصل ← تقويم ← بنية ← مواد ← دوام ← أصل ← اكتمال الإعداد ← التفعيل ← الجاهزية.
  (2) «الإعدادات مرتبطة بالسنة الدراسية وتعديلها لا يمس سنة سابقة» — تُنسخ إعدادات السنة إلى السنة التالية (أيام الدوام،
      الشعب، المواد، الدوام) ثم تُعدَّل نسختها، والسنة السابقة **متطابقة بايتياً**؛ ثم تُغلق السنة الأولى فلا يُكتب في إعداداتها.
وكل عملية في المسار مدققة بفاعلها وسببها. الأصل يُرفع بمخزن مزيّف (Storage مستبعد في CI — 2B-4/E10). البيانات بالرمز ZTQ.
"""

import pytest

from app import assets
from conftest import auth

ACTOR = "tenant_admin"


class _Store:
    def upload(self, path, data, content_type):
        self.path = path

    def delete(self, path):
        pass

    def signed_url(self, path):
        return "https://storage.example/signed"


@pytest.fixture(scope="module", autouse=True)
def _cleanup(admin, ids):
    yield
    zs = "select id from public.schools where school_code like 'ZTQ%'"
    zy = f"select id from public.academic_years where school_id in ({zs})"
    for stmt in (
        f"delete from public.grade_level_bell_schedules where school_id in ({zs})",
        f"delete from public.bell_periods where school_id in ({zs})",
        f"delete from public.bell_schedules where school_id in ({zs})",
        f"delete from public.grade_subjects where school_id in ({zs})",
        f"delete from public.subjects where school_id in ({zs})",
        f"delete from public.calendar_exceptions where school_id in ({zs})",
        f"delete from public.calendar_weekdays where school_id in ({zs})",
        f"delete from public.sections where school_id in ({zs})",
        f"delete from public.terms where academic_year_id in ({zy})",
        f"delete from public.academic_years where school_id in ({zs})",
        f"delete from public.grade_levels where school_id in ({zs})",
        f"delete from public.stages where school_id in ({zs})",
        f"delete from public.school_assets where school_id in ({zs})",
        f"delete from public.school_profiles where school_id in ({zs})",
        f"delete from public.identity_scopes where school_id in ({zs})",
        "delete from public.schools where school_code like 'ZTQ%'",
    ):
        admin.execute(stmt)


def call(client, method, path, body=None, status=(200, 201)):
    r = client.request(method, path, json=body, headers=auth(ACTOR))
    assert r.status_code in status, (method, path, r.status_code, r.text)
    return r.json()


def refused(client, method, path, body):
    r = client.request(method, path, json=body, headers=auth(ACTOR))
    assert r.status_code == 422, (method, path, r.status_code, r.text)
    return r.json()["detail"]


def year_snapshot(admin, year_id):
    """كل إعدادات السنة (الصفوف بكل أعمدتها) — للمقارنة البايتية."""
    rows = []
    for table in ("calendar_weekdays", "calendar_exceptions", "sections", "grade_subjects", "bell_schedules", "bell_periods", "grade_level_bell_schedules"):
        rows += [f"{table}:{r['j']}" for r in admin.execute(
            f"select to_jsonb(t)::text j from public.{table} t where t.academic_year_id = %s order by t.id", [year_id]).fetchall()]
    return rows


def test_phase2_acceptance_path(client, admin, ids):
    since = admin.execute("select coalesce(max(id), 0) n from public.audit_log").fetchone()["n"]
    school = call(client, "POST", "/schools", {"school_code": "ZTQ1", "name": "ZT Acceptance", "slug": "ztq-one"})
    sid = school["id"]

    def progress(**params):
        r = client.get(f"/schools/{sid}/setup-progress", params=params, headers=auth(ACTOR))
        assert r.status_code == 200, r.text
        body = r.json()
        return {s["key"]: s["done"] for s in body["steps"]}, body

    # ---------------------------------------------------- المعيار (1): مدرسة كاملة من الصفر بالترتيب
    call(client, "PUT", f"/schools/{sid}/profile", {"address": "Cairo", "phone_e164": "+201000000321", "email": "a@ztq.example",
                                                     "website": "https://ztq.example", "principal_display_name": "Principal"})
    y1 = call(client, "POST", f"/schools/{sid}/academic-years", {"name": "ZTQ 2085", "start_date": "2085-09-01", "end_date": "2086-06-30"})
    call(client, "POST", f"/academic-years/{y1['id']}/terms", {"name": "T1", "sequence_no": 1, "start_date": "2085-09-01", "end_date": "2086-01-20"})
    call(client, "PUT", f"/academic-years/{y1['id']}/weekdays", {"weekdays": [0, 1, 2, 3, 4], "reason": "school week"})
    call(client, "POST", f"/academic-years/{y1['id']}/calendar-exceptions",
         {"kind": "holiday", "name": "Mid-year", "start_date": "2086-02-01", "end_date": "2086-02-07"})
    stage = call(client, "POST", f"/schools/{sid}/stages", {"name": "ZTQ Primary", "sequence_no": 1})
    grade = call(client, "POST", f"/schools/{sid}/grade-levels", {"stage_id": stage["id"], "name": "ZTQ G1", "sequence_no": 1})
    call(client, "POST", f"/academic-years/{y1['id']}/sections", {"grade_level_id": grade["id"], "name": "A", "capacity": 30})
    subject = call(client, "POST", f"/schools/{sid}/subjects", {"subject_code": "ZTQAR", "name": "ZTQ Arabic"})
    link = call(client, "POST", f"/academic-years/{y1['id']}/grade-subjects", {"grade_level_id": grade["id"], "subject_id": subject["id"], "weekly_periods": 6})
    bell = call(client, "POST", f"/academic-years/{y1['id']}/bell-schedules", {"name": "ZTQ Morning"})
    period = call(client, "POST", f"/bell-schedules/{bell['id']}/periods", {"weekday": 0, "kind": "lesson", "start_time": "08:00", "end_time": "08:45"})
    call(client, "POST", f"/bell-schedules/{bell['id']}/copy-day", {"from_weekday": 0, "to_weekdays": [1, 2, 3, 4], "reason": "same every day"})
    call(client, "PUT", f"/academic-years/{y1['id']}/grade-bell-schedules/{grade['id']}", {"bell_schedule_id": bell["id"]})

    steps, body = progress()
    assert all(steps[k] for k in ("profile", "year", "calendar", "structure", "subjects", "bell")) and not steps["assets"]
    assert (body["setup_complete"], body["ready_for_enrollment"]) == (True, False)      # مستقلان: السنة planned

    store = _Store()
    client.app.dependency_overrides[assets.storage] = lambda: store
    try:
        png = b"\x89PNG\r\n\x1a\n" + b"\x00\x00\x00\x0dIHDR" + (64).to_bytes(4, "big") + (32).to_bytes(4, "big") + b"\x08\x02\x00\x00\x00" + b"\x00" * 8
        r = client.post(f"/schools/{sid}/assets", data={"kind": "logo", "reason": "school logo"}, files={"file": ("l.png", png, "image/png")}, headers=auth(ACTOR))
        assert r.status_code == 201, r.text
        logo = r.json()
        assert store.path.endswith(f"/{sid}/logo/{logo['id']}.png")                        # المسار مشتق في DB (E4)
    finally:
        client.app.dependency_overrides.pop(assets.storage, None)
    assert progress()[0]["assets"]

    call(client, "POST", f"/academic-years/{y1['id']}/activate", {"reason": "year starts"})
    _, body = progress()
    assert (body["setup_complete"], body["ready_for_enrollment"]) == (True, True)
    assert client.get(f"/schools/{sid}/readiness", headers=auth(ACTOR)).json()["ready"] is True   # تعريف 2A كما هو

    # ---------------------------------------------------- المعيار (2): الإعدادات للسنة، وتعديلها لا يمس سنة سابقة
    y2 = call(client, "POST", f"/schools/{sid}/academic-years", {"name": "ZTQ 2086", "start_date": "2086-09-01", "end_date": "2087-06-30"})
    before = year_snapshot(admin, y1["id"])
    assert len(before) == 5 + 1 + 1 + 1 + 1 + 5 + 1, before                                  # المقارنة ليست فارغة: كل جداول الإعداد ممثلة
    assert call(client, "POST", f"/academic-years/{y2['id']}/copy-weekdays", {"source_year_id": y1["id"], "reason": "next year"}) == {"created": 5}
    assert call(client, "POST", f"/academic-years/{y2['id']}/copy-sections", {"source_year_id": y1["id"], "reason": "next year"}) == {"created": 1}
    assert call(client, "POST", f"/academic-years/{y2['id']}/copy-grade-subjects", {"source_year_id": y1["id"], "reason": "next year"}) == {"created": 1}
    assert call(client, "POST", f"/academic-years/{y2['id']}/copy-bell-schedules", {"source_year_id": y1["id"], "reason": "next year"})["created"] == 1 + 5 + 1
    exceptions_y2 = call(client, "GET", f"/academic-years/{y2['id']}/calendar-exceptions")["rows"]
    assert exceptions_y2 == []                                                               # الاستثناءات المؤرخة لا تُنسخ (B13)
    _, body = progress(year_id=y2["id"])
    assert body["year"]["id"] == y2["id"] and not body["steps"][1]["done"]                   # السنة الثانية بلا فصل بعد
    # تعديل نسخ السنة الثانية
    link2 = call(client, "GET", f"/academic-years/{y2['id']}/grade-subjects")["rows"][0]
    call(client, "PATCH", f"/grade-subjects/{link2['id']}", {"weekly_periods": 7})
    bell2 = call(client, "GET", f"/academic-years/{y2['id']}/bell-schedules")["rows"][0]
    p2 = call(client, "GET", f"/bell-schedules/{bell2['id']}/periods")["rows"][0]
    call(client, "PATCH", f"/bell-periods/{p2['id']}", {"end_time": "08:50"})
    call(client, "PUT", f"/academic-years/{y2['id']}/weekdays", {"weekdays": [0, 1, 2, 3, 4, 6], "reason": "saturday classes"})
    assert year_snapshot(admin, y1["id"]) == before                                          # السنة السابقة لم تُمس بايتاً واحداً
    assert call(client, "GET", f"/academic-years/{y1['id']}/grade-subjects")["rows"][0]["weekly_periods"] == 6

    # إغلاق السنة الأولى ← إعداداتها مجمدة على كل مسار
    call(client, "POST", f"/academic-years/{y1['id']}/close", {"reason": "year ends"})
    assert refused(client, "PATCH", f"/grade-subjects/{link['id']}", {"weekly_periods": 5}) == "invariant_violation"
    assert refused(client, "PATCH", f"/bell-periods/{period['id']}", {"end_time": "08:40", "reason": "r"}) == "invariant_violation"
    assert refused(client, "PUT", f"/academic-years/{y1['id']}/weekdays", {"weekdays": [0], "reason": "r"}) in ("invalid_request", "invariant_violation")
    assert refused(client, "POST", f"/academic-years/{y1['id']}/calendar-exceptions",
                   {"kind": "holiday", "name": "x", "start_date": "2086-03-01", "end_date": "2086-03-01", "reason": "r"}) == "invariant_violation"
    assert year_snapshot(admin, y1["id"]) == before
    assert client.get(f"/schools/{sid}/setup-progress", params={"year_id": y1["id"]}, headers=auth(ACTOR)).status_code == 404

    # ---------------------------------------------------- التدقيق: كل عملية بفاعلها وسببها
    me = admin.execute("select p.id from public.profiles p join public.memberships m on m.profile_id = p.id"
                       " join public.membership_roles mr on mr.membership_id = m.id join public.roles r on r.id = mr.role_id"
                       " where r.code = 'tenant_admin' and r.platform_tenant_id is null limit 1").fetchone()["id"]
    domain = {r["action"]: r for r in admin.execute(
        "select action, reason, actor_id, actor_type from public.audit_log where id > %s and action in"
        " ('set_calendar_weekdays', 'copy_calendar_weekdays', 'copy_sections', 'copy_grade_subjects', 'copy_bell_schedules', 'copy_bell_day')", [since]).fetchall()}
    assert set(domain) == {"set_calendar_weekdays", "copy_calendar_weekdays", "copy_sections", "copy_grade_subjects", "copy_bell_schedules", "copy_bell_day"}
    assert all(r["actor_type"] == "tenant_user" and r["actor_id"] == me and r["reason"] for r in domain.values())
    logo_audit = admin.execute("select action, reason from public.audit_log where entity_type = 'school_assets' and entity_id = %s", [logo["id"]]).fetchall()
    assert [(a["action"], a["reason"]) for a in logo_audit] == [("insert", "school logo")]
    tables = {r["entity_type"] for r in admin.execute("select distinct entity_type from public.audit_log where id > %s", [since]).fetchall()}
    assert {"school_profiles", "subjects", "grade_subjects", "calendar_weekdays", "calendar_exceptions", "bell_schedules",
            "bell_periods", "grade_level_bell_schedules", "school_assets"} <= tables


def test_no_phase2_schema_or_permission_drift(admin):
    """2B-6 لا يضيف شيئاً: الكتالوج 75، والجداول 39 — كما تركتها 2B-4."""
    assert admin.execute("select count(*) n from public.permissions").fetchone()["n"] == 75
    assert admin.execute("select count(*) n from pg_tables where schemaname = 'public'").fetchone()["n"] == 39
