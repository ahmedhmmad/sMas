"""F2 — بوابة الإغلاق: E2E المصادقة لكل الأدوار بالمسار الكامل.

  credentials ─► Supabase Auth session ─► JWT (ES256، kid في JWKS) ─► auth.uid() ─► السياق
             ─► الدور/النطاق ─► البيانات المسموحة ─► البيانات الممنوعة مرفوضة

مسار كل حساب هو مساره الحقيقي:
  Platform Admin و tenant_admin : بريد حقيقي ← Supabase Auth مباشرة (هوية أصلية — قرار tenant_admin المؤجل)
  الموظفون السبعة               : (Origin الـTenant، بريد حقيقي، كلمة مرور) ← POST /auth/password/login (D3؛ F3)
  ولي الأمر                     : A / B / C عبر POST /accounts ثم onboarding (D4)
  الطالب                        : POST /students ← الدخول بالمعرّف ← first-login ← activate (D1، D2)

التوقعات من خريطة الأدوار المعتمدة (ROLE_PERMISSION_SEED §4) ونطاقات الـseed (E5)، لا من الملاحظة.
"""

import secrets
import uuid

import httpx
import jwt
import pytest

from conftest import DEV_PASSWORD, DEV_TENANT, ENV, auth, origin
from test_account_login import AUTH, PUB, TENANT_ADMIN, as_user, bearer, rest

REST = f"{ENV['SUPABASE_URL']}/rest/v1"
SEED_STUDENT = "e0000000-0000-4000-8000-000000000001"   # school-a
JWKS = None


def jwks_kids():
    global JWKS
    if JWKS is None:
        JWKS = {k["kid"] for k in httpx.get(f"{AUTH}/.well-known/jwks.json").json()["keys"]}
    return JWKS


def assert_supabase_session(session):
    assert set(session) == {"access_token", "refresh_token", "expires_in", "token_type"}
    hdr = jwt.get_unverified_header(session["access_token"])
    assert hdr["alg"] == "ES256" and hdr["kid"] in jwks_kids()
    return session["access_token"]


def native(email):
    r = httpx.post(f"{AUTH}/token?grant_type=password", headers=PUB, json={"email": email, "password": DEV_PASSWORD})
    assert r.status_code == 200, r.text
    s = r.json()
    return assert_supabase_session({k: s[k] for k in ("access_token", "refresh_token", "expires_in", "token_type")})


def me(client, token):
    return client.get("/me", headers=bearer(token)).json()


def school_codes(token):
    return sorted(s["school_code"] for s in rest(token, "schools?select=school_code&platform_tenant_id=eq." + DEV_TENANT))


def student_ids(token):
    return {s["id"] for s in rest(token, "students?select=id")}


def school_id(admin, code):
    return str(admin.execute("select id from public.schools where school_code = %s", [code]).fetchone()["id"])


@pytest.fixture(scope="module")
def e2e(client, admin):
    """طالب في كل من SB و SS (عبر الـSaga) — للبيانات الممنوعة ولأولياء الأمور B و C؛ أنماط المدارس."""
    def student_in(code):
        section = str(admin.execute("select s.id from public.sections s join public.schools sc on sc.id = s.school_id"
                                    " where sc.school_code = %s limit 1", [code]).fetchone()["id"])
        sid = str(uuid.uuid4())
        r = client.post("/students", headers=auth("tenant_admin"), json={
            "student_id": sid, "section_id": section, "effective_from": "2026-09-01",
            "first_name": "E2E", "family_name": code, "new_family_name": "E2E " + code})
        assert r.status_code == 201, r.text
        return sid
    for code, mode in (("SA", "A"), ("SB", "B"), ("SS", "C")):
        r = client.post(f"/schools/{school_id(admin, code)}/guardian-first-login-mode", json={"mode": mode, "reason": "E2E"},
                        headers=auth("tenant_admin"))
        assert r.status_code == 200
    return {"sb_student": student_in("SB"), "ss_student": student_in("SS")}


# ======================= المنصة =======================

def test_platform_admin(client, admin, e2e):
    token = native("platform@dev.smas.test")
    ctx = me(client, token)
    assert ctx["auth_user_id"] == "a0000000-0000-4000-8000-000000000000"
    assert ctx["system_user_id"] is not None and ctx["profile_id"] is None and ctx["tenant_id"] is None   # سياق المنصة (G10)
    assert client.get(f"/platform/tenants/{DEV_TENANT}", headers=bearer(token)).status_code == 200       # tenant.read + تدقيق N5
    assert school_codes(token) == []                                                                      # W1/M29: لا قراءة مباشرة للمنصة
    assert student_ids(token) == set()                                                                    # لا بيانات عملاء (C3)
    assert client.get(f"/schools/{school_id(admin, 'SA')}/students/export", headers=bearer(token)).status_code == 403   # لا student.export


