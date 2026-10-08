"""Phase 3A / 3-2 — حساب الموظف ودوره ونطاق مدرسته (docs/PHASE3_2_ACCOUNT_ACCESS.md) على seed التطوير (E5).

ما يُثبت: التفعيل الذري (حساب + نطاق المدرسة + دور) ثم **دخول فعلي بـOTP** من host المدرسة؛ T8 سقف الدور؛ العلاقة
(M47) وسياسة النطاق تحكمان المنح؛ السحب بسبب عبر G2 يزيل المفاتيح فوراً؛ لا إدارة ذاتية؛ لا سياق ولا سلطة من الجسم؛
التعويض عند الرفض. لا migration في 3-2. كل ما يُنشأ يحمل الرمز ZTA ويُحذف في نهاية الوحدة.
"""

import uuid

import pytest

from conftest import STAFF_ID, auth, origin

ZTA = "select id from public.staff where employee_code like 'ZTA%'"


@pytest.fixture(scope="module", autouse=True)
def _cleanup(admin):
    yield
    profiles = f"select profile_id from public.staff where employee_code like 'ZTA%' and profile_id is not null"
    members = f"select id from public.memberships where profile_id in ({profiles})"
    ids = [r["id"] for r in admin.execute(ZTA).fetchall()]
    pids = [r["profile_id"] for r in admin.execute(profiles).fetchall()]
    for stmt in (
        f"delete from public.membership_roles where membership_id in ({members})",
        f"delete from public.membership_scopes where membership_id in ({members})",
        f"delete from public.memberships where profile_id in ({profiles})",
        f"delete from public.staff_school_assignments where staff_id in ({ZTA})",
        "delete from public.staff where employee_code like 'ZTA%'",
    ):
        admin.execute(stmt)
    admin.execute("delete from public.profiles where id = any(%s)", [pids])
    admin.execute("delete from public.login_challenges where account_id = any(%s)", [ids])
    admin.execute("delete from public.auth_identities where auth_user_id = any(%s)", [ids])
    admin.execute("delete from auth.users where id = any(%s)", [ids])


def post(client, who, path, body=None):
    return client.post(path, json=body or {}, headers=auth(who))


def get(client, who, path):
    return client.get(path, headers=auth(who))


def bearer(token):
    return {"Authorization": f"Bearer {token}"}


@pytest.fixture(scope="module")
def role(admin):
    return {r["code"]: str(r["id"]) for r in admin.execute("select code, id from public.roles where platform_tenant_id is null").fetchall()}


def make_staff(client, who, school, code, email=True):
    body = {"employee_code": code, "first_name": "Zt", "family_name": code, "job_title": "Teacher", "effective_from": "2026-09-01"}
    if email:
        body["email"] = f"{code.lower()}@example.test"
    r = post(client, who, f"/schools/{school}/staff", body)
    assert r.status_code == 201, r.text
    return r.json()["id"]


def auth_user_exists(admin, staff_id):
    return admin.execute("select 1 as x from auth.users where id = %s", [staff_id]).fetchone() is not None


def otp_login(client, email, school="school-a"):
    """دخول الموظف الحقيقي: طلب رمز من host المدرسة، قراءته من المرسل، ثم جلسة Supabase Auth."""
    h = origin("dev", school)
    assert client.post("/auth/otp/request", json={"kind": "staff", "contact": email}, headers=h).status_code == 202
    codes = [c for _, to, c in client.app.state.otp_sender.messages if to == email]
    assert codes, "no OTP was sent — the account cannot start authentication"
    r = client.post("/auth/otp/verify", json={"kind": "staff", "contact": email, "code": codes[-1]}, headers=h)
    assert r.status_code == 200, r.text
    return r.json()["access_token"]


def caps(client, token):
    return set(client.get("/me/capabilities", headers=bearer(token)).json()["permissions"])


@pytest.fixture(scope="module")
def teacher(client, ids, role):
    """ZTA-1: يفعّله مدير المدرسة بدور المعلم ونطاق SA — الحالة المشتركة لاختبارات المنح والسحب."""
    sa = ids["school"]["SA"]
    sid = make_staff(client, "school_admin", sa, "ZTA-1")
    r = post(client, "school_admin", f"/schools/{sa}/staff/{sid}/account", {"role_id": role["teacher"]})
    assert r.status_code == 201, r.text
    return {"id": sid, "email": "zta-1@example.test", "activation": r.json()}


