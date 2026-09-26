"""F2 / D1 — هوية حساب الطالب الاصطناعية، الـSaga، والدخول بـOfficial/Temporary ID."""

import uuid

import httpx
import pytest

from app.auth_admin import student_email
from conftest import DEV_TENANT, ENV, auth

TENANT_CODE, SCHOOL_A, SCHOOL_B = "DEV", "school-a", "school-b"
SEED_STUDENT = "e0000000-0000-4000-8000-000000000001"
SEED_OFFICIAL = "30101010100000"


@pytest.fixture(scope="module")
def section_sa(admin):
    return str(admin.execute(
        "select s.id from public.sections s join public.grade_levels g on g.id = s.grade_level_id"
        " join public.schools sc on sc.id = s.school_id where sc.school_code = 'SA' and g.sequence_no = 1").fetchone()["id"])


def auth_user(student_id: str) -> httpx.Response:
    return httpx.get(f"{ENV['SUPABASE_URL']}/auth/v1/admin/users/{student_id}",
                     headers={"apikey": ENV["SUPABASE_SECRET_KEY"]})


def new_student(client, who, section, **extra):
    body = {"student_id": str(uuid.uuid4()), "section_id": section, "effective_from": "2026-09-01",
            "first_name": "Laila", "family_name": "Nasser", "new_family_name": "Nasser", **extra}
    return body, client.post("/students", json=body, headers=auth(who))


def login(client, identifier, password, tenant=TENANT_CODE, school=SCHOOL_A):
    return client.post("/auth/student/login", json={"tenant": tenant, "school": school,
                                                    "identifier": identifier, "password": password})


# ---------- الـSaga ----------

def test_saga_creates_account_with_synthetic_identity(client, admin, section_sa):
    body, r = new_student(client, "secretary", section_sa)
    assert r.status_code == 201
    sid, ident = body["student_id"], r.json()["login_identifier"]
    assert r.json()["student_id"] == sid and ident.startswith("TMP-")
    user = auth_user(sid).json()
    assert user["id"] == sid and user["email"] == student_email(sid)                    # D1
    row = admin.execute("select p.auth_user_id from public.students s join public.profiles p on p.id = s.student_profile_id"
                        " where s.id = %s", [sid]).fetchone()
    assert str(row["auth_user_id"]) == sid


def test_saga_retry_is_idempotent(client, section_sa):
    body, r1 = new_student(client, "secretary", section_sa)
    r2 = client.post("/students", json=body, headers=auth("secretary"))
    assert r1.status_code == r2.status_code == 201
    assert r1.json() == r2.json()


def test_saga_compensates_when_provisioning_is_refused(client, section_sa):
    """المعلم بلا student.create: قاعدة البيانات ترفض ⇒ حساب Auth المُنشأ في هذه المحاولة يُحذف."""
    body, r = new_student(client, "teacher", section_sa)
    assert r.status_code == 403
    assert auth_user(body["student_id"]).status_code == 404


def test_saga_out_of_scope_section(client, admin):
    """سكرتير SA وشعبة في SB: الدالة تقرر (not found) — FastAPI لا يقرر."""
    sb_section = str(admin.execute("select s.id from public.sections s join public.schools sc on sc.id = s.school_id"
                                   " where sc.school_code = 'SB' limit 1").fetchone()["id"])
    body, r = new_student(client, "secretary", sb_section)
    assert r.status_code == 404
    assert auth_user(body["student_id"]).status_code == 404


def test_identifier_shorter_than_password_minimum_is_rejected_before_writing(client, section_sa):
    body, r = new_student(client, "secretary", section_sa, official_id="123", official_id_type="national_id")
    assert r.status_code == 422 and r.json()["detail"] == "identifier_too_short_for_initial_password"
    assert auth_user(body["student_id"]).status_code == 404


# ---------- الدخول ----------

def test_login_with_temporary_id(client, section_sa, ids):
    body, r = new_student(client, "secretary", section_sa)
    ident = r.json()["login_identifier"]
    session = login(client, ident, ident)
    assert session.status_code == 200
    assert set(session.json()) == {"access_token", "refresh_token", "expires_in", "token_type"}   # لا بيانات أخرى
    me = client.get("/me", headers={"Authorization": f"Bearer {session.json()['access_token']}"}).json()
    assert me["auth_user_id"] == body["student_id"] and me["tenant_id"] == DEV_TENANT and me["profile_id"]


