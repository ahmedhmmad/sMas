"""Phase 3A / 3-4 — تضييق المعلم (R5، M50 + M51) على seed التطوير (docs/PHASE3_4_TEACHER_NARROWING.md).

ما يُثبت عبر المسارين اللذين يصل منهما العميل — FastAPI و**PostgREST مباشرة** بتوكن المعلم نفسه (الطبقة الأخيرة RLS):
معلم مُفعَّل (OTP حقيقي) بلا تكليف لا يرى طالباً؛ بتكليف تدريس يرى طلاب شعبته وحدهم وأولياء أمورهم؛ مربي الفصل يرى شعبته؛
التصدير 403؛ إنهاء التكليف يُفرغ القائمة في الجلسة نفسها؛ `/me/teaching`؛ والمدير والسكرتير كما كانا.
كل ما يُنشأ يحمل الرمز ZTR ويُحذف في نهاية الوحدة.
"""

import uuid

import httpx
import pytest

from conftest import ENV, auth, origin

ZTR = "select id from public.staff where employee_code like 'ZTR%'"
SEED_STUDENT = "e0000000-0000-4000-8000-000000000001"


@pytest.fixture(scope="module", autouse=True)
def _cleanup(admin):
    yield
    ids = [r["id"] for r in admin.execute(ZTR).fetchall()]
    pids = [r["profile_id"] for r in admin.execute("select profile_id from public.staff where employee_code like 'ZTR%' and profile_id is not null").fetchall()]
    students = [r["id"] for r in admin.execute("select id from public.students where first_name = 'Ztr'").fetchall()]
    spids = [r["student_profile_id"] for r in admin.execute("select student_profile_id from public.students where first_name = 'Ztr'").fetchall()]
    years = "select id from public.academic_years where name like 'ZTR%'"
    subjects = "select id from public.subjects where subject_code like 'ZTR%'"
    members = "select id from public.memberships where profile_id = any(%(p)s)"
    for stmt in (
        "alter table public.teaching_assignments disable trigger guard",
        "alter table public.class_teacher_assignments disable trigger guard",
        f"delete from public.teaching_assignments where staff_id in ({ZTR}) or academic_year_id in ({years})",
        f"delete from public.class_teacher_assignments where staff_id in ({ZTR}) or academic_year_id in ({years})",
        "alter table public.teaching_assignments enable trigger guard",
        "alter table public.class_teacher_assignments enable trigger guard",
        "delete from public.student_guardians where student_id = any(%(s)s)",
        "delete from public.guardians where first_name = 'Ztr'",
        "delete from public.enrollments where student_id = any(%(s)s)",
        "delete from public.students where id = any(%(s)s)",
        "delete from public.families where family_name = 'Ztr'",
        f"delete from public.grade_subjects where subject_id in ({subjects})",
        "delete from public.subjects where subject_code like 'ZTR%'",
        f"delete from public.sections where academic_year_id in ({years})",
        "delete from public.academic_years where name like 'ZTR%'",
        f"delete from public.membership_roles where membership_id in ({members})",
        f"delete from public.membership_scopes where membership_id in ({members})",
        "delete from public.memberships where profile_id = any(%(p)s)",
        f"delete from public.staff_school_assignments where staff_id in ({ZTR})",
        "delete from public.staff where employee_code like 'ZTR%'",
        "delete from public.profiles where id = any(%(p)s)",
        "delete from public.login_challenges where account_id = any(%(i)s)",
        "delete from public.auth_identities where auth_user_id = any(%(i)s)",
        "delete from auth.users where id = any(%(i)s)",
    ):
        params = {"p": pids + spids, "i": ids + students, "s": students}
        admin.execute(stmt, params) if "%(" in stmt else admin.execute(stmt)


def post(client, who, path, body=None):
    return client.post(path, json=body or {}, headers=auth(who))


def get(client, who, path):
    return client.get(path, headers=auth(who))


def bearer(token):
    return {"Authorization": f"Bearer {token}"}


