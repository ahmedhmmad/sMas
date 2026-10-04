"""Phase 2A / P2-E — اختبار القبول النهائي (اختبارات فقط: لا migration ولا endpoint ولا قاعدة جديدة).

المسار بالترتيب المعتمد للقبول:
  Tenant Admin → Group → School → Stage → Grade → Academic Year → Section → Term → Active Year → Ready for Enrollment
والجاهزية تُفحص بعد كل خطوة: لا تصير true قبل اكتمال شروطها، ولا تبقى true حين يسقط أحدها
(شعبة نشطة في سنة مخططة فقط، تعطيل الشعبة الوحيدة، أرشفة المدرسة). ثم: كل عملية في المسار لها صف تدقيق
بفاعلها وفعلها (وسببها حيث يلزم). البيانات بالرمز ZTA وتُحذف في النهاية.
"""

import pytest

from conftest import auth

ACTOR = "tenant_admin"


@pytest.fixture(scope="module", autouse=True)
def _cleanup(admin, ids):
    yield
    zt_schools = "select id from public.schools where school_code like 'ZTA%'"
    zt_years = f"select id from public.academic_years where school_id in ({zt_schools})"
    for stmt in (
        f"delete from public.sections where school_id in ({zt_schools})",
        f"delete from public.terms where academic_year_id in ({zt_years})",
        f"delete from public.academic_years where id in ({zt_years})",
        f"delete from public.grade_levels where school_id in ({zt_schools})",
        f"delete from public.stages where school_id in ({zt_schools})",
        f"delete from public.identity_scopes where school_id in ({zt_schools}) or group_id in (select id from public.groups where group_code like 'ZTA%')",
        "delete from public.schools where school_code like 'ZTA%'",
        "delete from public.groups where group_code like 'ZTA%'",
    ):
        admin.execute(stmt)


def call(client, method, path, body=None):
    r = client.request(method, path, json=body, headers=auth(ACTOR))
    assert r.status_code in (200, 201), (method, path, r.status_code, r.text)
    return r.json()


def ready(client, school_id):
    return client.get(f"/schools/{school_id}/readiness", headers=auth(ACTOR)).json()


NOT_YET = lambda year, section: {"school_active": True, "active_year": year, "active_section": section}  # noqa: E731