def test_login_with_official_id(client, section_sa):
    official = "29901010100011" + uuid.uuid4().hex[:4]
    _, r = new_student(client, "secretary", section_sa, official_id=official, official_id_type="national_id")
    assert r.json()["login_identifier"] == official
    assert login(client, official, official).status_code == 200


def test_seed_student_logs_in_by_official_id(client):
    """seed E5 على شكل D1: الحساب = معرّف الطالب، والدخول بالـOfficial ID."""
    r = login(client, SEED_OFFICIAL, "DevOnly-Seed-2026")
    assert r.status_code == 200
    me = client.get("/me", headers={"Authorization": f"Bearer {r.json()['access_token']}"}).json()
    assert me["auth_user_id"] == SEED_STUDENT


def test_temporary_to_official_keeps_auth_identity(client, admin, section_sa):
    """Temporary ← Official: هوية Auth لا تتغير؛ الدخول بالمعرّف الجديد وبكلمة المرور نفسها."""
    body, r = new_student(client, "secretary", section_sa)
    temp, sid = r.json()["login_identifier"], body["student_id"]
    official = "28801010100022" + uuid.uuid4().hex[:4]
    admin.execute("update public.students set official_id = %s, official_id_type = 'national_id' where id = %s", [official, sid])
    assert auth_user(sid).json()["email"] == student_email(sid)
    r = login(client, official, temp)
    assert r.status_code == 200
    me = client.get("/me", headers={"Authorization": f"Bearer {r.json()['access_token']}"}).json()
    assert me["auth_user_id"] == sid


@pytest.mark.parametrize("case", ["wrong_password", "unknown_identifier", "other_school", "unknown_school",
                                  "unknown_tenant", "email_as_identifier"])
def test_every_login_failure_is_identical(client, case):
    args = {
        "wrong_password":      (SEED_OFFICIAL, "nope-nope"),
        "unknown_identifier":  ("99999999999999", "DevOnly-Seed-2026"),
        "other_school":        (SEED_OFFICIAL, "DevOnly-Seed-2026", TENANT_CODE, SCHOOL_B),   # SB: مجموعة GA نفسها!
        "unknown_school":      (SEED_OFFICIAL, "DevOnly-Seed-2026", TENANT_CODE, "nope"),
        "unknown_tenant":      (SEED_OFFICIAL, "DevOnly-Seed-2026", "NOPE", SCHOOL_A),
        "email_as_identifier": (student_email(SEED_STUDENT), "DevOnly-Seed-2026"),
    }[case]
    r = login(client, *args)
    if case == "other_school":
        # SB في المجموعة نفسها ⇒ نطاق الهوية نفسه: الدخول صحيح من أي مدرسة في المجموعة (ضابط إيجابي)
        assert r.status_code == 200
        return
    assert (r.status_code, r.json()) == (401, {"detail": "invalid_credentials"})


def test_login_other_scope_fails_identically(client):
    """SS مستقلة = نطاق هوية آخر: المعرّف نفسه لا يُحَل هناك."""
    r = login(client, SEED_OFFICIAL, "DevOnly-Seed-2026", school="standalone")
    assert (r.status_code, r.json()) == (401, {"detail": "invalid_credentials"})


@pytest.mark.parametrize("identifier,password", [(SEED_OFFICIAL, "wrong"), ("00000000000000", "wrong")])
def test_rate_limit_is_the_same_for_existing_and_unknown(client, identifier, password):
    codes = [login(client, identifier, password).status_code for _ in range(11)]
    assert codes[:10] == [401] * 10 and codes[10] == 429


def test_login_response_leaks_no_synthetic_email(client):
    r = login(client, SEED_OFFICIAL, "DevOnly-Seed-2026")
    assert "students.smas.invalid" not in r.text and SEED_STUDENT not in r.text.replace(r.json()["access_token"], "")
