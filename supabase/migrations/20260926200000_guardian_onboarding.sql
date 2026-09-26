-- M27 — guardian_onboarding (Gate F2 / D4 — قرارات 2026-09-26)
-- المرجع: docs/F2_AUTHENTICATION.md §5؛ PLAN_v3.md المرحلة 9 (السطر 412) و§7.8
--
-- القرارات:
--   A = OTP ثم إنشاء كلمة مرور إجبارياً؛ B = OTP فقط وكلمة المرور اختيارية؛ C = كلمة مرور مؤقتة من المدرسة ثم تغيير إجباري
--   D4.1: النمط يحكم أول دخول (onboarding) فقط؛ بعده تحكم طرق الحساب نفسه (كلمة مرور إن وُجدت، OTP للاسترداد/فك القفل)
--   D4.2: الافتراضي A
--   التخزين: عمود على schools، لا يكتبه العميل؛ تغييره بدالة متحكَّم بها (security.manage + نطاق المدرسة)
--   المدرسة الهدف: مدرسة سياق الدخول (الـsubdomain، F3)، ويجب أن تكون المدرسة الحالية لابن نشط الارتباط؛ وإلا الرد نفسه
--   C: إصدار الكلمة المؤقتة بـsecurity.manage + ولي الأمر في النطاق الحالي
--
-- الآلية (تبني على M25 و M26 دون تغيير دلالتهما):
--   • حساب ولي الأمر الجديد pending (لم يُستكمل onboarding) — provision_account
--   • أثناء pending: OTP فقط عبر مدرسة سياق نمطها A أو B (C: لا OTP للـonboarding)
--       B ⇒ التحقق يفعّل الحساب مباشرة
--       A ⇒ التحقق يسجّل بدء الـonboarding (credential_issued_at من ساعة Supabase Auth)؛ الحساب يُفتح بعد تغيير
--           الكلمة عبر activate_first_login (D2، بلا تغيير)
--   • C: begin_guardian_temporary_password ← Admin API يضع الكلمة ← arm_guardian_temporary_password؛ ثم الدخول
--       بالكلمة، فالتغيير، فـactivate_first_login. للحساب غير المُستكمل فقط — إعادة الضبط مسار مستقل (5c)
--   • بعد active: لا أثر للنمط (D4.1)

-- ------------------------------------------------------------------
-- 1. النمط على المدرسة
-- ------------------------------------------------------------------
alter table public.schools
  add column guardian_first_login_mode text not null default 'A',
  add constraint schools_guardian_first_login_mode_chk check (guardian_first_login_mode in ('A', 'B', 'C'));

grant update (guardian_first_login_mode) on public.schools to app_owner;

set local role app_owner;

-- ------------------------------------------------------------------
-- 2. تغيير النمط — security.manage على المدرسة
-- ------------------------------------------------------------------
create function app.set_guardian_first_login_mode(p_school_id uuid, p_mode text, p_reason text)
returns text
language plpgsql
security definer
set search_path = app, public, pg_temp
as $$
declare v_current text;
begin
  if not app.has_permission('security.manage') then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  perform app.require_reason(p_reason);
  if p_mode is null or p_mode not in ('A', 'B', 'C') then
    raise exception 'mode must be A, B or C' using errcode = '22023';
  end if;
  select sc.guardian_first_login_mode into v_current from public.schools sc
   where sc.id = p_school_id and app.can_access_school(sc.id) for update;
  if not found then
    raise exception 'not found' using errcode = 'P0002';
  end if;
  if v_current = p_mode then
    return p_mode;
  end if;
  perform app.set_audit_context('set_guardian_first_login_mode', p_reason);
  update public.schools set guardian_first_login_mode = p_mode where id = p_school_id;
  perform app.set_audit_context(null, null);
  return p_mode;
end;
$$;

-- ------------------------------------------------------------------
-- 3. المدرسة الهدف: مدرسة السياق التي فيها ابن نشط الارتباط حالياً (أحدث تسجيل — H2) ⇒ نمطها، وإلا NULL
-- ------------------------------------------------------------------
create function app.guardian_onboarding_mode(p_guardian uuid, p_school_slug text)
returns text
language sql
stable
security definer
set search_path = app, public, pg_temp
as $$
  select sc.guardian_first_login_mode
  from public.guardians g
  join public.schools sc on sc.platform_tenant_id = g.platform_tenant_id
                        and sc.slug = lower(btrim(p_school_slug)) and sc.status = 'active'
  where g.id = p_guardian
    and exists (
      select 1 from public.student_guardians sg
       where sg.guardian_id = g.id and sg.status = 'active'
         and (select e.school_id from public.enrollments e where e.student_id = sg.student_id
               order by e.effective_from desc limit 1) = sc.id)
$$;

