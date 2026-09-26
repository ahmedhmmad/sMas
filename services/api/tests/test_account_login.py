"""F2 / D3 — هوية اصطناعية لحسابات Tenant: ولي الأمر (هاتف) والموظف (بريد — I6) عبر OTP وكلمة المرور.

الجانب DEV بالمسار الحقيقي: provision_guardian/provision_staff بـJWT tenant_admin ثم POST /accounts (الـSaga).
الـTenant الثاني fixture مباشرة (بلا مسار JWT فيه) بالهاتف نفسه والبريد نفسه.
"""

import json
import secrets
import uuid

import httpx
import jwt
import pytest

from app.auth_admin import SESSION_FIELDS, account_email
from conftest import DEV_TENANT, ENV, auth

AUTH = f"{ENV['SUPABASE_URL']}/auth/v1"
REST = f"{ENV['SUPABASE_URL']}/rest/v1"
SEC = {"apikey": ENV["SUPABASE_SECRET_KEY"]}
PUB = {"apikey": ENV["SUPABASE_PUBLISHABLE_KEY"]}
TENANT_ADMIN = "a0000000-0000-4000-8000-000000000001"
SEED_STUDENT = "e0000000-0000-4000-8000-000000000001"


def as_user(admin, auth_id, sql, params):
    with admin.transaction():
        admin.execute("set local role authenticated")
        admin.execute("select set_config('request.jwt.claims', %s, true)", [json.dumps({"sub": auth_id, "role": "authenticated"})])
        return admin.execute(sql, params).fetchone()


def outbox(client):
    return client.app.state.otp_sender.messages


def sent_to(client, contact):
    return [c for _, to, c in outbox(client) if to == contact]


def bearer(token):
    return {"Authorization": f"Bearer {token}"}


def rest(token, path):
    r = httpx.get(f"{REST}/{path}", headers={**PUB, **bearer(token)})
    return r.json() if r.status_code == 200 else r.status_code


@pytest.fixture(scope="module")
def world(client, admin):
    """حسابا ولي أمر وموظف في DEV (المسار الحقيقي) ونظيراهما بالهاتف/البريد نفسه في Tenant ثانٍ."""
    phone = "+2011" + f"{secrets.randbelow(10**8):08d}"
    only_b_phone = "+2012" + f"{secrets.randbelow(10**8):08d}"
    email = f"d3.{secrets.token_hex(4)}@school.test"
    g_a, s_a = str(uuid.uuid4()), str(uuid.uuid4())
    sa = admin.execute("select id from public.schools where school_code = 'SA'").fetchone()["id"]
    as_user(admin, TENANT_ADMIN, "select app.provision_guardian(%s, %s, 'mother', %s, 'Mona', 'D3', '2026-09-01')",
            [g_a, SEED_STUDENT, phone])
    as_user(admin, TENANT_ADMIN, "select app.provision_staff(%s, %s, %s, 'Sami', 'D3', 'Teacher', '2026-09-01', p_email => %s)",
            [s_a, sa, "D3-" + secrets.token_hex(3), email.upper()])
    created = {k: client.post("/accounts", json={"kind": k, "target_id": i}, headers=auth("tenant_admin")).status_code
               for k, i in (("guardian", g_a), ("staff", s_a))}

    b_code = "ZB" + secrets.token_hex(2).upper()
    b = str(admin.execute("insert into public.platform_tenants (tenant_code, name) values (%s, 'B') returning id", [b_code]).fetchone()["id"])

    def b_account(kind, contact):
        eid = str(uuid.uuid4())
        if kind == "guardian":
            admin.execute("insert into public.guardians (id, platform_tenant_id, first_name, family_name, phone_e164) values (%s, %s, 'G', 'B', %s)",
                          [eid, b, contact])
        else:
            admin.execute("insert into public.staff (id, platform_tenant_id, employee_code, first_name, family_name, email) values (%s, %s, 'B1', 'S', 'B', %s)",
                          [eid, b, contact])
        r = httpx.post(f"{AUTH}/admin/users", headers=SEC, json={"id": eid, "email": account_email(kind, eid), "email_confirm": True})
        admin.execute("insert into public.auth_identities (auth_user_id, kind) values (%s, 'tenant')", [eid])
        p = admin.execute("insert into public.profiles (platform_tenant_id, auth_user_id, display_name) values (%s, %s, 'b') returning id", [b, eid]).fetchone()["id"]
        admin.execute("insert into public.memberships (platform_tenant_id, profile_id) values (%s, %s)", [b, p])
        admin.execute(f"update public.{'guardians' if kind == 'guardian' else 'staff'} set profile_id = %s where id = %s", [p, eid])
        return eid, r.status_code

    g_b, g_b_status = b_account("guardian", phone)
    s_b, s_b_status = b_account("staff", email)
    b_account("guardian", only_b_phone)
    return {"phone": phone, "only_b_phone": only_b_phone, "email": email, "g_a": g_a, "s_a": s_a, "g_b": g_b, "s_b": s_b,
            "b_code": b_code, "b": b, "created": created, "b_status": (g_b_status, s_b_status)}


