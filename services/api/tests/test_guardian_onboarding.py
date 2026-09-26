"""F2 / D4 — onboarding ولي الأمر بالأنماط A/B/C عبر الـAPI (M27).

school-a = A (الافتراضي)، school-b = B، standalone = C. الأبناء عبر POST /students، وأولياء الأمور عبر
provision_guardian بـJWT tenant_admin ثم POST /accounts — المسار الحقيقي كله.
"""

import secrets
import uuid

import httpx
import pytest

from conftest import ENV, auth
from test_account_login import AUTH, PUB, TENANT_ADMIN, as_user, bearer, rest

SEED_STUDENT = "e0000000-0000-4000-8000-000000000001"   # في school-a


def new_student_in(client, admin, school_code):
    section = str(admin.execute("select s.id from public.sections s join public.schools sc on sc.id = s.school_id"
                                " where sc.school_code = %s limit 1", [school_code]).fetchone()["id"])
    sid = str(uuid.uuid4())
    r = client.post("/students", headers=auth("tenant_admin"), json={
        "student_id": sid, "section_id": section, "effective_from": "2026-09-01",
        "first_name": "Kid", "family_name": school_code, "new_family_name": school_code})
    assert r.status_code == 201, r.text
    return sid


def new_guardian(client, admin, children):
    gid, phone = str(uuid.uuid4()), "+2014" + f"{secrets.randbelow(10**8):08d}"
    as_user(admin, TENANT_ADMIN, "select app.provision_guardian(%s, %s, 'father', %s, 'D4', 'Parent', '2026-09-01')",
            [gid, children[0], phone])
    for extra in children[1:]:
        admin.execute("insert into public.student_guardians (student_id, guardian_id, platform_tenant_id, relationship_type,"
                      " is_primary, receives_whatsapp, can_pickup, status, effective_from)"
                      " select %s, %s, platform_tenant_id, 'father', false, false, false, 'active', '2026-09-01'"
                      " from public.guardians where id = %s", [extra, gid, gid])
    assert client.post("/accounts", json={"kind": "guardian", "target_id": gid}, headers=auth("tenant_admin")).status_code == 201
    return gid, phone


def school_id(admin, code):
    return str(admin.execute("select id from public.schools where school_code = %s", [code]).fetchone()["id"])


def set_mode(client, admin, code, mode, who="tenant_admin"):
    return client.post(f"/schools/{school_id(admin, code)}/guardian-first-login-mode",
                       json={"mode": mode, "reason": "D4 test"}, headers=auth(who))


def request(client, phone, school=None):
    before = len(client.app.state.otp_sender.messages)
    body = {"tenant": "DEV", "kind": "guardian", "contact": phone, **({"school": school} if school else {})}
    assert client.post("/auth/otp/request", json=body).status_code == 202
    msgs = client.app.state.otp_sender.messages[before:]
    return msgs[-1][2] if msgs else None


def verify(client, phone, code, school=None):
    body = {"tenant": "DEV", "kind": "guardian", "contact": phone, "code": code, **({"school": school} if school else {})}
    return client.post("/auth/otp/verify", json=body)


def me(client, token):
    return client.get("/me", headers=bearer(token)).json()


@pytest.fixture(scope="module")
def modes(client, admin):
    assert set_mode(client, admin, "SB", "B").status_code == 200
    assert set_mode(client, admin, "SS", "C").status_code == 200
    return {"b_child": new_student_in(client, admin, "SB"), "c_child": new_student_in(client, admin, "SS")}


# ---------------- إعداد النمط ----------------

def test_mode_setting_is_security_manage_in_scope(client, admin, modes):
    assert set_mode(client, admin, "SA", "B", who="secretary").status_code == 403       # بلا security.manage
    assert set_mode(client, admin, "SB", "A", who="school_admin").status_code == 404    # SB خارج نطاق school_admin (SA)
    r = client.post(f"/schools/{school_id(admin, 'SA')}/guardian-first-login-mode", json={"mode": "Z", "reason": "x"},
                    headers=auth("tenant_admin"))
    assert r.status_code == 422
    assert admin.execute("select guardian_first_login_mode m from public.schools where school_code = 'SA'").fetchone()["m"] == "A"


# ---------------- A ----------------

