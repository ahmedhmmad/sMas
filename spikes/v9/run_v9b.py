"""V9b — الإشارة في سجل تدقيق Supabase Auth: نوع الفعل، الفاعل، ونفس المعاملة أم لا."""
import json, pathlib, sys, uuid
sys.path.insert(0, str(pathlib.Path(__file__).parent))
import run_v9 as v  # يعيد تشغيل الحالات الثماني (V9) ثم نضيف الملاحظات

def audit(sid):
    return v.db.execute("select action, actor_username, xid::text from spike_v9.audit_events where auth_user_id = %s order by id", [sid]).fetchall()
def pw_xids(sid):
    return [r["xid"] for r in v.db.execute("select xid::text from spike_v9.events where auth_user_id = %s order by id", [sid]).fetchall()]

s, t = v.new_pending_student()
tok = v.login(t, t)
v.user_change(tok, "Signal-New-1")
a = audit(s)
v.note("b1.user_change.audit", json.dumps([(x["action"], x["actor_username"]) for x in a if x["action"] != "login"]))
upw = [x for x in a if x["action"] == "user_updated_password"]
v.note("b1.same_transaction_as_password_update", bool(upw) and upw[-1]["xid"] == pw_xids(s)[-1])

s2, t2 = v.new_pending_student()
v.admin_set(s2, t2)
v.note("b2.admin_set.audit_actions", json.dumps(sorted({(x["action"], x["actor_username"]) for x in audit(s2)})))

s3, t3 = v.new_pending_student()
tok3 = v.login(t3, t3)
n = len(audit(s3))
v.user_change(tok3, t3)
v.note("b3.same_password.new_audit_rows", len(audit(s3)) - n)

s4, t4 = v.new_pending_student()
tok4 = v.login(t4, t4)
n = len(audit(s4))
v.db.execute("insert into spike_v9.fail_for values (%s)", [s4])
v.note("b4.forced_failure.status", v.user_change(tok4, "Would-Be-New-2"))
v.db.execute("delete from spike_v9.fail_for where auth_user_id = %s", [s4])
v.note("b4.forced_failure.user_updated_password_rows_left", sum(1 for x in audit(s4)[n:] if x["action"] == "user_updated_password"))
pathlib.Path(__file__).with_name("out").joinpath("v9.txt").write_text("\n".join(v.out), encoding="utf-8")
