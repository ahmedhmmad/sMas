"""F3 — سياق الـhost: القواعد (متجهات مشتركة مع الواجهة وقيود DB)، CORS المرسَّخ، سياق الدخول من `Origin` وحده،
لا context drift من الجسم، لا كشف وجود، والسياق ليس تفويضاً.

    Origin → أين يُبحث · JWT → من المستخدم · DB/RLS → ما يصل إليه
"""

import base64
import json
import pathlib
import secrets
import uuid
from types import SimpleNamespace

import httpx
import psycopg
import pytest

from app import config
from app.auth_admin import account_email
from app.deps import login_context
from app import student_login
from app.host_context import RESERVED, SCHOOL_SLUG, TENANT_LABEL, HostContext, OriginBase, parse_host
from conftest import DEV_PASSWORD, ENV, STAFF_ID, auth, origin

ROOT = pathlib.Path(__file__).resolve().parents[3]
VECTORS = json.loads((ROOT / "docs/contracts/host_context_vectors.json").read_text(encoding="utf-8"))
AUTH = f"{ENV['SUPABASE_URL']}/auth/v1"
SEC = {"apikey": ENV["SUPABASE_SECRET_KEY"]}
SEED_OFFICIAL = "30101010100000"
SECRETARY_EMAIL = "secretary@dev.smas.test"
INVALID = (401, {"detail": "invalid_credentials"})


def _ctx(expected):
    return None if expected is None else HostContext(**expected)


def sub(session: dict) -> str:
    payload = session["access_token"].split(".")[1]
    return json.loads(base64.urlsafe_b64decode(payload + "=" * (-len(payload) % 4)))["sub"]


def staff_login(client, headers, email=SECRETARY_EMAIL, password=DEV_PASSWORD):
    return client.post("/auth/password/login", headers=headers, json={"kind": "staff", "contact": email, "password": password})


def outcome(r):
    return r.status_code, r.json()


# ======================= 1. القواعد: متجهات مشتركة =======================

@pytest.mark.parametrize("host,expected", VECTORS["hosts"]["cases"])
def test_host_rules(host, expected):
    assert parse_host(host, VECTORS["hosts"]["base"]) == _ctx(expected)


@pytest.mark.parametrize("section", ["origins", "production_origins"])
def test_origin_rules_are_the_host_rules(section):
    base = OriginBase.parse(VECTORS[section]["base"])
    for value, expected in VECTORS[section]["cases"]:
        assert base.context(value) == _ctx(expected), value


@pytest.mark.parametrize("value", VECTORS["bad_bases"])
def test_unanchored_or_wildcard_base_is_refused(value):
    with pytest.raises(ValueError):
        OriginBase.parse(value)


def test_base_is_required(monkeypatch):
    monkeypatch.delenv("API_CORS_ORIGIN_BASE")
    with pytest.raises(KeyError):
        config.origin_base()


def test_db_label_rule_is_the_same_rule(admin):
    """قيد M30 يقبل ما يقبله المحلل بالضبط — لا «hostname مقبول» لا يُخزَّن، ولا label مخزَّن لا يُحلَّل."""
    def db_accepts(label):
        try:
            with admin.transaction(force_rollback=True):
                admin.execute("insert into public.platform_tenants (tenant_code, host_label, name) values (%s, %s, 'x')",
                              ["ZV" + secrets.token_hex(3).upper(), label])
            return True
        except psycopg.errors.CheckViolation:
            return False

    labels = VECTORS["tenant_labels"]["valid"] + VECTORS["tenant_labels"]["invalid"]
    assert {x: db_accepts(x) for x in labels} == \
           {x: TENANT_LABEL.fullmatch(x) is not None and x not in RESERVED for x in labels} == \
           {x: x in VECTORS["tenant_labels"]["valid"] for x in labels}


