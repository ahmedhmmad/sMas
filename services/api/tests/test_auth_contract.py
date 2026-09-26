"""عقد تكامل Supabase Auth — V9b (Supabase Auth integration assumption، لا قاعدة PostgreSQL نملكها).

D2 (M25) يعتمد على سلوك Supabase Auth هذا. إن تغيّر في ترقية فهذا الملف يفشل في CI — والنظام نفسه يبقى
آمناً: بلا الإشارة لا تفعيل، والحسابات تبقى pending (fail closed) لا مفتوحة.

  1. الطالب يغيّر كلمته ⇒ صف `user_updated_password` بفاعل = الحساب نفسه
  2. كتابة المدير (Admin API) ⇒ `user_modified` بفاعل service_role فقط — لا `user_updated_password`
  3. الكلمة نفسها ⇒ `422 same_password` ولا صف
  4. كلمة ضعيفة ⇒ `422 weak_password` ولا صف
  5. الساعة: حدث تغيير الطالب بعد `auth.users.updated_at` لكتابة المدير السابقة (لحظة الإصدار في arm)
"""

import uuid

import httpx
import pytest

from conftest import ENV
from test_student_login import login, new_student

AUTH = f"{ENV['SUPABASE_URL']}/auth/v1"
ZERO = "00000000-0000-0000-0000-000000000000"


@pytest.fixture
def student(client, section_sa):
    body, r = new_student(client, "secretary", section_sa)
    ident = r.json()["login_identifier"]
    return body["student_id"], ident, login(client, ident, ident).json()["access_token"]


@pytest.fixture(scope="module")
def section_sa(admin):
    return str(admin.execute(
        "select s.id from public.sections s join public.grade_levels g on g.id = s.grade_level_id"
        " join public.schools sc on sc.id = s.school_id where sc.school_code = 'SA' and g.sequence_no = 1").fetchone()["id"])


def entries(admin, uid, since):
    return admin.execute(
        "select payload->>'action' as action, payload->>'actor_id' as actor, created_at from auth.audit_log_entries"
        " where created_at > %s and (payload->>'actor_id' = %s or payload->'traits'->>'user_id' = %s) order by created_at",
        [since, uid, uid]).fetchall()


def now(admin):
    return admin.execute("select clock_timestamp() as t").fetchone()["t"]


def user_put(token, password):
    return httpx.put(f"{AUTH}/user", headers={"apikey": ENV["SUPABASE_PUBLISHABLE_KEY"], "Authorization": f"Bearer {token}"},
                     json={"password": password})


def test_user_change_writes_user_updated_password_by_self(admin, student):
    uid, _, token = student
    t0 = now(admin)
    assert user_put(token, "Contract-" + uuid.uuid4().hex[:8]).status_code == 200
    rows = entries(admin, uid, t0)
    assert ("user_updated_password", uid) in {(r["action"], r["actor"]) for r in rows}


def test_admin_write_is_user_modified_by_service_role_only(admin, student):
    uid, ident, _ = student
    t0 = now(admin)
    r = httpx.put(f"{AUTH}/admin/users/{uid}", headers={"apikey": ENV["SUPABASE_SECRET_KEY"]}, json={"password": ident})
    assert r.status_code == 200
    rows = entries(admin, uid, t0)
    assert rows and {(x["action"], x["actor"]) for x in rows} == {("user_modified", ZERO)}


@pytest.mark.parametrize("case", ["same_password", "weak_password"])
def test_rejected_change_leaves_no_signal(admin, student, case):
    uid, ident, token = student
    t0 = now(admin)
    r = user_put(token, ident if case == "same_password" else "12345")
    assert (r.status_code, r.json().get("error_code")) == (422, case)
    assert [x for x in entries(admin, uid, t0) if x["action"] == "user_updated_password"] == []


def test_change_is_stamped_after_the_issuance(admin, student):
    uid, _, token = student
    issued = admin.execute("select credential_issued_at from public.auth_identities where auth_user_id = %s", [uid]).fetchone()[
        "credential_issued_at"]
    assert issued is not None
    assert user_put(token, "After-" + uuid.uuid4().hex[:8]).status_code == 200
    stamped = [x["created_at"] for x in entries(admin, uid, issued) if x["action"] == "user_updated_password"]
    assert stamped and all(t > issued for t in stamped)
