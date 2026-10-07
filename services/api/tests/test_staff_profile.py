"""Phase 3A / 3-1 — API ملف الموظف (M46 + دوال M21/M22 القائمة) على seed التطوير (E5).

ما يُثبت: الإنشاء (provision_staff) والتعديل والحالة وتكليفات المدارس والتخصصات والمؤهلات عبر المسار الوحيد
(JWT → معاملة authenticated → RLS/الدوال)؛ الرؤية **بالعلاقة** (staff_in_scope — H2): 404 لغير المرئي، 403 للمرئي
المرفوض؛ staff.read ≠ staff.update؛ لا Tenant ولا مدرسة ولا موظف من الجسم؛ التدقيق.
كل ما يُنشأ يحمل الرمز ZTF ويُحذف في نهاية الوحدة (اتصال postgres للاختبار فقط).
"""

import uuid

import pytest

from conftest import auth

ZTF = "select id from public.staff where employee_code like 'ZTF%'"


@pytest.fixture(scope="module", autouse=True)
def _cleanup(admin):
    yield
    for stmt in (
        f"delete from public.staff_specialties where staff_id in ({ZTF})",
        f"delete from public.staff_qualifications where staff_id in ({ZTF})",
        f"delete from public.staff_school_assignments where staff_id in ({ZTF})",
        "delete from public.staff where employee_code like 'ZTF%'",
    ):
        admin.execute(stmt)


def post(client, who, path, body=None):
    return client.post(path, json=body or {}, headers=auth(who))


def patch(client, who, path, body):
    return client.patch(path, json=body, headers=auth(who))


def get(client, who, path):
    return client.get(path, headers=auth(who))


def new_staff(code, **extra):
    return {"employee_code": code, "first_name": "Zt", "family_name": code, "job_title": "Teacher", "effective_from": "2026-09-01", **extra}


@pytest.fixture(scope="module")
def sa_staff(client, ids):
    sid = ids["school"]["SA"]
    r = post(client, "school_admin", f"/schools/{sid}/staff",
             new_staff("ZTF-1", father_name="Ali", email="ztf1@example.test", phone_e164="+201000000901", gender="male", hire_date="2026-08-15"))
    assert r.status_code == 201, r.text
    return r.json()


@pytest.fixture(scope="module")
def sb_staff(client, ids):
    r = post(client, "tenant_admin", f"/schools/{ids['school']['SB']}/staff", new_staff("ZTF-B"))
    assert r.status_code == 201, r.text
    return r.json()


def test_create_read_and_edit(client, ids, sa_staff):
    sid = ids["school"]["SA"]
    assert {k: sa_staff[k] for k in ("employee_code", "full_name", "status", "has_account")} == \
        {"employee_code": "ZTF-1", "full_name": "Zt Ali ZTF-1", "status": "active", "has_account": False}
    listed = {r["id"]: r for r in get(client, "school_admin", f"/schools/{sid}/staff").json()["rows"]}
    assert listed[sa_staff["id"]]["job_title"] == "Teacher"
    assert get(client, "school_admin", f"/staff/{sa_staff['id']}").json()["email"] == "ztf1@example.test"
    # إعادة الإرسال بالمعرّف نفسه آمنة (M22)؛ والمعرّف نفسه ببيانات مختلفة تعارض
    sid2 = str(uuid.uuid4())
    first = post(client, "school_admin", f"/schools/{sid}/staff", new_staff("ZTF-2", staff_id=sid2))
    again = post(client, "school_admin", f"/schools/{sid}/staff", new_staff("ZTF-2", staff_id=sid2))
    assert (first.status_code, again.status_code, again.json()["id"]) == (201, 201, sid2)
    assert post(client, "school_admin", f"/schools/{sid}/staff", new_staff("ZTF-3", staff_id=sid2)).status_code == 409
    assert post(client, "school_admin", f"/schools/{sid}/staff", new_staff("ZTF-1")).status_code == 409          # الرمز فريد في الـTenant
    assert post(client, "school_admin", f"/schools/{sid}/staff", new_staff("ZTF-4", email="ztf1@example.test")).status_code == 409   # البريد فريد
    # التعديل
    edited = patch(client, "school_admin", f"/staff/{sa_staff['id']}", {"phone_e164": "+201000000902", "grandfather_name": "Omar"})
    assert (edited.status_code, edited.json()["full_name"], edited.json()["phone_e164"]) == (200, "Zt Ali Omar ZTF-1", "+201000000902")
    assert patch(client, "school_admin", f"/staff/{sa_staff['id']}", {"phone_e164": "01000000902"}).status_code == 422   # E.164
    assert patch(client, "school_admin", f"/staff/{sa_staff['id']}", {"employee_code": "ZTF-X"}).status_code == 422     # الرمز ثابت
    assert patch(client, "school_admin", f"/staff/{sa_staff['id']}", {}).status_code == 422


