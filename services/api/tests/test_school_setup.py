"""Phase 2A / P2-C — API إعداد المدرسة على seed التطوير (E5).

ما يُثبت: المسار الكامل حتى ready_for_enrollment لكل دور يملكه بنطاقه؛ قاعدة 404 (غير مرئي) / 403 (مرئي ومرفوض)؛
لا سلطة من الجسم أو الترويسات أو الاستعلام؛ ربط أخطاء DB بالـHTTP؛ التدقيق؛ CORS لـPATCH.
كل ما يُنشأ هنا يحمل الرمز ZT ويُحذف في نهاية الوحدة (اتصال postgres للاختبار فقط) — الـseed يبقى كما هو.
"""

import uuid

import pytest

from conftest import auth

YEAR = {"name": "ZT 2030", "start_date": "2030-09-01", "end_date": "2031-06-30"}


@pytest.fixture(scope="module", autouse=True)
def _cleanup(admin):
    yield
    zt_schools = "select id from public.schools where school_code like 'ZT%'"
    zt_years = f"select id from public.academic_years where name like 'ZT%' or school_id in ({zt_schools})"
    for stmt in (
        f"delete from public.sections where academic_year_id in ({zt_years}) or school_id in ({zt_schools})",
        f"delete from public.terms where academic_year_id in ({zt_years})",
        f"delete from public.academic_years where id in ({zt_years})",
        f"delete from public.grade_levels where name like 'ZT%' or school_id in ({zt_schools})",
        f"delete from public.stages where name like 'ZT%' or school_id in ({zt_schools})",
        f"delete from public.identity_scopes where school_id in ({zt_schools}) or group_id in (select id from public.groups where group_code like 'ZT%')",
        "delete from public.schools where school_code like 'ZT%'",
        "delete from public.groups where group_code like 'ZT%'",
    ):
        admin.execute(stmt)


def post(client, who, path, body=None, **headers):
    return client.post(path, json=body or {}, headers=auth(who, **headers))


def patch(client, who, path, body):
    return client.patch(path, json=body, headers=auth(who))


def get(client, who, path, **kw):
    return client.get(path, headers=auth(who), **kw)


@pytest.fixture(scope="module")
def built(client, admin, ids):
    """tenant_admin يبني من الصفر: مجموعة، مدرستان، سنة، مرحلة، صف، شعبة — ويعيد المعرّفات.
    يعتمد على ids كي تُقرأ معرّفات الـseed قبل أي إضافة (حارس conftest يتحقق من مدارس الـseed الثلاث)."""
    group = post(client, "tenant_admin", "/groups", {"group_code": "ZTG1", "name": "ZT Group"})
    assert group.status_code == 201, group.text
    s1 = post(client, "tenant_admin", "/schools", {"group_id": group.json()["id"], "school_code": "ZT1", "name": "ZT One", "slug": "zt-one"})
    s2 = post(client, "tenant_admin", "/schools", {"school_code": "ZT2", "name": "ZT Two", "slug": "zt-two"})
    assert s1.status_code == 201 and s2.status_code == 201, (s1.text, s2.text)
    return {"group": group.json(), "s1": s1.json(), "s2": s2.json()}


# ------------------------------------------------------------------ المسار الكامل
def test_tenant_admin_builds_a_school_to_ready_for_enrollment(client, built):
    s1, s2 = built["s1"], built["s2"]
    assert s1["is_standalone"] is False and s1["status"] == "active" and s1["slug"] == "zt-one"
    assert s2["is_standalone"] is True and s2["guardian_first_login_mode"] == "A" and s2["timezone"] == "Africa/Cairo"
    sid = s1["id"]
    r = get(client, "tenant_admin", f"/schools/{sid}/readiness").json()
    assert r == {"ready": False, "checks": {"school_active": True, "active_year": False, "active_section": False}}

    year = post(client, "tenant_admin", f"/schools/{sid}/academic-years", YEAR)
    assert year.status_code == 201 and year.json()["status"] == "planned"
    yid = year.json()["id"]
    stage = post(client, "tenant_admin", f"/schools/{sid}/stages", {"name": "ZT Primary", "sequence_no": 1})
    grade = post(client, "tenant_admin", f"/schools/{sid}/grade-levels", {"stage_id": stage.json()["id"], "name": "ZT G1", "sequence_no": 1})
    section = post(client, "tenant_admin", f"/academic-years/{yid}/sections", {"grade_level_id": grade.json()["id"], "name": "A", "capacity": 30})
    assert (stage.status_code, grade.status_code, section.status_code) == (201, 201, 201)
    assert section.json()["school_id"] == sid and section.json()["academic_year_id"] == yid      # المدرسة من صف السنة، لا من العميل
    assert get(client, "tenant_admin", f"/schools/{sid}/readiness").json()["checks"]["active_year"] is False

    assert post(client, "tenant_admin", f"/academic-years/{yid}/activate", {"reason": "year starts"}).json()["status"] == "active"
    assert get(client, "tenant_admin", f"/schools/{sid}/readiness").json() == {
        "ready": True, "checks": {"school_active": True, "active_year": True, "active_section": True}}


