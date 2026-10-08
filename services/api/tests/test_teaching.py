"""Phase 3A / 3-3 — تكليفات التدريس ومربي الفصل ودورة الحياة (M48، M49) على seed التطوير (E5).

ما يُثبت عبر المسار الوحيد (JWT → معاملة authenticated → RLS/T17/الدوال): الإنشاء والإنهاء والاستبدال الذري؛ «نشط واحد»
ومنه **تزامن حقيقي** (معاملة مفتوحة تحجز الخانة وطلب ثانٍ ينتظر على الفهرس ثم 409)؛ الحراس؛ 404/403؛ لا سياق من الجسم؛
P10 عبر الـAPI (إنهاء تكليف المدرسة يُنهي تكليفاتها ويسحب نطاقها وحده، والجلسة تفقدها فوراً).
كل ما يُنشأ يحمل الرمز ZTT ويُحذف في نهاية الوحدة.
"""

import threading
import time
import uuid

import pytest

from conftest import auth, origin

ZTT = "select id from public.staff where employee_code like 'ZTT%'"


@pytest.fixture(scope="module", autouse=True)
def _cleanup(admin):
    yield
    ids = [r["id"] for r in admin.execute(ZTT).fetchall()]
    pids = [r["profile_id"] for r in admin.execute("select profile_id from public.staff where employee_code like 'ZTT%' and profile_id is not null").fetchall()]
    years = "select id from public.academic_years where name like 'ZTT%'"
    subjects = "select id from public.subjects where subject_code like 'ZTT%'"
    for stmt in (
        "alter table public.teaching_assignments disable trigger guard",
        "alter table public.class_teacher_assignments disable trigger guard",
        f"delete from public.teaching_assignments where staff_id in ({ZTT}) or subject_id in ({subjects}) or academic_year_id in ({years})",
        f"delete from public.class_teacher_assignments where staff_id in ({ZTT}) or academic_year_id in ({years})",
        "alter table public.teaching_assignments enable trigger guard",
        "alter table public.class_teacher_assignments enable trigger guard",
        f"delete from public.grade_subjects where subject_id in ({subjects})",
        f"delete from public.subjects where subject_code like 'ZTT%'",
        f"delete from public.sections where academic_year_id in ({years}) or name like 'ZTT%'",
        "delete from public.academic_years where name like 'ZTT%'",
        "delete from public.membership_roles where membership_id in (select id from public.memberships where profile_id = any(%(p)s))",
        "delete from public.membership_scopes where membership_id in (select id from public.memberships where profile_id = any(%(p)s))",
        "delete from public.memberships where profile_id = any(%(p)s)",
        f"delete from public.staff_school_assignments where staff_id in ({ZTT})",
        "delete from public.staff where employee_code like 'ZTT%'",
        "delete from public.profiles where id = any(%(p)s)",
        "delete from public.login_challenges where account_id = any(%(i)s)",
        "delete from public.auth_identities where auth_user_id = any(%(i)s)",
        "delete from auth.users where id = any(%(i)s)",
    ):
        admin.execute(stmt, {"p": pids, "i": ids}) if "%(" in stmt else admin.execute(stmt)


def post(client, who, path, body=None):
    return client.post(path, json=body or {}, headers=auth(who))


def get(client, who, path):
    return client.get(path, headers=auth(who))


def make_staff(client, who, school, code, email=False):
    body = {"employee_code": code, "first_name": "Zt", "family_name": code, "job_title": "Teacher", "effective_from": "2026-09-01"}
    if email:
        body["email"] = f"{code.lower()}@example.test"
    r = post(client, who, f"/schools/{school}/staff", body)
    assert r.status_code == 201, r.text
    return r.json()["id"]


