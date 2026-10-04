"""Phase 2B / 2B-1 — API المواد وربطها بالصفوف (M38–M40) على seed التطوير (E5).

ما يُثبت: الإنشاء والتعديل والنسخ عبر المسار الوحيد (JWT → معاملة authenticated → RLS/الحراس/الدالة)؛ 404 (غير مرئي) /
403 (مرئي ومرفوض)؛ subject.read ≠ subject.manage؛ حراس T13 من الـAPI؛ لا مدرسة من الجسم؛ التدقيق.
كل ما يُنشأ يحمل الرمز ZTS ويُحذف في نهاية الوحدة (اتصال postgres للاختبار فقط).
"""

import uuid

import pytest

from conftest import auth


@pytest.fixture(scope="module", autouse=True)
def _cleanup(admin):
    yield
    zts = "select id from public.subjects where subject_code like 'ZTS%'"
    for stmt in (
        f"delete from public.grade_subjects where subject_id in ({zts})",
        "delete from public.subjects where subject_code like 'ZTS%'",
        "delete from public.academic_years where name like 'ZTS%'",
        "delete from public.grade_levels where name like 'ZTS%'",
    ):
        admin.execute(stmt)


def post(client, who, path, body=None):
    return client.post(path, json=body or {}, headers=auth(who))


def patch(client, who, path, body):
    return client.patch(path, json=body, headers=auth(who))


def get(client, who, path):
    return client.get(path, headers=auth(who))


@pytest.fixture(scope="module")
def sa(client, ids):
    """مدرسة SA: صف نشط من الـseed، وسنتان planned جديدتان لـschool_admin."""
    sid = ids["school"]["SA"]
    grade = next(g for g in get(client, "school_admin", f"/schools/{sid}/grade-levels").json()["rows"] if g["status"] == "active")
    y1 = post(client, "school_admin", f"/schools/{sid}/academic-years", {"name": "ZTS 2050", "start_date": "2050-09-01", "end_date": "2051-06-30"})
    y2 = post(client, "school_admin", f"/schools/{sid}/academic-years", {"name": "ZTS 2051", "start_date": "2051-09-01", "end_date": "2052-06-30"})
    assert (y1.status_code, y2.status_code) == (201, 201), (y1.text, y2.text)
    return {"id": sid, "grade": grade["id"], "y1": y1.json()["id"], "y2": y2.json()["id"]}


def test_subject_catalog_create_and_edit(client, sa):
    sid = sa["id"]
    ar = post(client, "school_admin", f"/schools/{sid}/subjects", {"subject_code": "ZTS-AR", "name": "ZTS Arabic"})
    assert ar.status_code == 201, ar.text
    assert {k: ar.json()[k] for k in ("school_id", "subject_code", "status")} == {"school_id": sid, "subject_code": "ZTS-AR", "status": "active"}
    dup = post(client, "school_admin", f"/schools/{sid}/subjects", {"subject_code": "ZTS-AR", "name": "ZTS other"})
    assert (dup.status_code, dup.json()["detail"]) == (409, "conflict")
    assert post(client, "school_admin", f"/schools/{sid}/subjects", {"subject_code": "zts-lower", "name": "ZTS x"}).status_code == 422   # CHECK
    assert patch(client, "school_admin", f"/subjects/{ar.json()['id']}", {"name": "ZTS Arabic Language"}).json()["name"] == "ZTS Arabic Language"
    assert patch(client, "school_admin", f"/subjects/{ar.json()['id']}", {"subject_code": "ZTS-X"}).status_code == 422       # الرمز ثابت
    codes = [s["subject_code"] for s in get(client, "school_admin", f"/schools/{sid}/subjects").json()["rows"]]
    assert "ZTS-AR" in codes