def test_terms_lifecycle_through_the_api(client, built):
    sid = built["s1"]["id"]
    yid = get(client, "tenant_admin", f"/schools/{sid}/academic-years").json()["rows"][0]["id"]
    t1 = post(client, "tenant_admin", f"/academic-years/{yid}/terms", {"name": "T1", "sequence_no": 1, "start_date": "2030-09-01", "end_date": "2030-12-31"})
    t2 = post(client, "tenant_admin", f"/academic-years/{yid}/terms", {"name": "T2", "sequence_no": 2, "start_date": "2031-01-05", "end_date": "2031-06-20"})
    assert t1.status_code == 201 and t1.json()["status"] == "planned" and t1.json()["school_id"] == sid
    overlap = post(client, "tenant_admin", f"/academic-years/{yid}/terms", {"name": "T9", "sequence_no": 9, "start_date": "2030-12-01", "end_date": "2031-01-10"})
    assert overlap.status_code == 409 and overlap.json()["detail"] == "conflict"                    # EXCLUDE (23P01)
    outside = post(client, "tenant_admin", f"/academic-years/{yid}/terms", {"name": "T8", "sequence_no": 8, "start_date": "2031-06-21", "end_date": "2031-07-30"})
    assert outside.status_code == 422                                                                # خارج حدود السنة
    assert post(client, "tenant_admin", f"/terms/{t1.json()['id']}/activate", {"reason": "start"}).json()["status"] == "active"
    second = post(client, "tenant_admin", f"/terms/{t2.json()['id']}/activate", {"reason": "start"})
    assert (second.status_code, second.json()["detail"]) == (422, "invariant_violation")          # فصل نشط واحد
    assert patch(client, "tenant_admin", f"/terms/{t1.json()['id']}", {"end_date": "2030-12-20"}).status_code == 422
    assert patch(client, "tenant_admin", f"/terms/{t1.json()['id']}", {"name": "Term 1"}).json()["name"] == "Term 1"
    close_year = post(client, "tenant_admin", f"/academic-years/{yid}/close", {"reason": "r"})
    assert close_year.status_code == 422                                                             # سنة بفصل نشط
    assert post(client, "tenant_admin", f"/terms/{t1.json()['id']}/close", {"reason": "end"}).json()["status"] == "closed"
    assert post(client, "tenant_admin", f"/terms/{t1.json()['id']}/activate", {"reason": "again"}).status_code == 422


def test_year_edit_rules_and_conflicts(client, built):
    sid = built["s1"]["id"]
    yid = get(client, "tenant_admin", f"/schools/{sid}/academic-years").json()["rows"][0]["id"]
    assert patch(client, "tenant_admin", f"/academic-years/{yid}", {"name": "ZT 2030/31"}).json()["name"] == "ZT 2030/31"
    dates = patch(client, "tenant_admin", f"/academic-years/{yid}", {"end_date": "2031-07-01"})
    assert (dates.status_code, dates.json()["detail"]) == (422, "invariant_violation")             # active: الاسم فقط (T10)
    overlap = post(client, "tenant_admin", f"/schools/{sid}/academic-years", {"name": "ZT overlap", "start_date": "2031-06-01", "end_date": "2031-08-01"})
    assert overlap.status_code == 409
    assert patch(client, "tenant_admin", f"/academic-years/{yid}", {}).status_code == 422             # PATCH فارغ