# ======================= حسابات الـTenant بمسارها =======================

STAFF = {
    # الدور: (البريد الحقيقي، المعرّف، المدارس المرئية، يقرأ الطلاب، يصدّر)
    "group_manager":  ("group.manager@dev.smas.test",  "a0000000-0000-4000-8000-000000000002", ["SA", "SB"], True,  True),
    "school_admin":   ("school.admin@dev.smas.test",   "a0000000-0000-4000-8000-000000000003", ["SA"],       True,  True),
    "secretary":      ("secretary@dev.smas.test",      "a0000000-0000-4000-8000-000000000004", ["SA"],       True,  False),
    "accountant":     ("accountant@dev.smas.test",     "a0000000-0000-4000-8000-000000000005", ["SA"],       True,  False),
    "teacher":        ("teacher@dev.smas.test",        "a0000000-0000-4000-8000-000000000006", ["SA"],       True,  False),
    "counselor":      ("counselor@dev.smas.test",      "a0000000-0000-4000-8000-000000000007", ["SA"],       True,  False),
    "bus_supervisor": ("bus.supervisor@dev.smas.test", "a0000000-0000-4000-8000-000000000008", ["SA"],       False, False),
}


def tenant_checks(client, admin, token, auth_id, schools, reads, exports, e2e):
    ctx = me(client, token)
    assert ctx["auth_user_id"] == auth_id and ctx["tenant_id"] == DEV_TENANT and ctx["profile_id"] is not None
    assert ctx["system_user_id"] is None
    assert school_codes(token) == schools                                                       # النطاق
    visible = student_ids(token)
    if reads:
        assert SEED_STUDENT in visible                                                          # مسموح: طالب في النطاق
    else:
        assert visible == set()                                                                 # bus_supervisor بلا student.read
    assert e2e["ss_student"] not in visible or "SS" in schools                                  # ممنوع: طالب مدرسة خارج النطاق
    assert e2e["sb_student"] not in visible or "SB" in schools
    sa = school_id(admin, "SA")
    assert client.get(f"/schools/{sa}/students/export", headers=bearer(token)).status_code == (200 if exports else 403)
    ss = school_id(admin, "SS")
    assert client.get(f"/schools/{ss}", headers=bearer(token)).status_code == (200 if "SS" in schools else 404)
    assert client.get(f"/platform/tenants/{DEV_TENANT}", headers=bearer(token)).status_code == 403     # ليس سياق منصة


def test_tenant_admin(client, admin, e2e):
    token = native("tenant.admin@dev.smas.test")
    tenant_checks(client, admin, token, "a0000000-0000-4000-8000-000000000001", ["SA", "SB", "SS"], True, True, e2e)
    assert {e2e["sb_student"], e2e["ss_student"]} <= student_ids(token)                       # نطاق tenant: كل المدارس
    assert [t["tenant_code"] for t in rest(token, "platform_tenants?select=tenant_code")] == ["DEV"]   # Tenant نفسه فقط


@pytest.mark.parametrize("role", list(STAFF))
def test_staff(client, admin, e2e, role):
    email, auth_id, schools, reads, exports = STAFF[role]
    client.app.state.login_limiter.reset()
    r = client.post("/auth/password/login", json={"kind": "staff", "contact": email.upper(), "password": DEV_PASSWORD}, headers=origin())
    assert r.status_code == 200, r.text
    token = assert_supabase_session(r.json())
    assert jwt.decode(token, options={"verify_signature": False})["sub"] == auth_id              # auth.uid() = staff_id (I2)
    tenant_checks(client, admin, token, auth_id, schools, reads, exports, e2e)
    wrong = client.post("/auth/password/login", json={"kind": "staff", "contact": email, "password": "not-it"}, headers=origin())
    assert wrong.status_code == 401


# ======================= ولي الأمر: A / B / C =======================

def new_guardian(client, admin, child):
    gid, phone = str(uuid.uuid4()), "+2017" + f"{secrets.randbelow(10**8):08d}"
    as_user(admin, TENANT_ADMIN, "select app.provision_guardian(%s, %s, 'mother', %s, 'E2E', 'Parent', '2026-09-01')", [gid, child, phone])
    assert client.post("/accounts", json={"kind": "guardian", "target_id": gid}, headers=auth("tenant_admin")).status_code == 201
    return gid, phone