@pytest.fixture(scope="module")
def w(client, ids):
    """SA: سنة planned جديدة بشعبتين ومادتين مربوطتين بصف نشط، ومعلمان."""
    sa = ids["school"]["SA"]
    grade = next(g for g in get(client, "school_admin", f"/schools/{sa}/grade-levels").json()["rows"] if g["status"] == "active")["id"]
    year = post(client, "school_admin", f"/schools/{sa}/academic-years", {"name": "ZTT 2060", "start_date": "2060-09-01", "end_date": "2061-06-30"}).json()["id"]
    sec = [post(client, "school_admin", f"/academic-years/{year}/sections", {"grade_level_id": grade, "name": n}).json()["id"] for n in ("ZTT-A", "ZTT-B")]
    subj = {}
    for code in ("ZTT-AR", "ZTT-MA", "ZTT-UN"):
        subj[code] = post(client, "school_admin", f"/schools/{sa}/subjects", {"subject_code": code, "name": code}).json()["id"]
    for code, periods in (("ZTT-AR", 5), ("ZTT-MA", 4)):
        r = post(client, "school_admin", f"/academic-years/{year}/grade-subjects", {"grade_level_id": grade, "subject_id": subj[code], "weekly_periods": periods})
        assert r.status_code == 201, r.text
    return {"sa": sa, "sb": ids["school"]["SB"], "grade": grade, "year": year, "sec": sec, "subj": subj,
            "t1": make_staff(client, "school_admin", sa, "ZTT-1"), "t2": make_staff(client, "school_admin", sa, "ZTT-2")}


def rows(client, who, w, kind="teaching-assignments", **q):
    r = client.get(f"/academic-years/{w['year']}/{kind}", params=q, headers=auth(who))
    assert r.status_code == 200, r.text
    return r.json()["rows"]


def test_assign_replace_end(client, w, admin):
    s1, ar, ma = w["sec"][0], w["subj"]["ZTT-AR"], w["subj"]["ZTT-MA"]
    a = post(client, "school_admin", f"/sections/{s1}/teaching-assignments", {"subject_id": ar, "staff_id": w["t1"], "effective_from": "2060-09-01"})
    assert a.status_code == 201, a.text
    assert {k: a.json()[k] for k in ("school_id", "academic_year_id", "section_id", "subject_id", "staff_id", "status")} == \
        {"school_id": w["sa"], "academic_year_id": w["year"], "section_id": s1, "subject_id": ar, "staff_id": w["t1"], "status": "active"}
    # نشط واحد (T3): معلم ثانٍ للمادة نفسها في الشعبة نفسها
    dup = post(client, "school_admin", f"/sections/{s1}/teaching-assignments", {"subject_id": ar, "staff_id": w["t2"], "effective_from": "2060-09-01"})
    assert (dup.status_code, dup.json()["detail"]) == (409, "conflict")
    # المعلم نفسه لمادة أخرى ولشعبة أخرى
    assert post(client, "school_admin", f"/sections/{s1}/teaching-assignments", {"subject_id": ma, "staff_id": w["t1"], "effective_from": "2060-09-01"}).status_code == 201
    assert post(client, "school_admin", f"/sections/{w['sec'][1]}/teaching-assignments", {"subject_id": ar, "staff_id": w["t1"], "effective_from": "2060-09-01"}).status_code == 201
    listed = rows(client, "school_admin", w, section_id=s1, status="active")
    assert [(r["subject_code"], r["staff_name"], r["operational"]) for r in listed] == [("ZTT-AR", "Zt ZTT-1", True), ("ZTT-MA", "Zt ZTT-1", True)]
    assert len(rows(client, "school_admin", w, staff_id=w["t1"])) == 3
    assert rows(client, "school_admin", w, staff_id=w["t2"]) == []                       # التصفية بالموظف فعلية
    # الاستبدال: القديم ينتهي يوم بداية الجديد، والجديد نشط — في معاملة واحدة
    rep = post(client, "school_admin", f"/teaching-assignments/{a.json()['id']}/replace", {"staff_id": w["t2"], "effective_from": "2060-11-01", "reason": "transfer"})
    assert (rep.status_code, rep.json()["staff_id"], rep.json()["subject_id"], rep.json()["section_id"]) == (201, w["t2"], ar, s1)
    history = {r["staff_id"]: (r["status"], r["effective_to"]) for r in rows(client, "school_admin", w, section_id=s1) if r["subject_code"] == "ZTT-AR"}
    assert history == {w["t1"]: ("ended", "2060-11-01"), w["t2"]: ("active", None)}
    # الإنهاء بسبب
    path = f"/teaching-assignments/{rep.json()['id']}/end"
    assert post(client, "school_admin", path, {"effective_to": "2061-01-01"}).status_code == 422
    assert post(client, "school_admin", path, {"effective_to": "2060-10-01", "reason": "r"}).status_code == 422       # قبل البداية
    ended = post(client, "school_admin", path, {"effective_to": "2061-01-01", "reason": "left"})
    assert (ended.status_code, ended.json()["status"], ended.json()["effective_to"]) == (200, "ended", "2061-01-01")
    # السبب يصل إلى التدقيق كما أرسله المستخدم
    assert admin.execute("select reason from public.audit_log where entity_type = 'teaching_assignments' and entity_id = %s and action = 'end'",
                         [rep.json()["id"]]).fetchone()["reason"] == "left"
    only_t2 = rows(client, "school_admin", w, staff_id=w["t2"])
    assert only_t2 and {r["staff_id"] for r in only_t2} == {w["t2"]}
    assert post(client, "school_admin", path, {"effective_to": "2061-02-01", "reason": "again"}).status_code == 422
    assert post(client, "school_admin", f"/teaching-assignments/{uuid.uuid4()}/end", {"effective_to": "2061-01-01", "reason": "r"}).status_code == 404


