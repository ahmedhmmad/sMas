"""اختبارات F4 على Supabase المحلي مع seed التطوير (E5).

البيئة: إن لم تُضبط المتغيرات تُقرأ من `npx supabase status -o env`. الخدمة تتصل بدور `authenticator`
(كما في الإنتاج)؛ اتصال `postgres` هنا للاختبار فقط: قراءة المعرّفات، عدّ صفوف التدقيق، وتهيئة حالات
(إيقاف Tenant، سحب إسناد Platform Admin) تُعاد في نهاية كل اختبار.
"""

import json
import os
import pathlib
import subprocess
from contextlib import contextmanager

import httpx
import psycopg
import pytest
from fastapi.testclient import TestClient
from psycopg.rows import dict_row

ROOT = pathlib.Path(__file__).resolve().parents[3]
DEV_PASSWORD = "DevOnly-Seed-2026"        # حسابات seed التطوير فقط (E5) — لا وجود لها خارج local/CI
DEV_TENANT = "d0000000-0000-4000-8000-000000000001"
# بريد حساب Auth: المنصة و tenant_admin (bootstrap) بريد حقيقي؛ الموظفون هوية اصطناعية (D3/I2) — المعرّف = معرّف الموظف
STAFF_ID = {"school_admin": "a0000000-0000-4000-8000-000000000003", "secretary": "a0000000-0000-4000-8000-000000000004",
            "accountant": "a0000000-0000-4000-8000-000000000005", "teacher": "a0000000-0000-4000-8000-000000000006"}
EMAIL = {
    "platform": "platform@dev.smas.test",
    "tenant_admin": "tenant.admin@dev.smas.test",
    **{who: f"{sid}@staff.smas.invalid" for who, sid in STAFF_ID.items()},
}


def _load_env() -> dict[str, str]:
    if not os.environ.get("SUPABASE_URL") or not os.environ.get("TEST_ADMIN_DB_URL"):
        out = subprocess.run(
            "npx supabase status -o env", cwd=ROOT, shell=True, capture_output=True, text=True, check=True
        ).stdout
        status = {}
        for line in out.splitlines():
            key, sep, value = line.partition("=")
            if sep:
                status[key.strip()] = value.strip().strip('"')
        os.environ.setdefault("SUPABASE_URL", status["API_URL"])
        os.environ.setdefault("TEST_ADMIN_DB_URL", status["DB_URL"])
        os.environ.setdefault("TEST_ANON_KEY", status["ANON_KEY"])
        os.environ.setdefault("TEST_SERVICE_ROLE_KEY", status["SERVICE_ROLE_KEY"])
        os.environ.setdefault("SUPABASE_PUBLISHABLE_KEY", status["PUBLISHABLE_KEY"])
        os.environ.setdefault("SUPABASE_SECRET_KEY", status["SECRET_KEY"])
    # الخدمة: authenticator بكلمة مرور قاعدة البيانات المحلية
    os.environ.setdefault("API_OTP_SENDER", "local")          # D3: مرسل محلي للاختبار (القناة الحقيقية: المرحلة 5)
    os.environ.setdefault(
        "API_DATABASE_URL", os.environ["TEST_ADMIN_DB_URL"].replace("://postgres:", "://authenticator:", 1)
    )
    return dict(os.environ)


ENV = _load_env()

from app.main import app  # noqa: E402 — بعد ضبط البيئة


@pytest.fixture(scope="session")
def client():
    with TestClient(app, raise_server_exceptions=False) as c:
        yield c


@pytest.fixture(autouse=True)
def _fresh_login_limits(client):
    """حدّ محاولات الدخول لكل اختبار على حدة (اختبار الحد نفسه يملؤه عمداً)."""
    client.app.state.login_limiter.reset()


@pytest.fixture(scope="session")
def admin():
    with psycopg.connect(ENV["TEST_ADMIN_DB_URL"], autocommit=True, row_factory=dict_row) as conn:
        yield conn


@pytest.fixture(scope="session")
def ids(admin):
    schools = {r["school_code"]: str(r["id"]) for r in admin.execute(
        "select school_code, id from public.schools where platform_tenant_id = %s", [DEV_TENANT])}
    pa = admin.execute(
        "select su.id from public.system_users su join auth.users u on u.id = su.auth_user_id where u.email = %s",
        [EMAIL["platform"]]).fetchone()["id"]
    # المفتاح البريد الحقيقي: staff.email للموظفين، وبريد Auth لغيرهم
    profiles = {r["email"]: str(r["id"]) for r in admin.execute(
        "select coalesce(s.email, u.email) as email, p.id from public.profiles p join auth.users u on u.id = p.auth_user_id"
        " left join public.staff s on s.id = p.auth_user_id")}
    assert set(schools) == {"SA", "SB", "SS"}, "seed E5 مفقود — شغّل npx supabase db reset"
    return {"school": schools, "pa_system_user": str(pa), "profile": profiles, "tenant": DEV_TENANT}


_tokens: dict[str, str] = {}


def token(who: str) -> str:
    if who not in _tokens:
        r = httpx.post(
            f"{ENV['SUPABASE_URL']}/auth/v1/token?grant_type=password",
            headers={"apikey": ENV["TEST_ANON_KEY"]},
            json={"email": EMAIL[who], "password": DEV_PASSWORD},
        )
        r.raise_for_status()
        _tokens[who] = r.json()["access_token"]
    return _tokens[who]


def auth(who: str, **extra_headers: str) -> dict[str, str]:
    return {"Authorization": f"Bearer {token(who)}", **extra_headers}


class Audit:
    """صفوف audit_log الجديدة منذ لحظة الإنشاء."""

    def __init__(self, admin):
        self._admin = admin
        self._since = admin.execute("select coalesce(max(id), 0) as m from public.audit_log").fetchone()["m"]

    def new(self, **where) -> list[dict]:
        rows = self._admin.execute(
            "select * from public.audit_log where id > %s and action in ('read', 'export') order by id", [self._since]
        ).fetchall()
        return [r for r in rows if all(str(r[k]) == str(v) for k, v in where.items())]


@pytest.fixture
def audit(admin):
    return Audit(admin)


@contextmanager
def as_platform_admin(admin, pa_auth_user_id: str):
    """تنفيذ دالة متحكَّم بها باسم Platform Admin (للتهيئة فقط) — المسار نفسه الذي تفرضه الدالة."""
    with admin.transaction():
        admin.execute("set local role authenticated")
        admin.execute("select set_config('request.jwt.claims', %s, true)",
                      [json.dumps({"sub": pa_auth_user_id, "role": "authenticated"})])
        yield admin