def test_copy_sections_is_one_idempotent_operation(client, built, admin):
    sid = built["s1"]["id"]
    source = get(client, "tenant_admin", f"/schools/{sid}/academic-years").json()["rows"][0]["id"]
    target = post(client, "tenant_admin", f"/schools/{sid}/academic-years", {"name": "ZT 2031", "start_date": "2031-09-01", "end_date": "2032-06-30"}).json()["id"]
    first = post(client, "tenant_admin", f"/academic-years/{target}/copy-sections", {"source_year_id": source, "reason": "next year"})
    assert first.json() == {"created": 1}
    assert post(client, "tenant_admin", f"/academic-years/{target}/copy-sections", {"source_year_id": source, "reason": "again"}).json() == {"created": 0}
    into_active = post(client, "tenant_admin", f"/academic-years/{source}/copy-sections", {"source_year_id": target, "reason": "r"})
    assert into_active.status_code == 422
    rows = get(client, "tenant_admin", f"/academic-years/{target}/sections").json()["rows"]
    assert [(r["name"], r["capacity"], r["status"]) for r in rows] == [("A", 30, "active")]
    audit = admin.execute("select new_values, reason from public.audit_log where action = 'copy_sections' and entity_id = %s order by id", [target]).fetchall()
    assert [(a["new_values"]["created"], a["new_values"]["already_copied"], a["reason"]) for a in audit] == [(1, 0, "next year"), (0, 1, "again")]
    # الجاهزية تشترط شعبة نشطة **في السنة النشطة** (Q4): شعبة نشطة في سنة planned لا تكفي
    active_section = get(client, "tenant_admin", f"/academic-years/{source}/sections").json()["rows"][0]["id"]
    assert patch(client, "tenant_admin", f"/sections/{active_section}", {"status": "inactive"}).json()["status"] == "inactive"
    assert get(client, "tenant_admin", f"/schools/{sid}/readiness").json() == {
        "ready": False, "checks": {"school_active": True, "active_year": True, "active_section": False}}
    assert patch(client, "tenant_admin", f"/sections/{active_section}", {"status": "active"}).json()["status"] == "active"
    assert get(client, "tenant_admin", f"/schools/{sid}/readiness").json()["ready"] is True


def test_slug_change_errors_and_audit(client, built, admin):
    sid = built["s1"]["id"]
    changed = post(client, "tenant_admin", f"/schools/{sid}/slug", {"slug": "zt-north", "reason": "rebrand"})
    assert changed.status_code == 200 and changed.json()["slug"] == "zt-north" and changed.json()["id"] == sid
    assert post(client, "tenant_admin", f"/schools/{sid}/slug", {"slug": "Bad_Slug", "reason": "r"}).status_code == 422
    taken = post(client, "tenant_admin", f"/schools/{sid}/slug", {"slug": "school-a", "reason": "r"})
    assert (taken.status_code, taken.json()["detail"]) == (409, "conflict")
    assert post(client, "tenant_admin", f"/schools/{sid}/slug", {"slug": "zt-x"}).status_code == 422   # بلا سبب
    row = admin.execute("select actor_type, reason, old_values ->> 'slug' as old, new_values ->> 'slug' as new from public.audit_log"
                        " where action = 'change_slug' and entity_id = %s", [sid]).fetchall()
    assert [(r["actor_type"], r["reason"], r["old"], r["new"]) for r in row] == [("tenant_user", "rebrand", "zt-one", "zt-north")]


def test_archive_rules_and_guardian_mode(client, built):
    group_archive = post(client, "tenant_admin", f"/groups/{built['group']['id']}/archive", {"reason": "r"})
    assert (group_archive.status_code, group_archive.json()["detail"]) == (422, "invariant_violation")   # مجموعة بمدارس نشطة
    archived = post(client, "tenant_admin", f"/schools/{built['s2']['id']}/archive", {"reason": "closed down"})
    assert archived.status_code == 200 and archived.json()["status"] == "archived"
    assert post(client, "tenant_admin", f"/schools/{built['s2']['id']}/slug", {"slug": "zt-reborn", "reason": "r"}).status_code == 422
    mode = post(client, "tenant_admin", f"/schools/{built['s1']['id']}/guardian-first-login-mode", {"mode": "C", "reason": "policy"})
    assert mode.status_code == 200 and mode.json() == {"mode": "C"}
    assert get(client, "tenant_admin", "/schools").json()["rows"] and \
        {r["school_code"]: r["guardian_first_login_mode"] for r in get(client, "tenant_admin", "/schools").json()["rows"]}["ZT1"] == "C"
    assert patch(client, "tenant_admin", f"/groups/{built['group']['id']}", {"name": "ZT Group renamed"}).json()["name"] == "ZT Group renamed"