def test_class_teacher(client, w):
    s1, s2 = w["sec"]
    # مربٍّ لا يدرّس الشعبة، ولأكثر من شعبة (P7)
    c1 = post(client, "school_admin", f"/sections/{s1}/class-teacher", {"staff_id": w["t2"], "effective_from": "2060-09-01"})
    c2 = post(client, "school_admin", f"/sections/{s2}/class-teacher", {"staff_id": w["t2"], "effective_from": "2060-09-01"})
    assert (c1.status_code, c2.status_code) == (201, 201), (c1.text, c2.text)
    assert post(client, "school_admin", f"/sections/{s1}/class-teacher", {"staff_id": w["t1"], "effective_from": "2060-09-01"}).status_code == 409
    rep = post(client, "school_admin", f"/class-teacher-assignments/{c1.json()['id']}/replace", {"staff_id": w["t1"], "effective_from": "2060-10-01", "reason": "swap"})
    assert (rep.status_code, rep.json()["staff_id"]) == (201, w["t1"])
    active = {r["section_id"]: r["staff_id"] for r in rows(client, "school_admin", w, "class-teachers", status="active")}
    assert active == {s1: w["t1"], s2: w["t2"]}
    assert post(client, "school_admin", f"/class-teacher-assignments/{rep.json()['id']}/end", {"effective_to": "2060-12-01", "reason": "x"}).json()["status"] == "ended"