-- ------------------------------------------------------------------
-- 4. OTP بسياق المدرسة — تحل محل نسختي M26 (المعامل الجديد اختياري؛ الاستدعاء بثلاثة/أربعة معاملات يبقى صالحاً)
-- ------------------------------------------------------------------
drop function app.otp_issue(text, text, text);
drop function app.otp_verify(text, text, text, text);

create function app.otp_issue(p_tenant_code text, p_kind text, p_contact text, p_school_slug text default null)
returns text
language plpgsql
volatile
security definer
set search_path = app, public, pg_temp
as $$
declare a record; b bytea; v_code text; v_state text; v_mode text;
begin
  select * into a from app.login_account(p_tenant_code, p_kind, p_contact);
  if not found then
    return null;
  end if;
  -- D4: ولي أمر لم يُستكمل onboarding — عبر مدرسة سياق نمطها A أو B فقط
  select ai.credential_state into v_state from public.auth_identities ai where ai.auth_user_id = a.account_id;
  if p_kind = 'guardian' and v_state = 'pending' then
    v_mode := app.guardian_onboarding_mode(a.entity_id, p_school_slug);
    if v_mode is null or v_mode = 'C' then
      return null;
    end if;
  end if;
  update public.login_challenges set consumed_at = now() where account_id = a.account_id and consumed_at is null;
  b := extensions.gen_random_bytes(4);
  v_code := lpad((((get_byte(b, 0)::bigint << 24) + (get_byte(b, 1) << 16) + (get_byte(b, 2) << 8) + get_byte(b, 3)) % 1000000)::text, 6, '0');
  insert into public.login_challenges (platform_tenant_id, account_id, kind, code_hash, expires_at)
    values (a.tenant_id, a.account_id, p_kind, extensions.crypt(v_code, extensions.gen_salt('bf', 8)), now() + interval '5 minutes');
  return v_code;
end;
$$;

create function app.otp_verify(p_tenant_code text, p_kind text, p_contact text, p_code text, p_school_slug text default null)
returns uuid
language plpgsql
volatile
security definer
set search_path = app, public, pg_temp
as $$
declare a record; c public.login_challenges%rowtype; v_state text; v_issued timestamptz; v_mode text;
begin
  select * into a from app.login_account(p_tenant_code, p_kind, p_contact);
  if not found then
    return null;
  end if;
  select ai.credential_state, ai.credential_issued_at into v_state, v_issued
    from public.auth_identities ai where ai.auth_user_id = a.account_id for update;
  if p_kind = 'guardian' and v_state = 'pending' then
    v_mode := app.guardian_onboarding_mode(a.entity_id, p_school_slug);
    if v_mode is null or v_mode = 'C' then
      return null;
    end if;
  end if;
  select * into c from public.login_challenges
   where account_id = a.account_id and kind = p_kind and consumed_at is null and expires_at > now() and attempts < 5
   order by id desc limit 1
   for update;
  if not found then
    return null;
  end if;
  if c.code_hash <> extensions.crypt(coalesce(p_code, ''), c.code_hash) then
    update public.login_challenges
       set attempts = attempts + 1, consumed_at = case when attempts + 1 >= 5 then now() end
     where id = c.id;
    return null;
  end if;
  update public.login_challenges set consumed_at = now() where id = c.id;
  perform app.login_outcome(p_kind, a.entity_id, true, 'otp_login');
  -- D4 onboarding
  if v_mode = 'B' then
    perform app.set_audit_context('guardian_onboarding_b', null);
    update public.auth_identities set credential_state = 'active', credential_activated_at = now()
     where auth_user_id = a.account_id;
    perform app.set_audit_context(null, null);
  elsif v_mode = 'A' and v_issued is null then
    perform app.set_audit_context('guardian_onboarding_a', null);
    update public.auth_identities set credential_issued_at = app.auth_user_updated_at(a.account_id)
     where auth_user_id = a.account_id;
    perform app.set_audit_context(null, null);
  end if;
  return a.account_id;
end;
$$;

-- ------------------------------------------------------------------
-- 5. C — كلمة مرور مؤقتة من المدرسة (للحساب غير المُستكمل فقط)
-- ------------------------------------------------------------------
create function app.guardian_account_for_issue(p_guardian_id uuid)
returns uuid
language plpgsql
security definer
set search_path = app, public, pg_temp
as $$
declare v_account uuid; v_state text; v_activated timestamptz;
begin
  if not app.has_permission('security.manage') then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  select p.auth_user_id into v_account
    from public.guardians g join public.profiles p on p.id = g.profile_id
   where g.id = p_guardian_id and g.status = 'active' and app.guardian_in_scope(g.id);
  if not found then
    raise exception 'not found' using errcode = 'P0002';
  end if;
  select ai.credential_state, ai.credential_activated_at into v_state, v_activated
    from public.auth_identities ai where ai.auth_user_id = v_account for update;
  if v_state <> 'pending' or v_activated is not null then
    raise exception 'conflict: the guardian account is already onboarded — a reset is a separate flow (5c)' using errcode = '23505';
  end if;
  return v_account;