# ------------------------------------------------------------------ group_manager
def test_group_manager_creates_schools_in_its_group_only(client, ids, admin, built):
    ga = admin.execute("select id from public.groups where group_code = 'GA'").fetchone()["id"]
    mine = post(client, "group_manager", "/schools", {"group_id": str(ga), "school_code": "ZT3", "name": "ZT Three", "slug": "zt-three"})
    assert mine.status_code == 201 and mine.json()["group_id"] == str(ga)            # بلا RETURNING: يعمل لنطاق المجموعة
    other_group = post(client, "group_manager", "/schools", {"group_id": built["group"]["id"], "school_code": "ZT4", "name": "x", "slug": "zt-four"})
    standalone = post(client, "group_manager", "/schools", {"school_code": "ZT5", "name": "x", "slug": "zt-five"})
    assert (other_group.status_code, standalone.status_code) == (403, 403)
    assert post(client, "group_manager", "/groups", {"group_code": "ZTG2", "name": "x"}).status_code == 403
    codes = {r["school_code"] for r in get(client, "group_manager", "/schools").json()["rows"]}
    assert {"SA", "SB", "ZT3"} <= codes and "SS" not in codes and "ZT1" not in codes


# ------------------------------------------------------------------ school_admin و secretary: 404 مقابل 403
def test_school_admin_stays_inside_its_school(client, ids):
    sa, sb = ids["school"]["SA"], ids["school"]["SB"]
    assert [r["school_code"] for r in get(client, "school_admin", "/schools").json()["rows"]] == ["SA"]
    assert post(client, "school_admin", "/schools", {"school_code": "ZT6", "name": "x", "slug": "zt-six"}).status_code == 403
    year = post(client, "school_admin", f"/schools/{sa}/academic-years", {"name": "ZT SA 2040", "start_date": "2040-09-01", "end_date": "2041-06-30"})
    assert year.status_code == 201
    assert post(client, "school_admin", f"/schools/{sb}/academic-years", {"name": "ZT SB", "start_date": "2040-09-01", "end_date": "2041-06-30"}).status_code == 404
    assert get(client, "school_admin", f"/schools/{sb}/academic-years").status_code == 404
    assert get(client, "school_admin", f"/schools/{sb}/readiness").status_code == 404
    assert patch(client, "school_admin", f"/schools/{sb}", {"name": "hijack"}).status_code == 404
    assert post(client, "school_admin", f"/schools/{sb}/slug", {"slug": "zt-hijack", "reason": "r"}).status_code == 404
    sb_year = get(client, "tenant_admin", f"/schools/{sb}/academic-years").json()["rows"][0]["id"]
    assert patch(client, "school_admin", f"/academic-years/{sb_year}", {"name": "hijack"}).status_code == 404
    assert post(client, "school_admin", f"/academic-years/{sb_year}/terms",
                {"name": "ZT x", "sequence_no": 9, "start_date": "2026-09-01", "end_date": "2026-09-30"}).status_code == 404
    sb_grade = get(client, "tenant_admin", f"/schools/{sb}/grade-levels").json()["rows"][0]["id"]
    assert post(client, "school_admin", f"/academic-years/{sb_year}/sections", {"grade_level_id": sb_grade, "name": "ZT x"}).status_code == 404
    assert get(client, "school_admin", f"/academic-years/{sb_year}/sections").status_code == 404
    assert post(client, "school_admin", f"/academic-years/{sb_year}/copy-sections",
                {"source_year_id": year.json()["id"], "reason": "r"}).status_code == 404
    assert get(client, "school_admin", f"/schools/{sa}/readiness").json()["ready"] is True       # مدرسة الـseed جاهزة


