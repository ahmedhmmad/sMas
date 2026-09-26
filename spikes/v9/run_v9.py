"""V9 — تشغيل الحالات الثماني على Supabase Auth الحقيقي (محلياً، seed E5).

  cd services/api && .venv/Scripts/python ../../spikes/v9/run_v9.py

يفترض أن spikes/v9/setup.sql مطبَّق. يطبع سطراً لكل ملاحظة: `V9.<حالة>.<مفتاح> = <قيمة>`.
"""

import json
import os
import pathlib
import sys
import threading
import uuid

import httpx
import psycopg
from psycopg.rows import dict_row

API = pathlib.Path(__file__).resolve().parents[2] / "services" / "api"
sys.path[:0] = [str(API), str(API / "tests")]
os.chdir(API)

from conftest import ENV, auth  # noqa: E402 — يضبط البيئة من `supabase status`
from fastapi.testclient import TestClient  # noqa: E402
from app.main import app  # noqa: E402

AUTH = f"{ENV['SUPABASE_URL']}/auth/v1"
REST = f"{ENV['SUPABASE_URL']}/rest/v1"
PUB = {"apikey": ENV["SUPABASE_PUBLISHABLE_KEY"]}
SEC = {"apikey": ENV["SUPABASE_SECRET_KEY"]}
out: list[str] = []


def note(key, value):
    line = f"V9.{key} = {value}"
    out.append(line)
    print(line)


db = psycopg.connect(ENV["TEST_ADMIN_DB_URL"], autocommit=True, row_factory=dict_row)
client = TestClient(app, raise_server_exceptions=False).__enter__()
section = str(db.execute(
    "select s.id from public.sections s join public.grade_levels g on g.id = s.grade_level_id"
    " join public.schools sc on sc.id = s.school_id where sc.school_code = 'SA' and g.sequence_no = 1").fetchone()["id"])


def state(sid):
    r = db.execute("select state from spike_v9.credential where auth_user_id = %s", [sid]).fetchone()
    return r["state"] if r else None


def events(sid):
    return db.execute("select changed, cur_user, sess_user, app_name, state_before, state_after"
                      " from spike_v9.events where auth_user_id = %s order by id", [sid]).fetchall()


def new_pending_student():
    """الإنشاء كما في D2 المقترحة: issuing ← Saga (Admin API يضع الكلمة الأولية) ← arm ← pending."""
    sid = str(uuid.uuid4())
    db.execute("insert into spike_v9.credential values (%s, 'issuing', null)", [sid])
    r = client.post("/students", headers=auth("secretary"), json={
        "student_id": sid, "section_id": section, "effective_from": "2026-09-01",
        "first_name": "V9", "family_name": "Case", "new_family_name": "Case"})
    assert r.status_code == 201, r.text
    db.execute("select spike_v9.arm(%s)", [sid])
    return sid, r.json()["login_identifier"]


def login(ident, password):
    client.app.state.login_limiter.reset()
    r = client.post("/auth/student/login", json={"tenant": "DEV", "school": "school-a", "identifier": ident, "password": password})
    return r.json()["access_token"] if r.status_code == 200 else None


def access(token):
    """(profile_id من /me، عدد صفوف students عبر PostgREST مباشرة)."""
    me = client.get("/me", headers={"Authorization": f"Bearer {token}"}).json()
    rows = httpx.get(f"{REST}/students?select=id", headers={**PUB, "Authorization": f"Bearer {token}"}).json()
    return me["profile_id"] is not None, len(rows)


def user_change(token, password):
    r = httpx.put(f"{AUTH}/user", headers={**PUB, "Authorization": f"Bearer {token}"}, json={"password": password})
    return r.status_code, (r.json().get("error_code") if r.status_code != 200 else "ok")


def admin_set(sid, password):
    r = httpx.put(f"{AUTH}/admin/users/{sid}", headers=SEC, json={"password": password})
    return r.status_code


# 1–2. الإنشاء بحالة pending والوصول مرفوض
sid, temp = new_pending_student()
note("1.state_after_create", state(sid))
note("1.events_during_saga", json.dumps([(e["state_before"], e["state_after"]) for e in events(sid)]))
tok = login(temp, temp)
note("2.auth_login_with_temp", "session" if tok else "none")
note("2.access(profile,rows)", access(tok))

# 3. تغيير إلى كلمة جديدة
new = "New-Pass-" + uuid.uuid4().hex[:8]
note("3.user_change_new", user_change(tok, new))
note("3.state", state(sid))
note("3.event", json.dumps({k: events(sid)[-1][k] for k in ("changed", "cur_user", "sess_user", "app_name")}))
note("3.access_same_token", access(tok))
note("3.temp_still_logs_in", login(temp, temp) is not None)