def test_acceptance_path_and_readiness_never_early(client, admin):
    since = admin.execute("select coalesce(max(id), 0) as m from public.audit_log").fetchone()["m"]

    group = call(client, "POST", "/groups", {"group_code": "ZTA1", "name": "Acceptance group"})
    school = call(client, "POST", "/schools", {"group_id": group["id"], "school_code": "ZTA1", "name": "Acceptance school", "slug": "zta-one"})
    sid = school["id"]
    assert school["group_id"] == group["id"] and school["is_standalone"] is False
    assert ready(client, sid) == {"ready": False, "checks": NOT_YET(False, False)}

    stage = call(client, "POST", f"/schools/{sid}/stages", {"name": "Primary", "sequence_no": 1})
    grade = call(client, "POST", f"/schools/{sid}/grade-levels", {"stage_id": stage["id"], "name": "G1", "sequence_no": 1})
    assert ready(client, sid)["ready"] is False                       # بنية بلا سنة

    year = call(client, "POST", f"/schools/{sid}/academic-years", {"name": "2050", "start_date": "2050-09-01", "end_date": "2051-06-30"})
    section = call(client, "POST", f"/academic-years/{year['id']}/sections", {"grade_level_id": grade["id"], "name": "A", "capacity": 25})
    assert ready(client, sid) == {"ready": False, "checks": NOT_YET(False, False)}   # شعبة نشطة في سنة مخططة لا تكفي (Q4)

    term = call(client, "POST", f"/academic-years/{year['id']}/terms", {"name": "T1", "sequence_no": 1, "start_date": "2050-09-01", "end_date": "2051-01-31"})
    assert term["status"] == "planned"
    early = client.post(f"/terms/{term['id']}/activate", json={"reason": "too early"}, headers=auth(ACTOR))
    assert (early.status_code, early.json()["detail"]) == (422, "invariant_violation")   # فصل نشط في سنة غير نشطة

    call(client, "POST", f"/academic-years/{year['id']}/activate", {"reason": "year starts"})
    assert ready(client, sid) == {"ready": True, "checks": NOT_YET(True, True)}
    call(client, "POST", f"/terms/{term['id']}/activate", {"reason": "term starts"})
    assert ready(client, sid)["ready"] is True                        # الفصل ليس شرطاً للجاهزية، ولا يكسرها

    # السقوط: الشعبة الوحيدة تُعطَّل ← غير جاهزة؛ تُعاد ← جاهزة
    call(client, "PATCH", f"/sections/{section['id']}", {"status": "inactive"})
    assert ready(client, sid) == {"ready": False, "checks": NOT_YET(True, False)}
    call(client, "PATCH", f"/sections/{section['id']}", {"status": "active"})
    assert ready(client, sid)["ready"] is True

    # نسخ الشعب إلى سنة مخططة، المعرّف، نمط ولي الأمر
    nxt = call(client, "POST", f"/schools/{sid}/academic-years", {"name": "2051", "start_date": "2051-09-01", "end_date": "2052-06-30"})
    assert call(client, "POST", f"/academic-years/{nxt['id']}/copy-sections", {"source_year_id": year["id"], "reason": "next year"}) == {"created": 1}
    assert call(client, "POST", f"/academic-years/{nxt['id']}/copy-sections", {"source_year_id": year["id"], "reason": "again"}) == {"created": 0}
    call(client, "POST", f"/schools/{sid}/slug", {"slug": "zta-north", "reason": "rebrand"})
    call(client, "POST", f"/schools/{sid}/guardian-first-login-mode", {"mode": "B", "reason": "policy"})

    # الأرشفة: الفصل يُغلق، المدرسة تُؤرشف ← غير جاهزة مهما بقيت سنتها وشعبتها؛ ثم المجموعة الفارغة
    call(client, "POST", f"/terms/{term['id']}/close", {"reason": "term ends"})
    blocked = client.post(f"/groups/{group['id']}/archive", json={"reason": "r"}, headers=auth(ACTOR))
    assert blocked.status_code == 422                                  # مجموعة بمدرسة نشطة
    call(client, "POST", f"/schools/{sid}/archive", {"reason": "closed down"})
    assert ready(client, sid) == {"ready": False, "checks": {"school_active": False, "active_year": True, "active_section": True}}
    call(client, "POST", f"/groups/{group['id']}/archive", {"reason": "empty"})

    # التدقيق: كل عملية بفاعلها (مدير الـTenant) وفعلها، والسبب حيث يلزم
    profile = admin.execute("select id from public.profiles where auth_user_id = 'a0000000-0000-4000-8000-000000000001'").fetchone()["id"]
    rows = admin.execute(
        "select entity_type, action, reason, actor_type, actor_id from public.audit_log where id > %s and entity_type in"
        " ('groups','schools','stages','grade_levels','academic_years','sections','terms') order by id", [since]).fetchall()
    assert {r["actor_type"] for r in rows} == {"tenant_user"} and {r["actor_id"] for r in rows} == {profile}
    seen = {(r["entity_type"], r["action"], r["reason"]) for r in rows}
    for expected in [
        ("groups", "insert", None), ("schools", "insert", None), ("stages", "insert", None), ("grade_levels", "insert", None),
        ("academic_years", "insert", None), ("sections", "insert", None), ("terms", "insert", None),
        ("academic_years", "activate", "year starts"), ("terms", "activate", "term starts"), ("terms", "close", "term ends"),
        ("sections", "update", None), ("sections", "insert", "next year"),
        ("schools", "change_slug", "rebrand"), ("schools", "set_guardian_first_login_mode", "policy"),
        ("schools", "archive", "closed down"), ("groups", "archive", "empty"),
    ]:
        assert expected in seen, expected
    domain = admin.execute("select new_values, reason from public.audit_log where id > %s and action = 'copy_sections' order by id", [since]).fetchall()
    assert [(d["new_values"]["created"], d["reason"]) for d in domain] == [(1, "next year"), (0, "again")]
    # المرفوض لا يُدقَّق: لا صف «activate» للفصل قبل تفعيل السنة، ولا «archive» للمجموعة قبل أرشفة المدرسة
    assert sum(1 for r in rows if (r["entity_type"], r["action"]) == ("terms", "activate")) == 1
    assert sum(1 for r in rows if (r["entity_type"], r["action"]) == ("groups", "archive")) == 1