def test_secretary_reads_but_cannot_write(client, ids):
    sa = ids["school"]["SA"]
    years = get(client, "secretary", f"/schools/{sa}/academic-years").json()["rows"]
    seed_year = next(y for y in years if y["name"] == "2026/2027")
    assert get(client, "secretary", f"/academic-years/{seed_year['id']}/sections").json()["rows"]
    assert get(client, "secretary", f"/schools/{sa}/stages").status_code == 200
    assert get(client, "secretary", f"/schools/{sa}/readiness").json()["ready"] is True
    # المدرسة والسنة مرئيتان، والكتابة مرفوضة ← 403 (لا 404)
    assert post(client, "secretary", f"/schools/{sa}/academic-years", {"name": "ZT sec", "start_date": "2045-09-01", "end_date": "2046-06-30"}).status_code == 403
    assert patch(client, "secretary", f"/academic-years/{seed_year['id']}", {"name": "hijack"}).status_code == 403
    assert post(client, "secretary", f"/academic-years/{seed_year['id']}/close", {"reason": "r"}).status_code == 403
    assert patch(client, "secretary", f"/schools/{sa}", {"name": "hijack"}).status_code == 403


def test_readiness_needs_the_read_permissions(client, ids):
    """bus_supervisor يرى مدرسته (school.read) بلا academic_year.read / section.read: الشروط غير مرئية لا «غير متحققة» ← 403."""
    sa = ids["school"]["SA"]
    assert get(client, "bus_supervisor", f"/schools/{sa}").status_code == 200
    assert get(client, "bus_supervisor", f"/schools/{sa}/readiness").status_code == 403


def test_platform_admin_has_no_school_setup_path(client):
    assert get(client, "platform", "/schools").json() == {"rows": []}
    assert get(client, "platform", "/groups").json() == {"rows": []}
    assert post(client, "platform", "/schools", {"school_code": "ZT7", "name": "x", "slug": "zt-seven"}).status_code == 403
    assert post(client, "platform", "/groups", {"group_code": "ZTG3", "name": "x"}).status_code == 403


# ------------------------------------------------------------------ لا سلطة من الطلب
def test_no_context_or_authority_from_the_request(client, ids):
    sa, sb = ids["school"]["SA"], ids["school"]["SB"]
    forged_tenant = {"school_code": "ZT8", "name": "x", "slug": "zt-eight", "platform_tenant_id": "20000000-0000-0000-0000-000000000002"}
    assert post(client, "tenant_admin", "/schools", forged_tenant).status_code == 422
    assert post(client, "school_admin", f"/schools/{sa}/academic-years",
                {**YEAR, "name": "ZT forged", "school_id": sb}).status_code == 422
    section_id = get(client, "tenant_admin", f"/academic-years/{get(client, 'tenant_admin', f'/schools/{sa}/academic-years').json()['rows'][0]['id']}/sections").json()["rows"][0]["id"]
    assert patch(client, "school_admin", f"/sections/{section_id}", {"academic_year_id": str(uuid.uuid4())}).status_code == 422
    assert patch(client, "school_admin", f"/sections/{section_id}", {"status": "archived"}).status_code == 422
    forged_headers = {"X-School-Id": sb, "X-Tenant-Id": ids["tenant"], "X-Role": "tenant_admin"}
    rows = client.get("/schools", headers=auth("school_admin", **forged_headers), params={"school_id": sb, "tenant_id": ids["tenant"]}).json()["rows"]
    assert [r["school_code"] for r in rows] == ["SA"]
    assert get(client, "school_admin", f"/schools/{uuid.uuid4()}/academic-years").status_code == 404


def test_cors_preflight_allows_patch_from_a_school_host(client, ids):
    r = client.options(f"/sections/{uuid.uuid4()}", headers={
        "Origin": "http://school-a.dev.localhost:4173", "Access-Control-Request-Method": "PATCH",
        "Access-Control-Request-Headers": "authorization,content-type"})
    assert r.status_code == 200 and "PATCH" in r.headers["access-control-allow-methods"]
    assert "DELETE" not in r.headers["access-control-allow-methods"]


def test_no_delete_route(client, ids):
    assert client.delete(f"/schools/{ids['school']['SA']}", headers=auth("tenant_admin")).status_code == 405
