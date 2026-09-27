"""بيانات E2E المتصفح (F1) — تُنشأ بالمسارات الحقيقية ثم تُكتب JSON لـPlaywright.

  python tests/web_e2e_fixtures.py <out.json>

ليس اختبار pytest (بلا بادئة test_). يستعمل أدوات الـconftest نفسها: TestClient (FastAPI داخل العملية) وجلسات
seed E5، واتصال قاعدة البيانات لـprovision_guardian (لا مسار HTTP لإنشاء ولي أمر في F1).
"""

import json
import pathlib
import secrets
import sys
import uuid

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))

import psycopg  # noqa: E402
from psycopg.rows import dict_row  # noqa: E402

from conftest import ENV, TENANT_ADMIN_ID, auth  # noqa: E402
from fastapi.testclient import TestClient  # noqa: E402
from app.main import app  # noqa: E402


def main(out: str) -> None:
    db = psycopg.connect(ENV["TEST_ADMIN_DB_URL"], autocommit=True, row_factory=dict_row)
    school = {r["school_code"]: str(r["id"]) for r in db.execute(
        "select school_code, id from public.schools where platform_tenant_id = 'd0000000-0000-4000-8000-000000000001'")}

    def as_tenant_admin(sql, params):
        with db.transaction():
            db.execute("set local role authenticated")
            db.execute("select set_config('request.jwt.claims', %s, true)",
                       [json.dumps({"sub": TENANT_ADMIN_ID, "role": "authenticated"})])
            db.execute(sql, params)

    with TestClient(app) as client:
        for code, mode in (("SA", "A"), ("SB", "B"), ("SS", "C")):
            r = client.post(f"/schools/{school[code]}/guardian-first-login-mode", json={"mode": mode, "reason": "web E2E"},
                            headers=auth("tenant_admin"))
            assert r.status_code == 200, r.text

        def student_in(code, who="tenant_admin"):
            section = str(db.execute("select s.id from public.sections s where s.school_id = %s limit 1", [school[code]]).fetchone()["id"])
            sid = str(uuid.uuid4())
            r = client.post("/students", headers=auth(who), json={
                "student_id": sid, "section_id": section, "effective_from": "2026-09-01",
                "first_name": "Web", "family_name": "E2E " + code, "new_family_name": "Web E2E " + code})
            assert r.status_code == 201, r.text
            return {"id": sid, "identifier": r.json()["login_identifier"]}

        students = {"seed": {"id": "e0000000-0000-4000-8000-000000000001"}, "sb": student_in("SB"), "ss": student_in("SS"),
                    "fresh": student_in("SA", who="secretary")}

        def guardian(child):
            gid, phone = str(uuid.uuid4()), "+2019" + f"{secrets.randbelow(10**8):08d}"
            as_tenant_admin("select app.provision_guardian(%s, %s, 'mother', %s, 'Web', 'Parent', '2026-09-01')", [gid, child, phone])
            assert client.post("/accounts", json={"kind": "guardian", "target_id": gid}, headers=auth("tenant_admin")).status_code == 201
            return {"id": gid, "phone": phone}

        guardians = {"A": guardian(students["seed"]["id"]), "B": guardian(students["sb"]["id"]), "C": guardian(students["ss"]["id"])}
        r = client.post(f"/guardians/{guardians['C']['id']}/temporary-password", headers=auth("tenant_admin"))
        assert r.status_code == 201, r.text
        guardians["C"]["temporary_password"] = r.json()["temporary_password"]

    pathlib.Path(out).write_text(json.dumps({"schools": school, "students": students, "guardians": guardians}, indent=2),
                                 encoding="utf-8")


if __name__ == "__main__":
    main(sys.argv[1])