def test_visibility_is_by_relationship(client, ids, sa_staff, sb_staff):
    sid, sb = ids["school"]["SA"], ids["school"]["SB"]
    # school_admin SA: موظف SB غير موجود بالنسبة له — داخل الـTenant نفسه
    assert get(client, "school_admin", f"/staff/{sb_staff['id']}").status_code == 404
    assert patch(client, "school_admin", f"/staff/{sb_staff['id']}", {"first_name": "X"}).status_code == 404
    assert get(client, "school_admin", f"/schools/{sb}/staff").status_code == 404
    assert post(client, "school_admin", f"/staff/{sb_staff['id']}/specialties", {"name": "X"}).status_code == 404
    assert post(client, "school_admin", f"/schools/{sb}/staff", new_staff("ZTF-5")).status_code == 404
    # tenant_admin يرى الاثنين؛ group_manager (SA، SB) كذلك
    assert get(client, "tenant_admin", f"/staff/{sb_staff['id']}").status_code == 200
    assert get(client, "group_manager", f"/staff/{sa_staff['id']}").status_code == 200
    # المعلم: staff.read (PD1) بلا staff.update — يرى موظف مدرسته ولا يعدّله
    assert get(client, "teacher", f"/staff/{sa_staff['id']}").status_code == 200
    assert patch(client, "teacher", f"/staff/{sa_staff['id']}", {"first_name": "X"}).status_code == 403
    assert post(client, "teacher", f"/schools/{sid}/staff", new_staff("ZTF-6")).status_code == 403
    # السكرتير بلا staff.read: يرى المدرسة ولا يرى موظفيها
    assert get(client, "secretary", f"/schools/{sid}/staff").json() == {"rows": []}
    assert get(client, "secretary", f"/staff/{sa_staff['id']}").status_code == 404
    assert get(client, "platform", f"/staff/{sa_staff['id']}").status_code == 404


def test_specialties_and_qualifications(client, sa_staff, sb_staff, admin):
    sp = post(client, "school_admin", f"/staff/{sa_staff['id']}/specialties", {"name": "  Mathematics "})
    assert (sp.status_code, sp.json()["name"], sp.json()["status"]) == (201, "Mathematics", "active")
    assert post(client, "school_admin", f"/staff/{sa_staff['id']}/specialties", {"name": "Mathematics"}).status_code == 409
    off = patch(client, "school_admin", f"/staff-specialties/{sp.json()['id']}", {"status": "inactive"})
    assert off.json()["status"] == "inactive"
    q = post(client, "school_admin", f"/staff/{sa_staff['id']}/qualifications",
             {"degree": "bachelor", "field": "Math", "institution": "Cairo University", "graduation_year": 2012})
    assert q.status_code == 201, q.text
    assert post(client, "school_admin", f"/staff/{sa_staff['id']}/qualifications", {"degree": "phd", "field": "x"}).status_code == 422
    assert post(client, "school_admin", f"/staff/{sa_staff['id']}/qualifications", {"degree": "other", "field": "x", "graduation_year": 1800}).status_code == 422
    fixed = patch(client, "school_admin", f"/staff-qualifications/{q.json()['id']}", {"degree": "master", "graduation_year": 2014})
    assert (fixed.json()["degree"], fixed.json()["graduation_year"]) == ("master", 2014)
    assert [r["field"] for r in get(client, "teacher", f"/staff/{sa_staff['id']}/qualifications").json()["rows"]] == ["Math"]
    assert [r["name"] for r in get(client, "school_admin", f"/staff/{sa_staff['id']}/specialties").json()["rows"]] == ["Mathematics"]
    # المعلم يرى ولا يكتب؛ السكرتير لا يرى؛ مدرسة أخرى لا ترى
    assert post(client, "teacher", f"/staff/{sa_staff['id']}/specialties", {"name": "X"}).status_code == 403
    assert patch(client, "teacher", f"/staff-specialties/{sp.json()['id']}", {"name": "X"}).status_code == 403
    assert get(client, "secretary", f"/staff/{sa_staff['id']}/specialties").status_code == 404
    assert patch(client, "school_admin", f"/staff-qualifications/{uuid.uuid4()}", {"field": "x"}).status_code == 404
    sbq = post(client, "tenant_admin", f"/staff/{sb_staff['id']}/qualifications", {"degree": "diploma", "field": "Arts"}).json()
    assert patch(client, "school_admin", f"/staff-qualifications/{sbq['id']}", {"field": "x"}).status_code == 404
    # التدقيق: الفاعل مدير المدرسة
    row = admin.execute("select a.actor_type, a.action from public.audit_log a where a.entity_type = 'staff_specialties' and a.entity_id = %s order by a.id",
                        [sp.json()["id"]]).fetchall()
    assert [(r["actor_type"], r["action"]) for r in row] == [("tenant_user", "insert"), ("tenant_user", "update")]


