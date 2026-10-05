"""Phase 2B / 2B-2 — API التقويم (M41، M42؛ C1–C5) على seed التطوير (E5).

ما يُثبت: أيام الدوام بعملية مجموعة واحدة (C2: التعريف الأول لسنة نشطة ثم التجميد)؛ الاستثناءات بـCRUD والسبب يصل من الجسم
إلى DB والتدقيق في المعاملة نفسها (C3) — وغيابه في سنة نشطة يرفضه DB لا الـAPI؛ «اليوم» بتوقيت المدرسة (C1)؛ 404/403؛
لا مدرسة من الجسم؛ النسخ. كل ما يُنشأ يُحذف في نهاية الوحدة (اتصال postgres للاختبار فقط).
"""

import datetime
import uuid
from zoneinfo import ZoneInfo

import pytest

from conftest import auth

TODAY = datetime.datetime.now(ZoneInfo("Africa/Cairo")).date()       # مدارس الـseed بتوقيت القاهرة


def day(offset: int) -> str:
    return (TODAY + datetime.timedelta(days=offset)).isoformat()


@pytest.fixture(scope="module", autouse=True)
def _cleanup(admin, ids):
    yield
    seed = f"select id from public.schools where id in ('{ids['school']['SA']}', '{ids['school']['SB']}')"
    years = f"select id from public.academic_years where name like 'ZTC%' or school_id in ({seed})"
    for stmt in (
        f"delete from public.calendar_exceptions where academic_year_id in ({years})",
        f"delete from public.calendar_weekdays where academic_year_id in ({years})",
        "delete from public.academic_years where name like 'ZTC%'",
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


def active_year(client, school_id):
    return next(y for y in get(client, "tenant_admin", f"/schools/{school_id}/academic-years").json()["rows"] if y["status"] == "active")["id"]


@pytest.fixture(scope="module")
def sa(client, ids):
    sid = ids["school"]["SA"]
    planned = post(client, "school_admin", f"/schools/{sid}/academic-years", {"name": "ZTC 2060", "start_date": "2060-09-01", "end_date": "2061-06-30"})
    assert planned.status_code == 201, planned.text
    return {"id": sid, "active": active_year(client, sid), "planned": planned.json()["id"]}


def test_weekdays_first_definition_then_fixed(client, sa, admin):
    """C2: سنة الـseed النشطة بلا أيام دوام — تُعرَّف مرة واحدة بسبب ثم تُجمَّد؛ القرار في DB."""
    path = f"/academic-years/{sa['active']}/weekdays"
    since = admin.execute("select coalesce(max(id), 0) as n from public.audit_log").fetchone()["n"]   # التدقيق لا يُحذف: صفوف هذا التشغيل فقط
    assert get(client, "school_admin", path).json() == {"rows": []}
    assert put(client, "secretary", path, {"weekdays": [0, 1, 2, 3, 4], "reason": "r"}).status_code == 403
    assert put(client, "school_admin", path, {"weekdays": [0, 1, 2, 3, 4]}).status_code == 422          # السبب إلزامي
    first = put(client, "school_admin", path, {"weekdays": [0, 1, 2, 3, 4], "reason": "school week"})
    assert first.status_code == 200, first.text
    assert first.json()["changed"] == 5 and [(r["weekday"], r["status"]) for r in first.json()["rows"]] == [(d, "active") for d in range(5)]
    again = put(client, "school_admin", path, {"weekdays": [0, 1], "reason": "r"})
    assert (again.status_code, again.json()["detail"]) == (422, "invalid_request")                     # مجمَّدة بعد التعريف
    assert [r["weekday"] for r in get(client, "secretary", path).json()["rows"]] == [0, 1, 2, 3, 4]
    audit = admin.execute("select reason, new_values ->> 'changed' as n from public.audit_log where action = 'set_calendar_weekdays' and entity_id = %s and id > %s",
                          [sa["active"], since]).fetchall()
    assert [(a["reason"], a["n"]) for a in audit] == [("school week", "5")]


def test_weekdays_planned_and_copy(client, sa):
    path = f"/academic-years/{sa['planned']}/weekdays"
    assert put(client, "school_admin", path, {"weekdays": [7], "reason": "r"}).status_code == 422
    assert put(client, "school_admin", path, {"weekdays": [0, 1], "reason": "start"}).json()["changed"] == 2
    assert post(client, "school_admin", f"/academic-years/{sa['planned']}/copy-weekdays", {"source_year_id": sa["active"]}).status_code == 422   # بلا سبب
    copied = post(client, "school_admin", f"/academic-years/{sa['planned']}/copy-weekdays", {"source_year_id": sa["active"], "reason": "next year"})
    assert copied.status_code == 200 and copied.json() == {"created": 3}                               # 0 و 1 «منسوخان سابقاً»
    assert post(client, "school_admin", f"/academic-years/{sa['planned']}/copy-weekdays", {"source_year_id": sa["active"], "reason": "again"}).json() == {"created": 0}
    into_active = post(client, "school_admin", f"/academic-years/{sa['active']}/copy-weekdays", {"source_year_id": sa["planned"], "reason": "r"})
    assert (into_active.status_code, into_active.json()["detail"]) == (422, "invalid_request")


def test_active_year_exceptions_follow_b8(client, sa, admin):
    """C1/C3/C4 من الـAPI: السبب من الجسم يصل إلى DB والتدقيق؛ غيابه أو الماضي يرفضه DB."""
    base = f"/academic-years/{sa['active']}/calendar-exceptions"
    no_reason = post(client, "school_admin", base, {"kind": "holiday", "name": "ZTC trip", "start_date": day(5), "end_date": day(6)})
    assert (no_reason.status_code, no_reason.json()["detail"]) == (422, "invalid_request")            # 22023 من الحارس، لا من الـAPI
    past = post(client, "school_admin", base, {"kind": "holiday", "name": "ZTC past", "start_date": day(-1), "end_date": day(-1), "reason": "r"})
    assert (past.status_code, past.json()["detail"]) == (422, "invariant_violation")
    made = post(client, "school_admin", base, {"kind": "holiday", "name": "ZTC trip", "start_date": day(5), "end_date": day(6), "reason": "school trip"})
    assert made.status_code == 201, made.text
    row = made.json()
    assert (row["school_id"], row["academic_year_id"], row["status"]) == (sa["id"], sa["active"], "active")   # المدرسة من صف السنة
    exc = row["id"]
    assert patch(client, "school_admin", f"/calendar-exceptions/{exc}", {"end_date": day(7)}).status_code == 422          # بلا سبب
    moved = patch(client, "school_admin", f"/calendar-exceptions/{exc}", {"end_date": day(7), "reason": "one more day"})
    assert moved.status_code == 200 and moved.json()["end_date"] == day(7)
    into_past = patch(client, "school_admin", f"/calendar-exceptions/{exc}", {"start_date": day(-2), "reason": "r"})
    assert (into_past.status_code, into_past.json()["detail"]) == (422, "invariant_violation")
    cancelled = post(client, "school_admin", f"/calendar-exceptions/{exc}/cancel", {"reason": "trip cancelled"})
    assert cancelled.status_code == 200 and cancelled.json()["status"] == "cancelled"
    assert post(client, "school_admin", f"/calendar-exceptions/{exc}/cancel", {"reason": "again"}).status_code == 422     # نهائي
    today = post(client, "school_admin", base, {"kind": "holiday", "name": "ZTC storm", "start_date": day(0), "end_date": day(0), "reason": "storm closure"})
    assert today.status_code == 201, today.text                                                       # C1: اليوم نفسه
    audit = admin.execute("select action, reason from public.audit_log where entity_type = 'calendar_exceptions' and entity_id = %s order by id", [exc]).fetchall()
    assert [(a["action"], a["reason"]) for a in audit] == [("insert", "school trip"), ("update", "one more day"), ("update", "trip cancelled")]


def test_study_day_rule_c5(client, sa):
    base = f"/academic-years/{sa['active']}/calendar-exceptions"
    sunday = TODAY + datetime.timedelta(days=(6 - TODAY.weekday()) % 7 + 14)        # Python: الاثنين 0 … الأحد 6
    friday = sunday + datetime.timedelta(days=5)
    on_school_day = post(client, "school_admin", base, {"kind": "study_day", "name": "ZTC x", "start_date": sunday.isoformat(), "end_date": sunday.isoformat(), "reason": "r"})
    assert (on_school_day.status_code, on_school_day.json()["detail"]) == (422, "invariant_violation")
    on_rest_day = post(client, "school_admin", base, {"kind": "study_day", "name": "ZTC makeup", "start_date": friday.isoformat(), "end_date": friday.isoformat(), "reason": "makeup"})
    assert on_rest_day.status_code == 201, on_rest_day.text


def test_planned_year_needs_no_reason(client, sa):
    made = post(client, "school_admin", f"/academic-years/{sa['planned']}/calendar-exceptions",
                {"kind": "holiday", "name": "ZTC eid", "start_date": "2061-03-01", "end_date": "2061-03-03"})
    assert made.status_code == 201 and made.json()["status"] == "active"
    overlap = post(client, "school_admin", f"/academic-years/{sa['planned']}/calendar-exceptions",
                   {"kind": "holiday", "name": "ZTC eid 2", "start_date": "2061-03-02", "end_date": "2061-03-05"})
    assert (overlap.status_code, overlap.json()["detail"]) == (409, "conflict")                       # EXCLUDE
    outside = post(client, "school_admin", f"/academic-years/{sa['planned']}/calendar-exceptions",
                   {"kind": "holiday", "name": "ZTC out", "start_date": "2061-07-01", "end_date": "2061-07-02"})
    assert outside.status_code == 422


def test_read_is_not_write_and_school_isolation(client, sa, ids):
    sb = ids["school"]["SB"]
    sb_year = active_year(client, sb)
    sb_exc = post(client, "tenant_admin", f"/academic-years/{sb_year}/calendar-exceptions",
                  {"kind": "holiday", "name": "ZTC sb", "start_date": day(20), "end_date": day(20), "reason": "r"})
    assert sb_exc.status_code == 201, sb_exc.text
    # school_admin SA: مدرسة أخرى = غير موجودة
    for path in (f"/academic-years/{sb_year}/weekdays", f"/academic-years/{sb_year}/calendar-exceptions"):
        assert get(client, "school_admin", path).status_code == 404
    assert put(client, "school_admin", f"/academic-years/{sb_year}/weekdays", {"weekdays": [0], "reason": "r"}).status_code == 404
    assert post(client, "school_admin", f"/academic-years/{sb_year}/calendar-exceptions",
                {"kind": "holiday", "name": "x", "start_date": day(21), "end_date": day(21), "reason": "r"}).status_code == 404
    assert patch(client, "school_admin", f"/calendar-exceptions/{sb_exc.json()['id']}", {"name": "hijack", "reason": "r"}).status_code == 404
    assert post(client, "school_admin", f"/calendar-exceptions/{sb_exc.json()['id']}/cancel", {"reason": "r"}).status_code == 404
    assert post(client, "school_admin", f"/academic-years/{sb_year}/copy-weekdays", {"source_year_id": sa["active"], "reason": "r"}).status_code == 404
    # secretary: يقرأ (academic_year.read) ولا يكتب — مرئي ومرفوض ← 403
    exc = get(client, "secretary", f"/academic-years/{sa['active']}/calendar-exceptions").json()["rows"]
    assert exc
    assert post(client, "secretary", f"/academic-years/{sa['active']}/calendar-exceptions",
                {"kind": "holiday", "name": "x", "start_date": day(22), "end_date": day(22), "reason": "r"}).status_code == 403
    assert patch(client, "secretary", f"/calendar-exceptions/{exc[0]['id']}", {"name": "hijack", "reason": "r"}).status_code == 403
    assert post(client, "secretary", f"/calendar-exceptions/{exc[0]['id']}/cancel", {"reason": "r"}).status_code == 403
    # bus_supervisor: بلا academic_year.read — السنة نفسها غير مرئية
    assert get(client, "bus_supervisor", f"/academic-years/{sa['active']}/calendar-exceptions").status_code == 404


def test_no_school_status_or_kind_from_the_body(client, sa, ids):
    base = f"/academic-years/{sa['planned']}/calendar-exceptions"
    assert post(client, "school_admin", base, {"kind": "holiday", "name": "x", "start_date": "2061-04-01", "end_date": "2061-04-01",
                                               "school_id": ids["school"]["SB"]}).status_code == 422
    assert post(client, "school_admin", base, {"kind": "holiday", "name": "x", "start_date": "2061-04-01", "end_date": "2061-04-01",
                                               "status": "cancelled"}).status_code == 422
    assert post(client, "school_admin", base, {"kind": "vacation", "name": "x", "start_date": "2061-04-01", "end_date": "2061-04-01"}).status_code == 422
    exc = get(client, "school_admin", base).json()["rows"][0]
    assert patch(client, "school_admin", f"/calendar-exceptions/{exc['id']}", {"kind": "study_day"}).status_code == 422
    assert patch(client, "school_admin", f"/calendar-exceptions/{exc['id']}", {"status": "cancelled"}).status_code == 422
    assert patch(client, "school_admin", f"/calendar-exceptions/{uuid.uuid4()}", {"name": "x"}).status_code == 404
    assert client.delete(f"/calendar-exceptions/{exc['id']}", headers=auth("school_admin")).status_code == 405
