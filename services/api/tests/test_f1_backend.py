"""F1 — إضافات الخلفية المعتمدة: /me/capabilities (M28)، قائمة Tenants المدقَّقة، CORS، مرسل OTP الملفي."""

import json
import pathlib
import uuid

import pytest

from app import otp_sender
from conftest import DEV_TENANT, auth, origin

SEED_ROLES = {"secretary": "secretary", "school_admin": "school_admin", "tenant_admin": "tenant_admin", "teacher": "teacher"}


def role_keys(admin, role):
    return sorted(r["code"] for r in admin.execute(
        "select p.code from public.role_permissions rp join public.roles ro on ro.id = rp.role_id"
        " join public.permissions p on p.id = rp.permission_id where ro.code = %s and ro.platform_tenant_id is null", [role]))


# ---------------- capabilities ----------------

@pytest.mark.parametrize("who", list(SEED_ROLES))
def test_capabilities_are_the_role_keys(client, admin, who):
    body = client.get("/me/capabilities", headers=auth(who)).json()
    assert body["context"] == "tenant"
    assert body["permissions"] == role_keys(admin, SEED_ROLES[who])            # مشتقة في DB من الدور نفسه
    assert set(body) == {"context", "permissions"}                              # مفاتيح فقط: لا أدوار ولا نطاقات ولا معرّفات


def test_capabilities_read_without_export(client):
    sec = client.get("/me/capabilities", headers=auth("secretary")).json()["permissions"]
    adm = client.get("/me/capabilities", headers=auth("school_admin")).json()["permissions"]
    assert "student.read" in sec and "student.export" not in sec
    assert "student.export" in adm


def test_capabilities_platform_context(client, admin):
    body = client.get("/me/capabilities", headers=auth("platform")).json()
    expected = sorted(r["code"] for r in admin.execute(
        "select p.code from public.platform_admin_role_permissions x join public.platform_admin_roles ro on ro.id = x.platform_admin_role_id"
        " join public.permissions p on p.id = x.permission_id where ro.code = 'platform_admin'"))
    assert body == {"context": "platform", "permissions": expected}              # لا اتحاد مع مفاتيح Tenant


def test_capabilities_pending_student_is_empty(client, admin):
    section = str(admin.execute("select s.id from public.sections s join public.schools sc on sc.id = s.school_id"
                                " where sc.school_code = 'SA' limit 1").fetchone()["id"])
    sid = str(uuid.uuid4())
    ident = client.post("/students", headers=auth("secretary"), json={
        "student_id": sid, "section_id": section, "effective_from": "2026-09-01",
        "first_name": "Cap", "family_name": "Test", "new_family_name": "Cap"}).json()["login_identifier"]
    client.app.state.login_limiter.reset()
    token = client.post("/auth/student/login", json={"identifier": ident, "password": ident},
                        headers=origin("dev", "school-a")).json()["access_token"]
    assert client.get("/me/capabilities", headers={"Authorization": f"Bearer {token}"}).json() == {"context": None, "permissions": []}


def test_capabilities_require_a_valid_token(client):
    assert client.get("/me/capabilities").status_code == 401


# ---------------- قائمة Tenants (N5) ----------------

def test_platform_tenant_list_is_audited(client, audit):
    r = client.get("/platform/tenants", headers=auth("platform"))
    assert r.status_code == 200
    rows = r.json()["rows"]
    assert DEV_TENANT in {row["id"] for row in rows}
    audited = audit.new(action="read", entity_type="platform_tenants")
    assert sorted(a["entity_id"] for a in audited) == sorted(row["id"] for row in rows)          # صف تدقيق لكل Tenant مقروء
    assert {a["actor_type"] for a in audited} == {"platform_admin"}


def test_platform_tenant_list_is_platform_only(client, audit):
    assert client.get("/platform/tenants", headers=auth("tenant_admin")).status_code == 403
    assert audit.new() == []


# CORS: F3 استبدل القائمة الصريحة بأصل أساسي مرسَّخ — اختباراته في test_host_context.py


# ---------------- مرسل OTP الملفي ----------------

def test_file_sender_writes_json_lines(tmp_path):
    box = otp_sender.FileOutbox(str(tmp_path / "otp.jsonl"))
    box.send("guardian", "+201000000001", "123456")
    assert json.loads((tmp_path / "otp.jsonl").read_text(encoding="utf-8").strip()) == {
        "kind": "guardian", "contact": "+201000000001", "code": "123456"}


def test_file_sender_refuses_a_path_inside_the_web_app():
    with pytest.raises(ValueError):
        otp_sender.FileOutbox(str(otp_sender.WEB_APP / "public" / "otp.jsonl"))


@pytest.mark.parametrize("value", ["local", "file:/tmp/otp.jsonl"])
def test_dev_senders_refused_in_production(monkeypatch, value):
    monkeypatch.setenv("API_OTP_SENDER", value)
    with pytest.raises(ValueError):
        otp_sender.load_sender("production")


def test_no_http_route_reads_the_outbox(client):
    paths = set(client.get("/openapi.json").json()["paths"])
    assert not any("otp" in p and "request" not in p and "verify" not in p for p in paths)
    assert not any("outbox" in p for p in paths)