def test_school_assignments(client, ids, sa_staff, admin):
    sid, sb = ids["school"]["SA"], ids["school"]["SB"]
    extra = post(client, "school_admin", f"/schools/{sid}/staff", new_staff("ZTF-7")).json()
    # tenant_admin يضيف تكليفاً في SB (توظيف متزامن — خيار b)
    sb_a = post(client, "tenant_admin", f"/schools/{sb}/staff-assignments", {"staff_id": extra["id"], "job_title": "Counselor", "effective_from": "2026-09-01"})
    assert sb_a.status_code == 201, sb_a.text
    # school_admin SA لا يرى تكليف SB ولا يضيف فيها
    mine = get(client, "school_admin", f"/staff/{extra['id']}/school-assignments").json()["rows"]
    assert {r["school_id"] for r in mine} == {sid}
    assert post(client, "school_admin", f"/schools/{sb}/staff-assignments", {"staff_id": extra["id"], "job_title": "X", "effective_from": "2026-09-01"}).status_code == 404
    assert patch(client, "school_admin", f"/staff-assignments/{sb_a.json()['id']}", {"job_title": "X"}).status_code == 404
    # تعديل وإنهاء تكليف SA بسبب؛ بعده لا يرى SA الموظف (H2: التكليف النشط وحده)
    sa_a = mine[0]
    assert patch(client, "school_admin", f"/staff-assignments/{sa_a['id']}", {"job_title": "Senior Teacher"}).json()["job_title"] == "Senior Teacher"
    assert post(client, "school_admin", f"/staff-assignments/{sa_a['id']}/end", {"effective_to": "2026-12-31"}).status_code == 422   # بلا سبب
    assert post(client, "school_admin", f"/staff-assignments/{sa_a['id']}/end", {"effective_to": "2026-08-01", "reason": "r"}).status_code == 422
    ended = post(client, "school_admin", f"/staff-assignments/{sa_a['id']}/end", {"effective_to": "2026-12-31", "reason": "moved to SB"})
    assert (ended.status_code, ended.json()["status"]) == (200, "ended")
    # السبب يصل إلى التدقيق كما أرسله المستخدم (لا قيمة ثابتة من الخادم)
    assert admin.execute("select reason from public.audit_log where entity_type = 'staff_school_assignments' and entity_id = %s and action = 'end'",
                         [sa_a["id"]]).fetchone()["reason"] == "moved to SB"
    assert post(client, "school_admin", f"/staff-assignments/{sa_a['id']}/end", {"effective_to": "2027-01-31", "reason": "r"}).status_code == 422
    assert get(client, "school_admin", f"/staff/{extra['id']}").status_code == 404
    assert extra["id"] not in {r["id"] for r in get(client, "school_admin", f"/schools/{sid}/staff").json()["rows"]}
    assert get(client, "tenant_admin", f"/staff/{extra['id']}").status_code == 200   # ما زال نشطاً في SB
    # …لكن قائمة SA لا تعرضه حتى لمن يراه: القائمة = التكليفات النشطة في المدرسة وحدها
    assert extra["id"] not in {r["id"] for r in get(client, "tenant_admin", f"/schools/{sid}/staff").json()["rows"]}
    assert extra["id"] in {r["id"] for r in get(client, "tenant_admin", f"/schools/{sb}/staff").json()["rows"]}
    # الحالة في الجسم لا تُقبل
    assert post(client, "tenant_admin", f"/schools/{sid}/staff-assignments",
                {"staff_id": extra["id"], "job_title": "X", "effective_from": "2027-01-01", "status": "ended"}).status_code == 422