def otp_login(client, email, school="school-a"):
    h = origin("dev", school)
    assert client.post("/auth/otp/request", json={"kind": "staff", "contact": email}, headers=h).status_code == 202
    codes = [c for _, to, c in client.app.state.otp_sender.messages if to == email]
    r = client.post("/auth/otp/verify", json={"kind": "staff", "contact": email, "code": codes[-1]}, headers=h)
    assert r.status_code == 200, r.text
    return r.json()["access_token"]


def rest(token, table, query="select=id"):
    """PostgREST مباشرة بتوكن المستخدم — لا FastAPI في الطريق: ما يعود هو ما تسمح به RLS وحدها."""
    r = httpx.get(f"{ENV['SUPABASE_URL']}/rest/v1/{table}?{query}", headers={"apikey": ENV["TEST_ANON_KEY"], **bearer(token)})
    assert r.status_code == 200, r.text
    return r.json()


def students_of(client, token, school):
    r = client.get(f"/schools/{school}/students", headers=bearer(token))
    assert r.status_code == 200, r.text
    return {row["id"] for row in r.json()["rows"]}


@pytest.fixture(scope="module")
def w(client, ids, admin):
    """SA: سنة planned بشعبتين، مادة مربوطة بالصف، ثلاثة طلاب (اثنان في أ وواحد في ب)، ولي أمر لطالب في أ،
    ومعلمان مُفعَّلان بدور teacher — بلا أي تكليف بعد."""
    sa = ids["school"]["SA"]
    client.app.state.login_limiter.reset()      # fixture الوحدة يسبق إعادة الضبط لكل اختبار (conftest) — والدخولان هنا حقيقيان
    role = str(admin.execute("select id from public.roles where code = 'teacher' and platform_tenant_id is null").fetchone()["id"])
    grade = next(g for g in get(client, "school_admin", f"/schools/{sa}/grade-levels").json()["rows"] if g["status"] == "active")["id"]
    year = post(client, "school_admin", f"/schools/{sa}/academic-years", {"name": "ZTR 2062", "start_date": "2062-09-01", "end_date": "2063-06-30"}).json()["id"]
    sec = [post(client, "school_admin", f"/academic-years/{year}/sections", {"grade_level_id": grade, "name": n}).json()["id"] for n in ("ZTR-A", "ZTR-B")]
    subject = post(client, "school_admin", f"/schools/{sa}/subjects", {"subject_code": "ZTR-MA", "name": "ZTR Math"}).json()["id"]
    link = post(client, "school_admin", f"/academic-years/{year}/grade-subjects", {"grade_level_id": grade, "subject_id": subject, "weekly_periods": 4})
    assert link.status_code == 201, link.text

    def student(section, family):
        body = {"student_id": str(uuid.uuid4()), "section_id": section, "effective_from": "2062-09-01",
                "first_name": "Ztr", "family_name": family, "new_family_name": "Ztr"}
        r = post(client, "secretary", "/students", body)
        assert r.status_code == 201, r.text
        return body["student_id"]
    a1, a2, b1 = student(sec[0], "A-one"), student(sec[0], "A-two"), student(sec[1], "B-one")
    # ولي أمر a1: بيانات تجهيز (لا مسار API لولي الأمر في هذه المرحلة) — موضوع الاختبار هو **القراءة**
    guardian = admin.execute(
        "insert into public.guardians (platform_tenant_id, first_name, family_name, phone_e164) values (%s, 'Ztr', 'Guardian', '+201099990001') returning id",
        [ids["tenant"]]).fetchone()["id"]
    admin.execute("insert into public.student_guardians (student_id, guardian_id, platform_tenant_id, relationship_type, effective_from)"
                  " values (%s, %s, %s, 'father', '2062-09-01')", [a1, guardian, ids["tenant"]])

    def teacher(code):
        r = post(client, "school_admin", f"/schools/{sa}/staff", {"employee_code": code, "first_name": "Zt", "family_name": code, "job_title": "Teacher",
                                                                  "effective_from": "2026-09-01", "email": f"{code.lower()}@example.test"})
        assert r.status_code == 201, r.text
        sid = r.json()["id"]
        act = post(client, "school_admin", f"/schools/{sa}/staff/{sid}/account", {"role_id": role})     # N4: المدير يسند teacher بعد M51
        assert act.status_code == 201, act.text
        return {"id": sid, "token": otp_login(client, f"{code.lower()}@example.test")}
    return {"sa": sa, "sb": ids["school"]["SB"], "year": year, "sec": sec, "subject": subject, "a1": a1, "a2": a2, "b1": b1,
            "guardian": str(guardian), "t1": teacher("ZTR-1"), "t2": teacher("ZTR-2")}