def test_activation_is_one_call_and_the_staff_member_really_logs_in(client, ids, role, teacher):
    sa, sb = ids["school"]["SA"], ids["school"]["SB"]
    a = teacher["activation"]
    assert (a["has_account"], a["membership_status"], a["can_login"]) == (True, "active", True)
    assert [r["code"] for r in a["roles"]] == ["teacher"]
    assert [(s["scope_type"], s["school_id"]) for s in a["scopes"]] == [("school", sa)]
    # الدخول الفعلي بـOTP من host المدرسة، ثم ما يسمح به دور المعلم داخل مدرسته وحدها
    token = otp_login(client, teacher["email"])
    mine = caps(client, token)
    assert {"staff.read", "student.read_assigned", "subject.read"} <= mine      # 3-4 (M51): المعلم يقرأ الطلاب بالتكليف وحده
    assert not ({"student.read", "profile.read", "staff.update", "role.assign", "membership.read"} & mine)
    assert client.get(f"/schools/{sa}/staff", headers=bearer(token)).status_code == 200
    assert client.get(f"/schools/{sb}/staff", headers=bearer(token)).status_code == 404
    assert client.get(f"/staff/{teacher['id']}/access", headers=bearer(token)).status_code == 403      # بلا membership.read
    # إعادة التفعيل آمنة وبلا أثر
    again = post(client, "school_admin", f"/schools/{sa}/staff/{teacher['id']}/account", {"role_id": role["teacher"]})
    assert (again.status_code, [r["code"] for r in again.json()["roles"]], len(again.json()["scopes"])) == (200, ["teacher"], 1)
    assert get(client, "school_admin", f"/staff/{teacher['id']}/access").json() == again.json()


def test_refused_role_leaves_nothing_behind(client, ids, role, admin):
    """T8 سقف الدور؛ والرفض ذري: لا عضوية ولا نطاق ولا حساب Auth متروك."""
    sa = ids["school"]["SA"]
    sid = make_staff(client, "school_admin", sa, "ZTA-2")
    r = post(client, "school_admin", f"/schools/{sa}/staff/{sid}/account", {"role_id": role["tenant_admin"]})
    assert (r.status_code, r.json()["detail"]) == (403, "role_exceeds_authority")
    assert "tenant." not in r.text                                                    # الرد لا يسرد المفاتيح
    assert admin.execute("select profile_id from public.staff where id = %s", [sid]).fetchone()["profile_id"] is None
    assert not auth_user_exists(admin, sid)
    assert get(client, "school_admin", f"/staff/{sid}/access").json()["has_account"] is False
    # دور غير موجود ← 404 وبلا أثر كذلك
    assert post(client, "school_admin", f"/schools/{sa}/staff/{sid}/account", {"role_id": str(uuid.uuid4())}).status_code == 404
    assert not auth_user_exists(admin, sid)
    # ثم التفعيل الصحيح ينجح على الموظف نفسه
    assert post(client, "school_admin", f"/schools/{sa}/staff/{sid}/account", {"role_id": role["secretary"]}).status_code == 201


def test_relationship_and_scope_decide(client, ids, role, admin):
    sa, sb = ids["school"]["SA"], ids["school"]["SB"]
    sb_staff = make_staff(client, "tenant_admin", sb, "ZTA-B")
    # موظف مدرسة أخرى، ومدرسة خارج النطاق: غير موجودين لمدير SA
    assert post(client, "school_admin", f"/schools/{sa}/staff/{sb_staff}/account", {"role_id": role["teacher"]}).status_code == 404
    assert post(client, "school_admin", f"/schools/{sb}/staff/{sb_staff}/account", {"role_id": role["teacher"]}).status_code == 404
    assert get(client, "school_admin", f"/staff/{sb_staff}/access").status_code == 404
    assert not auth_user_exists(admin, sb_staff)
    # tenant_admin كما كان: يفعّل موظف SB
    ok = post(client, "tenant_admin", f"/schools/{sb}/staff/{sb_staff}/account", {"role_id": role["teacher"]})
    assert (ok.status_code, [s["school_id"] for s in ok.json()["scopes"]]) == (201, [sb])
    # موظف SA مطلوب له حساب في SB بلا تكليف فيها: رسالة واضحة (والأمان في DB)
    sa_staff = make_staff(client, "school_admin", sa, "ZTA-3")
    r = post(client, "tenant_admin", f"/schools/{sb}/staff/{sa_staff}/account", {"role_id": role["teacher"]})
    assert (r.status_code, r.json()["detail"]) == (422, "staff_not_assigned")
    assert not auth_user_exists(admin, sa_staff)
    # بلا بريد: لا حساب (الدخول OTP على البريد)
    no_mail = make_staff(client, "school_admin", sa, "ZTA-4", email=False)
    r = post(client, "school_admin", f"/schools/{sa}/staff/{no_mail}/account", {"role_id": role["teacher"]})
    assert (r.status_code, r.json()["detail"]) == (422, "email_required")
    assert not auth_user_exists(admin, no_mail)