def test_db_school_slug_rule_is_the_same_rule(admin):
    """M30b: قيد `schools_slug_chk` = قاعدة slug في المحلل — كل slug يقبله DB صالح كـlabel في الـhost، والعكس."""
    def db_accepts(slug):
        code = "ZS" + secrets.token_hex(3).upper()
        try:
            with admin.transaction(force_rollback=True):
                # Tenant خاص بالمعاملة: لا تصادم تفرد مع slugs الـseed — القيد المختبَر هو الصيغة وحدها
                tenant = admin.execute("insert into public.platform_tenants (tenant_code, host_label, name) values (%s, %s, 'x')"
                                       " returning id", [code, code.lower()]).fetchone()["id"]
                admin.execute("insert into public.schools (platform_tenant_id, school_code, name, slug) values (%s, 'S1', 'x', %s)",
                              [tenant, slug])
            return True
        except psycopg.errors.CheckViolation:
            return False

    slugs = VECTORS["school_slugs"]["valid"] + VECTORS["school_slugs"]["invalid"]
    assert {x: db_accepts(x) for x in slugs} == \
           {x: SCHOOL_SLUG.fullmatch(x) is not None for x in slugs} == \
           {x: x in VECTORS["school_slugs"]["valid"] for x in slugs}


# ======================= 2. CORS مرسَّخ =======================

def preflight(client, value):
    return client.options("/me/capabilities", headers={"Origin": value, "Access-Control-Request-Method": "GET",
                                                        "Access-Control-Request-Headers": "authorization"})


@pytest.mark.parametrize("value", ["http://school-a.dev.localhost:4173", "http://dev.localhost:4173", "http://admin.localhost:4173"])
def test_cors_allows_the_three_host_shapes(client, value):
    assert preflight(client, value).headers.get("access-control-allow-origin") == value
    r = client.get("/health", headers={"Origin": value})
    assert r.headers.get("access-control-allow-origin") == value and "Origin" in r.headers.get("vary", "")


@pytest.mark.parametrize("value", ["http://evil-localhost:4173", "http://localhost.evil.com:4173",
                                   "http://school-a.dev.localhost.evil.com:4173", "http://localhost:4173",
                                   "http://api.localhost:4173", "https://dev.localhost:4173", "http://dev.localhost:5173",
                                   "http://a.school-a.dev.localhost:4173", "*", "null"])
def test_cors_refuses_lookalikes(client, value):
    assert "access-control-allow-origin" not in preflight(client, value).headers
    assert "access-control-allow-origin" not in client.get("/health", headers={"Origin": value}).headers


# ======================= 3. سياق الدخول من Origin وحده =======================

LOGIN_BODIES = {
    "/auth/student/login": {"identifier": SEED_OFFICIAL, "password": DEV_PASSWORD},
    "/auth/otp/request": {"kind": "staff", "contact": SECRETARY_EMAIL},
    "/auth/otp/verify": {"kind": "staff", "contact": SECRETARY_EMAIL, "code": "000000"},
    "/auth/password/login": {"kind": "staff", "contact": SECRETARY_EMAIL, "password": DEV_PASSWORD},
}
DRIFT = [{"school": "school-b"}, {"tenant": "dev"}, {"school_id": str(uuid.uuid4()), "tenant_id": str(uuid.uuid4())}]


@pytest.mark.parametrize("path", list(LOGIN_BODIES))
@pytest.mark.parametrize("extra", DRIFT, ids=["school", "tenant", "ids"])
def test_no_context_drift_from_the_body(client, path, extra):
    """Origin = School A + جسم يسمّي غيرها ← رفض (الحقول غير موجودة في الـschema أصلاً)، لا اختيار أحدهما."""
    r = client.post(path, headers=origin("dev", "school-a"), json={**LOGIN_BODIES[path], **extra})
    assert r.status_code == 422
    assert any(e["type"] == "extra_forbidden" for e in r.json()["detail"])


