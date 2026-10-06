"""Phase 2B / 2B-5 — `GET /schools/{id}/setup-progress` (W1–W6) على seed التطوير.

ما يُثبت: كل خطوة تتحول بشرطها الدقيق؛ المواد والدوام شرط **شامل لكل صف نشط له شعب** (W2)؛ `setup_complete` مستقل عن
`ready_for_enrollment` في الاتجاهين (W3)؛ سنة القياس الافتراضية والمختارة صراحةً (W1)؛ 404/403 (W4)؛ لا مسار كتابة للمعالج.
مدرسة اختبار جديدة ZTP تُبنى وتُحذف في نهاية الوحدة.
"""

import uuid

import pytest

from conftest import auth


@pytest.fixture(scope="module", autouse=True)
def _cleanup(admin):
    yield
    zs = "select id from public.schools where school_code like 'ZTP%'"
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
        f"delete from public.school_profiles where school_id in ({zs})",
        f"delete from public.identity_scopes where school_id in ({zs})",
        "delete from public.schools where school_code like 'ZTP%'",
    ):
        admin.execute(stmt)


def post(client, path, body, who="tenant_admin"):
    r = client.post(path, json=body, headers=auth(who))
    assert r.status_code in (200, 201), (path, r.status_code, r.text)
    return r.json()


def put(client, path, body, who="tenant_admin"):
    r = client.put(path, json=body, headers=auth(who))
    assert r.status_code == 200, (path, r.text)
    return r.json()


def progress(client, school_id, who="tenant_admin", **params):
    r = client.get(f"/schools/{school_id}/setup-progress", params=params, headers=auth(who))
    assert r.status_code == 200, r.text
    body = r.json()
    return {s["key"]: s for s in body["steps"]}, body


def done(steps):
    return {k for k, s in steps.items() if s["done"]}


def test_steps_turn_on_exactly_by_their_condition(client, ids):   # ids أولاً: حارس الـseed يرى مدارسه الثلاث قبل ZTP1
    school = post(client, "/schools", {"school_code": "ZTP1", "name": "ZT Progress", "slug": "ztp-one"})
    sid = school["id"]
    steps, body = progress(client, sid)
    assert body["year"] is None and done(steps) == set() and body["setup_complete"] is False and body["ready_for_enrollment"] is False

    put(client, f"/schools/{sid}/profile", {"address": "Cairo", "phone_e164": None, "email": None, "website": None, "principal_display_name": None})
    assert not progress(client, sid)[0]["profile"]["done"]                                  # العنوان والهاتف معاً
    put(client, f"/schools/{sid}/profile", {"address": "Cairo", "phone_e164": "+201000000555", "email": None, "website": None, "principal_display_name": None})
    assert progress(client, sid)[0]["profile"]["done"]

    year = post(client, f"/schools/{sid}/academic-years", {"name": "ZTP 2080", "start_date": "2080-09-01", "end_date": "2081-06-30"})
    steps, body = progress(client, sid)
    assert body["year"]["id"] == year["id"] and not steps["year"]["done"]                  # W1: أقرب planned؛ بلا فصل
    post(client, f"/academic-years/{year['id']}/terms", {"name": "T1", "sequence_no": 1, "start_date": "2080-09-01", "end_date": "2081-01-15"})
    assert progress(client, sid)[0]["year"]["done"]

    put(client, f"/academic-years/{year['id']}/weekdays", {"weekdays": [0, 1, 2, 3, 4], "reason": "week"})
    assert progress(client, sid)[0]["calendar"]["done"]

    stage = post(client, f"/schools/{sid}/stages", {"name": "ZTP Primary", "sequence_no": 1})
    g1 = post(client, f"/schools/{sid}/grade-levels", {"stage_id": stage["id"], "name": "ZTP G1", "sequence_no": 1})
    g2 = post(client, f"/schools/{sid}/grade-levels", {"stage_id": stage["id"], "name": "ZTP G2", "sequence_no": 2})
    assert not progress(client, sid)[0]["structure"]["done"]                                # بلا شعبة
    post(client, f"/academic-years/{year['id']}/sections", {"grade_level_id": g1["id"], "name": "A"})
    steps, _ = progress(client, sid)
    assert steps["structure"]["done"] and steps["subjects"] == {"key": "subjects", "done": False, "missing": 1}

    subject = post(client, f"/schools/{sid}/subjects", {"subject_code": "ZTPAR", "name": "ZTP Arabic"})
    post(client, f"/academic-years/{year['id']}/grade-subjects", {"grade_level_id": g1["id"], "subject_id": subject["id"], "weekly_periods": 5})
    assert progress(client, sid)[0]["subjects"]["done"]

    # W2 شامل: صف ثانٍ له شعبة ← المواد والدوام غير مكتملين حتى يُجهَّز هو أيضاً
    post(client, f"/academic-years/{year['id']}/sections", {"grade_level_id": g2["id"], "name": "A"})
    steps, _ = progress(client, sid)
    assert (steps["subjects"]["done"], steps["subjects"]["missing"]) == (False, 1)
    post(client, f"/academic-years/{year['id']}/grade-subjects", {"grade_level_id": g2["id"], "subject_id": subject["id"], "weekly_periods": 4})
    assert progress(client, sid)[0]["subjects"]["done"]

    bell = post(client, f"/academic-years/{year['id']}/bell-schedules", {"name": "ZTP Morning"})
    put(client, f"/academic-years/{year['id']}/grade-bell-schedules/{g1['id']}", {"bell_schedule_id": bell["id"]})
    steps, _ = progress(client, sid)
    assert (steps["bell"]["done"], steps["bell"]["missing"]) == (False, 2)                  # G1: جدول بلا حصة lesson؛ G2: بلا إسناد
    post(client, f"/bell-schedules/{bell['id']}/periods", {"weekday": 0, "kind": "break", "name": "Recess", "start_time": "08:00", "end_time": "08:15"})
    assert progress(client, sid)[0]["bell"]["missing"] == 2                                 # الاستراحة ليست حصة
    post(client, f"/bell-schedules/{bell['id']}/periods", {"weekday": 0, "kind": "lesson", "start_time": "08:15", "end_time": "09:00"})
    steps, _ = progress(client, sid)
    assert (steps["bell"]["done"], steps["bell"]["missing"]) == (False, 1)                  # W2 شامل: G1 جاهز و G2 غير مُسنَد
    put(client, f"/academic-years/{year['id']}/grade-bell-schedules/{g2['id']}", {"bell_schedule_id": bell["id"]})
    steps, body = progress(client, sid)
    assert steps["bell"]["done"] and not steps["assets"]["done"] and steps["assets"]["optional"] is True

    # W3: مكتمل وغير جاهز (السنة planned) — ليس تناقضاً؛ والأصول لا تدخل
    assert (body["setup_complete"], body["ready_for_enrollment"]) == (True, False)
    post(client, f"/academic-years/{year['id']}/activate", {"reason": "year starts"})
    steps, body = progress(client, sid)
    assert (body["setup_complete"], body["ready_for_enrollment"], body["year"]["status"]) == (True, True, "active")
    readiness = client.get(f"/schools/{sid}/readiness", headers=auth("tenant_admin")).json()
    assert readiness["ready"] is True                                                       # الجاهزية كما هي (2A)

    # W1: السنة المختارة صراحةً تُقاس هي، والافتراضي يبقى النشطة
    nxt = post(client, f"/schools/{sid}/academic-years", {"name": "ZTP 2081", "start_date": "2081-09-01", "end_date": "2082-06-30"})
    assert progress(client, sid)[1]["year"]["id"] == year["id"]
    steps, body = progress(client, sid, year_id=nxt["id"])
    assert body["year"]["id"] == nxt["id"] and done(steps) == {"profile"} and body["setup_complete"] is False
    assert body["ready_for_enrollment"] is True                                             # مستقلة عن سنة القياس

    # W1: السنة المغلقة لا تُقاس؛ والافتراضي ينتقل إلى أقرب planned
    post(client, f"/academic-years/{year['id']}/close", {"reason": "year ends"})
    r = client.get(f"/schools/{sid}/setup-progress", params={"year_id": year["id"]}, headers=auth("tenant_admin"))
    assert r.status_code == 404
    assert progress(client, sid)[1]["year"]["id"] == nxt["id"]