def test_guards_reach_the_client_as_refusals(client, w, admin):
    s2, ma, un = w["sec"][1], w["subj"]["ZTT-MA"], w["subj"]["ZTT-UN"]
    base = f"/sections/{s2}/teaching-assignments"
    # مادة غير مربوطة بصف الشعبة: الـFK يرفض
    r = post(client, "school_admin", base, {"subject_id": un, "staff_id": w["t1"], "effective_from": "2060-09-01"})
    assert (r.status_code, r.json()["detail"]) == (422, "invalid_reference")
    # موظف في إجازة: لا تكليف جديد (Q4)؛ والعودة تسمح
    leave = make_staff(client, "school_admin", w["sa"], "ZTT-L")
    assert post(client, "school_admin", f"/staff/{leave}/status", {"status": "on_leave", "reason": "leave"}).status_code == 200
    r = post(client, "school_admin", base, {"subject_id": ma, "staff_id": leave, "effective_from": "2060-09-01"})
    assert (r.status_code, r.json()["detail"]) == (422, "invariant_violation")
    assert post(client, "school_admin", f"/sections/{s2}/class-teacher", {"staff_id": leave, "effective_from": "2061-01-01"}).json()["detail"] == "invariant_violation"
    # موظف مدرسة أخرى: لا تكليف مدرسة نشط في SA
    sb_staff = make_staff(client, "tenant_admin", w["sb"], "ZTT-B")
    r = post(client, "tenant_admin", base, {"subject_id": ma, "staff_id": sb_staff, "effective_from": "2060-09-01"})
    assert (r.status_code, r.json()["detail"]) == (422, "invariant_violation")
    # ربط المادة معطَّل
    link = next(g for g in get(client, "school_admin", f"/academic-years/{w['year']}/grade-subjects").json()["rows"] if g["subject_id"] == ma)
    assert client.patch(f"/grade-subjects/{link['id']}", json={"status": "inactive"}, headers=auth("school_admin")).status_code == 200
    assert post(client, "school_admin", base, {"subject_id": ma, "staff_id": w["t2"], "effective_from": "2060-09-01"}).json()["detail"] == "invariant_violation"
    # T8: لا حارس عكسي — التكليف القائم على الربط المعطَّل يبقى ويظهر «معلَّقاً» (operational = false)
    suspended = [r for r in rows(client, "school_admin", w, status="active") if r["subject_code"] == "ZTT-MA"]
    assert suspended and all(r["operational"] is False for r in suspended)
    assert client.patch(f"/grade-subjects/{link['id']}", json={"status": "active"}, headers=auth("school_admin")).status_code == 200
    assert all(r["operational"] for r in rows(client, "school_admin", w, status="active") if r["subject_code"] == "ZTT-MA")
    assert admin.execute("select count(*) n from public.teaching_assignments where staff_id = any(%s)", [[leave, sb_staff]]).fetchone()["n"] == 0
    # Q4: الموظف المكلَّف يصير on_leave — تكليفاته تبقى وتظهر «معلَّقة»، وتعود عند عودته
    mine = lambda: [r["operational"] for r in rows(client, "school_admin", w, staff_id=w["t1"], status="active")]
    assert mine() and all(mine())
    assert post(client, "school_admin", f"/staff/{w['t1']}/status", {"status": "on_leave", "reason": "leave"}).status_code == 200
    assert mine() and not any(mine())
    assert post(client, "school_admin", f"/staff/{w['t1']}/status", {"status": "active", "reason": "back"}).status_code == 200
    assert all(mine())


def test_one_active_under_real_concurrency(client, w, admin):
    """T3: الفهرس الفريد الجزئي هو سلطة التزامن. معاملة مفتوحة تحجز (شعبة، مادة)، وطلب API ثانٍ **ينتظر** على الفهرس؛
    عند التزام الأولى يفشل الثاني بـ23505 ← 409 — وصف نشط واحد في DB."""
    s2, ma = w["sec"][1], w["subj"]["ZTT-MA"]
    result = {}

    def second():
        result["r"] = post(client, "school_admin", f"/sections/{s2}/teaching-assignments", {"subject_id": ma, "staff_id": w["t2"], "effective_from": "2060-09-01"})

    token = auth("school_admin")          # خارج الخيط: لا شبكة داخل النافذة الحرجة
    assert token
    t = threading.Thread(target=second)
    with admin.transaction():
        admin.execute(
            "insert into public.teaching_assignments (platform_tenant_id, school_id, academic_year_id, grade_level_id, section_id, subject_id, staff_id, effective_from)"
            " select sc.platform_tenant_id, s.school_id, s.academic_year_id, s.grade_level_id, s.id, %s, %s, '2060-09-01'"
            "   from public.sections s join public.schools sc on sc.id = s.school_id where s.id = %s", [ma, w["t1"], s2])
        t.start()
        time.sleep(1.5)
        assert t.is_alive(), "the second request did not wait on the unique index — the race is not exercised"
    t.join(timeout=20)
    assert not t.is_alive()
    assert (result["r"].status_code, result["r"].json()["detail"]) == (409, "conflict")
    active = admin.execute("select staff_id from public.teaching_assignments where section_id = %s and subject_id = %s and status = 'active'", [s2, ma]).fetchall()
    assert [str(r["staff_id"]) for r in active] == [w["t1"]]
    # والمعاملة المتراجعة لا تحجز: بعد rollback ينجح الطلب
    s1 = w["sec"][0]
    current = admin.execute("select id from public.teaching_assignments where section_id = %s and subject_id = %s and status = 'active'", [s1, ma]).fetchone()
    assert post(client, "school_admin", f"/teaching-assignments/{current['id']}/end", {"effective_to": "2060-09-01", "reason": "free the slot"}).status_code == 200
    try:
        with admin.transaction():
            admin.execute(
                "insert into public.teaching_assignments (platform_tenant_id, school_id, academic_year_id, grade_level_id, section_id, subject_id, staff_id, effective_from)"
                " select sc.platform_tenant_id, s.school_id, s.academic_year_id, s.grade_level_id, s.id, %s, %s, '2060-09-01'"
                "   from public.sections s join public.schools sc on sc.id = s.school_id where s.id = %s", [ma, w["t1"], s1])
            raise RuntimeError("rollback")
    except RuntimeError:
        pass
    assert post(client, "school_admin", f"/sections/{s1}/teaching-assignments", {"subject_id": ma, "staff_id": w["t2"], "effective_from": "2060-09-01"}).status_code == 201


