-- M30 — tenant_host_context (Gate F3 — قرار 2026-10-01)
-- المرجع: PLAN_v3.md §3.2 («الـsubdomain يحدد سياق المدرسة للواجهة، لكنه لا يمنح أي صلاحية»)؛ قرار F3↔D4
-- (tenant + school المستخرجان من الـsubdomain مصدر السياق، لا قيمة يختارها العميل في الجسم)؛ قرارات F3 1–5.
--
-- شكل الـhost:  {school}.{tenant}.{base} ← سياق مدرسة · {tenant}.{base} ← سياق Tenant · admin.{base} ← المنصة
--
-- 1. platform_tenants.host_label — معرّف DNS للـTenant، منفصل عن tenant_code (معرّف أعمال يسمح بـ`_` والأحرف
--    الكبيرة، فلا يصلح label). فريد على مستوى المنصة؛ `admin` و`api` و`www` محجوزة؛ لا يكتبه العميل (لا GRANT)؛
--    يُحدَّد في bootstrap_tenant. tenant_code لا يتغير.
-- 2. السياق = «أين يُبحث» فقط: دوال الدخول (M24، M26، M27) تبحث بـhost_label بدل tenant_code، ومعاملها
--    الجديد يسمّى بذلك. الجلسة الناتجة هوية الحساب وحده؛ السلطة من RLS كأي مستخدم (F4).
-- 3. app.login_context — المحلّل الوحيد للسياق: Tenant نشط بهذا الـlabel، و**إن سمّى الـhost مدرسةً** فمدرسة
--    نشطة فيه بهذا الـslug — وإلا لا شيء. فالـhost الذي يسمّي مدرسة مؤرشفة أو غير موجودة لا يجد أي حساب
--    (موظف، ولي أمر، طالب) — والرد الخارجي نفسه لكل الحالات (لا كشف وجود).
-- 4. bootstrap_tenant يستقبل host_label (توقيع جديد؛ نص M22 نفسه + العمود في الإدخال والـidempotency).

-- ------------------------------------------------------------------
-- 1. العمود
-- ------------------------------------------------------------------
alter table public.platform_tenants add column host_label text;
-- قاعدة قائمة (إن وُجدت صفوف): اشتقاق أولي من tenant_code؛ تصادم أو label محجوز يُفشل الـmigration صراحةً
update public.platform_tenants set host_label = lower(replace(tenant_code, '_', '-')) where host_label is null;
alter table public.platform_tenants
  alter column host_label set not null,
  add constraint platform_tenants_host_label_chk      check (host_label ~ '^[a-z0-9][a-z0-9-]{0,62}$'),
  add constraint platform_tenants_host_label_reserved check (host_label not in ('admin', 'api', 'www')),
  add constraint platform_tenants_host_label_uq       unique (host_label);
-- لا GRANT: SELECT على مستوى الجدول قائم (M20) ويشمله؛ لا INSERT ولا UPDATE لأي دور عميل

-- ------------------------------------------------------------------
-- 2. الدوال — تُستبدل (اسم المعامل يتغير) ثم تُعاد امتيازاتها كما كانت
-- ------------------------------------------------------------------
drop function app.resolve_student_login(text, text, text);
drop function app.otp_issue(text, text, text, text);
drop function app.otp_verify(text, text, text, text, text);
drop function app.password_login_account(text, text, text);
drop function app.password_login_result(text, text, text, boolean);
drop function app.login_account(text, text, text);
drop function app.bootstrap_tenant(uuid, text, text, uuid, text);

set local role app_owner;

-- المحلّل الوحيد لسياق الدخول
create function app.login_context(p_tenant_label text, p_school_slug text)
returns table (tenant_id uuid, school_id uuid)
language sql
stable
security definer
set search_path = app, public, pg_temp
as $$
  select t.id, sc.id
  from public.platform_tenants t
  left join public.schools sc
    on sc.platform_tenant_id = t.id and sc.slug = lower(btrim(p_school_slug)) and sc.status = 'active'
  where t.host_label = lower(btrim(p_tenant_label)) and t.status = 'active'
    and (p_school_slug is null or sc.id is not null)
$$;

-- M24 — الطالب: سياق مدرسة إلزامي
create function app.resolve_student_login(p_tenant_label text, p_school_slug text, p_identifier text)
returns uuid
language sql
stable
security definer
set search_path = app, public, pg_temp
as $$
  select case when count(*) = 1 then (array_agg(p.auth_user_id))[1] end
  from app.login_context(p_tenant_label, p_school_slug) c
  join public.schools sc on sc.id = c.school_id
  join public.identity_scopes i on i.owner_id = sc.scope_owner_id
  join public.students s
    on s.identity_scope_id = i.id and s.status = 'active'
   and (s.official_id = btrim(p_identifier) or s.temporary_id = upper(btrim(p_identifier)))
  join public.profiles p on p.id = s.student_profile_id
$$;

