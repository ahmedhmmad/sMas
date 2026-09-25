-- M22 — provisioning_functions
-- المرجع: docs/DB_IMPLEMENTATION_SPEC_v1.md §5.1، §5.2، §5.4 (Saga)، §5.0.2؛ قرارات G4، G8، H1، O1، O3، G10، M20، M21b
--
-- صف الهوية يولد مع العلاقة التي تجعله مرئياً (§5.1)، ولا يُنشأ إلا هنا (G4 — لا INSERT مباشر، M20):
--   provision_student   profile + membership + دور student + (family) + student + enrollment
--   provision_staff     staff + أول تكليف
--   provision_guardian  guardian + ارتباط بطالب
--   provision_account   profile + membership (+ دور guardian) لموظف/ولي أمر قائم
--   bootstrap_tenant    tenant + profile + membership + دور tenant_admin + نطاق tenant
--
-- العقد (§5.0.2) كما في M21: الصلاحية أولاً، النطاق على صفوف مقروءة من الجداول، عدم الكشف (P0002)، invariants،
-- سياق التدقيق يُضبط ثم يُصفَّر، SECURITY DEFINER بهوية app_owner، لا p_actor، لا SQL ديناميكي.
--
-- Saga (§5.4): auth.users يُنشأ خارج المعاملة (Admin API). الدالة معاملة واحدة: فشلها لا يترك profile ولا student؛
-- تعويض auth user مسؤولية FastAPI. Idempotency: المعرّف الذي يولّده العميل (student_id …) مفتاحها —
-- إعادة الطلب نفسه تُرجع الكيان القائم دون إنشاء ثانٍ؛ المعرّف نفسه بمعطيات مختلفة = تعارض (23505).
--
-- H1: provision_student لا تقبل identity_scope_id؛ تشتقه من المدرسة الهدف (schools.scope_owner_id). ولا تُرجعه.
-- المخرجات: المعرّف فقط — لا بيانات نطاق الهوية.
--
-- قرار 2026-09-26: bootstrap_tenant يُستدعى بـJWT الـPlatform Admin (has_platform_permission('tenant.create'))،
-- فالفاعل مُتحقَّق منه في DB ومُدقَّق كـplatform_admin. T8 يُعفى إعفاءً ضيقاً: سياق المنصة + tenant.create، على
-- INSERT في membership_roles/membership_scopes فقط — آمن لأن Platform Admin بلا أي سياسة RLS على الجدولين،
-- فلا يكتب فيهما إلا من داخل هذه الدالة.

-- ------------------------------------------------------------------
-- 1. T8 — الإعفاء الضيق (M19 باقية في التاريخ؛ الجسم يُستبدل بالاسم نفسه)
-- ------------------------------------------------------------------
set local role app_owner;

create or replace function app.tg_authz_integrity()
returns trigger
language plpgsql
security definer
set search_path = app, public, pg_temp
as $$
declare
  v_row     jsonb := case when tg_op = 'DELETE' then to_jsonb(old) else to_jsonb(new) end;
  v_missing text;
begin
  if app.auth_uid() is null then          -- G7: سياق service مُعفى
    return null;
  end if;
  -- قرار 2026-09-26: bootstrap_tenant — سياق المنصة + tenant.create، إدراج فقط، في الجدولين فقط
  if tg_op = 'INSERT'
     and tg_table_name in ('membership_roles', 'membership_scopes')
     and app.current_security_context() = 'platform'
     and app.has_platform_permission('tenant.create') then
    return null;
  end if;

  if tg_table_name = 'membership_roles' then
    select string_agg(p.code, ', ' order by p.code) into v_missing
    from public.role_permissions rp
    join public.permissions p on p.id = rp.permission_id
    where rp.role_id = (v_row ->> 'role_id')::uuid
      and not app.has_permission(p.code);
    if v_missing is not null then
      raise exception 'T8: role grants permissions the actor does not hold: %', v_missing
        using errcode = '42501';
    end if;

  elsif tg_table_name = 'role_permissions' then
    select p.code into v_missing
    from public.permissions p
    where p.id = (v_row ->> 'permission_id')::uuid
      and not app.has_permission(p.code);
    if v_missing is not null then
      raise exception 'T8: permission not held by the actor: %', v_missing
        using errcode = '42501';
    end if;

  elsif tg_table_name = 'membership_scopes' then
    select string_agg(distinct p.code, ', ' order by p.code) into v_missing
    from public.membership_roles mr
    join public.role_permissions rp on rp.role_id = mr.role_id
    join public.permissions p       on p.id = rp.permission_id
    where mr.membership_id = (v_row ->> 'membership_id')::uuid
      and not app.has_permission(p.code);
    if v_missing is not null then
      raise exception 'T8: scope grant would enable permissions the actor does not hold: %', v_missing
        using errcode = '42501';
    end if;
  end if;

  return null;