def test_a_teacher_without_an_assignment_sees_no_student(client, w):
    """R5: المفتاح بلا العلاقة — عبر FastAPI و PostgREST معاً."""
    t = w["t1"]["token"]
    mine = set(client.get("/me/capabilities", headers=bearer(t)).json()["permissions"])
    assert {"student.read_assigned", "enrollment.read_assigned", "guardian.read_assigned", "family.read_assigned", "staff.read"} <= mine
    assert not ({"student.read", "enrollment.read", "guardian.read", "family.read", "profile.read", "student.export"} & mine)
    assert students_of(client, t, w["sa"]) == set()
    assert client.get("/me/teaching", headers=bearer(t)).json() == {"rows": []}
    for table in ("students", "enrollments", "guardians", "families", "student_guardians"):
        assert rest(t, table, "select=*") == [], table
    # N8: ملفه وحده
    assert [p["auth_user_id"] for p in rest(t, "profiles", "select=auth_user_id")] == [w["t1"]["id"]]


def test_teaching_assignment_opens_exactly_its_section(client, w):
    t = w["t1"]["token"]
    r = post(client, "school_admin", f"/sections/{w['sec'][0]}/teaching-assignments", {"subject_id": w["subject"], "staff_id": w["t1"]["id"], "effective_from": "2062-09-01"})
    assert r.status_code == 201, r.text
    w["t1"]["assignment"] = r.json()["id"]
    # الجلسة نفسها، بلا دخول جديد
    assert students_of(client, t, w["sa"]) == {w["a1"], w["a2"]}
    assert {s["id"] for s in rest(t, "students")} == {w["a1"], w["a2"]}
    assert rest(t, "students", f"select=id&id=eq.{w['b1']}") == []                      # طالب آخر في مدرسته: غير مرئي
    assert rest(t, "students", f"select=id&id=eq.{SEED_STUDENT}") == []                 # ولا طالب شعبة معلم آخر
    assert {e["student_id"] for e in rest(t, "enrollments", "select=student_id,section_id")} == {w["a1"], w["a2"]}
    assert [g["id"] for g in rest(t, "guardians")] == [w["guardian"]]                   # ولي أمر طالبه — مشتق من الطالب
    assert [(x["student_id"], x["guardian_id"]) for x in rest(t, "student_guardians", "select=student_id,guardian_id")] == [(w["a1"], w["guardian"])]
    assert len(rest(t, "families")) == 2                                                # أسرتا طالبيه (كل طالب أُنشئ بأسرة جديدة) — لا أسرة طالب ب
    assert [p["auth_user_id"] for p in rest(t, "profiles", "select=auth_user_id")] == [w["t1"]["id"]]
    # القراءة ليست تصديراً، ولا مدرسة أخرى
    assert client.get(f"/schools/{w['sa']}/students/export", headers=bearer(t)).status_code == 403
    assert client.get(f"/schools/{w['sb']}/students", headers=bearer(t)).status_code == 404
    # لا كتابة عبر الفرع الجديد
    upd = httpx.patch(f"{ENV['SUPABASE_URL']}/rest/v1/students?id=eq.{w['a1']}", json={"first_name": "Hacked"},
                      headers={"apikey": ENV["TEST_ANON_KEY"], "Prefer": "return=representation", **bearer(t)})
    assert upd.status_code in (401, 403) or upd.json() == []


