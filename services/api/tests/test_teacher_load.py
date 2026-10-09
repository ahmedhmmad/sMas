"""Phase 3A / 3-5 — النصاب والحد الاختياري (M52) على seed التطوير (docs/PHASE3_5_WORKLOAD.md).

ما يُثبت عبر المسار الوحيد (JWT → معاملة authenticated → RLS/T18): النصاب **مشتق** (المنتهي لا يُحتسب، تغيّر الحصص ينعكس،
المعلَّق يُعدّ منفصلاً، مربي الفصل بلا حصص، الإجازة تُحتسب)؛ الحد اختياري ويُزال بـnull؛ `over_limit` = أكبر تماماً؛
**التكليف فوق الحد ينجح** (L7)؛ رؤية الحد أضيق من staff.read (L5)؛ السبب في السنة النشطة (C3)؛ لا سياق من الجسم.
كل ما يُنشأ يحمل الرمز ZTL ويُحذف في نهاية الوحدة.
"""

import uuid

import pytest

from conftest import STAFF_ID, auth

ZTL = "select id from public.staff where employee_code like 'ZTL%'"
SEED_TEACHER = STAFF_ID["teacher"]


@pytest.fixture(scope="module", autouse=True)
def _cleanup(admin):
    yield
    years = "select id from public.academic_years where name like 'ZTL%'"
    subjects = "select id from public.subjects where subject_code like 'ZTL%'"
    for stmt in (
        f"delete from public.teacher_load_limits where staff_id in ({ZTL}) or academic_year_id in ({years})",
        "alter table public.teaching_assignments disable trigger guard",
        "alter table public.class_teacher_assignments disable trigger guard",
        f"delete from public.teaching_assignments where staff_id in ({ZTL}) or academic_year_id in ({years})",
        f"delete from public.class_teacher_assignments where staff_id in ({ZTL}) or academic_year_id in ({years})",
        "alter table public.teaching_assignments enable trigger guard",
        "alter table public.class_teacher_assignments enable trigger guard",
        f"delete from public.grade_subjects where subject_id in ({subjects})",
        "delete from public.subjects where subject_code like 'ZTL%'",
        f"delete from public.sections where academic_year_id in ({years})",
        "delete from public.academic_years where name like 'ZTL%'",
        f"delete from public.staff_school_assignments where staff_id in ({ZTL})",
        "delete from public.staff where employee_code like 'ZTL%'",
    ):
        admin.execute(stmt)


def post(client, who, path, body=None):
    return client.post(path, json=body or {}, headers=auth(who))


def get(client, who, path):
    return client.get(path, headers=auth(who))


def put(client, who, path, body):
    return client.put(path, json=body, headers=auth(who))


def patch(client, who, path, body):
    return client.patch(path, json=body, headers=auth(who))


@pytest.fixture(scope="module")
def w(client, ids):
    """SA: سنة planned بشعبتين، مادتان مربوطتان (5 و4 حصص)، وموظفان."""
    sa = ids["school"]["SA"]
    grade = next(g for g in get(client, "school_admin", f"/schools/{sa}/grade-levels").json()["rows"] if g["status"] == "active")["id"]
    year = post(client, "school_admin", f"/schools/{sa}/academic-years", {"name": "ZTL 2064", "start_date": "2064-09-01", "end_date": "2065-06-30"}).json()["id"]
    sec = [post(client, "school_admin", f"/academic-years/{year}/sections", {"grade_level_id": grade, "name": n}).json()["id"] for n in ("ZTL-A", "ZTL-B")]
    subj, link = {}, {}
    for code, periods in (("ZTL-AR", 5), ("ZTL-MA", 4)):
        subj[code] = post(client, "school_admin", f"/schools/{sa}/subjects", {"subject_code": code, "name": code}).json()["id"]
        r = post(client, "school_admin", f"/academic-years/{year}/grade-subjects", {"grade_level_id": grade, "subject_id": subj[code], "weekly_periods": periods})
        assert r.status_code == 201, r.text
        link[code] = r.json()["id"]

    def staff(code):
        r = post(client, "school_admin", f"/schools/{sa}/staff", {"employee_code": code, "first_name": "Zt", "family_name": code, "job_title": "Teacher", "effective_from": "2026-09-01"})
        assert r.status_code == 201, r.text
        return r.json()["id"]
    active_year = next(y for y in get(client, "school_admin", f"/schools/{sa}/academic-years").json()["rows"] if y["status"] == "active")["id"]
    return {"sa": sa, "sb": ids["school"]["SB"], "year": year, "active_year": active_year, "sec": sec, "subj": subj, "link": link,
            "t1": staff("ZTL-1"), "t2": staff("ZTL-2")}


