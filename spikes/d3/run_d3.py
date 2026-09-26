"""D3 Spike — الدورة الكاملة ومعايير النجاح الثمانية (docs/F2_AUTHENTICATION.md §4).

  cd services/api && .venv/Scripts/python ../../spikes/d3/run_d3.py

يفترض seed E5 و spikes/d3/setup.sql. «الخادم» هنا وحدة Python تمثّل ما سيكون في FastAPI:
  request_otp(tenant, phone)       ← استجابة واحدة دائماً؛ الرمز يُرسل فقط إن وُجد حساب في ذلك الـTenant
  verify_otp(tenant, phone, code)  ← تحقق + محاولات + قفل ← Admin generate_link (magiclink، لا يُرسل شيئاً)
                                     ← POST /verify بالـtoken_hash ← الجلسة يصدرها Supabase Auth نفسه
  password_login(tenant, phone, pw) ← الحساب ← password grant بالبريد الاصطناعي
لا JWT يُصنع هنا. المتصفح لا يرى إلا حقول الجلسة.
"""

import hashlib
import json
import os
import pathlib
import secrets
import sys
import uuid

import httpx
import jwt
import psycopg
from cryptography.hazmat.primitives.asymmetric import ec
from psycopg.rows import dict_row

API = pathlib.Path(__file__).resolve().parents[2] / "services" / "api"
sys.path[:0] = [str(API), str(API / "tests")]
os.chdir(API)

from conftest import ENV  # noqa: E402 — البيئة من `supabase status`
from fastapi.testclient import TestClient  # noqa: E402
from app.main import app  # noqa: E402

AUTH = f"{ENV['SUPABASE_URL']}/auth/v1"
REST = f"{ENV['SUPABASE_URL']}/rest/v1"
PUB = {"apikey": ENV["SUPABASE_PUBLISHABLE_KEY"]}
SEC = {"apikey": ENV["SUPABASE_SECRET_KEY"]}
SESSION_FIELDS = ("access_token", "refresh_token", "expires_in", "token_type")
out: list[str] = []


def note(key, value):
    line = f"D3.{key} = {value}"
    out.append(line)
    print(line)


db = psycopg.connect(ENV["TEST_ADMIN_DB_URL"], autocommit=True, row_factory=dict_row)
client = TestClient(app, raise_server_exceptions=False).__enter__()
sent: list[tuple[str, str]] = []            # مرسل اختبار: (هاتف، رمز)


def email_of(account):
    return f"{account}@guardians.smas.invalid"


# ---------------- «الخادم» ----------------

def resolve(tenant, phone):
    return db.execute("select * from spike_d3.resolve(%s, %s)", [tenant, phone]).fetchone()


def request_otp(tenant, phone):
    acct = resolve(tenant, phone)
    if acct and not acct["locked"]:
        code, salt = f"{secrets.randbelow(10**6):06d}", secrets.token_hex(8)
        db.execute("insert into spike_d3.otp (tenant_id, phone_e164, account_id, salt, code_hash, expires_at)"
                   " values (%s, %s, %s, %s, %s, now() + interval '5 minutes')",
                   [acct["tenant_id"], phone, acct["account_id"], salt, hashlib.sha256((salt + code).encode()).hexdigest()])
        sent.append((phone, code))
    return {"status": "sent"}                                          # الاستجابة نفسها دائماً


def issue_session(account):
    link = httpx.post(f"{AUTH}/admin/generate_link", headers=SEC, json={"type": "magiclink", "email": email_of(account)})
    if link.status_code != 200:
        return None
    r = httpx.post(f"{AUTH}/verify", headers=PUB, json={"type": "magiclink", "token_hash": link.json()["hashed_token"]})
    return {k: r.json()[k] for k in SESSION_FIELDS} if r.status_code == 200 else None