-- M26 — حساب نشط واحد أو لا شيء (I1)، داخل سياق صالح
create function app.login_account(p_tenant_label text, p_kind text, p_contact text, p_school_slug text default null)
returns table (account_id uuid, tenant_id uuid, entity_id uuid, locked boolean)
language sql
stable
security definer
set search_path = app, public, pg_temp
as $$
  select p.auth_user_id, c.tenant_id, g.id, coalesce(g.locked_until > now(), false)
  from app.login_context(p_tenant_label, p_school_slug) c
  join public.guardians g on g.platform_tenant_id = c.tenant_id and g.phone_e164 = btrim(p_contact) and g.status = 'active'
  join public.profiles p  on p.id = g.profile_id and p.status = 'active'
  where p_kind = 'guardian'
  union all
  select p.auth_user_id, c.tenant_id, s.id, coalesce(s.locked_until > now(), false)
  from app.login_context(p_tenant_label, p_school_slug) c
  join public.staff s    on s.platform_tenant_id = c.tenant_id and lower(btrim(s.email)) = lower(btrim(p_contact)) and s.status = 'active'
  join public.profiles p on p.id = s.profile_id and p.status = 'active'
  where p_kind = 'staff'
$$;

-- M27 — OTP بسياق المدرسة (النص نفسه؛ الحساب يُحَل داخل سياق الـhost)
create function app.otp_issue(p_tenant_label text, p_kind text, p_contact text, p_school_slug text default null)
returns text
language plpgsql
volatile
security definer
set search_path = app, public, pg_temp
as $$
declare a record; b bytea; v_code text; v_state text; v_mode text;
begin
  select * into a from app.login_account(p_tenant_label, p_kind, p_contact, p_school_slug);
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

create function app.otp_verify(p_tenant_label text, p_kind text, p_contact text, p_code text, p_school_slug text default null)
returns uuid
language plpgsql
volatile
security definer
set search_path = app, public, pg_temp
as $$
declare a record; c public.login_challenges%rowtype; v_state text; v_issued timestamptz; v_mode text;
begin
  select * into a from app.login_account(p_tenant_label, p_kind, p_contact, p_school_slug);
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

-- M26 — كلمة المرور: قبل الـgrant الحساب إن لم يكن مقفلاً؛ وبعده النتيجة
create function app.password_login_account(p_tenant_label text, p_kind text, p_contact text, p_school_slug text default null)
returns uuid
language sql
stable
security definer
set search_path = app, public, pg_temp
as $$
  select a.account_id from app.login_account(p_tenant_label, p_kind, p_contact, p_school_slug) a where not a.locked
$$;

create function app.password_login_result(p_tenant_label text, p_kind text, p_contact text, p_success boolean,
                                          p_school_slug text default null)
returns void
language plpgsql
volatile
security definer
set search_path = app, public, pg_temp
as $$
declare a record;
begin
  select * into a from app.login_account(p_tenant_label, p_kind, p_contact, p_school_slug);
  if found then
    perform app.login_outcome(p_kind, a.entity_id, p_success, case when p_success then 'password_login' else 'password_login_failed' end);
  end if;
end;
$$;

-- M22 — bootstrap_tenant: النص نفسه + host_label
create function app.bootstrap_tenant(p_tenant_id uuid, p_tenant_code text, p_host_label text, p_name text,
                                     p_admin_auth_user_id uuid, p_admin_display_name text)
returns uuid
language plpgsql security definer set search_path = app, public, pg_temp
as $$
declare v_membership uuid; v_existing record;
begin
  if not app.has_platform_permission('tenant.create') then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  -- idempotency: المعرّف نفسه بالمعطيات نفسها ← الموجود
  select t.tenant_code, t.host_label into v_existing from public.platform_tenants t where t.id = p_tenant_id;
  if found then
    if v_existing.tenant_code = p_tenant_code and v_existing.host_label = p_host_label and exists (
         select 1 from public.profiles p where p.platform_tenant_id = p_tenant_id and p.auth_user_id = p_admin_auth_user_id) then
      return p_tenant_id;
    end if;
    raise exception 'conflict: tenant % already exists with different data', p_tenant_id using errcode = '23505';
  end if;

  perform app.set_audit_context('bootstrap', 'bootstrap_tenant');
  insert into public.platform_tenants (id, tenant_code, host_label, name) values (p_tenant_id, p_tenant_code, p_host_label, p_name);
  v_membership := app.new_tenant_account(p_tenant_id, p_admin_auth_user_id, p_admin_display_name);
  insert into public.membership_roles (membership_id, role_id, platform_tenant_id, role_owner_key)
    values (v_membership, app.system_role_id('tenant_admin'), p_tenant_id, '00000000-0000-0000-0000-000000000000');
  insert into public.membership_scopes (membership_id, platform_tenant_id, scope_type)
    values (v_membership, p_tenant_id, 'tenant');
  perform app.set_audit_context(null, null);
  return p_tenant_id;
end;
$$;

reset role;

-- ------------------------------------------------------------------
-- 3. EXECUTE — كما كانت: الدخول قبل JWT ⇒ service_role وحده؛ الداخليتان لا لأحد؛ bootstrap في allowlist M20
-- ------------------------------------------------------------------
revoke all on function app.login_context(text, text), app.login_account(text, text, text, text),
                       app.resolve_student_login(text, text, text),
                       app.otp_issue(text, text, text, text), app.otp_verify(text, text, text, text, text),
                       app.password_login_account(text, text, text, text),
                       app.password_login_result(text, text, text, boolean, text),
                       app.bootstrap_tenant(uuid, text, text, text, uuid, text)
  from public;
grant execute on function app.resolve_student_login(text, text, text),
                          app.otp_issue(text, text, text, text), app.otp_verify(text, text, text, text, text),
                          app.password_login_account(text, text, text, text),
                          app.password_login_result(text, text, text, boolean, text)
  to service_role;
grant execute on function app.bootstrap_tenant(uuid, text, text, text, uuid, text) to authenticated;