def test_ready_but_not_set_up_is_possible(client, ids):
    """W3 في الاتجاه الآخر: مدرسة الـseed جاهزة للتسجيل (2A) دون تقويم ولا دوام."""
    _, body = progress(client, ids["school"]["SA"])
    assert (body["ready_for_enrollment"], body["setup_complete"]) == (True, False)


def test_visibility_and_read_permissions(client, ids):
    sa, sb = ids["school"]["SA"], ids["school"]["SB"]
    assert client.get(f"/schools/{sb}/setup-progress", headers=auth("school_admin")).status_code == 404     # غير مرئية
    assert client.get(f"/schools/{sa}/setup-progress", headers=auth("bus_supervisor")).status_code == 403   # مرئية بلا مفاتيح القراءة
    assert client.get(f"/schools/{sa}/setup-progress", headers=auth("secretary")).status_code == 200        # يملك مفاتيح القراءة السبعة
    assert client.get(f"/schools/{uuid.uuid4()}/setup-progress", headers=auth("tenant_admin")).status_code == 404
    assert client.get(f"/schools/{sa}/setup-progress", params={"year_id": str(uuid.uuid4())}, headers=auth("tenant_admin")).status_code == 404


def test_the_wizard_has_no_write_path(client):
    """B14: لا endpoint كتابة خاص بالمعالج — مسار التقدم قراءة فقط."""
    paths = client.app.openapi()["paths"]                                  # كل المسارات المسجلة وأفعالها
    assert set(paths["/schools/{school_id}/setup-progress"]) == {"get"}
    assert [p for p, ops in paths.items() if ("wizard" in p or "progress" in p) and set(ops) - {"get"}] == []
    sa = client.get("/schools", headers=auth("tenant_admin")).json()["rows"][0]["id"]
    assert client.post(f"/schools/{sa}/setup-progress", headers=auth("tenant_admin")).status_code == 405