# 4. تغيير إلى الكلمة المؤقتة نفسها
sid4, temp4 = new_pending_student()
tok4 = login(temp4, temp4)
n_before = len(events(sid4))
note("4.user_change_same", user_change(tok4, temp4))
note("4.trigger_fired", len(events(sid4)) > n_before)
note("4.state", state(sid4))
note("4.access", access(tok4))

# 5. إعادة ضبط المدير
sid5, temp5 = new_pending_student()
note("5a.admin_set_same_temp_while_pending", admin_set(sid5, temp5))
note("5a.state", state(sid5))
note("5a.event", json.dumps({k: events(sid5)[-1][k] for k in ("changed", "cur_user", "sess_user", "app_name")}))
note("5a.temp_logs_in_and_access", access(login(temp5, temp5)))
sid5b, temp5b = new_pending_student()
note("5b.admin_set_new_temp_while_pending", admin_set(sid5b, "Reset-" + temp5b))
note("5b.state", state(sid5b))
# 5c: حساب active يُعاد ضبطه بلا مسار issuing ⇒ هل يعود الإجبار؟
sid5c, temp5c = new_pending_student()
user_change(login(temp5c, temp5c), "Mine-" + uuid.uuid4().hex[:6])
note("5c.state_before_reset", state(sid5c))
note("5c.admin_reset", admin_set(sid5c, "School-Reset-1"))
note("5c.state_after_reset", state(sid5c))
note("5c.reset_password_access", access(login(temp5c, "School-Reset-1")))

# 6. فشل التحديث
sid6, temp6 = new_pending_student()
tok6 = login(temp6, temp6)
note("6a.user_change_too_short", user_change(tok6, "12345"))
note("6a.state", state(sid6))
db.execute("insert into spike_v9.fail_for values (%s)", [sid6])
note("6b.user_change_forced_failure", user_change(tok6, "Would-Be-New-1"))
db.execute("delete from spike_v9.fail_for where auth_user_id = %s", [sid6])
note("6b.state", state(sid6))
note("6b.events_persisted", len(events(sid6)))
note("6b.temp_still_valid", login(temp6, temp6) is not None)
note("6b.new_password_valid", login(temp6, "Would-Be-New-1") is not None)
note("6b.access", access(tok6))

# 7. الحساب active لا يتأثر بتغييرات أخرى
sid7, temp7 = new_pending_student()
tok7 = login(temp7, temp7)
user_change(tok7, "Seven-Pass-1")
n7 = len(events(sid7))
login(temp7, "Seven-Pass-1")                                                            # last_sign_in_at
httpx.put(f"{AUTH}/admin/users/{sid7}", headers=SEC, json={"user_metadata": {"x": 1}})  # بيانات أخرى
note("7.events_from_non_password_updates", len(events(sid7)) - n7)
note("7.user_change_again", user_change(login(temp7, "Seven-Pass-1"), "Seven-Pass-2"))
note("7.state", state(sid7))

# 8. السباق
sid8, temp8 = new_pending_student()
tok8 = login(temp8, temp8)
res = {}
ts = [threading.Thread(target=lambda p=p: res.__setitem__(p, user_change(tok8, p))) for p in ("Race-A-111", "Race-B-222")]
[t.start() for t in ts]
[t.join() for t in ts]
note("8a.two_user_changes", json.dumps(res))
note("8a.state", state(sid8))
note("8a.logins(A,B,temp)", (login(temp8, "Race-A-111") is not None, login(temp8, "Race-B-222") is not None, login(temp8, temp8) is not None))

open_with_temp = 0
for i in range(10):
    s, t = new_pending_student()
    tk = login(t, t)
    user_change(tk, f"Mine-{i}-xyz")                              # الطالب فعّل حسابه
    def school_reset():
        db.execute("update spike_v9.credential set state = 'issuing' where auth_user_id = %s", [s])
        admin_set(s, f"Tmp-Reset-{i}")
        db.execute("select spike_v9.arm(%s)", [s])
    def student_change():
        user_change(tk, f"Mine2-{i}-xyz")
    a, b = threading.Thread(target=school_reset), threading.Thread(target=student_change)
    a.start(); b.start(); a.join(); b.join()
    reset_works = login(t, f"Tmp-Reset-{i}") is not None
    if state(s) == "active" and reset_works:
        open_with_temp += 1
note("8b.reset_vs_change_open_with_school_temp(of 10)", open_with_temp)

pathlib.Path(__file__).with_name("out").mkdir(exist_ok=True)
pathlib.Path(__file__).with_name("out").joinpath("v9.txt").write_text("\n".join(out), encoding="utf-8")
