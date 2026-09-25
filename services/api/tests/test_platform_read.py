"""F4 §6 — N5: قراءة Platform Admin لبيانات Tenant — بصلاحية المنصة فقط، ومُدقَّقة، وتفشل مغلقة."""

import pytest

import app.main
from conftest import DEV_TENANT, auth


def test_platform_admin_read_is_audited(client, ids, audit):
    r = client.get(f"/platform/tenants/{DEV_TENANT}", headers=auth("platform"))
    assert r.status_code == 200 and r.json()["tenant_code"] == "DEV"
    rows = audit.new(action="read")
    assert len(rows) == 1
    row = rows[0]
    assert (row["entity_type"], row["entity_id"]) == ("platform_tenants", DEV_TENANT)
    assert row["actor_type"] == "platform_admin"
    assert str(row["actor_id"]) == ids["pa_system_user"]        # system_user من DB
    assert str(row["platform_tenant_id"]) == DEV_TENANT and row["school_id"] is None


@pytest.mark.parametrize("who", ["tenant_admin", "secretary"])
def test_tenant_users_cannot_use_platform_route(client, audit, who):
    """tenant_admin يملك `tenant.read` على Tenant نفسه — لكن في سياق Tenant، لا منصة (G10)."""
    assert client.get(f"/platform/tenants/{DEV_TENANT}", headers=auth(who)).status_code == 403
    assert audit.new() == []


def test_platform_admin_without_permission_reads_nothing(client, admin, ids, audit):
    """سحب إسناد الدور ⇒ الهوية باقية (سياق المنصة) لكن بلا `tenant.read` ⇒ RLS تخفي الصف ولا تدقيق."""
    admin.execute("update public.platform_admin_assignments set status = 'revoked', revoked_at = now()"
                  " where system_user_id = %s and status = 'active'", [ids["pa_system_user"]])
    try:
        assert client.get("/me", headers=auth("platform")).json()["system_user_id"] == ids["pa_system_user"]
        assert client.get(f"/platform/tenants/{DEV_TENANT}", headers=auth("platform")).status_code == 404
        assert audit.new() == []
    finally:
        admin.execute("update public.platform_admin_assignments set status = 'active', revoked_at = null"
                      " where system_user_id = %s", [ids["pa_system_user"]])
    assert client.get(f"/platform/tenants/{DEV_TENANT}", headers=auth("platform")).status_code == 200   # ضابط


def test_audit_failure_returns_no_data(client, audit, monkeypatch):
    """Fail closed: فشل كتابة التدقيق يلغي المعاملة — لا بيانات في الاستجابة ولا صف تدقيق."""
    def broken(*_a, **_k):
        raise RuntimeError("audit store unavailable")
    monkeypatch.setattr(app.main, "write_access_audit", broken)
    r = client.get(f"/platform/tenants/{DEV_TENANT}", headers=auth("platform"))
    assert r.status_code == 500
    assert "DEV" not in r.text and "Development" not in r.text
    assert audit.new() == []


def test_failure_after_audit_write_rolls_it_back(client, audit, monkeypatch):
    """الذرية: صف التدقيق في معاملة القراءة نفسها — فشل بعد كتابته يلغيه ولا يُرجع البيانات."""
    real = app.main.write_access_audit

    def then_fail(*a, **k):
        real(*a, **k)
        raise RuntimeError("failure after the audit insert")
    monkeypatch.setattr(app.main, "write_access_audit", then_fail)
    r = client.get(f"/platform/tenants/{DEV_TENANT}", headers=auth("platform"))
    assert r.status_code == 500 and "DEV" not in r.text
    assert audit.new() == []