def test_login_schemas_have_no_context_fields(client):
    schemas = client.get("/openapi.json").json()["components"]["schemas"]
    for name in ("StudentLogin", "OtpRequest", "OtpVerify", "PasswordLogin"):
        props = set(schemas[name]["properties"])
        assert not props & {"tenant", "school", "tenant_id", "school_id", "tenant_code", "host"}, name
        assert schemas[name].get("additionalProperties") is False, name


@pytest.mark.parametrize("value,expected", [
    ("http://school-a.dev.localhost:4173", HostContext("school", "dev", "school-a")),
    ("http://dev.localhost:4173", HostContext("tenant", "dev")),
    ("http://admin.localhost:4173", None),                   # المنصة ليست سياق دخول Tenant
    (None, None),
])
def test_login_context_contract(client, value, expected):
    """عقد الاعتمادية نفسها (دفاع أول): المنصة والغياب ← None. قاعدة البيانات دفاع ثانٍ (login_context بلا Tenant ← لا شيء)."""
    request = SimpleNamespace(app=client.app, headers={} if value is None else {"origin": value})
    assert login_context(request) == expected


SEED_STUDENT = "e0000000-0000-4000-8000-000000000001"


@pytest.mark.parametrize("ctx", [HostContext("tenant", "dev"), HostContext("platform")], ids=["tenant_host", "admin_host"])
def test_student_login_requires_a_school_host_in_fastapi_itself(client, monkeypatch, ctx):
    """Defense-in-depth invariant (مراجعة F3): FastAPI نفسه يرفض دخول الطالب خارج host مدرسة — لا بالمصادفة من DB.
    الطبقتان الأخريان مستبدلتان بما **كان سيسمح** بالدخول: الاعتمادية تمرر السياق كما هو (حتى المنصة)، والبحث في DB
    يُحَل إلى طالب الـseed أياً كان السياق. الفحص الصريح وحده يمنعه — وإزالته تُفشل هذا الاختبار."""
    looked_up = []
    monkeypatch.setattr(student_login, "resolve", lambda db, c, body: looked_up.append(c) or uuid.UUID(SEED_STUDENT))
    body = {"identifier": SEED_OFFICIAL, "password": DEV_PASSWORD}
    try:
        client.app.dependency_overrides[login_context] = lambda: ctx
        refused = client.post("/auth/student/login", json=body)
        client.app.dependency_overrides[login_context] = lambda: HostContext("school", "dev", "school-a")   # ضابط
        control = client.post("/auth/student/login", json=body)
    finally:
        client.app.dependency_overrides.pop(login_context, None)
    assert outcome(refused) == INVALID
    assert looked_up == [HostContext("school", "dev", "school-a")]      # لم يُبحث عن الطالب خارج host مدرسة أصلاً
    assert control.status_code == 200                                    # البدائل كانت ستسمح فعلاً


def test_student_context_comes_from_the_origin(client):
    body = LOGIN_BODIES["/auth/student/login"]
    assert client.post("/auth/student/login", headers=origin("dev", "school-a"), json=body).status_code == 200
    for headers in (origin("dev"),                                               # سياق Tenant: لا مدرسة
                    {"Origin": "http://admin.localhost:4173"},                   # المنصة
                    {},                                                          # بلا Origin
                    {"Origin": "http://school-a.dev.localhost.evil.com:4173"},   # خارج الأصل الأساسي
                    {"Host": "school-a.dev.localhost:4173"},                     # Host ليس مصدر السياق
                    {"Origin": "http://school-a.dev.localhost:4174"}):
        client.app.state.login_limiter.reset()
        assert outcome(client.post("/auth/student/login", headers=headers, json=body)) == INVALID, headers


@pytest.mark.parametrize("headers", [{}, {"Origin": "http://admin.localhost:4173"}, {"Origin": "https://evil.test"}],
                         ids=["none", "platform", "foreign"])