def test_replacement_is_atomic(client, w, admin):
    s2, ar = w["sec"][1], w["subj"]["ZTT-AR"]
    current = admin.execute("select id, staff_id from public.teaching_assignments where section_id = %s and subject_id = %s and status = 'active'", [s2, ar]).fetchone()
    leave = admin.execute("select id from public.staff where employee_code = 'ZTT-L'").fetchone()["id"]
    r = post(client, "school_admin", f"/teaching-assignments/{current['id']}/replace", {"staff_id": str(leave), "effective_from": "2060-12-01", "reason": "swap"})
    assert (r.status_code, r.json()["detail"]) == (422, "invariant_violation")           # البديل في إجازة
    after = admin.execute("select status, effective_to from public.teaching_assignments where id = %s", [current["id"]]).fetchone()
    assert (after["status"], after["effective_to"]) == ("active", None), "the old assignment was ended although the replacement failed"
    assert post(client, "school_admin", f"/teaching-assignments/{current['id']}/replace", {"staff_id": w["t2"], "effective_from": "2060-12-01"}).status_code == 422   # بلا سبب


def test_scope_and_keys(client, w, ids):
    s1, ar = w["sec"][0], w["subj"]["ZTT-AR"]
    body = {"subject_id": ar, "staff_id": w["t1"], "effective_from": "2060-09-01"}
    any_row = rows(client, "school_admin", w)[0]
    # المعلم: يقرأ (staff.read) ولا يكتب
    assert rows(client, "teacher", w) and post(client, "teacher", f"/sections/{s1}/teaching-assignments", body).status_code == 403
    assert post(client, "teacher", f"/teaching-assignments/{any_row['id']}/end", {"effective_to": "2061-01-01", "reason": "r"}).status_code == 403
    assert post(client, "teacher", f"/sections/{s1}/class-teacher", {"staff_id": w["t1"]}).status_code == 403
    # السكرتير بلا staff.read: السنة مرئية والتكليفات لا
    assert rows(client, "secretary", w) == [] and rows(client, "secretary", w, "class-teachers") == []
    assert post(client, "secretary", f"/sections/{s1}/teaching-assignments", body).status_code == 403
    assert post(client, "secretary", f"/teaching-assignments/{any_row['id']}/end", {"effective_to": "2061-01-01", "reason": "r"}).status_code == 404
    # مدرسة أخرى و Tenant آخر
    sb_year = get(client, "tenant_admin", f"/schools/{w['sb']}/academic-years").json()["rows"][0]["id"]
    assert get(client, "school_admin", f"/academic-years/{sb_year}/teaching-assignments").status_code == 404
    assert get(client, "platform", f"/academic-years/{w['year']}/teaching-assignments").status_code == 404
    assert get(client, "group_manager", f"/academic-years/{w['year']}/teaching-assignments").status_code == 200


def test_no_context_from_the_body(client, w):
    s1, ar = w["sec"][0], w["subj"]["ZTT-AR"]
    good = {"subject_id": ar, "staff_id": w["t1"], "effective_from": "2060-09-01"}
    for extra in ({"school_id": w["sb"]}, {"academic_year_id": str(uuid.uuid4())}, {"grade_level_id": w["grade"]}, {"status": "ended"},
                  {"platform_tenant_id": str(uuid.uuid4())}, {"section_id": w["sec"][1]}):
        assert post(client, "school_admin", f"/sections/{s1}/teaching-assignments", {**good, **extra}).status_code == 422
    assert post(client, "school_admin", f"/sections/{s1}/class-teacher", {"staff_id": w["t1"], "subject_id": ar}).status_code == 422
    assert post(client, "school_admin", f"/sections/{uuid.uuid4()}/teaching-assignments", good).status_code == 404
    row = rows(client, "school_admin", w)[0]
    for method in ("delete", "patch", "put"):
        assert getattr(client, method)(f"/teaching-assignments/{row['id']}", headers=auth("school_admin")).status_code in (404, 405)