def test_grade_subjects_guards_and_copy(client, sa, admin):
    sid, grade, y1, y2 = sa["id"], sa["grade"], sa["y1"], sa["y2"]
    ma = post(client, "school_admin", f"/schools/{sid}/subjects", {"subject_code": "ZTS-MA", "name": "ZTS Math"}).json()
    link = post(client, "school_admin", f"/academic-years/{y1}/grade-subjects",
                {"grade_level_id": grade, "subject_id": ma["id"], "weekly_periods": 5})
    assert link.status_code == 201, link.text
    assert (link.json()["school_id"], link.json()["academic_year_id"], link.json()["counts_toward_total"]) == (sid, y1, True)   # المدرسة من صف السنة
    again = post(client, "school_admin", f"/academic-years/{y1}/grade-subjects", {"grade_level_id": grade, "subject_id": ma["id"], "weekly_periods": 4})
    assert again.status_code == 409                                                                   # المفتاح الطبيعي
    assert post(client, "school_admin", f"/academic-years/{y1}/grade-subjects",
                {"grade_level_id": grade, "subject_id": ma["id"], "weekly_periods": 0}).status_code == 422
    assert patch(client, "school_admin", f"/grade-subjects/{link.json()['id']}", {"weekly_periods": 6, "counts_toward_total": False}).json()["weekly_periods"] == 6

    # T13: لا تعطيل لمادة تُدرَّس في سنة غير مغلقة؛ ولا إعادة تفعيل ربط لمادة معطلة
    blocked = patch(client, "school_admin", f"/subjects/{ma['id']}", {"status": "inactive"})
    assert (blocked.status_code, blocked.json()["detail"]) == (422, "invariant_violation")

    first = post(client, "school_admin", f"/academic-years/{y2}/copy-grade-subjects", {"source_year_id": y1, "reason": "next year"})
    assert first.json() == {"created": 1}
    assert post(client, "school_admin", f"/academic-years/{y2}/copy-grade-subjects", {"source_year_id": y1, "reason": "again"}).json() == {"created": 0}
    copied = get(client, "school_admin", f"/academic-years/{y2}/grade-subjects").json()["rows"]
    assert [(r["subject_id"], r["weekly_periods"], r["counts_toward_total"], r["status"]) for r in copied] == [(ma["id"], 6, False, "active")]
    assert post(client, "school_admin", f"/academic-years/{y2}/copy-grade-subjects", {"source_year_id": y1}).status_code == 422   # بلا سبب
    audit = admin.execute("select new_values, reason from public.audit_log where action = 'copy_grade_subjects' and entity_id = %s order by id", [y2]).fetchall()
    assert [(a["new_values"]["created"], a["new_values"]["already_copied"], a["reason"]) for a in audit] == [(1, 0, "next year"), (0, 1, "again")]

    # المتعارض يُفشل النسخ كله
    assert patch(client, "school_admin", f"/grade-subjects/{copied[0]['id']}", {"weekly_periods": 2}).status_code == 200
    conflict = post(client, "school_admin", f"/academic-years/{y2}/copy-grade-subjects", {"source_year_id": y1, "reason": "r"})
    assert (conflict.status_code, conflict.json()["detail"]) == (422, "invariant_violation")

    for gs in (link.json()["id"], copied[0]["id"]):
        assert patch(client, "school_admin", f"/grade-subjects/{gs}", {"status": "inactive"}).json()["status"] == "inactive"
    assert patch(client, "school_admin", f"/subjects/{ma['id']}", {"status": "inactive"}).json()["status"] == "inactive"
    revive = patch(client, "school_admin", f"/grade-subjects/{link.json()['id']}", {"status": "active"})
    assert (revive.status_code, revive.json()["detail"]) == (422, "invariant_violation")


def test_copy_into_an_active_year_is_refused(client, sa, ids):
    seed_year = next(y for y in get(client, "school_admin", f"/schools/{sa['id']}/academic-years").json()["rows"] if y["status"] == "active")
    r = post(client, "school_admin", f"/academic-years/{seed_year['id']}/copy-grade-subjects", {"source_year_id": sa["y1"], "reason": "r"})
    assert (r.status_code, r.json()["detail"]) == (422, "invalid_request")