def test_no_context_fails_like_everything_else(client, headers):
    before = len(client.app.state.otp_sender.messages)
    r = client.post("/auth/otp/request", headers=headers, json=LOGIN_BODIES["/auth/otp/request"])
    assert outcome(r) == (202, {"status": "sent"}) and len(client.app.state.otp_sender.messages) == before
    assert outcome(client.post("/auth/otp/verify", headers=headers, json=LOGIN_BODIES["/auth/otp/verify"])) == INVALID
    assert outcome(staff_login(client, headers)) == INVALID
    assert staff_login(client, origin()).status_code == 200                      # ضابط: السياق الصحيح


# ======================= 4. الـslug نفسه في Tenantين، وسياق غير صالح =======================

@pytest.fixture(scope="module")
def tenant_b(admin):
    """Tenant B بمدرسة slug‏ school-a (كـDEV) وموظف بالبريد نفسه لسكرتير DEV — وكلمة مرور مختلفة."""
    code = "F3" + secrets.token_hex(2).upper()
    label, pw, sid = code.lower(), "F3-" + secrets.token_hex(6), str(uuid.uuid4())
    b = str(admin.execute("insert into public.platform_tenants (tenant_code, host_label, name) values (%s, %s, 'F3 B') returning id",
                          [code, label]).fetchone()["id"])
    school = str(admin.execute("insert into public.schools (platform_tenant_id, school_code, name, slug) values (%s, 'SA', 'SA', 'school-a')"
                               " returning id", [b]).fetchone()["id"])
    r = httpx.post(f"{AUTH}/admin/users", headers=SEC,
                   json={"id": sid, "email": account_email("staff", sid), "password": pw, "email_confirm": True})
    assert r.status_code == 200, r.text
    admin.execute("insert into public.auth_identities (auth_user_id, kind) values (%s, 'tenant')", [sid])
    p = admin.execute("insert into public.profiles (platform_tenant_id, auth_user_id, display_name) values (%s, %s, 'b') returning id",
                      [b, sid]).fetchone()["id"]
    admin.execute("insert into public.staff (id, platform_tenant_id, employee_code, first_name, family_name, email, profile_id)"
                  " values (%s, %s, 'B1', 'S', 'B', %s, %s)", [sid, b, SECRETARY_EMAIL, p])
    return {"id": b, "label": label, "school": school, "staff": sid, "password": pw}


def test_same_slug_in_two_tenants_does_not_collide(client, tenant_b):
    a = staff_login(client, origin("dev", "school-a"))
    b = staff_login(client, origin(tenant_b["label"], "school-a"), password=tenant_b["password"])
    assert a.status_code == b.status_code == 200
    assert sub(a.json()) == STAFF_ID["secretary"] and sub(b.json()) == tenant_b["staff"]
    # كل حساب في سياقه وحده: كلمة مرور A على host B والعكس ← الفشل العام
    assert outcome(staff_login(client, origin(tenant_b["label"], "school-a"))) == INVALID
    assert outcome(staff_login(client, origin("dev", "school-a"), password=tenant_b["password"])) == INVALID


def test_invalid_operational_context_fails_identically(client, admin, tenant_b):
    """مدرسة مؤرشفة، مدرسة غير موجودة، Tenant غير موجود، Tenant موقوف — الرد نفسه تماماً كالكلمة الخاطئة."""
    label, pw = tenant_b["label"], tenant_b["password"]
    wrong = outcome(staff_login(client, origin(label), password="not-it"))
    assert wrong == INVALID
    cases = {"unknown_school": origin(label, "nope"), "unknown_tenant": origin("f3-nosuch", "school-a")}
    admin.execute("update public.schools set status = 'archived', archived_at = now() where id = %s", [tenant_b["school"]])
    try:
        cases["archived_school"] = outcome(staff_login(client, origin(label, "school-a"), password=pw))
        assert staff_login(client, origin(label), password=pw).status_code == 200      # ضابط: host الـTenant ما زال صالحاً
    finally:
        admin.execute("update public.schools set status = 'active', archived_at = null where id = %s", [tenant_b["school"]])
    admin.execute("update public.platform_tenants set status = 'suspended', suspended_at = now() where id = %s", [tenant_b["id"]])
    try:
        cases["suspended_tenant"] = outcome(staff_login(client, origin(label, "school-a"), password=pw))
    finally:
        admin.execute("update public.platform_tenants set status = 'active', suspended_at = null where id = %s", [tenant_b["id"]])
    for name in ("unknown_school", "unknown_tenant"):
        cases[name] = outcome(staff_login(client, cases[name], password=pw))
    assert cases == dict.fromkeys(cases, wrong)
    assert staff_login(client, origin(label, "school-a"), password=pw).status_code == 200  # ضابط: بعد الاستعادة


