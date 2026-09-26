-- M25 — first_login_credential (Gate F2 / D2 — الخيار B المعتمد 2026-09-26)
-- المرجع: docs/F2_AUTHENTICATION.md §3 و§3.1 (V9، V9b)
--
-- الهدف الأمني: لا مسار يجعل الحساب مفتوحاً قبل استيفاء شرط first-login.
--
--   pending ──(الطالب يغيّر كلمته عبر Supabase Auth)──► FastAPI ──► app.activate_first_login() ──► active
--   أي فشل في التفعيل ⇒ يبقى pending (fail closed) ويُعاد.
--
-- الإشارة (V9b — Supabase Auth integration assumption، لا قاعدة PostgreSQL نملكها):
--   auth.audit_log_entries.payload: action = 'user_updated_password' و actor_id = الحساب نفسه — يكتبه
--   Supabase Auth في معاملة تغيير الكلمة نفسها، ولا يكتبه المدير أبداً (المدير: 'user_modified' بـservice_role).
--   لا trigger على auth.users ولا auth.audit_log_entries: قراءة فقط.
--   إن توقفت الإشارة (ترقية/إعداد) ⇒ لا تفعيل ⇒ الحسابات تبقى مغلقة، لا مفتوحة.
--
-- 1. auth_identities: credential_state / credential_issued_at / credential_activated_at (DD §2.0)
-- 2. بوابة الجذر (نمط M21b): current_profile_id و current_tenant_id = NULL ما لم يكن credential_state = 'active'
-- 3. provision_student: الحساب يولد pending (نص M24 + سطر واحد)
-- 4. app.arm_first_login(auth_user_id): لحظة الإصدار = auth.users.updated_at (عبر دالة R2 ضيقة) بعد كتابة الكلمة المؤقتة
--    (ساعة Supabase Auth نفسها التي تختم سجل التدقيق — لا انحراف ساعات بين خادمين)؛ مرة واحدة
-- 5. app.activate_first_login(): بلا معاملات — الفاعل auth.uid() وحده؛ الشروط التسعة المعتمدة

-- ------------------------------------------------------------------
-- 1. الحالة
-- ------------------------------------------------------------------
alter table public.auth_identities
  add column credential_state        text        not null default 'active',
  add column credential_issued_at    timestamptz,
  add column credential_activated_at timestamptz,
  add constraint auth_identities_credential_state_chk     check (credential_state in ('active', 'pending')),
  add constraint auth_identities_credential_kind_chk      check (kind = 'tenant' or credential_state = 'active'),
  add constraint auth_identities_credential_activated_chk check (credential_activated_at is null or credential_state = 'active');

grant update (credential_state, credential_issued_at, credential_activated_at) on public.auth_identities to app_owner;

-- ------------------------------------------------------------------
-- قراءة schema auth — نمط R2 (app.auth_uid): app_owner لا يصل إلى schema auth أصلاً (ولا يستطيع postgres
-- منحه USAGE عليه)، فدالتان ضيقتان ملك postgres، search_path فارغ، EXECUTE لـapp_owner وحده، تعيدان ما يلزم فقط:
-- لحظة، وقيمة منطقية — لا صف ولا payload ولا hash.
-- ------------------------------------------------------------------
create function app.auth_user_updated_at(p_uid uuid)
returns timestamptz
language sql
stable
security definer
set search_path = ''
as $$ select u.updated_at from auth.users u where u.id = p_uid $$;

-- الإشارة المعتمدة (V9b): user_updated_password بفاعل = الحساب نفسه، بعد لحظة معيّنة. EXISTS على كل الصفوف المؤهلة.
create function app.auth_password_changed_by_self_after(p_uid uuid, p_after timestamptz)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from auth.audit_log_entries e
     where e.payload ->> 'action'   = 'user_updated_password'
       and e.payload ->> 'actor_id' = p_uid::text
       and e.created_at > p_after)
$$;

revoke execute on function app.auth_user_updated_at(uuid), app.auth_password_changed_by_self_after(uuid, timestamptz)
  from public, anon, authenticated, service_role;
grant execute on function app.auth_user_updated_at(uuid), app.auth_password_changed_by_self_after(uuid, timestamptz)
  to app_owner;

set local role app_owner;

-- ------------------------------------------------------------------
-- 2. بوابة الجذر — نص M21b + شرط الحالة
-- ------------------------------------------------------------------
create or replace function app.current_profile_id()
returns uuid
language sql
stable
security definer
set search_path = app, public, pg_temp
as $$
  select p.id
  from public.profiles p
  join public.platform_tenants t on t.id = p.platform_tenant_id
  join public.auth_identities ai on ai.auth_user_id = p.auth_user_id
  where p.auth_user_id = app.auth_uid()
    and p.status = 'active'
    and t.status = 'active'
    and ai.credential_state = 'active';