end;
$$;

reset role;

-- ------------------------------------------------------------------
-- 2. ما تكتبه دوال الإنشاء — لمالكها فقط
-- ------------------------------------------------------------------
grant insert on public.platform_tenants, public.auth_identities, public.profiles, public.memberships,
                public.membership_roles, public.membership_scopes, public.families, public.students,
                public.staff, public.staff_school_assignments, public.guardians, public.student_guardians
  to app_owner;
grant select on public.families, public.staff_school_assignments to app_owner;
grant update (profile_id) on public.staff, public.guardians to app_owner;
grant usage, select on sequence app.temporary_id_seq to app_owner;

set local role app_owner;

-- ------------------------------------------------------------------
-- أدوات داخلية (لا EXECUTE لأحد)
-- ------------------------------------------------------------------
-- دور نظام بكوده — يجب أن يكون مبذوراً (M23)
create function app.system_role_id(p_code text)
returns uuid
language plpgsql
stable
security definer
set search_path = app, public, pg_temp
as $$
declare v_id uuid;
begin
  select r.id into v_id from public.roles r where r.code = p_code and r.is_system and r.platform_tenant_id is null;
  if v_id is null then
    raise exception 'system role % is not seeded', p_code using errcode = 'P0002';
  end if;
  return v_id;
end;
$$;

-- هوية Tenant لحساب Auth قائم: auth_identities + profile + membership — O1/G10 تفرضهما القيود
create function app.new_tenant_account(p_tenant uuid, p_auth_user_id uuid, p_display_name text)
returns uuid                                   -- membership id
language plpgsql
security definer
set search_path = app, public, pg_temp
as $$
declare v_profile uuid; v_membership uuid;
begin
  insert into public.auth_identities (auth_user_id, kind) values (p_auth_user_id, 'tenant');
  insert into public.profiles (platform_tenant_id, auth_user_id, display_name)
    values (p_tenant, p_auth_user_id, p_display_name) returning id into v_profile;
  insert into public.memberships (platform_tenant_id, profile_id)
    values (p_tenant, v_profile) returning id into v_membership;
  return v_membership;
end;
$$;

-- ------------------------------------------------------------------
-- bootstrap_tenant — سياق المنصة
-- ------------------------------------------------------------------
create function app.bootstrap_tenant(p_tenant_id uuid, p_tenant_code text, p_name text,
                                     p_admin_auth_user_id uuid, p_admin_display_name text)
returns uuid
language plpgsql security definer set search_path = app, public, pg_temp
as $$
declare v_membership uuid; v_existing text;
begin
  if not app.has_platform_permission('tenant.create') then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  -- idempotency: المعرّف نفسه بالمعطيات نفسها ← الموجود
  select t.tenant_code into v_existing from public.platform_tenants t where t.id = p_tenant_id;
  if found then
    if v_existing = p_tenant_code and exists (
         select 1 from public.profiles p where p.platform_tenant_id = p_tenant_id and p.auth_user_id = p_admin_auth_user_id) then
      return p_tenant_id;
    end if;
    raise exception 'conflict: tenant % already exists with different data', p_tenant_id using errcode = '23505';
  end if;

  perform app.set_audit_context('bootstrap', 'bootstrap_tenant');
  insert into public.platform_tenants (id, tenant_code, name) values (p_tenant_id, p_tenant_code, p_name);
  v_membership := app.new_tenant_account(p_tenant_id, p_admin_auth_user_id, p_admin_display_name);
  insert into public.membership_roles (membership_id, role_id, platform_tenant_id, role_owner_key)
    values (v_membership, app.system_role_id('tenant_admin'), p_tenant_id, '00000000-0000-0000-0000-000000000000');
  insert into public.membership_scopes (membership_id, platform_tenant_id, scope_type)
    values (v_membership, p_tenant_id, 'tenant');
  perform app.set_audit_context(null, null);
  return p_tenant_id;
end;
$$;

-- ------------------------------------------------------------------
-- provision_student — H1: النطاق من المدرسة الهدف
-- ------------------------------------------------------------------
create function app.provision_student(
  p_student_id uuid, p_auth_user_id uuid, p_section_id uuid, p_effective_from date,
  p_first_name text, p_family_name text,
  p_father_name text default null, p_grandfather_name text default null,
  p_official_id text default null, p_official_id_type text default null,
  p_gender text default null, p_birth_date date default null, p_nationality text default null,
  p_family_id uuid default null, p_new_family_name text default null, p_enrollment_no text default null)