def otp(client, phone, school=None):
    client.app.state.login_limiter.reset()
    body = {"kind": "guardian", "contact": phone}
    client.post("/auth/otp/request", json=body, headers=origin("dev", school))
    code = [c for _, to, c in client.app.state.otp_sender.messages if to == phone][-1]
    r = client.post("/auth/otp/verify", json={**body, "code": code}, headers=origin("dev", school))
    assert r.status_code == 200, r.text
    return assert_supabase_session(r.json())


def guardian_open(client, token, gid, child, forbidden):
    ctx = me(client, token)
    assert ctx["auth_user_id"] == gid and ctx["tenant_id"] == DEV_TENANT and ctx["profile_id"] is not None
    assert [g["id"] for g in rest(token, "guardians?select=id")] == [gid]
    assert student_ids(token) == {child}                                                       # ابنه وحده
    assert forbidden not in student_ids(token)
    assert school_codes(token) == []                                                           # §6 بند 8: لا صف مدرسة (المرحلة 9)
    assert client.get(f"/platform/tenants/{DEV_TENANT}", headers=bearer(token)).status_code == 403


def closed(client, token):
    return me(client, token)["profile_id"] is None and student_ids(token) == set()


def test_guardian_mode_a(client, admin, e2e):
    gid, phone = new_guardian(client, admin, SEED_STUDENT)
    token = otp(client, phone, "school-a")
    assert closed(client, token)
    assert httpx.put(f"{AUTH}/user", headers={**PUB, **bearer(token)}, json={"password": "E2E-A-" + secrets.token_hex(4)}).status_code == 200
    assert client.post("/auth/activate", headers=bearer(token)).json() == {"state": "active"}
    guardian_open(client, token, gid, SEED_STUDENT, e2e["ss_student"])


def test_guardian_mode_b(client, admin, e2e):
    gid, phone = new_guardian(client, admin, e2e["sb_student"])
    token = otp(client, phone, "school-b")
    guardian_open(client, token, gid, e2e["sb_student"], SEED_STUDENT)                     # يُفتح بالـOTP وحده


def test_guardian_mode_c(client, admin, e2e):
    gid, phone = new_guardian(client, admin, e2e["ss_student"])
    temp = client.post(f"/guardians/{gid}/temporary-password", headers=auth("tenant_admin")).json()["temporary_password"]
    r = client.post("/auth/password/login", json={"kind": "guardian", "contact": phone, "password": temp}, headers=origin())
    token = assert_supabase_session(r.json())
    assert closed(client, token)
    assert httpx.put(f"{AUTH}/user", headers={**PUB, **bearer(token)}, json={"password": "E2E-C-" + secrets.token_hex(4)}).status_code == 200
    assert client.post("/auth/activate", headers=bearer(token)).json() == {"state": "active"}
    guardian_open(client, token, gid, e2e["ss_student"], SEED_STUDENT)


# ======================= الطالب =======================

def test_student_first_login(client, admin, e2e):
    section = str(admin.execute("select s.id from public.sections s join public.schools sc on sc.id = s.school_id"
                                " where sc.school_code = 'SA' limit 1").fetchone()["id"])
    sid = str(uuid.uuid4())
    ident = client.post("/students", headers=auth("secretary"), json={
        "student_id": sid, "section_id": section, "effective_from": "2026-09-01",
        "first_name": "E2E", "family_name": "Student", "new_family_name": "E2E Student"}).json()["login_identifier"]
    client.app.state.login_limiter.reset()
    r = client.post("/auth/student/login", json={"identifier": ident, "password": ident}, headers=origin("dev", "school-a"))
    token = assert_supabase_session(r.json())
    assert me(client, token)["auth_user_id"] == sid and closed(client, token)                 # D2: مغلق حتى تغيير الكلمة
    assert httpx.put(f"{AUTH}/user", headers={**PUB, **bearer(token)}, json={"password": "E2E-S-" + secrets.token_hex(4)}).status_code == 200
    assert client.post("/auth/activate", headers=bearer(token)).json() == {"state": "active"}
    ctx = me(client, token)
    assert ctx["tenant_id"] == DEV_TENANT and ctx["profile_id"] is not None
    assert student_ids(token) == {sid}                                                         # صفه وحده
    assert SEED_STUDENT not in student_ids(token)
    assert rest(token, "guardians?select=id") == [] and school_codes(token) == []
    assert client.get(f"/schools/{school_id(admin, 'SA')}/students/export", headers=bearer(token)).status_code == 403
