"""Phase 2B / 2B-3 — API الدوام والحصص (M43، M44؛ D1–D7) على seed التطوير (E5).

ما يُثبت: الجداول والحصص لكل يوم (D1)؛ رقم الحصة مشتق و`id` ثابت (D5)؛ منع التداخل من DB ← 409 والتلاصق مسموح (D6)؛
D4 من الجهتين؛ نسخ يوم داخل الجدول بلا دمج صامت؛ إسناد الصف (D2)؛ السنة النشطة بسبب (D3)؛ النسخ إلى سنة جديدة؛ 404/403؛
لا مدرسة ولا هوية من الجسم. كل ما يُنشأ يُحذف في نهاية الوحدة (اتصال postgres للاختبار فقط).
"""

import uuid

import pytest

from conftest import auth


@pytest.fixture(scope="module", autouse=True)
def _cleanup(admin, ids):
    yield
    years = (f"select id from public.academic_years where name like 'ZTB%' or school_id in "
             f"('{ids['school']['SA']}', '{ids['school']['SB']}')")
    for stmt in (
        f"delete from public.grade_level_bell_schedules where academic_year_id in ({years})",
        f"delete from public.bell_periods where academic_year_id in ({years})",
        f"delete from public.bell_schedules where academic_year_id in ({years})",
        f"delete from public.calendar_exceptions where academic_year_id in ({years})",
        f"delete from public.calendar_weekdays where academic_year_id in ({years})",
        "delete from public.academic_years where name like 'ZTB%'",
    ):
        admin.execute(stmt)


def post(client, who, path, body=None):
    return client.post(path, json=body or {}, headers=auth(who))


def put(client, who, path, body):
    return client.put(path, json=body, headers=auth(who))


def patch(client, who, path, body):
    return client.patch(path, json=body, headers=auth(who))


def get(client, who, path):
    return client.get(path, headers=auth(who))


def lesson(day, start, end, **kw):
    return {"weekday": day, "kind": "lesson", "start_time": start, "end_time": end, **kw}


@pytest.fixture(scope="module")
def sa(client, ids):
    """SA: سنتان planned بأيام دوام الأحد–الخميس، وجدول «صباحي» في الأولى."""
    sid = ids["school"]["SA"]
    years = []
    for name, start, end in (("ZTB 2070", "2070-09-01", "2071-06-30"), ("ZTB 2071", "2071-09-01", "2072-06-30")):
        y = post(client, "school_admin", f"/schools/{sid}/academic-years", {"name": name, "start_date": start, "end_date": end})
        assert y.status_code == 201, y.text
        years.append(y.json()["id"])
    assert put(client, "school_admin", f"/academic-years/{years[0]}/weekdays", {"weekdays": [0, 1, 2, 3, 4], "reason": "week"}).status_code == 200
    morning = post(client, "school_admin", f"/academic-years/{years[0]}/bell-schedules", {"name": "ZTB Morning"})
    assert morning.status_code == 201, morning.text
    grade = next(g for g in get(client, "school_admin", f"/schools/{sid}/grade-levels").json()["rows"] if g["status"] == "active")
    return {"id": sid, "y1": years[0], "y2": years[1], "morning": morning.json()["id"], "grade": grade["id"]}


def test_periods_per_day_derived_numbers_stable_id(client, sa):
    path = f"/bell-schedules/{sa['morning']}/periods"
    l1 = post(client, "school_admin", path, lesson(0, "08:00", "08:45"))
    brk = post(client, "school_admin", path, {"weekday": 0, "kind": "break", "name": "Recess", "start_time": "08:45", "end_time": "09:00"})
    l2 = post(client, "school_admin", path, lesson(0, "09:00", "09:45"))
    thu = post(client, "school_admin", path, lesson(4, "08:00", "08:40"))                       # D1: الخميس أقصر
    assert [r.status_code for r in (l1, brk, l2, thu)] == [201, 201, 201, 201], (l1.text, brk.text)
    assert (l2.json()["school_id"], l2.json()["academic_year_id"]) == (sa["id"], sa["y1"])         # من صف الجدول
    rows = get(client, "secretary", path).json()["rows"]
    assert [(r["weekday"], r["kind"], r["start_time"], r["lesson_no"]) for r in rows] == [
        (0, "lesson", "08:00:00", 1), (0, "break", "08:45:00", None), (0, "lesson", "09:00:00", 2), (4, "lesson", "08:00:00", 1)]
    moved = patch(client, "school_admin", f"/bell-periods/{l2.json()['id']}", {"end_time": "09:50"})
    assert moved.status_code == 200 and moved.json()["id"] == l2.json()["id"]                     # D5: id ثابت عند التعديل
    assert post(client, "school_admin", path, {"weekday": 0, "kind": "break", "start_time": "07:00", "end_time": "07:15"}).status_code == 422   # الاستراحة باسم