def test_my_teaching_lists_operational_assignments_only(client, w):
    rows = client.get("/me/teaching", headers=bearer(w["t1"]["token"])).json()["rows"]
    assert [(r["kind"], r["section_id"], r["subject_id"], r["section_name"], r["subject_name"], r["academic_year_name"]) for r in rows] == \
        [("teaching", w["sec"][0], w["subject"], "ZTR-A", "ZTR Math", "ZTR 2062")]
    assert rows[0]["id"] == w["t1"]["assignment"] and rows[0]["school_id"] == w["sa"]
    # ليست مسار قراءة لغيره: الثاني بلا تكليف ← فارغة، والمدير (ليس مكلَّفاً) ← فارغة
    assert client.get("/me/teaching", headers=bearer(w["t2"]["token"])).json() == {"rows": []}
    assert get(client, "school_admin", "/me/teaching").json() == {"rows": []}
    assert client.get("/me/teaching").status_code == 401


def test_class_teacher_sees_its_section_without_teaching_it(client, w):
    t = w["t2"]["token"]
    assert students_of(client, t, w["sa"]) == set()
    r = post(client, "school_admin", f"/sections/{w['sec'][1]}/class-teacher", {"staff_id": w["t2"]["id"], "effective_from": "2062-09-01"})
    assert r.status_code == 201, r.text
    assert students_of(client, t, w["sa"]) == {w["b1"]}
    assert {s["id"] for s in rest(t, "students")} == {w["b1"]}
    assert rest(t, "guardians") == []                                                   # ولي أمر طالب الشعبة الأخرى: لا
    assert [r["kind"] for r in client.get("/me/teaching", headers=bearer(t)).json()["rows"]] == ["class_teacher"]
    # المعلم الأول لم يتغير
    assert students_of(client, w["t1"]["token"], w["sa"]) == {w["a1"], w["a2"]}


def test_other_roles_are_unchanged_and_the_seed_teacher_is_assigned(client, w):
    everyone = {w["a1"], w["a2"], w["b1"], SEED_STUDENT}
    for who in ("school_admin", "secretary", "accountant", "group_manager", "tenant_admin"):
        seen = {r["id"] for r in get(client, who, f"/schools/{w['sa']}/students").json()["rows"]}
        assert everyone <= seen, who
    # المدير يحمل المفاتيح الأربعة (N4) — بلا أثر على ما يراه ولا على تصديره
    assert get(client, "school_admin", f"/schools/{w['sa']}/students/export").status_code == 200
    # معلم الـseed مكلَّف بشعبة طالب الـseed (N11): يراه، ولا يرى طلاب الشعب الأخرى
    seed_teacher = {r["id"] for r in get(client, "teacher", f"/schools/{w['sa']}/students").json()["rows"]}
    assert SEED_STUDENT in seed_teacher and not (seed_teacher & {w["a1"], w["a2"], w["b1"]})
    assert [(r["kind"], r["subject_code"]) for r in get(client, "teacher", "/me/teaching").json()["rows"]] == [("teaching", "MATH")]
    assert get(client, "bus_supervisor", f"/schools/{w['sa']}/students").json()["rows"] == []


def test_ending_the_assignment_empties_the_list_in_the_same_session(client, w):
    t = w["t1"]["token"]
    assert students_of(client, t, w["sa"]) == {w["a1"], w["a2"]}
    r = post(client, "school_admin", f"/teaching-assignments/{w['t1']['assignment']}/end", {"effective_to": "2062-12-01", "reason": "left the section"})
    assert r.status_code == 200, r.text
    assert students_of(client, t, w["sa"]) == set()
    assert rest(t, "students") == [] and rest(t, "guardians") == [] and rest(t, "enrollments") == []
    assert client.get("/me/teaching", headers=bearer(t)).json() == {"rows": []}
    # الإجازة (بلا cascade): مربي الفصل يفقد الرؤية ثم تعود بالعودة — الصف نفسه لم يُمس (Q4، P5)
    t2 = w["t2"]["token"]
    assert post(client, "school_admin", f"/staff/{w['t2']['id']}/status", {"status": "on_leave", "reason": "leave"}).status_code == 200
    assert rest(t2, "students") == [] and client.get("/me/teaching", headers=bearer(t2)).json() == {"rows": []}
    assert post(client, "school_admin", f"/staff/{w['t2']['id']}/status", {"status": "active", "reason": "back"}).status_code == 200
    assert {s["id"] for s in rest(t2, "students")} == {w["b1"]}