def test_grant_and_revoke_take_effect_at_once(client, ids, role, teacher, admin):
    sa = ids["school"]["SA"]
    token = otp_login(client, teacher["email"])
    base = f"/staff/{teacher['id']}/access"
    assert "student.create" not in caps(client, token)
    more = post(client, "school_admin", f"{base}/roles/{role['secretary']}")
    assert (more.status_code, [r["code"] for r in more.json()["roles"]]) == (200, ["secretary", "teacher"])
    assert "student.create" in caps(client, token)                                       # الجلسة نفسها، المفاتيح من DB
    assert post(client, "school_admin", f"{base}/roles/{role['secretary']}").status_code == 200   # مكرر: بلا أثر
    assert post(client, "school_admin", f"{base}/roles/{role['tenant_admin']}").json()["detail"] == "role_exceeds_authority"
    # السحب بسبب
    assert post(client, "school_admin", f"{base}/roles/{role['secretary']}/revoke").status_code == 422
    gone = post(client, "school_admin", f"{base}/roles/{role['secretary']}/revoke", {"reason": "no longer front desk"})
    assert (gone.status_code, [r["code"] for r in gone.json()["roles"]]) == (200, ["teacher"])
    assert "student.create" not in caps(client, token)
    assert post(client, "school_admin", f"{base}/roles/{role['secretary']}/revoke", {"reason": "again"}).status_code == 404
    last = admin.execute("select action, reason, actor_type from public.audit_log where entity_type = 'membership_roles' order by id desc limit 1").fetchone()
    assert (last["action"], last["reason"], last["actor_type"]) == ("delete", "no longer front desk", "tenant_user")
    # سحب نطاق المدرسة: المدرسة تختفي من جلسة الموظف فوراً؛ ثم مدير المدرسة يعيده (M47: عضوية بلا نطاقات + تكليف نشط)
    off = post(client, "school_admin", f"/schools/{sa}/staff/{teacher['id']}/access-scope/revoke", {"reason": "pause"})
    assert (off.status_code, off.json()["scopes"]) == (200, [])
    assert client.get(f"/schools/{sa}/staff", headers=bearer(token)).status_code == 404
    back = post(client, "school_admin", f"/schools/{sa}/staff/{teacher['id']}/access-scope")
    assert (back.status_code, [s["school_id"] for s in back.json()["scopes"]]) == (200, [sa])
    assert client.get(f"/schools/{sa}/staff", headers=bearer(token)).status_code == 200


def test_scope_outside_the_actor_and_the_subset_rule(client, ids, role, teacher):
    sa, sb = ids["school"]["SA"], ids["school"]["SB"]
    # مدير SA لا يمنح نطاق SB (المدرسة غير موجودة له)
    assert post(client, "school_admin", f"/schools/{sb}/staff/{teacher['id']}/access-scope").status_code == 404
    # tenant_admin: بلا تكليف في SB ← رسالة؛ بعد التكليف ← نطاق SB
    assert post(client, "tenant_admin", f"/schools/{sb}/staff/{teacher['id']}/access-scope").json()["detail"] == "staff_not_assigned"
    assert post(client, "tenant_admin", f"/schools/{sb}/staff-assignments",
                {"staff_id": teacher["id"], "job_title": "Teacher", "effective_from": "2026-09-01"}).status_code == 201
    both = post(client, "tenant_admin", f"/schools/{sb}/staff/{teacher['id']}/access-scope")
    assert sorted(s["school_id"] for s in both.json()["scopes"]) == sorted([sa, sb])
    # بعدها العضوية تتجاوز نطاق مدير SA: يراها ولا يديرها (كل نطاقات الهدف ⊆ الفاعل — F4)
    seen = get(client, "school_admin", f"/staff/{teacher['id']}/access")
    # دلالة قائمة (سياسة membership_scopes): صف نطاق SB يظهر بمعرّفه، بلا اسم المدرسة ولا رمزها — ولا يمنح مدير SA وصولاً إليها
    assert seen.status_code == 200 and {s["school_id"]: (s["name"], s["school_code"]) != (None, None) for s in seen.json()["scopes"]} == {sa: True, sb: False}
    assert get(client, "school_admin", f"/schools/{sb}/staff").status_code == 404
    assert post(client, "school_admin", f"/staff/{teacher['id']}/access/roles/{role['accountant']}").status_code == 403
    assert post(client, "school_admin", f"/staff/{teacher['id']}/access/roles/{role['teacher']}/revoke", {"reason": "x"}).status_code == 403
    assert post(client, "school_admin", f"/schools/{sa}/staff/{teacher['id']}/access-scope/revoke", {"reason": "x"}).status_code == 403
    assert [r["code"] for r in get(client, "tenant_admin", f"/staff/{teacher['id']}/access").json()["roles"]] == ["teacher"]
    # سحب نطاق مدرسة واحدة لا يمس نطاق الأخرى (G2 على صف تلك المدرسة وحده)
    only_sa = post(client, "tenant_admin", f"/schools/{sb}/staff/{teacher['id']}/access-scope/revoke", {"reason": "left SB"})
    assert (only_sa.status_code, [s["school_id"] for s in only_sa.json()["scopes"]]) == (200, [sa])


