"""F4 §4 — `service_role` خادمي فقط، ولا يصير طريقاً لتجاوز التفويض.

الخدمة لا تحمل مفتاح service_role القديم (JWT) أصلاً؛ تتصل بـ`authenticator` وتبدّل إلى دور `service_role` في
ثلاثة مواضع مسمّاة فقط: إدراج صف التدقيق (audit.py، F4)، حل معرّف دخول الطالب (student_login.py، D1)،
ودوال دخول حسابات Tenant قبل JWT (account_login.py، D3).
المفتاح السري لـAuth Admin API (Saga §5.4) يقرؤه auth_admin.py وحده. المفتاح المقدَّم كـBearer مرفوض في test_tokens.
"""

import pathlib
import re

from conftest import DEV_TENANT, ENV, auth

APP = pathlib.Path(__file__).resolve().parents[1] / "app"


def _sources() -> dict[str, str]:
    return {p.name: p.read_text(encoding="utf-8") for p in APP.glob("*.py")}


def test_service_does_not_read_the_service_role_key():
    for name, src in _sources().items():
        assert "SERVICE_ROLE_KEY" not in src, name


def test_secret_key_read_only_by_auth_admin():
    readers = {n for n, src in _sources().items() if "SECRET_KEY" in src}
    assert readers == {"auth_admin.py"}


def test_role_switch_to_service_role_only_in_named_places():
    switches = {n for n, src in _sources().items() if re.search(r"set_config\('role',\s*'service_role'", src)}
    assert switches == {"audit.py", "student_login.py", "account_login.py"}


def test_every_user_transaction_runs_as_authenticated():
    src = _sources()["db.py"]
    assert "set_config('role', 'authenticated', true)" in src
    assert "set_config('request.jwt.claims', %s, true)" in src


def test_responses_carry_no_credentials(client, ids):
    secrets = [ENV["TEST_SERVICE_ROLE_KEY"], ENV["SUPABASE_SECRET_KEY"], ENV["API_DATABASE_URL"], ENV["TEST_ADMIN_DB_URL"]]
    sa = ids["school"]["SA"]
    calls = [
        ("/health", {}), ("/me", auth("secretary")), (f"/schools/{sa}", auth("secretary")),
        (f"/schools/{sa}/students/export", auth("school_admin")), (f"/platform/tenants/{DEV_TENANT}", auth("platform")),
        ("/me", {"Authorization": "Bearer broken"}), ("/openapi.json", {}),
    ]
    for path, headers in calls:
        r = client.get(path, headers=headers)
        blob = r.text + str(dict(r.headers))
        assert not any(s in blob for s in secrets), path
