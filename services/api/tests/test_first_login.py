"""F2 / D2 (الخيار B) — الحساب مغلق حتى تغيير كلمة المرور الأولى، والتفعيل متحكَّم به وfail-closed."""

import uuid

import httpx
import pytest

from conftest import DEV_TENANT, ENV
from test_auth_contract import section_sa, user_put  # noqa: F401 — fixture مشتركة
from test_student_login import login, new_student

REST = f"{ENV['SUPABASE_URL']}/rest/v1"


def bearer(token):
    return {"Authorization": f"Bearer {token}"}


def state(admin, uid):
    return admin.execute("select credential_state from public.auth_identities where auth_user_id = %s", [uid]).fetchone()[
        "credential_state"]


def rows_via_postgrest(token):
    return len(httpx.get(f"{REST}/students?select=id",
                         headers={"apikey": ENV["SUPABASE_PUBLISHABLE_KEY"], **bearer(token)}).json())


@pytest.fixture
def pending(client, section_sa):  # noqa: F811
    body, r = new_student(client, "secretary", section_sa)
    ident = r.json()["login_identifier"]
    return body["student_id"], ident, login(client, ident, ident).json()["access_token"]


def test_new_student_account_is_pending_and_closed(client, admin, pending):
    uid, _, token = pending
    assert state(admin, uid) == "pending"
    me = client.get("/me", headers=bearer(token)).json()
    assert me["auth_user_id"] == uid and me["profile_id"] is None and me["tenant_id"] is None
    assert rows_via_postgrest(token) == 0                      # المسار المباشر مغلق أيضاً — الحد في DB


def test_activation_before_change_is_refused(client, admin, pending):
    uid, _, token = pending
    r = client.post("/auth/activate", headers=bearer(token))
    assert (r.status_code, r.json()["detail"]) == (409, "password_change_required")
    assert state(admin, uid) == "pending"


def test_change_then_activate_opens_the_account(client, admin, pending):
    uid, ident, token = pending
    new = "Mine-" + uuid.uuid4().hex[:8]
    assert user_put(token, new).status_code == 200
    r = client.post("/auth/activate", headers=bearer(token))
    assert (r.status_code, r.json()) == (200, {"state": "active"})
    assert state(admin, uid) == "active"
    me = client.get("/me", headers=bearer(token)).json()
    assert me["profile_id"] is not None and me["tenant_id"] == DEV_TENANT
    assert rows_via_postgrest(token) == 1                      # صفه هو فقط
    assert client.post("/auth/activate", headers=bearer(token)).status_code == 200      # idempotent
    assert login(client, ident, ident).status_code == 401       # الكلمة المؤقتة انتهت
    assert login(client, ident, new).status_code == 200


def test_admin_write_does_not_satisfy_first_login(client, admin, pending):
    """V9 5a: المدير يضع الكلمة المؤقتة نفسها أثناء pending — كانت تفتح الحساب في الآلية المرفوضة."""
    uid, ident, token = pending
    r = httpx.put(f"{ENV['SUPABASE_URL']}/auth/v1/admin/users/{uid}", headers={"apikey": ENV["SUPABASE_SECRET_KEY"]},
                  json={"password": ident})
    assert r.status_code == 200
    assert client.post("/auth/activate", headers=bearer(token)).status_code == 409
    assert state(admin, uid) == "pending"
    assert rows_via_postgrest(login(client, ident, ident).json()["access_token"]) == 0


@pytest.mark.parametrize("attempt", ["same_password", "weak_password"])
def test_rejected_change_keeps_account_closed(client, admin, pending, attempt):
    uid, ident, token = pending
    assert user_put(token, ident if attempt == "same_password" else "12345").status_code == 422
    assert client.post("/auth/activate", headers=bearer(token)).status_code == 409
    assert state(admin, uid) == "pending"


def test_unissued_account_stays_closed_even_after_a_change(client, admin, pending):
    """fail closed: لحظة الإصدار مفقودة (فشل arm) ⇒ لا تفعيل حتى مع تغيير صالح."""
    uid, _, token = pending
    admin.execute("update public.auth_identities set credential_issued_at = null where auth_user_id = %s", [uid])
    assert user_put(token, "Mine-" + uuid.uuid4().hex[:8]).status_code == 200
    assert client.post("/auth/activate", headers=bearer(token)).status_code == 409
    assert state(admin, uid) == "pending"


def test_staff_accounts_are_unaffected(client):
    from conftest import auth
    assert client.get("/me", headers=auth("secretary")).json()["profile_id"] is not None
    assert client.post("/auth/activate", headers=auth("secretary")).json() == {"state": "active"}