returns uuid
language plpgsql security definer set search_path = app, public, pg_temp
as $$
declare
  v_sec public.sections%rowtype; v_school public.schools%rowtype; v_scope uuid;
  v_membership uuid; v_profile uuid; v_family uuid; v_existing uuid;
begin
  if not (app.has_permission('student.create') and app.has_permission('enrollment.create')) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  -- المدرسة الهدف من الشعبة، ونطاق الفاعل عليها
  select s.* into v_sec from public.sections s where s.id = p_section_id and app.can_access_school(s.school_id);
  if not found then raise exception 'not found' using errcode = 'P0002'; end if;
  select sc.* into v_school from public.schools sc where sc.id = v_sec.school_id;
  if v_school.status <> 'active' then
    raise exception 'invariant: target school is not active' using errcode = '23514';
  end if;
  -- idempotency
  select st.student_profile_id into v_existing from public.students st where st.id = p_student_id;
  if found then
    if exists (select 1 from public.profiles p where p.id = v_existing and p.auth_user_id = p_auth_user_id)
       and exists (select 1 from public.enrollments e where e.student_id = p_student_id and e.school_id = v_sec.school_id) then
      return p_student_id;
    end if;
    raise exception 'conflict: student % already exists with different data', p_student_id using errcode = '23505';
  end if;
  if p_family_id is not null and p_new_family_name is not null then
    raise exception 'either an existing family or a new family name, not both' using errcode = '22023';
  end if;
  if p_family_id is not null and not app.family_in_scope(p_family_id) then
    raise exception 'not found' using errcode = 'P0002';
  end if;
  -- H1: نطاق الهوية من المدرسة، لا من العميل
  select i.id into v_scope from public.identity_scopes i where i.owner_id = v_school.scope_owner_id;

  perform app.set_audit_context('provision', 'provision_student');
  v_membership := app.new_tenant_account(v_school.platform_tenant_id, p_auth_user_id,
                    btrim(p_first_name || ' ' || p_family_name));
  select m.profile_id into v_profile from public.memberships m where m.id = v_membership;
  insert into public.membership_roles (membership_id, role_id, platform_tenant_id, role_owner_key)
    values (v_membership, app.system_role_id('student'), v_school.platform_tenant_id, '00000000-0000-0000-0000-000000000000');
  v_family := p_family_id;
  if p_new_family_name is not null then
    insert into public.families (platform_tenant_id, family_name) values (v_school.platform_tenant_id, p_new_family_name)
      returning id into v_family;
  end if;
  insert into public.students (id, platform_tenant_id, identity_scope_id, student_profile_id, family_id,
                               official_id, official_id_type, temporary_id,
                               first_name, father_name, grandfather_name, family_name,
                               gender, birth_date, nationality)
    values (p_student_id, v_school.platform_tenant_id, v_scope, v_profile, v_family,
            p_official_id, p_official_id_type,
            case when p_official_id is null then app.next_temporary_id() end,
            p_first_name, p_father_name, p_grandfather_name, p_family_name,
            p_gender, p_birth_date, p_nationality);
  insert into public.enrollments (school_id, student_id, platform_tenant_id, academic_year_id, grade_level_id, section_id,
                                  identity_scope_id, scope_owner_id, enrollment_no, effective_from)
    values (v_sec.school_id, p_student_id, v_school.platform_tenant_id, v_sec.academic_year_id, v_sec.grade_level_id, v_sec.id,
            v_scope, v_school.scope_owner_id, p_enrollment_no, p_effective_from);
  perform app.set_audit_context(null, null);
  return p_student_id;
end;
$$;

-- ------------------------------------------------------------------
-- provision_staff — staff + أول تكليف (الحساب لاحقاً عبر provision_account)
-- ------------------------------------------------------------------
create function app.provision_staff(
  p_staff_id uuid, p_school_id uuid, p_employee_code text, p_first_name text, p_family_name text,
  p_job_title text, p_effective_from date,
  p_father_name text default null, p_grandfather_name text default null,
  p_national_id text default null, p_phone_e164 text default null, p_email text default null,
  p_gender text default null, p_birth_date date default null, p_hire_date date default null)