def load(client, who, w, year=None):
    r = get(client, who, f"/academic-years/{year or w['year']}/teacher-load")
    assert r.status_code == 200, r.text
    return {row["staff_id"]: row for row in r.json()["rows"]}


def assign(client, w, section, subject, staff="t1"):
    r = post(client, "school_admin", f"/sections/{w['sec'][section]}/teaching-assignments",
             {"subject_id": w["subj"][subject], "staff_id": w[staff], "effective_from": "2064-09-01"})
    assert r.status_code == 201, r.text
    return r.json()["id"]


def limit(client, w, value, staff="t1", who="school_admin", **extra):
    return put(client, who, f"/academic-years/{w['year']}/teacher-load-limits/{w[staff]}", {"max_weekly_periods": value, **extra})


def test_the_load_is_derived_from_operational_teaching_assignments(client, w):
    assert load(client, "school_admin", w) == {}                                   # لا تكليف ولا حد ← لا صف
    a_ar, a_ma, b_ar = assign(client, w, 0, "ZTL-AR"), assign(client, w, 0, "ZTL-MA"), assign(client, w, 1, "ZTL-AR")
    w["a_ma"] = a_ma
    row = load(client, "school_admin", w)[w["t1"]]
    assert (row["weekly_periods"], row["teaching_count"], row["suspended_count"], row["class_teacher_count"]) == (14, 3, 0, 0)
    assert (row["staff_name"], row["employee_code"], row["staff_status"]) == ("Zt ZTL-1", "ZTL-1", "active")
    assert (row["limit_visible"], row["max_weekly_periods"], row["over_limit"]) == (True, None, False)     # بلا حد ← لا تنبيه
    # مربي الفصل تكليف بلا حصص
    assert post(client, "school_admin", f"/sections/{w['sec'][0]}/class-teacher", {"staff_id": w["t1"], "effective_from": "2064-09-01"}).status_code == 201
    row = load(client, "school_admin", w)[w["t1"]]
    assert (row["weekly_periods"], row["class_teacher_count"]) == (14, 1)
    # المنتهي لا يُحتسب
    assert post(client, "school_admin", f"/teaching-assignments/{b_ar}/end", {"effective_to": "2064-12-01", "reason": "left B"}).status_code == 200
    row = load(client, "school_admin", w)[w["t1"]]
    assert (row["weekly_periods"], row["teaching_count"]) == (9, 2)
    # تغيير الحصص في الربط ينعكس فوراً — لا رقم مخزّن
    assert patch(client, "school_admin", f"/grade-subjects/{w['link']['ZTL-AR']}", {"weekly_periods": 7}).status_code == 200
    assert load(client, "school_admin", w)[w["t1"]]["weekly_periods"] == 11
    # تعطيل الربط: التكليف «معلَّق» — يخرج من المجموع ويُعدّ منفصلاً
    assert patch(client, "school_admin", f"/grade-subjects/{w['link']['ZTL-MA']}", {"status": "inactive"}).status_code == 200
    row = load(client, "school_admin", w)[w["t1"]]
    assert (row["weekly_periods"], row["teaching_count"], row["suspended_count"]) == (7, 1, 1)
    assert patch(client, "school_admin", f"/grade-subjects/{w['link']['ZTL-MA']}", {"status": "active"}).status_code == 200
    row = load(client, "school_admin", w)[w["t1"]]
    assert (row["weekly_periods"], row["teaching_count"], row["suspended_count"]) == (11, 2, 0)
    # موظف بلا أي تكليف ولا حد: لا صف
    assert w["t2"] not in load(client, "school_admin", w)


