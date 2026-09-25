"""F4 — M21b عبر الـAPI: إيقاف الـTenant يقطع السياق من جذره؛ JWT صالح لا يعيده."""

from conftest import DEV_TENANT, as_platform_admin, auth


def test_suspended_tenant_loses_access(client, admin, ids):
    sa = ids["school"]["SA"]
    pa_auth = "a0000000-0000-4000-8000-000000000000"
    assert client.get(f"/schools/{sa}", headers=auth("school_admin")).status_code == 200   # ضابط
    with as_platform_admin(admin, pa_auth) as conn:
        conn.execute("select app.suspend_tenant(%s, 'F4 test')", [DEV_TENANT])
    try:
        me = client.get("/me", headers=auth("school_admin")).json()
        assert me["profile_id"] is None and me["tenant_id"] is None
        assert client.get(f"/schools/{sa}", headers=auth("school_admin")).status_code == 404
        assert client.get(f"/schools/{sa}/students", headers=auth("secretary")).status_code == 404
        assert client.get(f"/schools/{sa}/students/export", headers=auth("school_admin")).status_code == 403
        # سياق المنصة منفصل ولا يتأثر: Platform Admin يرى الـTenant موقوفاً
        assert client.get(f"/platform/tenants/{DEV_TENANT}", headers=auth("platform")).json()["status"] == "suspended"
    finally:
        with as_platform_admin(admin, pa_auth) as conn:
            conn.execute("select app.reactivate_tenant(%s, 'F4 test')", [DEV_TENANT])
    assert client.get(f"/schools/{sa}", headers=auth("school_admin")).status_code == 200