def verify_otp(tenant, phone, code):
    acct = resolve(tenant, phone)
    if not acct or acct["locked"]:
        return None
    ch = db.execute("select * from spike_d3.otp where tenant_id = %s and phone_e164 = %s and consumed_at is null"
                    " and expires_at > now() order by id desc limit 1", [acct["tenant_id"], phone]).fetchone()
    if not ch or ch["account_id"] != acct["account_id"]:
        return None
    if hashlib.sha256((ch["salt"] + code).encode()).hexdigest() != ch["code_hash"]:
        db.execute("update spike_d3.otp set attempts = attempts + 1 where id = %s", [ch["id"]])
        g = db.execute("update public.guardians set failed_login_count = failed_login_count + 1,"
                       " locked_until = case when failed_login_count + 1 >= 5 then now() + interval '15 minutes' end"
                       " where id = %s returning failed_login_count", [acct["guardian_id"]]).fetchone()
        return None
    db.execute("update spike_d3.otp set consumed_at = now() where id = %s", [ch["id"]])
    db.execute("update public.guardians set failed_login_count = 0, locked_until = null, last_login_at = now() where id = %s",
               [acct["guardian_id"]])
    return issue_session(acct["account_id"])


def password_login(tenant, phone, password):
    acct = resolve(tenant, phone)
    email = email_of(acct["account_id"] if acct and not acct["locked"] else uuid.uuid4())
    r = httpx.post(f"{AUTH}/token?grant_type=password", headers=PUB, json={"email": email, "password": password})
    return {k: r.json()[k] for k in SESSION_FIELDS} if (acct and r.status_code == 200) else None


# ---------------- أدوات فحص ----------------

def me(tok):
    return client.get("/me", headers={"Authorization": f"Bearer {tok}"}).json()


def rest(tok, path):
    r = httpx.get(f"{REST}/{path}", headers={**PUB, "Authorization": f"Bearer {tok}"})
    return r.json() if r.status_code == 200 else f"HTTP {r.status_code}"


def last_code(phone):
    return next(c for p, c in reversed(sent) if p == phone)


# ---------------- Fixture: الهاتف نفسه في Tenantين ----------------
P = "+2015" + f"{secrets.randbelow(10**8):08d}"                        # في A و B
Q = "+2016" + f"{secrets.randbelow(10**8):08d}"                        # في B فقط
DEV = "d0000000-0000-4000-8000-000000000001"
B_CODE = "SPK" + secrets.token_hex(2).upper()
B = db.execute("insert into public.platform_tenants (tenant_code, name) values (%s, 'Spike B') returning id", [B_CODE]).fetchone()["id"]


def new_guardian(tenant, phone, link_seed_student=False):
    gid = db.execute("insert into public.guardians (platform_tenant_id, first_name, family_name, phone_e164)"
                     " values (%s, 'G', 'D3', %s) returning id", [tenant, phone]).fetchone()["id"]
    if link_seed_student:
        db.execute("insert into public.student_guardians (student_id, guardian_id, platform_tenant_id, relationship_type,"
                   " is_primary, receives_whatsapp, can_pickup, status, effective_from)"
                   " values ('e0000000-0000-4000-8000-000000000001', %s, %s, 'mother', false, false, false, 'active', '2026-09-01')",
                   [gid, tenant])
    r = httpx.post(f"{AUTH}/admin/users", headers=SEC, json={"id": str(gid), "email": email_of(gid), "email_confirm": True})
    db.execute("select spike_d3.bind_guardian(%s, %s, %s)", [tenant, gid, gid])
    return str(gid), r.status_code


gA, stA = new_guardian(DEV, P, link_seed_student=True)
gB, stB = new_guardian(B, P)
gQ, stQ = new_guardian(B, Q)

# 1. الهاتف نفسه ⇒ حسابان في Tenantين
note("1.create_A_B(status)", (stA, stB))
note("1.auth_users_phone_column", [r["phone"] for r in db.execute("select phone from auth.users where id in (%s, %s)", [gA, gB])])
note("1.distinct_accounts", gA != gB)