def request_code(client, tenant, kind, contact):
    r = client.post("/auth/otp/request", json={"tenant": tenant, "kind": kind, "contact": contact})
    assert (r.status_code, r.json()) == (202, {"status": "sent"})


def verify(client, tenant, kind, contact, code):
    return client.post("/auth/otp/verify", json={"tenant": tenant, "kind": kind, "contact": contact, "code": code})


def otp_session(client, tenant, kind, contact):
    request_code(client, tenant, kind, contact)
    r = verify(client, tenant, kind, contact, sent_to(client, contact.strip())[-1])
    assert r.status_code == 200, r.text
    return r.json()


def password(client, tenant, kind, contact, pw):
    return client.post("/auth/password/login", json={"tenant": tenant, "kind": kind, "contact": contact, "password": pw})


# ---------------- الحسابات ----------------

def test_accounts_are_synthetic_with_entity_ids(world):
    assert world["created"] == {"guardian": 201, "staff": 201} and world["b_status"] == (200, 200)
    for kind, eid in (("guardian", world["g_a"]), ("staff", world["s_a"])):
        u = httpx.get(f"{AUTH}/admin/users/{eid}", headers=SEC).json()
        assert u["id"] == eid and u["email"] == account_email(kind, eid) and not u.get("phone")      # I2 + D3


def test_account_saga_compensates_on_refusal(client, admin):
    gid = str(uuid.uuid4())
    as_user(admin, TENANT_ADMIN, "select app.provision_guardian(%s, %s, 'father', %s, 'X', 'Y', '2026-09-01')",
            [gid, SEED_STUDENT, "+2013" + f"{secrets.randbelow(10**8):08d}"])
    r = client.post("/accounts", json={"kind": "guardian", "target_id": gid}, headers=auth("teacher"))   # بلا membership.create
    assert r.status_code == 403
    assert httpx.get(f"{AUTH}/admin/users/{gid}", headers=SEC).status_code == 404


# ---------------- ولي الأمر والموظف: الدورة نفسها ----------------

@pytest.mark.parametrize("kind", ["guardian", "staff"])
def test_otp_cycle_gives_a_supabase_session_for_the_entity(client, world, kind):
    contact = world["phone"] if kind == "guardian" else world["email"]
    s = otp_session(client, "DEV", kind, contact if kind == "guardian" else contact.upper())
    assert set(s) == set(SESSION_FIELDS)
    hdr = jwt.get_unverified_header(s["access_token"])
    jwks = {k["kid"] for k in httpx.get(f"{AUTH}/.well-known/jwks.json").json()["keys"]}
    assert hdr["alg"] == "ES256" and hdr["kid"] in jwks                                      # صادر عن Supabase Auth
    me = client.get("/me", headers=bearer(s["access_token"])).json()
    assert me["auth_user_id"] == world["g_a" if kind == "guardian" else "s_a"]                # auth.uid() = معرّف الكيان
    assert me["tenant_id"] == DEV_TENANT and me["profile_id"] is not None


def test_guardian_session_sees_own_row_and_child_only(client, world):
    s = otp_session(client, "DEV", "guardian", world["phone"])["access_token"]
    assert [g["id"] for g in rest(s, "guardians?select=id")] == [world["g_a"]]
    assert [x["id"] for x in rest(s, "students?select=id")] == [SEED_STUDENT]
    assert rest(s, f"guardians?select=id&id=eq.{world['g_b']}") == []


@pytest.mark.parametrize("kind", ["guardian", "staff"])
def test_same_contact_other_tenant_is_another_account(client, world, kind):
    contact = world["phone"] if kind == "guardian" else world["email"]
    a_id, b_id = world["g_a" if kind == "guardian" else "s_a"], world["g_b" if kind == "guardian" else "s_b"]
    request_code(client, "DEV", kind, contact)
    code_a = sent_to(client, contact)[-1]
    assert verify(client, world["b_code"], kind, contact, code_a).status_code == 401           # رمز A لا يعمل على B
    s_b = otp_session(client, world["b_code"], kind, contact)
    me_b = client.get("/me", headers=bearer(s_b["access_token"])).json()
    assert me_b["auth_user_id"] == b_id and me_b["tenant_id"] == world["b"]
    assert rest(s_b["access_token"], "students?select=id") == []                               # B لا يرى شيئاً من DEV
    assert rest(s_b["access_token"], f"profiles?select=id&platform_tenant_id=eq.{DEV_TENANT}") == []
    s_a = verify(client, "DEV", kind, contact, code_a)                                          # رمز A ما زال صالحاً في A
    assert s_a.status_code == 200
    assert client.get("/me", headers=bearer(s_a.json()["access_token"])).json()["auth_user_id"] == a_id


