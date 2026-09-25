"""F4 §7 — P3: قناة التصدير منفصلة عن القراءة، وكل تصدير مُدقَّق."""

import pytest

from conftest import auth


@pytest.mark.parametrize("who", ["secretary", "accountant"])
def test_read_without_export(client, ids, audit, who):
    """ضابط سلبي: `student.read` بلا `student.export` — القراءة تعمل، والتصدير مرفوض، ولا صف تدقيق."""
    sa = ids["school"]["SA"]
    assert client.get(f"/schools/{sa}/students", headers=auth(who)).status_code == 200
    r = client.get(f"/schools/{sa}/students/export", headers=auth(who))
    assert r.status_code == 403 and r.json()["detail"] == "forbidden"
    assert audit.new() == []


def test_export_with_permission_is_audited_per_student(client, ids, audit):
    sa = ids["school"]["SA"]
    read = client.get(f"/schools/{sa}/students", headers=auth("school_admin")).json()["rows"]
    r = client.get(f"/schools/{sa}/students/export", headers=auth("school_admin"))
    assert r.status_code == 200
    exported = r.json()["rows"]
    assert exported == read and len(exported) == 1          # الصفوف نفسها تحت RLS، لا أكثر
    rows = audit.new(action="export")
    assert [(x["entity_type"], x["entity_id"]) for x in rows] == [("students", exported[0]["id"])]
    row = rows[0]
    assert row["actor_type"] == "tenant_user"
    assert str(row["actor_id"]) == ids["profile"]["school.admin@dev.smas.test"]     # من DB لا من الـclaims
    assert str(row["school_id"]) == sa and str(row["platform_tenant_id"]) == ids["tenant"]
    assert row["source"] == "api" and row["new_values"]["row_count"] == 1


@pytest.mark.parametrize("school", ["SB", "SS"])
def test_export_outside_scope_is_rejected(client, ids, audit, school):
    """الصلاحية بلا نطاق لا تكفي: school_admin في SA لا يصدّر من SB/SS."""
    r = client.get(f"/schools/{ids['school'][school]}/students/export", headers=auth("school_admin"))
    assert r.status_code == 403
    assert audit.new() == []