# 2. A لا يعرف وجود الهاتف في B
n = len(sent)
note("2.request_A_phone_only_in_B", request_otp("DEV", Q))
note("2.request_A_phone_in_A", request_otp("DEV", P))
note("2.messages_sent(Q in A, P in A)", ([p for p, _ in sent[n:]].count(Q), [p for p, _ in sent[n:]].count(P)))
note("2.account_creation_in_B_never_blocked", stB == 200 and stQ == 200)

# 3. رمز A لا يعمل على B
code_a = last_code(P)
note("3.code_A_on_B", verify_otp(B_CODE, P, code_a))
request_otp(B_CODE, P)
code_b = last_code(P)
note("3.code_A_on_B_after_B_request", verify_otp(B_CODE, P, code_a) if code_a != code_b else "skip(same code)")
sA = verify_otp("DEV", P, code_a)
note("3.code_A_on_A.session_fields", sorted(sA) if sA else None)
note("3.session_A.sub==account_A", jwt.decode(sA["access_token"], options={"verify_signature": False})["sub"] == gA)
note("3.code_single_use", verify_otp("DEV", P, code_a))
sB = verify_otp(B_CODE, P, code_b)
note("3.code_B_on_B.sub==account_B", sB is not None and jwt.decode(sB["access_token"], options={"verify_signature": False})["sub"] == gB)

# 4. جلسة A لا تصل إلى B
mA, mB = me(sA["access_token"]), me(sB["access_token"])
note("4.me_A.tenant", mA["tenant_id"] == DEV and mA["profile_id"] is not None)
note("4.me_B.tenant", str(mB["tenant_id"]) == str(B))
note("4.A.guardians_visible", [g["id"] for g in rest(sA["access_token"], "guardians?select=id")] == [gA])
note("4.A.sees_B_guardian", rest(sA["access_token"], f"guardians?select=id&id=eq.{gB}"))
note("4.A.sees_B_profiles", rest(sA["access_token"], f"profiles?select=id&platform_tenant_id=eq.{B}"))
note("4.A.children(students)", len(rest(sA["access_token"], "students?select=id")))
note("4.B.students", len(rest(sB["access_token"], "students?select=id")))
note("4.B.sees_A_guardian", rest(sB["access_token"], f"guardians?select=id&id=eq.{gA}"))

# 5. القفل والإلغاء
for _ in range(5):
    request_otp("DEV", P)
    verify_otp("DEV", P, "000000" if last_code(P) != "000000" else "111111")
lock = db.execute("select failed_login_count, locked_until > now() as locked from public.guardians where id = %s", [gA]).fetchone()
note("5a.after_5_wrong_codes", (lock["failed_login_count"], lock["locked"]))
n = len(sent)
request_otp("DEV", P)
note("5a.locked_request_sends_nothing", len(sent) == n)
note("5a.locked_verify_with_old_valid_code", verify_otp("DEV", P, code_a))
db.execute("update public.guardians set failed_login_count = 0, locked_until = null where id = %s", [gA])
r = httpx.put(f"{AUTH}/admin/users/{gA}", headers=SEC, json={"ban_duration": "24h"})
note("5b.auth_ban", r.status_code)
request_otp("DEV", P)
note("5b.banned_verify_session", verify_otp("DEV", P, last_code(P)))
rr = httpx.post(f"{AUTH}/token?grant_type=refresh_token", headers=PUB, json={"refresh_token": sA["refresh_token"]})
note("5b.banned_refresh", rr.status_code)
httpx.put(f"{AUTH}/admin/users/{gA}", headers=SEC, json={"ban_duration": "none"})
db.execute("update public.profiles set status = 'suspended' where auth_user_id = %s", [gA])
request_otp("DEV", P)
sS = verify_otp("DEV", P, last_code(P))
note("5c.suspended_profile.session_but_context", (sS is not None, me(sS["access_token"])["profile_id"] if sS else None,
                                                  len(rest(sS["access_token"], "students?select=id")) if sS else None))
db.execute("update public.profiles set status = 'active' where auth_user_id = %s", [gA])

