-- M26 — tenant_account_login (Gate F2 / D3 — معتمد 2026-09-26 بعد Spike D3)
-- المرجع: docs/F2_AUTHENTICATION.md §4 و§4.1؛ CLAUDE.md §6 (D3، I1، I2)
--
-- هوية اصطناعية لكل حساب Tenant (ولي أمر، موظف): الهاتف/البريد الحقيقي في guardians/staff، وحساب Auth
-- معرّفه = معرّف الكيان (I2) وبريده اصطناعي لا يغادر الخادم. الجلسة يصدرها Supabase Auth
-- (Admin generate_link + /verify في FastAPI) — لا JWT يُصنع خارج Supabase Auth.
--
-- 1. staff: أعمدة القفل (نظير guardians) + البريد فريد داخل الـTenant (tenant + email ⇒ حساب واحد)
-- 2. login_challenges: تحديات OTP — hash (bcrypt) لا نص؛ بلا وصول عميل؛ **بلا T7** (لا تُنسخ الـhashes إلى audit_log)
-- 3. دوال متحكَّم بها قبل JWT (EXECUTE لـservice_role وحده):
--      otp_issue / otp_verify / password_login_account / password_login_result
--    والمحلّل الداخلي login_account (لا EXECUTE لأحد): tenant + (هاتف | بريد) ⇒ حساب
--    I1: الحساب الموقوف (profile أو الكيان أو الـTenant) لا يبدأ مصادقة أصلاً — ولا يختلف الرد الخارجي.
-- 4. provision_account: I2 مفروض في DB (معرّف الحساب = معرّف ولي الأمر/الموظف)
--
-- الافتراضيات (للمراجعة): صلاحية الرمز 5 دقائق؛ 5 محاولات لكل تحدٍّ؛ طلب جديد يُبطل ما قبله؛
-- 5 إخفاقات كلمة مرور ⇒ قفل 15 دقيقة؛ نجاح OTP يفك القفل (PLAN §7.8: «فك القفل ذاتياً عبر OTP»)؛
-- الموظف يدخل بحالة `active` فقط.

-- ------------------------------------------------------------------
-- 1. staff
-- ------------------------------------------------------------------
alter table public.staff
  add column failed_login_count int not null default 0,
  add column locked_until       timestamptz,
  add column last_login_at      timestamptz,
  add constraint staff_failed_login_chk check (failed_login_count >= 0);

create unique index staff_tenant_email_uq on public.staff (platform_tenant_id, lower(btrim(email))) where email is not null;

-- كنظيرها في guardians: مقروءة لمن يقرأ الصف، لا يكتبها العميل
grant select (failed_login_count, locked_until, last_login_at) on public.staff to authenticated;

-- ------------------------------------------------------------------
-- 2. login_challenges
-- ------------------------------------------------------------------
create table public.login_challenges (
  id                 bigint      generated always as identity,
  platform_tenant_id uuid        not null,
  account_id         uuid        not null,
  kind               text        not null,
  code_hash          text        not null,
  attempts           int         not null default 0,
  expires_at         timestamptz not null,
  consumed_at        timestamptz,
  created_at         timestamptz not null default now(),
  constraint login_challenges_pkey          primary key (id),
  constraint login_challenges_tenant_fk     foreign key (platform_tenant_id) references public.platform_tenants (id),
  constraint login_challenges_account_fk    foreign key (account_id) references public.auth_identities (auth_user_id),
  constraint login_challenges_kind_chk      check (kind in ('guardian', 'staff')),
  constraint login_challenges_attempts_chk  check (attempts between 0 and 5)
);
create index login_challenges_account_idx on public.login_challenges (account_id, id desc);

alter table public.login_challenges enable row level security;
alter table public.login_challenges force  row level security;
revoke all on public.login_challenges from anon, authenticated, service_role;
grant select, insert, update on public.login_challenges to app_owner;

-- pgcrypto (schema extensions — ملك postgres) لـbcrypt الرمز وتوليده
grant usage on schema extensions to app_owner;

set local role app_owner;

-- ------------------------------------------------------------------
-- 3. المحلّل الداخلي — حساب نشط واحد أو لا شيء (I1)
-- ------------------------------------------------------------------
create function app.login_account(p_tenant_code text, p_kind text, p_contact text)
returns table (account_id uuid, tenant_id uuid, entity_id uuid, locked boolean)
language sql
stable
security definer
set search_path = app, public, pg_temp
as $$
  select p.auth_user_id, t.id, g.id, coalesce(g.locked_until > now(), false)
  from public.platform_tenants t
  join public.guardians g on g.platform_tenant_id = t.id and g.phone_e164 = btrim(p_contact) and g.status = 'active'
  join public.profiles p  on p.id = g.profile_id and p.status = 'active'
  where p_kind = 'guardian' and t.tenant_code = upper(btrim(p_tenant_code)) and t.status = 'active'
  union all
  select p.auth_user_id, t.id, s.id, coalesce(s.locked_until > now(), false)
  from public.platform_tenants t
  join public.staff s    on s.platform_tenant_id = t.id and lower(btrim(s.email)) = lower(btrim(p_contact)) and s.status = 'active'
  join public.profiles p on p.id = s.profile_id and p.status = 'active'
  where p_kind = 'staff' and t.tenant_code = upper(btrim(p_tenant_code)) and t.status = 'active'