def test_overlap_is_refused_by_the_database(client, sa, admin):
    path = f"/bell-schedules/{sa['morning']}/periods"
    over = post(client, "school_admin", path, lesson(0, "09:30", "10:30"))
    assert (over.status_code, over.json()["detail"]) == (409, "conflict")                         # D6: 23P01
    assert post(client, "school_admin", path, lesson(0, "09:50", "10:30")).status_code == 201       # D6: التلاصق مسموح
    evening = post(client, "school_admin", f"/academic-years/{sa['y1']}/bell-schedules", {"name": "ZTB Evening"})
    assert post(client, "school_admin", f"/bell-schedules/{evening.json()['id']}/periods", lesson(0, "09:30", "10:30")).status_code == 201   # فترة أخرى
    assert post(client, "school_admin", path, lesson(1, "10:00", "09:00")).status_code == 422       # البداية قبل النهاية
    # المسار المباشر (postgres) يُرفض أيضاً — القيد في DB لا في الـAPI
    with pytest.raises(Exception, match="bell_periods_no_overlap"):
        with admin.transaction():
            admin.execute("insert into public.bell_periods (school_id, academic_year_id, bell_schedule_id, weekday, kind, start_time, end_time)"
                          " select school_id, academic_year_id, id, 0, 'lesson', '08:30', '09:10' from public.bell_schedules where id = %s", [sa["morning"]])


def test_d4_both_directions(client, sa):
    friday = post(client, "school_admin", f"/bell-schedules/{sa['morning']}/periods", lesson(5, "08:00", "08:45"))
    assert (friday.status_code, friday.json()["detail"]) == (422, "invariant_violation")
    drop_sunday = put(client, "school_admin", f"/academic-years/{sa['y1']}/weekdays", {"weekdays": [1, 2, 3, 4], "reason": "r"})
    assert (drop_sunday.status_code, drop_sunday.json()["detail"]) == (422, "invariant_violation")


def test_copy_day_and_grade_assignment(client, sa):
    path = f"/bell-schedules/{sa['morning']}/copy-day"
    copied = post(client, "school_admin", path, {"from_weekday": 0, "to_weekdays": [1, 2], "reason": "same as sunday"})
    assert copied.status_code == 200 and copied.json() == {"created": 8}                           # 4 فترات × يومان
    busy = post(client, "school_admin", path, {"from_weekday": 0, "to_weekdays": [1, 3], "reason": "r"})
    assert (busy.status_code, busy.json()["detail"]) == (422, "invariant_violation")               # لا دمج صامت
    assert post(client, "school_admin", path, {"from_weekday": 0, "to_weekdays": [3]}).status_code == 422   # بلا سبب
    first = put(client, "school_admin", f"/academic-years/{sa['y1']}/grade-bell-schedules/{sa['grade']}", {"bell_schedule_id": sa["morning"]})
    assert first.status_code == 200 and first.json()["bell_schedule_id"] == sa["morning"]
    evening = next(s for s in get(client, "school_admin", f"/academic-years/{sa['y1']}/bell-schedules").json()["rows"] if s["name"] == "ZTB Evening")
    again = put(client, "school_admin", f"/academic-years/{sa['y1']}/grade-bell-schedules/{sa['grade']}", {"bell_schedule_id": evening["id"]})
    assert again.status_code == 200 and again.json()["id"] == first.json()["id"]                  # D2: تغيير الإسناد نفسه
    assert [r["grade_level_id"] for r in get(client, "secretary", f"/academic-years/{sa['y1']}/grade-bell-schedules").json()["rows"]] == [sa["grade"]]
    off = patch(client, "school_admin", f"/bell-schedules/{evening['id']}", {"status": "inactive"})
    assert (off.status_code, off.json()["detail"]) == (422, "invariant_violation")                 # له حصص ومُسنَد


def test_copy_to_a_new_year(client, sa, admin):
    weeks = post(client, "school_admin", f"/academic-years/{sa['y2']}/copy-weekdays", {"source_year_id": sa["y1"], "reason": "week"})
    assert weeks.json() == {"created": 5}
    copied = post(client, "school_admin", f"/academic-years/{sa['y2']}/copy-bell-schedules", {"source_year_id": sa["y1"], "reason": "next year"})
    assert copied.status_code == 200, copied.text
    assert copied.json()["created"] > 0
    assert post(client, "school_admin", f"/academic-years/{sa['y2']}/copy-bell-schedules", {"source_year_id": sa["y1"], "reason": "again"}).json() == {"created": 0}
    assert post(client, "school_admin", f"/academic-years/{sa['y2']}/copy-bell-schedules", {"source_year_id": sa["y1"]}).status_code == 422
    names = sorted(s["name"] for s in get(client, "school_admin", f"/academic-years/{sa['y2']}/bell-schedules").json()["rows"])
    assert names == ["ZTB Evening", "ZTB Morning"]
    audit = admin.execute("select new_values from public.audit_log where action = 'copy_bell_schedules' and entity_id = %s and reason = 'next year'", [sa["y2"]]).fetchone()
    assert audit["new_values"]["schedules"] == 2 and audit["new_values"]["assignments"] == 1