# 6. كلمة المرور للحساب نفسه
tok = sS["access_token"] if sS else verify_otp("DEV", P, last_code(P))["access_token"]
pw = "Guardian-" + secrets.token_hex(4)
note("6.user_sets_password", httpx.put(f"{AUTH}/user", headers={**PUB, "Authorization": f"Bearer {tok}"}, json={"password": pw}).status_code)
pA = password_login("DEV", P, pw)
note("6.password_login_A", pA is not None and me(pA["access_token"])["tenant_id"] == DEV)
note("6.same_password_on_B", password_login(B_CODE, P, pw))
note("6.phone_only_in_B_on_A", password_login("DEV", Q, pw))

# 7. لا service_role في المتصفح
returned = json.dumps([sA, sB, pA])
note("7.client_sees_only_session_fields", all(set(x) == set(SESSION_FIELDS) for x in (sA, sB, pA)))
note("7.no_admin_material_in_responses", not any(s in returned for s in ("hashed_token", "action_link", "email_otp", ENV["SUPABASE_SECRET_KEY"], "guardians.smas.invalid")))

# 8. لا JWT خارج Supabase Auth
jwks = httpx.get(f"{AUTH}/.well-known/jwks.json").json()["keys"]
hdr = jwt.get_unverified_header(sA["access_token"])
note("8.token_alg_kid_in_jwks", (hdr["alg"], hdr["kid"] in {k["kid"] for k in jwks}))
note("8.fastapi_accepts_supabase_token", client.get("/me", headers={"Authorization": f"Bearer {sA['access_token']}"}).status_code)
forged_claims = jwt.decode(sA["access_token"], options={"verify_signature": False})
own_key = ec.generate_private_key(ec.SECP256R1())
forged_es = jwt.encode(forged_claims, own_key, algorithm="ES256", headers={"kid": hdr["kid"]})
forged_hs = jwt.encode(forged_claims, "x" * 40, algorithm="HS256")
note("8.forged_ES256_same_kid(fastapi,postgrest)", (client.get("/me", headers={"Authorization": f"Bearer {forged_es}"}).status_code,
                                                    rest(forged_es, "students?select=id")))
note("8.forged_HS256(fastapi,postgrest)", (client.get("/me", headers={"Authorization": f"Bearer {forged_hs}"}).status_code,
                                           rest(forged_hs, "students?select=id")))
src = pathlib.Path(__file__).read_text(encoding="utf-8")
signing = [ln.strip() for ln in src.splitlines() if "jwt.encode(" in ln and "signing = " not in ln]
note("8.spike_signs_only_the_two_forged_tokens", len(signing) == 2 and all("own_key" in ln or '"x" * 40' in ln for ln in signing))

# إضافات: التجديد، وإعادة استعمال رابط الجلسة
rr = httpx.post(f"{AUTH}/token?grant_type=refresh_token", headers=PUB, json={"refresh_token": pA["refresh_token"]})
note("x.refresh", (rr.status_code, rr.status_code == 200 and jwt.decode(rr.json()["access_token"], options={"verify_signature": False})["sub"] == gA))
link = httpx.post(f"{AUTH}/admin/generate_link", headers=SEC, json={"type": "magiclink", "email": email_of(gA)}).json()["hashed_token"]
first = httpx.post(f"{AUTH}/verify", headers=PUB, json={"type": "magiclink", "token_hash": link}).status_code
again = httpx.post(f"{AUTH}/verify", headers=PUB, json={"type": "magiclink", "token_hash": link}).status_code
note("x.magiclink_single_use", (first, again))
note("x.auth_audit_actions_A", sorted({r["a"] for r in db.execute(
    "select payload->>'action' a from auth.audit_log_entries where payload->>'actor_id' = %s", [gA])}))

pathlib.Path(__file__).with_name("out").mkdir(exist_ok=True)
pathlib.Path(__file__).with_name("out").joinpath("d3.txt").write_text("\n".join(out), encoding="utf-8")