def test_otp_in_an_invalid_context_sends_nothing(client, admin, tenant_b):
    msgs = client.app.state.otp_sender.messages
    body = {"kind": "staff", "contact": SECRETARY_EMAIL}
    admin.execute("update public.schools set status = 'archived', archived_at = now() where id = %s", [tenant_b["school"]])
    try:
        before = len(msgs)
        r = client.post("/auth/otp/request", headers=origin(tenant_b["label"], "school-a"), json=body)
        assert outcome(r) == (202, {"status": "sent"}) and len(msgs) == before
    finally:
        admin.execute("update public.schools set status = 'active', archived_at = null where id = %s", [tenant_b["school"]])
    before = len(msgs)
    assert client.post("/auth/otp/request", headers=origin(tenant_b["label"], "school-a"), json=body).status_code == 202
    assert len(msgs) == before + 1                                                          # ضابط: السياق الصالح يرسل


# ======================= 5. السياق ليس تفويضاً =======================

def test_context_is_not_authorization(client, ids):
    """سكرتير SA يدخل من host المدرسة SB: السياق SB، لكن RLS لا تعطيه SB وتبقي له SA — كأنه دخل من host الـTenant."""
    via_sb = staff_login(client, origin("dev", "school-b"))
    via_tenant = staff_login(client, origin("dev"))
    assert via_sb.status_code == via_tenant.status_code == 200 and sub(via_sb.json()) == sub(via_tenant.json())
    sa, sb = ids["school"]["SA"], ids["school"]["SB"]
    results = []
    for session in (via_sb.json(), via_tenant.json()):
        bearer = {"Authorization": f"Bearer {session['access_token']}"}
        results.append([(r.status_code, r.json()) for r in (
            client.get(f"/schools/{sb}/students", headers=bearer),
            client.get(f"/schools/{sa}/students", headers=bearer),
            client.get("/me/capabilities", headers=bearer),
        )])
    assert results[0] == results[1]
    assert results[0][0][0] == 404 and results[0][1][0] == 200


@pytest.mark.parametrize("path", ["/me", "/me/capabilities", "/schools/{SB}/students", "/schools/{SB}/students/export"])
def test_origin_changes_no_data_response(client, ids, path):
    """طلبات البيانات لا تقرأ Origin: host المدرسة الهدف لا يغيّر الرد."""
    url = path.replace("{SB}", ids["school"]["SB"])
    plain = client.get(url, headers=auth("secretary"))
    for o in (origin("dev", "school-b"), origin("dev"), {"Origin": "http://admin.localhost:4173"}):
        r = client.get(url, headers=auth("secretary", **o))
        assert (r.status_code, r.content) == (plain.status_code, plain.content), (url, o)


def test_only_login_reads_the_context():
    """حارس بنيوي: Origin يقرؤه login_context وحده، ولا يستدعيه إلا مسارا الدخول؛ ولا ترويسة أخرى غير Authorization."""
    app_dir = ROOT / "services/api/app"
    src = {p.name: p.read_text(encoding="utf-8") for p in app_dir.glob("*.py")}
    assert {n for n, s in src.items() if "headers.get(" in s} == {"deps.py", "security.py"}
    assert {n for n, s in src.items() if "login_context" in s} == {"deps.py", "student_login.py", "account_login.py"}
    assert {n for n, s in src.items() if ".context(" in s} == {"deps.py", "main.py"}   # login_context + CORS