def test_the_limit_is_optional_and_over_means_strictly_greater(client, w):
    """النصاب الآن 11."""
    r = limit(client, w, 20)
    assert (r.status_code, r.json()["max_weekly_periods"], r.json()["staff_id"], r.json()["academic_year_id"], r.json()["school_id"]) == \
        (200, 20, w["t1"], w["year"], w["sa"])
    row = load(client, "school_admin", w)[w["t1"]]
    assert (row["max_weekly_periods"], row["over_limit"]) == (20, False)
    assert limit(client, w, 11).status_code == 200                                 # التساوي ليس تجاوزاً
    assert load(client, "school_admin", w)[w["t1"]]["over_limit"] is False
    assert limit(client, w, 10).status_code == 200
    assert load(client, "school_admin", w)[w["t1"]]["over_limit"] is True
    cleared = limit(client, w, None)                                               # الإزالة = null، والصف باقٍ
    assert (cleared.status_code, cleared.json()["max_weekly_periods"]) == (200, None)
    row = load(client, "school_admin", w)[w["t1"]]
    assert (row["max_weekly_periods"], row["over_limit"]) == (None, False)
    # حد لموظف بلا تكليفات يظهر بنصاب صفر؛ وإزالته تُخفي الصف
    assert limit(client, w, 12, staff="t2").status_code == 200
    row = load(client, "school_admin", w)[w["t2"]]
    assert (row["weekly_periods"], row["teaching_count"], row["max_weekly_periods"], row["over_limit"]) == (0, 0, 12, False)
    assert limit(client, w, None, staff="t2").status_code == 200
    assert w["t2"] not in load(client, "school_admin", w)


def test_the_load_never_refuses_an_assignment(client, w):
    """L7: الحد 5 والنصاب 11 أصلاً — تكليف جديد ينجح، والتنبيه نتيجة عرض."""
    assert limit(client, w, 5).status_code == 200
    assert load(client, "school_admin", w)[w["t1"]]["over_limit"] is True
    more = assign(client, w, 1, "ZTL-MA")                                           # +4 فوق الحد
    row = load(client, "school_admin", w)[w["t1"]]
    assert (row["weekly_periods"], row["max_weekly_periods"], row["over_limit"]) == (15, 5, True)
    # والاستبدال والإنهاء كما هما
    rep = post(client, "school_admin", f"/teaching-assignments/{more}/replace", {"staff_id": w["t2"], "effective_from": "2064-10-01", "reason": "swap"})
    assert rep.status_code == 201, rep.text
    both = load(client, "school_admin", w)
    assert (both[w["t1"]]["weekly_periods"], both[w["t2"]]["weekly_periods"]) == (11, 4)
    # الإجازة: التكليف قائم فيُحتسب، وحالة الموظف تُعرض (النصاب تخطيط لا أمان)
    assert post(client, "school_admin", f"/staff/{w['t2']}/status", {"status": "on_leave", "reason": "leave"}).status_code == 200
    row = load(client, "school_admin", w)[w["t2"]]
    assert (row["weekly_periods"], row["staff_status"]) == (4, "on_leave")
    assert post(client, "school_admin", f"/staff/{w['t2']}/status", {"status": "active", "reason": "back"}).status_code == 200