returns uuid
language plpgsql security definer set search_path = app, public, pg_temp
as $$
declare v_school public.schools%rowtype;
begin
  if not (app.has_permission('staff.create') and app.has_permission('staff.assign')) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  select sc.* into v_school from public.schools sc where sc.id = p_school_id and app.can_access_school(sc.id);
  if not found then raise exception 'not found' using errcode = 'P0002'; end if;
  if v_school.status <> 'active' then
    raise exception 'invariant: target school is not active' using errcode = '23514';
  end if;
  if exists (select 1 from public.staff s where s.id = p_staff_id) then
    if exists (select 1 from public.staff s join public.staff_school_assignments a on a.staff_id = s.id
               where s.id = p_staff_id and s.employee_code = p_employee_code and a.school_id = p_school_id) then
      return p_staff_id;
    end if;
    raise exception 'conflict: staff % already exists with different data', p_staff_id using errcode = '23505';
  end if;

  perform app.set_audit_context('provision', 'provision_staff');
  insert into public.staff (id, platform_tenant_id, employee_code, first_name, father_name, grandfather_name, family_name,
                            national_id, phone_e164, email, gender, birth_date, hire_date)
    values (p_staff_id, v_school.platform_tenant_id, p_employee_code, p_first_name, p_father_name, p_grandfather_name, p_family_name,
            p_national_id, p_phone_e164, p_email, p_gender, p_birth_date, p_hire_date);
  insert into public.staff_school_assignments (staff_id, school_id, platform_tenant_id, job_title, effective_from)
    values (p_staff_id, p_school_id, v_school.platform_tenant_id, p_job_title, p_effective_from);
  perform app.set_audit_context(null, null);
  return p_staff_id;
end;
$$;

-- ------------------------------------------------------------------
-- provision_guardian — guardian + ارتباط بطالب في النطاق الحالي (H2)
-- ------------------------------------------------------------------
create function app.provision_guardian(
  p_guardian_id uuid, p_student_id uuid, p_relationship_type text, p_phone_e164 text,
  p_first_name text, p_family_name text, p_effective_from date,
  p_father_name text default null, p_grandfather_name text default null,
  p_alt_phone_e164 text default null, p_email text default null, p_national_id text default null,
  p_is_primary boolean default false)
returns uuid
language plpgsql security definer set search_path = app, public, pg_temp
as $$
declare v_tenant uuid;
begin
  if not (app.has_permission('guardian.create') and app.has_permission('guardian.link')) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  select st.platform_tenant_id into v_tenant from public.students st
   where st.id = p_student_id and app.student_in_scope(st.id);
  if not found then raise exception 'not found' using errcode = 'P0002'; end if;
  if exists (select 1 from public.guardians g where g.id = p_guardian_id) then
    if exists (select 1 from public.student_guardians l join public.guardians g on g.id = l.guardian_id
               where l.guardian_id = p_guardian_id and l.student_id = p_student_id and g.phone_e164 = p_phone_e164) then
      return p_guardian_id;
    end if;
    raise exception 'conflict: guardian % already exists with different data', p_guardian_id using errcode = '23505';
  end if;

  perform app.set_audit_context('provision', 'provision_guardian');
  insert into public.guardians (id, platform_tenant_id, first_name, father_name, grandfather_name, family_name,
                                phone_e164, alt_phone_e164, email, national_id)
    values (p_guardian_id, v_tenant, p_first_name, p_father_name, p_grandfather_name, p_family_name,
            p_phone_e164, p_alt_phone_e164, p_email, p_national_id);
  insert into public.student_guardians (student_id, guardian_id, platform_tenant_id, relationship_type, is_primary, effective_from)
    values (p_student_id, p_guardian_id, v_tenant, p_relationship_type, p_is_primary, p_effective_from);
  perform app.set_audit_context(null, null);
  return p_guardian_id;
end;
$$;

-- ------------------------------------------------------------------
-- provision_account — حساب لموظف/ولي أمر قائم (membership.create + العلاقة في النطاق)
--   guardian: + دور guardian النظامي، بلا نطاق.  staff: بلا دور ولا نطاق — يُمنحان لاحقاً عبر role.assign/scope.assign (T8).
-- ------------------------------------------------------------------
create function app.provision_account(p_kind text, p_target_id uuid, p_auth_user_id uuid)
returns uuid                                   -- profile id
language plpgsql security definer set search_path = app, public, pg_temp
as $$
declare v_tenant uuid; v_current uuid; v_name text; v_membership uuid; v_profile uuid;
begin
  if not app.has_permission('membership.create') then
    raise exception 'forbidden' using errcode = '42501';
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

-- ------------------------------------------------------------------
-- 3. EXECUTE — allowlist M20؛ الأدوات الداخلية لا لأحد
-- ------------------------------------------------------------------
grant execute on function
  app.bootstrap_tenant(uuid, text, text, uuid, text),
  app.provision_student(uuid, uuid, uuid, date, text, text, text, text, text, text, text, date, text, uuid, text, text),
  app.provision_staff(uuid, uuid, text, text, text, text, date, text, text, text, text, text, text, date, date),
  app.provision_guardian(uuid, uuid, text, text, text, text, date, text, text, text, text, text, boolean),
  app.provision_account(text, uuid, uuid)
to authenticated;