def test_mode_a_otp_then_forced_password(client, admin, modes):
    gid, phone = new_guardian(client, admin, [SEED_STUDENT])
    assert request(client, phone) is None                                   # بلا مدرسة سياق
    assert request(client, phone, "school-b") is None                       # مدرسة بلا ابن له
    code = request(client, phone, "school-a")
    assert code is not None
    token = verify(client, phone, code, "school-a").json()["access_token"]
    assert me(client, token)["profile_id"] is None and rest(token, "students?select=id") == []     # مغلق حتى الكلمة
    assert client.post("/auth/activate", headers=bearer(token)).status_code == 409
    assert httpx.put(f"{AUTH}/user", headers={**PUB, **bearer(token)}, json={"password": "A-" + secrets.token_hex(5)}).status_code == 200
    assert client.post("/auth/activate", headers=bearer(token)).json() == {"state": "active"}
    assert me(client, token)["auth_user_id"] == gid and me(client, token)["profile_id"] is not None
    assert [s["id"] for s in rest(token, "students?select=id")] == [SEED_STUDENT]


# ---------------- B ----------------

def test_mode_b_otp_only_opens_immediately(client, admin, modes):
    gid, phone = new_guardian(client, admin, [modes["b_child"]])
    token = verify(client, phone, request(client, phone, "school-b"), "school-b").json()["access_token"]
    assert me(client, token)["profile_id"] is not None                     # بلا كلمة مرور
    assert [s["id"] for s in rest(token, "students?select=id")] == [modes["b_child"]]
    assert client.post("/auth/activate", headers=bearer(token)).json() == {"state": "active"}


def test_target_school_decides_when_children_differ(client, admin, modes):
    """ابن في A وآخر في B: الدخول عبر school-b ⇒ دلالة B (الحساب يُفتح بلا كلمة مرور)."""
    _, phone = new_guardian(client, admin, [SEED_STUDENT, modes["b_child"]])
    token = verify(client, phone, request(client, phone, "school-b"), "school-b").json()["access_token"]
    assert me(client, token)["profile_id"] is not None


# ---------------- C ----------------

def test_mode_c_temporary_password_then_forced_change(client, admin, modes):
    gid, phone = new_guardian(client, admin, [modes["c_child"]])
    assert request(client, phone, "standalone") is None                     # C: لا OTP للـonboarding
    assert client.post(f"/guardians/{gid}/temporary-password", headers=auth("secretary")).status_code == 403
    r = client.post(f"/guardians/{gid}/temporary-password", headers=auth("tenant_admin"))
    assert r.status_code == 201
    temp = r.json()["temporary_password"]
    login = client.post("/auth/password/login", json={"tenant": "DEV", "kind": "guardian", "contact": phone, "password": temp})
    assert login.status_code == 200
    token = login.json()["access_token"]
    assert me(client, token)["profile_id"] is None                          # مغلق حتى التغيير
    mine = "C-" + secrets.token_hex(5)
    assert httpx.put(f"{AUTH}/user", headers={**PUB, **bearer(token)}, json={"password": mine}).status_code == 200
    assert client.post("/auth/activate", headers=bearer(token)).json() == {"state": "active"}
    assert me(client, token)["profile_id"] is not None
    assert client.post("/auth/password/login", json={"tenant": "DEV", "kind": "guardian", "contact": phone,
                                                     "password": temp}).status_code == 401
    # بعد الـonboarding: لا إعادة إصدار (إعادة الضبط مسار مستقل — 5c)
    assert client.post(f"/guardians/{gid}/temporary-password", headers=auth("tenant_admin")).status_code == 409


# ---------------- D4.1 ----------------

def test_later_logins_ignore_the_mode(client, admin, modes):
    gid, phone = new_guardian(client, admin, [modes["b_child"]])
    verify(client, phone, request(client, phone, "school-b"), "school-b")   # onboarding (B)
    try:
        assert set_mode(client, admin, "SB", "C").status_code == 200
        code = request(client, phone)                                        # بلا مدرسة، والمدرسة صارت C
        assert code is not None
        token = verify(client, phone, code).json()["access_token"]
        assert me(client, token)["auth_user_id"] == gid and me(client, token)["profile_id"] is not None
    finally:
        set_mode(client, admin, "SB", "B")