def test_read_is_not_manage(client, sa):
    sid = sa["id"]
    subject = get(client, "school_admin", f"/schools/{sid}/subjects").json()["rows"][0]
    for role in ("secretary", "teacher"):
        assert get(client, role, f"/schools/{sid}/subjects").status_code == 200
        assert get(client, role, f"/schools/{sid}/subjects").json()["rows"]
        assert get(client, role, f"/academic-years/{sa['y1']}/grade-subjects").json()["rows"]   # academic_year.read + subject.read
    # secretary يرى المدرسة والسنة والمادة، والكتابة مرفوضة ← 403
    assert post(client, "secretary", f"/schools/{sid}/subjects", {"subject_code": "ZTS-SEC", "name": "ZTS sec"}).status_code == 403
    assert patch(client, "secretary", f"/subjects/{subject['id']}", {"name": "hijack"}).status_code == 403
    assert post(client, "secretary", f"/academic-years/{sa['y1']}/grade-subjects",
                {"grade_level_id": sa["grade"], "subject_id": subject["id"], "weekly_periods": 3}).status_code == 403
    assert post(client, "secretary", f"/academic-years/{sa['y2']}/copy-grade-subjects", {"source_year_id": sa["y1"], "reason": "r"}).status_code == 403
    # bus_supervisor يرى المدرسة بلا subject.read: القائمة فارغة، لا تسريب
    assert get(client, "bus_supervisor", f"/schools/{sid}/subjects").json() == {"rows": []}


def test_school_admin_stays_inside_its_school(client, sa, ids):
    sb = ids["school"]["SB"]
    sb_year = get(client, "tenant_admin", f"/schools/{sb}/academic-years").json()["rows"][0]["id"]
    sb_grade = get(client, "tenant_admin", f"/schools/{sb}/grade-levels").json()["rows"][0]["id"]
    sa_subject = get(client, "school_admin", f"/schools/{sa['id']}/subjects").json()["rows"][0]
    assert get(client, "school_admin", f"/schools/{sb}/subjects").status_code == 404
    assert post(client, "school_admin", f"/schools/{sb}/subjects", {"subject_code": "ZTS-SB", "name": "ZTS x"}).status_code == 404
    assert get(client, "school_admin", f"/academic-years/{sb_year}/grade-subjects").status_code == 404
    assert post(client, "school_admin", f"/academic-years/{sb_year}/copy-grade-subjects", {"source_year_id": sa["y1"], "reason": "r"}).status_code == 404
    # صف من مدرسة أخرى في سنة SA: الـFK المركّب يرفض (لا ربط عبر المدارس)
    cross = post(client, "school_admin", f"/academic-years/{sa['y1']}/grade-subjects",
                 {"grade_level_id": sb_grade, "subject_id": sa_subject["id"], "weekly_periods": 3})
    assert (cross.status_code, cross.json()["detail"]) == (422, "invalid_reference")
    assert get(client, "platform", f"/schools/{sa['id']}/subjects").status_code == 404


def test_no_school_or_identity_from_the_body(client, sa, ids):
    sid, sb = sa["id"], ids["school"]["SB"]
    assert post(client, "school_admin", f"/schools/{sid}/subjects", {"subject_code": "ZTS-F", "name": "ZTS f", "school_id": sb}).status_code == 422
    subject = get(client, "school_admin", f"/schools/{sid}/subjects").json()["rows"][0]
    assert patch(client, "school_admin", f"/subjects/{subject['id']}", {"school_id": sb}).status_code == 422
    links = get(client, "school_admin", f"/academic-years/{sa['y1']}/grade-subjects").json()["rows"]
    assert patch(client, "school_admin", f"/grade-subjects/{links[0]['id']}", {"academic_year_id": sa["y2"]}).status_code == 422
    assert patch(client, "school_admin", f"/grade-subjects/{links[0]['id']}", {"status": "archived"}).status_code == 422
    assert patch(client, "school_admin", f"/grade-subjects/{uuid.uuid4()}", {"weekly_periods": 3}).status_code == 404
    assert client.delete(f"/subjects/{subject['id']}", headers=auth("school_admin")).status_code == 405