def test_status_transitions(client, ids, admin):
    sid = ids["school"]["SA"]
    s = post(client, "school_admin", f"/schools/{sid}/staff", new_staff("ZTF-8")).json()
    path = f"/staff/{s['id']}/status"
    assert post(client, "school_admin", path, {"status": "on_leave"}).status_code == 422                         # بلا سبب
    assert post(client, "teacher", path, {"status": "on_leave", "reason": "r"}).status_code == 403
    assert post(client, "school_admin", path, {"status": "on_leave", "reason": "leave"}).json()["status"] == "on_leave"
    assert admin.execute("select reason from public.audit_log where entity_type = 'staff' and entity_id = %s and action = 'set_status' order by id desc limit 1",
                         [s["id"]]).fetchone()["reason"] == "leave"
    assert post(client, "school_admin", path, {"status": "active", "reason": "back"}).json()["status"] == "active"
    assert post(client, "school_admin", path, {"status": "archived", "reason": "r"}).status_code == 422          # active ← archived ممنوع
    assert post(client, "school_admin", path, {"status": "ended", "reason": "r"}).status_code == 422              # effective_to مطلوب
    done = post(client, "school_admin", path, {"status": "ended", "reason": "resigned", "effective_to": "2026-12-31"})
    assert done.status_code == 200, done.text
    assert done.json().get("visible") is False                                                                   # H2: لا تكليف نشط
    assert get(client, "school_admin", f"/staff/{s['id']}").status_code == 404
    # الأرشفة بنطاق الـTenant (M21)
    # الأرشفة: نطاق مدرسة لا يكفي لموظف منتهٍ (غير مرئي ← 404)؛ نطاق الـTenant يكفي (M21)
    assert post(client, "school_admin", path, {"status": "archived", "reason": "archive"}).status_code == 404
    assert get(client, "tenant_admin", f"/staff/{s['id']}").status_code == 404                                    # الصف غير مرئي (H2)…
    arch = post(client, "tenant_admin", path, {"status": "archived", "reason": "archive"})
    assert (arch.status_code, arch.json().get("visible")) == (200, False)                                        # …والأرشفة بنطاق الـTenant ممكنة


def test_no_context_from_the_body(client, ids, sa_staff):
    sid, sb = ids["school"]["SA"], ids["school"]["SB"]
    assert post(client, "school_admin", f"/schools/{sid}/staff", new_staff("ZTF-9", platform_tenant_id=ids["tenant"])).status_code == 422
    assert post(client, "school_admin", f"/schools/{sid}/staff", new_staff("ZTF-9", school_id=sb)).status_code == 422
    assert post(client, "school_admin", f"/staff/{sa_staff['id']}/specialties", {"name": "X", "staff_id": str(uuid.uuid4())}).status_code == 422
    assert post(client, "school_admin", f"/staff/{sa_staff['id']}/qualifications",
                {"degree": "other", "field": "x", "platform_tenant_id": ids["tenant"]}).status_code == 422
    assert patch(client, "school_admin", f"/staff/{sa_staff['id']}", {"status": "archived"}).status_code == 422
    sp = get(client, "school_admin", f"/staff/{sa_staff['id']}/specialties").json()["rows"][0]
    assert patch(client, "school_admin", f"/staff-specialties/{sp['id']}", {"staff_id": str(uuid.uuid4())}).status_code == 422
    for path in (f"/staff/{sa_staff['id']}", f"/staff-specialties/{sp['id']}"):
        assert client.delete(path, headers=auth("school_admin")).status_code in (404, 405)