def test_active_year_needs_a_reason(client, ids):
    sid = ids["school"]["SA"]
    year = next(y for y in get(client, "tenant_admin", f"/schools/{sid}/academic-years").json()["rows"] if y["status"] == "active")["id"]
    put(client, "school_admin", f"/academic-years/{year}/weekdays", {"weekdays": [0, 1, 2, 3, 4], "reason": "school week"})   # C2 (قد تكون معرَّفة)
    no_reason = post(client, "school_admin", f"/academic-years/{year}/bell-schedules", {"name": "ZTB Active"})
    assert (no_reason.status_code, no_reason.json()["detail"]) == (422, "invalid_request")          # D3: 22023 من الحارس
    made = post(client, "school_admin", f"/academic-years/{year}/bell-schedules", {"name": "ZTB Active", "reason": "winter timing"})
    assert made.status_code == 201, made.text
    assert post(client, "school_admin", f"/bell-schedules/{made.json()['id']}/periods", lesson(0, "08:00", "08:45")).status_code == 422
    assert post(client, "school_admin", f"/bell-schedules/{made.json()['id']}/periods", lesson(0, "08:00", "08:45", reason="first lesson")).status_code == 201


def test_isolation_read_is_not_write_and_no_identity_from_the_body(client, sa, ids):
    sb = ids["school"]["SB"]
    sb_year = next(y for y in get(client, "tenant_admin", f"/schools/{sb}/academic-years").json()["rows"] if y["status"] == "active")["id"]
    assert get(client, "school_admin", f"/academic-years/{sb_year}/bell-schedules").status_code == 404
    assert post(client, "school_admin", f"/academic-years/{sb_year}/bell-schedules", {"name": "x", "reason": "r"}).status_code == 404
    assert post(client, "school_admin", f"/academic-years/{sb_year}/copy-bell-schedules", {"source_year_id": sa["y1"], "reason": "r"}).status_code == 404
    assert put(client, "school_admin", f"/academic-years/{sb_year}/grade-bell-schedules/{sa['grade']}", {"bell_schedule_id": sa["morning"]}).status_code == 404
    sb_sched = post(client, "tenant_admin", f"/academic-years/{sb_year}/bell-schedules", {"name": "ZTB SB", "reason": "r"})
    assert sb_sched.status_code == 201, sb_sched.text
    for call in (lambda: get(client, "school_admin", f"/bell-schedules/{sb_sched.json()['id']}/periods"),
                 lambda: post(client, "school_admin", f"/bell-schedules/{sb_sched.json()['id']}/periods", lesson(0, "08:00", "08:45", reason="r")),
                 lambda: patch(client, "school_admin", f"/bell-schedules/{sb_sched.json()['id']}", {"name": "hijack", "reason": "r"})):
        assert call().status_code == 404
    period = get(client, "school_admin", f"/bell-schedules/{sa['morning']}/periods").json()["rows"][0]
    assert post(client, "secretary", f"/academic-years/{sa['y1']}/bell-schedules", {"name": "x"}).status_code == 403
    assert patch(client, "secretary", f"/bell-periods/{period['id']}", {"end_time": "08:50"}).status_code == 403
    assert post(client, "secretary", f"/bell-schedules/{sa['morning']}/copy-day", {"from_weekday": 0, "to_weekdays": [3], "reason": "r"}).status_code == 403
    assert get(client, "bus_supervisor", f"/academic-years/{sa['y1']}/bell-schedules").status_code == 404
    assert post(client, "school_admin", f"/bell-schedules/{sa['morning']}/periods", {**lesson(3, "08:00", "08:45"), "school_id": sb}).status_code == 422
    assert patch(client, "school_admin", f"/bell-periods/{period['id']}", {"bell_schedule_id": str(uuid.uuid4())}).status_code == 422
    assert patch(client, "school_admin", f"/bell-schedules/{sa['morning']}", {"academic_year_id": sa["y2"]}).status_code == 422
    assert patch(client, "school_admin", f"/bell-periods/{uuid.uuid4()}", {"end_time": "08:50"}).status_code == 404
    assert client.delete(f"/bell-periods/{period['id']}", headers=auth("school_admin")).status_code == 405
