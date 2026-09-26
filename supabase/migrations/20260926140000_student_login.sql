-- M24 — student_login (Gate F2 / D1)
-- المرجع: CLAUDE.md §6 (D1، 2026-09-26)؛ DB_IMPLEMENTATION_SPEC_v1.md §5.4
--
-- D1: auth.users.id = student_id؛ بريد Auth اصطناعي `<student_id>@students.smas.invalid` لا يراه الطالب؛
--     الدخول بـOfficial ID أو Temporary ID يُحَل هنا إلى الحساب داخل نطاق الهوية الصحيح.
--
-- 1. app.resolve_student_login — دالة متحكَّم بها قبل وجود JWT (الفئة 4: تجاوز RLS بعد تحقق صريح)
--    • المدخل: tenant_code + slug المدرسة (يحملهما الـsubdomain في F3 — الـslug فريد داخل الـTenant فقط)
--      + المعرّف كما يكتبه الطالب.
--    • المخرج: معرّف حساب Auth أو NULL — لا tenant ولا school ولا بيانات طالب؛ وNULL واحد لكل أسباب الفشل
--      (Tenant غير موجود/موقوف، مدرسة غير موجودة/مؤرشفة، معرّف غير موجود، طالب غير نشط، تطابق مزدوج).
--    • EXECUTE لـservice_role وحده (FastAPI قبل الدخول)؛ لا anon ولا authenticated (M20).
--    • الحالة `active` وحدها تُحَل: `withdrawn` و`archived` لا يدخلان (افتراض يُراجَع).
-- 2. provision_student — نفس نص M22 + فرض D1 (معرّف الحساب = معرّف الطالب) في قاعدة البيانات.

set local role app_owner;

create function app.resolve_student_login(p_tenant_code text, p_school_slug text, p_identifier text)
returns uuid
language sql
stable
security definer
set search_path = app, public, pg_temp
as $$
  select case when count(*) = 1 then (array_agg(p.auth_user_id))[1] end
  from public.platform_tenants t
  join public.schools sc
    on sc.platform_tenant_id = t.id and sc.slug = lower(btrim(p_school_slug)) and sc.status = 'active'
  join public.identity_scopes i on i.owner_id = sc.scope_owner_id
  join public.students s
    on s.identity_scope_id = i.id and s.status = 'active'
   and (s.official_id = btrim(p_identifier) or s.temporary_id = upper(btrim(p_identifier)))
  join public.profiles p on p.id = s.student_profile_id
  where t.tenant_code = upper(btrim(p_tenant_code)) and t.status = 'active'
$$;

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

reset role;

revoke all on function app.resolve_student_login(text, text, text) from public;
grant execute on function app.resolve_student_login(text, text, text) to service_role;