$$;

-- تسجيل نتيجة الدخول على الكيان (T7 يدقّقها بفعلها)
create function app.login_outcome(p_kind text, p_entity uuid, p_success boolean, p_action text)
returns void
language plpgsql
security definer
set search_path = app, public, pg_temp
as $$
begin
  perform app.set_audit_context(p_action, null);
  if p_kind = 'guardian' then
    update public.guardians
       set failed_login_count = case when p_success then 0 else failed_login_count + 1 end,
           locked_until       = case when p_success then null
                                     when failed_login_count + 1 >= 5 then now() + interval '15 minutes'
                                     else locked_until end,
           last_login_at      = case when p_success then now() else last_login_at end
     where id = p_entity;
  else
    update public.staff
       set failed_login_count = case when p_success then 0 else failed_login_count + 1 end,
           locked_until       = case when p_success then null
                                     when failed_login_count + 1 >= 5 then now() + interval '15 minutes'
                                     else locked_until end,
           last_login_at      = case when p_success then now() else last_login_at end
     where id = p_entity;
  end if;
  perform app.set_audit_context(null, null);
end;
$$;

-- ------------------------------------------------------------------
-- OTP — الإصدار: الرمز يعود لـFastAPI ليرسله؛ المخزَّن bcrypt. NULL = لا حساب (الرد الخارجي نفسه)
-- ------------------------------------------------------------------
create function app.otp_issue(p_tenant_code text, p_kind text, p_contact text)
returns text
language plpgsql
volatile
security definer
set search_path = app, public, pg_temp
as $$
declare a record; b bytea; v_code text;
begin
  select * into a from app.login_account(p_tenant_code, p_kind, p_contact);
  if not found then
    return null;
  end if;
  update public.login_challenges set consumed_at = now() where account_id = a.account_id and consumed_at is null;
  b := extensions.gen_random_bytes(4);
  v_code := lpad((((get_byte(b, 0)::bigint << 24) + (get_byte(b, 1) << 16) + (get_byte(b, 2) << 8) + get_byte(b, 3)) % 1000000)::text, 6, '0');
  insert into public.login_challenges (platform_tenant_id, account_id, kind, code_hash, expires_at)
    values (a.tenant_id, a.account_id, p_kind, extensions.crypt(v_code, extensions.gen_salt('bf', 8)), now() + interval '5 minutes');
  return v_code;
end;
$$;

-- OTP — التحقق: معرّف الحساب أو NULL. نجاح ⇒ استهلاك + فك القفل (PLAN §7.8)
create function app.otp_verify(p_tenant_code text, p_kind text, p_contact text, p_code text)
returns uuid
language plpgsql
volatile
security definer
set search_path = app, public, pg_temp
as $$
declare a record; c public.login_challenges%rowtype;
begin
  select * into a from app.login_account(p_tenant_code, p_kind, p_contact);
  if not found then
    return null;
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
  return a.account_id;
end;
$$;

-- كلمة المرور — قبل الـgrant: الحساب إن لم يكن مقفلاً؛ وبعده: النتيجة (تعدّ الإخفاقات وتقفل)
create function app.password_login_account(p_tenant_code text, p_kind text, p_contact text)
returns uuid
language sql
stable
security definer
set search_path = app, public, pg_temp
as $$
  select a.account_id from app.login_account(p_tenant_code, p_kind, p_contact) a where not a.locked
$$;

create function app.password_login_result(p_tenant_code text, p_kind text, p_contact text, p_success boolean)
returns void
language plpgsql
volatile
security definer
set search_path = app, public, pg_temp
as $$
declare a record;
begin
  select * into a from app.login_account(p_tenant_code, p_kind, p_contact);
  if found then
    perform app.login_outcome(p_kind, a.entity_id, p_success, case when p_success then 'password_login' else 'password_login_failed' end);
  end if;
end;
$$;

-- ------------------------------------------------------------------
-- 4. provision_account — I2 (نص M22 + فحص)
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

-- EXECUTE: قبل JWT ⇒ service_role وحده؛ الداخليتان لا لأحد
revoke all on function app.login_account(text, text, text), app.login_outcome(text, uuid, boolean, text),
                       app.otp_issue(text, text, text), app.otp_verify(text, text, text, text),
                       app.password_login_account(text, text, text), app.password_login_result(text, text, text, boolean)
  from public;
grant execute on function app.otp_issue(text, text, text), app.otp_verify(text, text, text, text),
                          app.password_login_account(text, text, text), app.password_login_result(text, text, text, boolean)
  to service_role;