def test_lifecycle_through_the_api(client, w, admin):
    """P10 + T11: إنهاء تكليف المدرسة يُنهي تكليفات تلك المدرسة ويسحب نطاقها — والجلسة تفقدها فوراً؛ الدور والعضوية يبقيان."""
    sa = w["sa"]
    role = admin.execute("select id from public.roles where code = 'teacher' and platform_tenant_id is null").fetchone()["id"]
    sid = make_staff(client, "school_admin", sa, "ZTT-9", email=True)
    assert post(client, "school_admin", f"/schools/{sa}/staff/{sid}/account", {"role_id": str(role)}).status_code == 201
    year = post(client, "school_admin", f"/schools/{sa}/academic-years", {"name": "ZTT 2062", "start_date": "2062-09-01", "end_date": "2063-06-30"}).json()["id"]
    sec = post(client, "school_admin", f"/academic-years/{year}/sections", {"grade_level_id": w["grade"], "name": "ZTT-L"}).json()["id"]
    assert post(client, "school_admin", f"/academic-years/{year}/grade-subjects",
                {"grade_level_id": w["grade"], "subject_id": w["subj"]["ZTT-AR"], "weekly_periods": 5}).status_code == 201
    assert post(client, "school_admin", f"/sections/{sec}/teaching-assignments", {"subject_id": w["subj"]["ZTT-AR"], "staff_id": sid, "effective_from": "2062-09-01"}).status_code == 201
    assert post(client, "school_admin", f"/sections/{sec}/class-teacher", {"staff_id": sid, "effective_from": "2062-09-01"}).status_code == 201
    # جلسة الموظف
    h = origin("dev", "school-a")
    email = "ztt-9@example.test"
    client.post("/auth/otp/request", json={"kind": "staff", "contact": email}, headers=h)
    code = [c for _, to, c in client.app.state.otp_sender.messages if to == email][-1]
    token = {"Authorization": "Bearer " + client.post("/auth/otp/verify", json={"kind": "staff", "contact": email, "code": code}, headers=h).json()["access_token"]}
    assert client.get(f"/schools/{sa}/staff", headers=token).status_code == 200
    # إنهاء تكليف المدرسة
    assignment = get(client, "school_admin", f"/staff/{sid}/school-assignments").json()["rows"][0]["id"]
    assert post(client, "school_admin", f"/staff-assignments/{assignment}/end", {"effective_to": "2062-12-31", "reason": "left the school"}).status_code == 200
    state = admin.execute(
        "select (select string_agg(status, ',') from public.teaching_assignments where staff_id = %(s)s) t,"
        "       (select string_agg(status, ',') from public.class_teacher_assignments where staff_id = %(s)s) c,"
        "       (select count(*) from public.membership_scopes ms join public.memberships m on m.id = ms.membership_id join public.staff st on st.profile_id = m.profile_id where st.id = %(s)s) scopes,"
        "       (select count(*) from public.membership_roles mr join public.memberships m on m.id = mr.membership_id join public.staff st on st.profile_id = m.profile_id where st.id = %(s)s) roles,"
        "       (select m.status from public.memberships m join public.staff st on st.profile_id = m.profile_id where st.id = %(s)s) membership", {"s": sid}).fetchone()
    assert (state["t"], state["c"], state["scopes"], state["roles"], state["membership"]) == ("ended", "ended", 0, 1, "active")
    assert client.get(f"/schools/{sa}/staff", headers=token).status_code == 404            # الجلسة نفسها فقدت المدرسة
    audit = admin.execute("select action, reason from public.audit_log where entity_type = 'membership_scopes' order by id desc limit 1").fetchone()
    assert (audit["action"], audit["reason"]) == ("delete", "left the school")