$$;

create or replace function app.current_tenant_id()
returns uuid
language sql
stable
security definer
set search_path = app, public, pg_temp
as $$
  select p.platform_tenant_id
  from public.profiles p
  join public.platform_tenants t on t.id = p.platform_tenant_id
  join public.auth_identities ai on ai.auth_user_id = p.auth_user_id
  where p.auth_user_id = app.auth_uid()
    and p.status = 'active'
    and t.status = 'active'
    and ai.credential_state = 'active';
$$;

-- ------------------------------------------------------------------
-- 3. provision_student — الحساب يولد pending (نص M24 + سطر D2)
-- ------------------------------------------------------------------
create or replace function app.provision_student(
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
  -- D1 (F2): حساب الطالب معرّفه هو معرّف الطالب نفسه — مفتاح الـSaga، وثابت عبر Temporary ← Official
  if p_auth_user_id is distinct from p_student_id then
    raise exception 'invariant: student account id must equal student id (D1)' using errcode = '22023';
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
  -- D2 (M25): الحساب مغلق من لحظة إنشائه حتى يغيّر الطالب كلمة المرور الأولية (= معرّفه)
  update public.auth_identities set credential_state = 'pending' where auth_user_id = p_auth_user_id;
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
-- 4. arm_first_login — تسجيل لحظة إصدار الكلمة المؤقتة (بعد كتابتها عبر Admin API)
--    يستدعيه FastAPI في الـSaga بـJWT المستدعي نفسه الذي أنشأ الطالب.
-- ------------------------------------------------------------------
create function app.arm_first_login(p_auth_user_id uuid)
returns text
language plpgsql
security definer
set search_path = app, public, pg_temp
as $$
declare v_state text; v_issued timestamptz;
begin
  if not app.has_permission('student.create') then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  -- حساب طالب في نطاق المستدعي الحالي (H2)
  if not exists (select 1 from public.students s join public.profiles p on p.id = s.student_profile_id
                 where p.auth_user_id = p_auth_user_id and app.student_in_scope(s.id)) then
    raise exception 'not found' using errcode = 'P0002';
  end if;
  select ai.credential_state, ai.credential_issued_at into v_state, v_issued
    from public.auth_identities ai where ai.auth_user_id = p_auth_user_id for update;
  -- مرة واحدة: إعادة الإصدار (إعادة الضبط) مسار مستقل له حالته (قرار 5c) — لا تحريك للحظة هنا
  if v_state <> 'pending' or v_issued is not null then
    return v_state;
  end if;
  perform app.set_audit_context('arm_first_login', null);
  update public.auth_identities
     set credential_issued_at = app.auth_user_updated_at(p_auth_user_id)
   where auth_user_id = p_auth_user_id;
  perform app.set_audit_context(null, null);
  return 'pending';
end;
$$;

-- ------------------------------------------------------------------
-- 5. activate_first_login — الشروط المعتمدة:
--    (1) pending  (2) الحساب = auth.uid() لا معامل  (3–6) حدث user_updated_password بفاعل الحساب نفسه
--    بعد لحظة الإصدار (EXISTS على كل الصفوف المؤهلة لا «آخر صف»؛ user_modified لا يُقبل)
--    (7) idempotent  (8) سياق تدقيق activate_first_login  (9) لا مسار بلا auth.uid() (service_role مرفوض)
-- ------------------------------------------------------------------
create function app.activate_first_login()
returns text
language plpgsql
security definer
set search_path = app, public, pg_temp
as $$
declare v_uid uuid := app.auth_uid(); v_state text; v_issued timestamptz;
begin
  if v_uid is null then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  select ai.credential_state, ai.credential_issued_at into v_state, v_issued
    from public.auth_identities ai where ai.auth_user_id = v_uid and ai.kind = 'tenant' for update;
  if not found then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if v_state = 'active' then
    return 'active';
  end if;
  if v_issued is null or not app.auth_password_changed_by_self_after(v_uid, v_issued) then
    return 'pending';
  end if;
  perform app.set_audit_context('activate_first_login', null);
  update public.auth_identities
     set credential_state = 'active', credential_activated_at = now()
   where auth_user_id = v_uid;
  perform app.set_audit_context(null, null);
  return 'active';
end;
$$;

reset role;

-- EXECUTE: allowlist M20 (controlled functions) — 20 ← 22
revoke all on function app.arm_first_login(uuid), app.activate_first_login() from public;
grant execute on function app.arm_first_login(uuid), app.activate_first_login() to authenticated;