def test_limit_visibility_is_narrower_than_staff_read(client, w):
    """L5: المعلم (staff.read) يرى نصاب زملائه — المشتق من تكليفات يقرؤها أصلاً — ولا يرى حدودهم؛ يرى حدّه هو."""
    path = f"/academic-years/{w['year']}/teacher-load-limits/{SEED_TEACHER}"
    assert put(client, "teacher", path, {"max_weekly_periods": 30}).status_code == 403            # لا يضع حدّه
    assert put(client, "school_admin", path, {"max_weekly_periods": 18}).status_code == 200
    assert put(client, "teacher", path, {"max_weekly_periods": 30}).status_code == 403            # ولا يعدّل صفّه المرئي
    seen = load(client, "teacher", w)
    mine, colleague = seen[SEED_TEACHER], seen[w["t1"]]
    assert (mine["limit_visible"], mine["max_weekly_periods"], mine["over_limit"], mine["weekly_periods"]) == (True, 18, False, 0)
    assert (colleague["limit_visible"], colleague["max_weekly_periods"], colleague["over_limit"]) == (False, None, None)
    assert colleague["weekly_periods"] == 11                                         # النصاب المشتق مرئي بـstaff.read (3-3)
    assert put(client, "teacher", f"/academic-years/{w['year']}/teacher-load-limits/{w['t1']}", {"max_weekly_periods": 1}).status_code == 403
    assert load(client, "school_admin", w)[w["t1"]]["max_weekly_periods"] == 5       # لم يتغير
    # السكرتير: لا staff.read ولا staff.assign — لا تكليفات ولا حدود
    assert load(client, "secretary", w) == {}
    assert put(client, "secretary", f"/academic-years/{w['year']}/teacher-load-limits/{w['t1']}", {"max_weekly_periods": 1}).status_code == 404   # لا يرى الموظف
    # من لا يرى السنة
    assert get(client, "bus_supervisor", f"/academic-years/{w['year']}/teacher-load").status_code == 404                # بلا academic_year.read
    assert client.get(f"/academic-years/{w['year']}/teacher-load").status_code == 401
    # مدير الـTenant يرى ويكتب
    assert load(client, "tenant_admin", w)[w["t1"]]["max_weekly_periods"] == 5
    assert put(client, "school_admin", path, {"max_weekly_periods": None}).status_code == 200


def test_validation_reason_and_no_context_from_the_body(client, w, admin):
    base = f"/academic-years/{w['year']}/teacher-load-limits/{w['t1']}"
    for bad in ({"max_weekly_periods": 0}, {"max_weekly_periods": 101}, {}, {"max_weekly_periods": "many"},
                {"max_weekly_periods": 5, "school_id": w["sb"]}, {"max_weekly_periods": 5, "staff_id": w["t2"]},
                {"max_weekly_periods": 5, "academic_year_id": w["active_year"]}, {"max_weekly_periods": 5, "platform_tenant_id": str(uuid.uuid4())}):
        assert put(client, "school_admin", base, bad).status_code == 422, bad
    assert put(client, "school_admin", f"/academic-years/{w['year']}/teacher-load-limits/{uuid.uuid4()}", {"max_weekly_periods": 5}).status_code == 404
    assert put(client, "school_admin", f"/academic-years/{uuid.uuid4()}/teacher-load-limits/{w['t1']}", {"max_weekly_periods": 5}).status_code == 404
    assert get(client, "school_admin", f"/academic-years/{uuid.uuid4()}/teacher-load").status_code == 404
    assert client.delete(base, headers=auth("school_admin")).status_code == 405                  # لا حذف
    # السنة النشطة: السبب إلزامي (C3) — DB تقرر، ويصل إلى التدقيق
    active = f"/academic-years/{w['active_year']}/teacher-load-limits/{w['t1']}"
    no_reason = put(client, "school_admin", active, {"max_weekly_periods": 22})
    assert (no_reason.status_code, no_reason.json()["detail"]) == (422, "invalid_request")
    ok = put(client, "school_admin", active, {"max_weekly_periods": 22, "reason": "mid-year review"})
    assert ok.status_code == 200, ok.text
    assert put(client, "school_admin", active, {"max_weekly_periods": 23}).status_code == 422     # والتعديل كذلك
    changed = put(client, "school_admin", active, {"max_weekly_periods": 23, "reason": "corrected"})
    assert (changed.status_code, changed.json()["id"], changed.json()["max_weekly_periods"]) == (200, ok.json()["id"], 23)
    reasons = [r["reason"] for r in admin.execute(
        "select reason from public.audit_log where entity_type = 'teacher_load_limits' and entity_id = %s order by id", [ok.json()["id"]]).fetchall()]
    assert reasons == ["mid-year review", "corrected"]
    row = load(client, "school_admin", w, w["active_year"])[w["t1"]]
    assert (row["weekly_periods"], row["max_weekly_periods"], row["over_limit"]) == (0, 23, False)