end;
$$;

-- قبل كتابة الكلمة: لحظة الإصدار تُمحى ⇒ لا تفعيل ممكن حتى الـarm (fail closed)
create function app.begin_guardian_temporary_password(p_guardian_id uuid)
returns uuid
language plpgsql
security definer
set search_path = app, public, pg_temp
as $$
declare v_account uuid := app.guardian_account_for_issue(p_guardian_id);
begin
  perform app.set_audit_context('issue_temporary_password', null);
  update public.auth_identities set credential_issued_at = null where auth_user_id = v_account;
  perform app.set_audit_context(null, null);
  return v_account;
end;
$$;

-- بعد كتابتها عبر Admin API: لحظة الإصدار = auth.users.updated_at (ساعة Supabase Auth)
create function app.arm_guardian_temporary_password(p_guardian_id uuid)
returns text
language plpgsql
security definer
set search_path = app, public, pg_temp
as $$
declare v_account uuid := app.guardian_account_for_issue(p_guardian_id);
begin
  perform app.set_audit_context('arm_temporary_password', null);
  update public.auth_identities set credential_issued_at = app.auth_user_updated_at(v_account)
   where auth_user_id = v_account and credential_issued_at is null;
  perform app.set_audit_context(null, null);
  return 'pending';
end;
$$;

-- ------------------------------------------------------------------
-- 6. provision_account — حساب ولي الأمر يولد pending (نص M26 + سطر D4)
-- ------------------------------------------------------------------
create or replace function app.provision_account(p_kind text, p_target_id uuid, p_auth_user_id uuid)
returns uuid                                   -- profile id
language plpgsql security definer set search_path = app, public, pg_temp
as $$
declare v_tenant uuid; v_current uuid; v_name text; v_membership uuid; v_profile uuid;
begin
  if not app.has_permission('membership.create') then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  -- I2 (D3): معرّف حساب Auth = معرّف ولي الأمر/الموظف
  if p_auth_user_id is distinct from p_target_id then
    raise exception 'invariant: account id must equal the guardian/staff id (D3/I2)' using errcode = '22023';
  end if;
  if p_kind = 'staff' then
    select s.platform_tenant_id, s.profile_id, btrim(s.first_name || ' ' || s.family_name) into v_tenant, v_current, v_name
      from public.staff s where s.id = p_target_id and app.staff_in_scope(s.id) for update;
  elsif p_kind = 'guardian' then
    select g.platform_tenant_id, g.profile_id, btrim(g.first_name || ' ' || g.family_name) into v_tenant, v_current, v_name
      from public.guardians g where g.id = p_target_id and app.guardian_in_scope(g.id) and g.status = 'active' for update;
  else
    raise exception 'kind must be staff or guardian' using errcode = '22023';
  end if;
  if not found then raise exception 'not found' using errcode = 'P0002'; end if;
  if v_current is not null then
    if exists (select 1 from public.profiles p where p.id = v_current and p.auth_user_id = p_auth_user_id) then
      return v_current;
    end if;
    raise exception 'conflict: % % already has an account', p_kind, p_target_id using errcode = '23505';
  end if;

  perform app.set_audit_context('provision', 'provision_account');
  v_membership := app.new_tenant_account(v_tenant, p_auth_user_id, v_name);
  select m.profile_id into v_profile from public.memberships m where m.id = v_membership;
  if p_kind = 'guardian' then
    -- D4 (M27): الحساب لم يُستكمل onboarding — يحكمه نمط مدرسة السياق عند أول دخول
    update public.auth_identities set credential_state = 'pending' where auth_user_id = p_auth_user_id;
    insert into public.membership_roles (membership_id, role_id, platform_tenant_id, role_owner_key)
      values (v_membership, app.system_role_id('guardian'), v_tenant, '00000000-0000-0000-0000-000000000000');
    update public.guardians set profile_id = v_profile where id = p_target_id;
  else
    update public.staff set profile_id = v_profile where id = p_target_id;
  end if;
  perform app.set_audit_context(null, null);
  return v_profile;
end;
$$;

reset role;

-- EXECUTE
revoke all on function app.set_guardian_first_login_mode(uuid, text, text), app.guardian_onboarding_mode(uuid, text),
                       app.otp_issue(text, text, text, text), app.otp_verify(text, text, text, text, text),
                       app.guardian_account_for_issue(uuid), app.begin_guardian_temporary_password(uuid),
                       app.arm_guardian_temporary_password(uuid)
  from public;
grant execute on function app.otp_issue(text, text, text, text), app.otp_verify(text, text, text, text, text) to service_role;
grant execute on function app.set_guardian_first_login_mode(uuid, text, text), app.begin_guardian_temporary_password(uuid),
                          app.arm_guardian_temporary_password(uuid)
  to authenticated;