@pytest.mark.parametrize("contact_key", ["only_b_phone", "unknown"])
def test_no_cross_tenant_disclosure(client, world, contact_key):
    contact = world["only_b_phone"] if contact_key == "only_b_phone" else "+2019" + f"{secrets.randbelow(10**8):08d}"
    before = len(outbox(client))
    request_code(client, "DEV", "guardian", contact)                                            # الرد نفسه
    assert len(outbox(client)) == before                                                        # ولا رسالة
    r = verify(client, "DEV", "guardian", contact, "123456")
    assert (r.status_code, r.json()) == (401, {"detail": "invalid_credentials"})


def test_code_is_single_use(client, world):
    request_code(client, "DEV", "staff", world["email"])
    code = sent_to(client, world["email"])[-1]
    assert verify(client, "DEV", "staff", world["email"], code).status_code == 200
    assert verify(client, "DEV", "staff", world["email"], code).status_code == 401


@pytest.mark.parametrize("kind", ["guardian", "staff"])
def test_suspended_account_cannot_start_authentication(client, admin, world, kind):
    """I1: لا رمز، ولا جلسة حتى برمز صدر قبل الإيقاف — والرد الخارجي نفسه."""
    contact, eid = (world["phone"], world["g_a"]) if kind == "guardian" else (world["email"], world["s_a"])
    request_code(client, "DEV", kind, contact)
    earlier = sent_to(client, contact)[-1]
    admin.execute("update public.profiles set status = 'suspended' where auth_user_id = %s", [eid])
    try:
        before = len(outbox(client))
        request_code(client, "DEV", kind, contact)
        assert len(outbox(client)) == before
        assert verify(client, "DEV", kind, contact, earlier).status_code == 401
        assert password(client, "DEV", kind, contact, "whatever-1").status_code == 401
    finally:
        admin.execute("update public.profiles set status = 'active' where auth_user_id = %s", [eid])


@pytest.mark.parametrize("kind", ["guardian", "staff"])
def test_password_flow_lock_and_otp_unlock(client, admin, world, kind):
    contact, eid = (world["phone"], world["g_a"]) if kind == "guardian" else (world["email"], world["s_a"])
    token = otp_session(client, "DEV", kind, contact)["access_token"]
    pw = "Mine-" + secrets.token_hex(4)
    assert httpx.put(f"{AUTH}/user", headers={**PUB, **bearer(token)}, json={"password": pw}).status_code == 200
    assert password(client, "DEV", kind, contact, pw).status_code == 200
    assert password(client, world["b_code"], kind, contact, pw).status_code == 401                 # الكلمة نفسها على B
    for _ in range(5):
        assert password(client, "DEV", kind, contact, "wrong-password").status_code == 401
    assert password(client, "DEV", kind, contact, pw).status_code == 401                           # مقفل
    table = "guardians" if kind == "guardian" else "staff"
    assert admin.execute(f"select locked_until > now() as l from public.{table} where id = %s", [eid]).fetchone()["l"]
    client.app.state.login_limiter.reset()               # حد المحاولات طبقة مستقلة (له اختباره) — هنا القفل وحده
    otp_session(client, "DEV", kind, contact)                                                       # PLAN §7.8: فك القفل بـOTP
    assert password(client, "DEV", kind, contact, pw).status_code == 200


def test_client_receives_only_session_fields(client, world):
    request_code(client, "DEV", "guardian", world["phone"])
    r = verify(client, "DEV", "guardian", world["phone"], sent_to(client, world["phone"])[-1])
    body = r.text
    assert set(r.json()) == set(SESSION_FIELDS)
    for leak in ("hashed_token", "action_link", "email_otp", ".smas.invalid", ENV["SUPABASE_SECRET_KEY"]):
        assert leak not in body


def test_otp_request_rate_limit_is_the_same_for_existing_and_unknown(client, world):
    for contact in (world["phone"], "+2018" + f"{secrets.randbelow(10**8):08d}"):
        client.app.state.login_limiter.reset()
        codes = [client.post("/auth/otp/request", json={"tenant": "DEV", "kind": "guardian", "contact": contact}).status_code
                 for _ in range(11)]
        assert codes[:10] == [202] * 10 and codes[10] == 429