def test_no_self_management_and_readers(client, ids, role, teacher, admin):
    sa = ids["school"]["SA"]
    me = STAFF_ID["school_admin"]
    assert post(client, "school_admin", f"/staff/{me}/access/roles/{role['teacher']}").status_code == 403
    assert post(client, "school_admin", f"/schools/{sa}/staff/{me}/access-scope/revoke", {"reason": "x"}).status_code == 403
    # المعلم: يرى الموظف (staff.read) ولا يقرأ الوصول ولا يكتبه؛ محاولته لا تترك حساب Auth
    fresh = make_staff(client, "school_admin", sa, "ZTA-5")
    assert get(client, "teacher", f"/staff/{fresh}/access").status_code == 403
    assert post(client, "teacher", f"/schools/{sa}/staff/{fresh}/account", {"role_id": role["teacher"]}).status_code == 403
    assert not auth_user_exists(admin, fresh)
    assert admin.execute("select profile_id from public.staff where id = %s", [fresh]).fetchone()["profile_id"] is None
    # السكرتير لا يرى الموظف أصلاً
    assert get(client, "secretary", f"/staff/{fresh}/access").status_code == 404
    assert post(client, "secretary", f"/schools/{sa}/staff/{fresh}/account", {"role_id": role["teacher"]}).status_code == 404
    assert get(client, "platform", f"/staff/{fresh}/access").status_code == 404


def test_assignable_roles_are_display_only(client, ids, teacher):
    rows = {r["code"]: r for r in get(client, "school_admin", f"/staff/{teacher['id']}/access/assignable-roles").json()["rows"]}
    assert rows["teacher"]["assignable"] is True and rows["tenant_admin"]["assignable"] is False
    # T8 = «صلاحيات الدور ⊆ صلاحيات الفاعل»: مدير المدرسة يسند دوراً مساوياً له (school_admin) ولا يسند group_manager — سلوك Foundation كما هو
    assert rows["school_admin"]["assignable"] is True and rows["group_manager"]["assignable"] is False
    assert "guardian" not in rows and "student" not in rows
    ta = {r["code"]: r["assignable"] for r in get(client, "tenant_admin", f"/staff/{teacher['id']}/access/assignable-roles").json()["rows"]}
    assert ta["school_admin"] is True and ta["teacher"] is True
    assert get(client, "secretary", f"/staff/{teacher['id']}/access/assignable-roles").status_code == 404


def test_no_context_or_authority_from_the_body(client, ids, role, teacher):
    sa, sb = ids["school"]["SA"], ids["school"]["SB"]
    path = f"/schools/{sa}/staff/{teacher['id']}/account"
    for extra in ({"school_id": sb}, {"membership_id": str(uuid.uuid4())}, {"platform_tenant_id": ids["tenant"]}, {"scope_type": "tenant"}):
        assert post(client, "school_admin", path, {"role_id": role["teacher"], **extra}).status_code == 422
    assert post(client, "school_admin", path, {}).status_code == 422
    assert post(client, "school_admin", f"/staff/{teacher['id']}/access/roles/{role['teacher']}/revoke",
                {"reason": "x", "membership_id": str(uuid.uuid4())}).status_code == 422
    assert client.delete(f"/staff/{teacher['id']}/access/roles/{role['teacher']}", headers=auth("school_admin")).status_code in (404, 405)
