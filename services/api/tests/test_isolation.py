"""F4 §2 و§5 — السياق من قاعدة البيانات، والعزل بين المدارس، وعدم تأثير سياق الطلب في السلطة."""

import pytest

from conftest import DEV_TENANT, auth

# كل ما قد يرسله عميل ليدّعي سياقاً — يجب ألا يغيّر شيئاً
FORGED_HEADERS = {
    "X-Tenant-Id": "20000000-0000-0000-0000-000000000002",
    "X-School-Id": "",            # يُملأ بمدرسة الهدف في كل اختبار
    "X-Role": "tenant_admin",
    "X-Permission": "student.export",
    "X-Platform-Admin": "true",
}


def forged(ids, school="SB"):
    return {**FORGED_HEADERS, "X-School-Id": ids["school"][school]}


def forged_query(ids, school="SB"):
    return {"school_id": ids["school"][school], "tenant_id": DEV_TENANT, "role": "tenant_admin", "scope": "tenant"}


def test_context_is_derived_from_db(client, ids):
    body = client.get("/me", headers=auth("secretary")).json()
    assert body["profile_id"] == ids["profile"]["secretary@dev.smas.test"]
    assert body["tenant_id"] == DEV_TENANT
    assert body["system_user_id"] is None


def test_platform_context_is_derived_from_db(client, ids):
    body = client.get("/me", headers=auth("platform")).json()
    assert body["system_user_id"] == ids["pa_system_user"]
    assert body["profile_id"] is None and body["tenant_id"] is None


def test_user_a_reaches_school_a(client, ids):
    sa = ids["school"]["SA"]
    assert client.get(f"/schools/{sa}", headers=auth("secretary")).json()["school_code"] == "SA"
    rows = client.get(f"/schools/{sa}/students", headers=auth("secretary")).json()["rows"]
    assert len(rows) == 1


@pytest.mark.parametrize("school", ["SB", "SS"])
def test_user_a_cannot_reach_school_b(client, ids, school):
    """نفس الـTenant، مدرسة أخرى (SB في المجموعة نفسها، SS مستقلة) — تطابق Tenant ليس كافياً (§1.1 بند 5)."""
    sid = ids["school"][school]
    assert client.get(f"/schools/{sid}", headers=auth("secretary")).status_code == 404
    assert client.get(f"/schools/{sid}/students", headers=auth("secretary")).status_code == 404


def test_school_b_exists_positive_control(client, ids):
    """ضابط: المدرستان موجودتان ويراهما صاحب نطاق Tenant — الرفض أعلاه عزل لا غياب."""
    for school in ("SB", "SS"):
        assert client.get(f"/schools/{ids['school'][school]}", headers=auth("tenant_admin")).status_code == 200


def test_forged_school_context_does_not_raise_authority(client, ids):
    sb = ids["school"]["SB"]
    r = client.get(f"/schools/{sb}", headers=auth("secretary", **forged(ids, "SB")), params=forged_query(ids, "SB"))
    assert r.status_code == 404
    # ولا بتمرير مدرسة المستخدم نفسه كسياق لطلب مدرسة أخرى
    r = client.get(f"/schools/{sb}/students", headers=auth("secretary", **forged(ids, "SA")), params=forged_query(ids, "SA"))
    assert r.status_code == 404


def test_forged_role_and_tenant_do_not_change_context(client, ids):
    plain = client.get("/me", headers=auth("secretary")).json()
    forged_ctx = client.get("/me", headers=auth("secretary", **forged(ids)), params=forged_query(ids)).json()
    assert forged_ctx == plain


def test_forged_role_does_not_grant_export(client, ids):
    sa = ids["school"]["SA"]
    r = client.get(f"/schools/{sa}/students/export", headers=auth("secretary", **forged(ids, "SA")), params=forged_query(ids, "SA"))
    assert r.status_code == 403


def test_forged_platform_claim_does_not_open_platform_route(client, ids):
    r = client.get(f"/platform/tenants/{DEV_TENANT}", headers=auth("tenant_admin", **forged(ids)))
    assert r.status_code == 403
