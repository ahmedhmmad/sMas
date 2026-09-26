-- M20 — privileges: سجل §4.6 حرفياً على كل جدول، الامتيازات على مستوى الجدول، الامتيازات الافتراضية،
-- و EXECUTE بفئتين (RLS helpers تستدعيها سياسة / controlled functions في allowlist).
-- فحص صلاحية العمود يسبق RLS، فالرفض هنا لا يحتاج صفوفاً ولا صلاحيات تطبيق.
begin;

create temp table r (k text primary key, v text) on commit drop;
grant all on r to public;

create function pg_temp.rec(p_key text, p_sql text) returns void
language plpgsql as $$
declare x text;
begin
  begin
    execute p_sql into x;
    x := coalesce(x, '<null>');
  exception when others then
    x := 'ERR ' || sqlstate || ': ' || sqlerrm;
  end;
  insert into r values (p_key, x) on conflict (k) do update set v = excluded.v;
end $$;

-- ============ السجل المتوقع (§4.6 + M17b + M19) ============
create temp table expected (t text primary key, ins text, upd text) on commit drop;
insert into expected values
  ('academic_years',            'end_date,name,school_id,start_date', 'end_date,name,start_date'),
  ('audit_log',                 '', ''),
  ('auth_identities',           '', ''),
  ('login_challenges',          '', ''),     -- M26: لا منح للعميل إطلاقاً
  ('enrollments',               'academic_year_id,effective_from,enrollment_no,grade_level_id,identity_scope_id,platform_tenant_id,school_id,scope_owner_id,section_id,student_id', 'enrollment_no'),
  ('families',                  '', 'address,family_name'),   -- M20b: family_code غير قابل للتعديل (قاعدة الثوابت)
  ('grade_levels',              'name,school_id,sequence_no,stage_id,status', 'name,school_id,sequence_no,stage_id,status'),
  ('groups',                    'group_code,name,platform_tenant_id', 'name'),
  ('guardians',                 '', 'alt_phone_e164,email,family_name,father_name,first_name,grandfather_name,national_id,residence_country'),
  ('identity_scopes',           '', ''),
  ('membership_roles',          'membership_id,platform_tenant_id,role_id,role_owner_key', ''),
  ('membership_scopes',         'group_id,membership_id,platform_tenant_id,school_id,scope_type', ''),
  ('memberships',               '', ''),
  ('permissions',               '', ''),
  ('platform_admin_assignments','', ''),
  ('platform_admin_role_permissions', '', ''),
  ('platform_admin_roles',      '', ''),
  ('platform_tenants',          '', 'name'),
  ('profiles',                  '', 'display_name'),
  ('role_permissions',          'permission_id,role_id', ''),
  ('roles',                     'code,description,name,platform_tenant_id', 'description,name'),
  ('schools',                   'group_id,name,platform_tenant_id,school_code,slug,timezone', 'name,slug,timezone'),
  ('sections',                  'academic_year_id,capacity,gender_policy,grade_level_id,name,school_id,status', 'academic_year_id,capacity,gender_policy,grade_level_id,name,school_id,status'),
  ('staff',                     '', 'birth_date,email,family_name,father_name,first_name,gender,grandfather_name,hire_date,national_id,phone_e164'),
  ('staff_school_assignments',  'effective_from,is_primary,job_title,platform_tenant_id,school_id,staff_id', 'is_primary,job_title'),
  ('stages',                    'name,school_id,sequence_no,status', 'name,school_id,sequence_no,status'),
  ('student_guardians',         'can_pickup,effective_from,guardian_id,is_primary,platform_tenant_id,receives_whatsapp,relationship_type,student_id', 'can_pickup,is_primary,receives_whatsapp,relationship_type'),
  ('students',                  '', 'birth_date,family_id,family_name,father_name,first_name,gender,grandfather_name,nationality,official_id,official_id_type'),
  ('system_users',              '', ''),
  ('terms',                     'academic_year_id,end_date,name,school_id,sequence_no,start_date,status,year_end_date,year_start_date', 'academic_year_id,end_date,name,school_id,sequence_no,start_date,status,year_end_date,year_start_date');

create temp view actual as
  select c.relname::text as t,
         coalesce(string_agg(a.attname::text, ',' order by a.attname::text collate "C")
                    filter (where has_column_privilege('authenticated', c.oid, a.attnum, 'INSERT')), '') as ins,
         coalesce(string_agg(a.attname::text, ',' order by a.attname::text collate "C")
                    filter (where has_column_privilege('authenticated', c.oid, a.attnum, 'UPDATE')), '') as upd
  from pg_class c join pg_attribute a on a.attrelid = c.oid and a.attnum > 0 and not a.attisdropped
  where c.relnamespace = 'public'::regnamespace and c.relkind = 'r'
  group by c.relname;

-- ============ الرفض السلوكي: أعمدة خارج السجل ============
select set_config('request.jwt.claims', json_build_object('sub', gen_random_uuid(), 'role', 'authenticated')::text, true);
set local role authenticated;
select pg_temp.rec('b.roles_status',     $q$update public.roles set status = 'active'$q$);                         -- M19
select pg_temp.rec('b.ssa_status',       $q$update public.staff_school_assignments set status = 'active'$q$);       -- M17b
select pg_temp.rec('b.ssa_insert_ended', $q$insert into public.staff_school_assignments (staff_id, school_id, platform_tenant_id, job_title, effective_from, status) values (gen_random_uuid(), gen_random_uuid(), gen_random_uuid(), 'x', current_date, 'ended')$q$);
select pg_temp.rec('b.groups_tenant',    $q$update public.groups set platform_tenant_id = gen_random_uuid()$q$);
select pg_temp.rec('b.schools_group',    $q$update public.schools set group_id = null$q$);                          -- الدمج إجراء §5.4
select pg_temp.rec('b.profiles_auth',    $q$update public.profiles set auth_user_id = gen_random_uuid()$q$);
select pg_temp.rec('b.students_scope',   $q$update public.students set identity_scope_id = gen_random_uuid()$q$);
select pg_temp.rec('b.students_tmp',     $q$update public.students set temporary_id = 'TMP-2026-000001'$q$);
select pg_temp.rec('b.guardians_phone',  $q$update public.guardians set phone_e164 = '+201000000000'$q$);            -- مسار OTP
select pg_temp.rec('b.guardians_lock',   $q$update public.guardians set failed_login_count = 0$q$);
select pg_temp.rec('b.enr_status',       $q$update public.enrollments set status = 'withdrawn'$q$);
select pg_temp.rec('b.enr_school',       $q$update public.enrollments set school_id = gen_random_uuid()$q$);         -- E1 بطبقة الصلاحية
select pg_temp.rec('b.ay_status',        $q$update public.academic_years set status = 'active'$q$);                  -- activate/close: M21
select pg_temp.rec('b.memberships',      $q$update public.memberships set status = 'ended'$q$);
select pg_temp.rec('b.sg_status',        $q$update public.student_guardians set status = 'ended'$q$);                -- unlink: M21
select pg_temp.rec('b.family_code',      $q$update public.families set family_code = 'X'$q$);                         -- M20b
select pg_temp.rec('b.archive',          $q$update public.students set archived_at = now()$q$);
select pg_temp.rec('b.tenant_insert',    $q$insert into public.platform_tenants (tenant_code, name) values ('TX', 'TX')$q$);   -- bootstrap_tenant
select pg_temp.rec('b.truncate',         $q$truncate public.groups$q$);
select pg_temp.rec('b.delete_groups',    $q$delete from public.groups$q$);
select pg_temp.rec('b.audit_select',     $q$select count(*)::text from public.audit_log$q$);                          -- مسموح؛ RLS تحكم الصفوف
select pg_temp.rec('b.allowed_upd',      $q$with u as (update public.students set first_name = first_name returning 1) select count(*)::text from u$q$);
reset role;
set local role anon;
select pg_temp.rec('b.anon_select',      $q$select count(*)::text from public.schools$q$);
select pg_temp.rec('b.anon_audit',       $q$select count(*)::text from public.audit_log$q$);
reset role;

-- ============ الامتيازات الافتراضية لجدول جديد ============
create table public.zz_future (x int);
select pg_temp.rec('d.future', $q$select string_agg(g || ':' || p, ',' order by g, p) from unnest(array['anon','authenticated']) g,
  unnest(array['SELECT','INSERT','UPDATE','DELETE','TRUNCATE','TRIGGER','REFERENCES']) p
  where has_table_privilege(g, 'public.zz_future', p)$q$);
drop table public.zz_future;

-- ============ EXECUTE بفئتين ============
-- allowlist الدوال المتحكَّم بها (§5.0): فارغة الآن — M21/M22 تضيف إليها مع منحها
create temp table controlled_allowlist (f regprocedure primary key) on commit drop;
insert into controlled_allowlist values   -- M21
  ('app.suspend_tenant(uuid,text)'), ('app.reactivate_tenant(uuid,text)'), ('app.archive_group(uuid,text)'),
  ('app.archive_school(uuid,text)'), ('app.end_membership(uuid,text)'), ('app.archive_student(uuid,text)'),
  ('app.set_staff_status(uuid,text,text,date)'), ('app.end_staff_assignment(uuid,date,text)'),
  ('app.archive_guardian(uuid,text)'), ('app.unlink_guardian(uuid,date,text)'),
  ('app.activate_academic_year(uuid,text)'), ('app.close_academic_year(uuid,text)'),
  ('app.close_enrollment(uuid,text,date,text)'), ('app.transfer_enrollment(uuid,uuid,date,text,text)'),
  ('app.set_role_status(uuid,text,text)'),
  -- M22
  ('app.bootstrap_tenant(uuid,text,text,uuid,text)'),
  ('app.provision_student(uuid,uuid,uuid,date,text,text,text,text,text,text,text,date,text,uuid,text,text)'),
  ('app.provision_staff(uuid,uuid,text,text,text,text,date,text,text,text,text,text,text,date,date)'),
  ('app.provision_guardian(uuid,uuid,text,text,text,text,date,text,text,text,text,text,boolean)'),
  ('app.provision_account(text,uuid,uuid)'),
  ('app.arm_first_login(uuid)'), ('app.activate_first_login()');   -- M25 (F2/D2)
select pg_temp.rec('x.uncategorized', $q$select coalesce(string_agg(p.oid::regprocedure::text, ','), 'none') from pg_proc p
  where p.pronamespace = 'app'::regnamespace and has_function_privilege('authenticated', p.oid, 'EXECUTE')
    and not exists (select 1 from pg_policies pol where pol.schemaname = 'public'
                     and coalesce(pol.qual, '') || coalesce(pol.with_check, '') ~ ('app\.' || p.proname || '\('))
    and not exists (select 1 from controlled_allowlist a where a.f = p.oid)$q$);
select pg_temp.rec('x.allowlist_missing', $q$select coalesce(string_agg(f::text, ','), 'none') from controlled_allowlist
  where not has_function_privilege('authenticated', f, 'EXECUTE')$q$);

select plan(30 + 1 + 24 + 7 + 5 + 1);

-- ---------- السجل: كل جدول بالاسم ----------
select is(coalesce(a.ins, '<missing>') || ' | ' || coalesce(a.upd, '<missing>'), e.ins || ' | ' || e.upd,
          format('%s: INSERT | UPDATE columns match §4.6', e.t))
  from expected e left join actual a using (t) order by e.t;
select set_eq('select t from actual', 'select t from expected', 'the registry covers exactly the 30 tables (29 Foundation + login_challenges)');

-- ---------- الرفض السلوكي ----------
select ok((select v from r where k = 'b.roles_status')     like 'ERR 42501%permission denied%roles%',                    'M19: roles.status is not client-writable');
select ok((select v from r where k = 'b.ssa_status')       like 'ERR 42501%permission denied%staff_school_assignments%', 'M17b: staff_school_assignments.status is not client-writable');
select ok((select v from r where k = 'b.ssa_insert_ended') like 'ERR 42501%permission denied%staff_school_assignments%', 'M17b: a new assignment cannot be inserted with a chosen status');
select ok((select v from r where k = 'b.groups_tenant')    like 'ERR 42501%permission denied%groups%',                   'platform_tenant_id is never client-writable (groups)');
select ok((select v from r where k = 'b.schools_group')    like 'ERR 42501%permission denied%schools%',                  'schools.group_id is immutable (joining a group is a merge, §5.4)');
select ok((select v from r where k = 'b.profiles_auth')    like 'ERR 42501%permission denied%profiles%',                 'profiles.auth_user_id is immutable');
select ok((select v from r where k = 'b.students_scope')   like 'ERR 42501%permission denied%students%',                 'students.identity_scope_id is immutable');
select ok((select v from r where k = 'b.students_tmp')     like 'ERR 42501%permission denied%students%',                 'students.temporary_id is immutable');
select ok((select v from r where k = 'b.guardians_phone')  like 'ERR 42501%permission denied%guardians%',                'guardians.phone_e164 changes only through the OTP path (PLAN §7.8)');
select ok((select v from r where k = 'b.guardians_lock')   like 'ERR 42501%permission denied%guardians%',                'guardian security fields are not client-writable');
select ok((select v from r where k = 'b.enr_status')       like 'ERR 42501%permission denied%enrollments%',              'enrollments.status is a state transition');
select ok((select v from r where k = 'b.enr_school')       like 'ERR 42501%permission denied%enrollments%',              'E1 at the privilege layer: enrollments.school_id is not updatable');
select ok((select v from r where k = 'b.ay_status')        like 'ERR 42501%permission denied%academic_years%',           'academic_years.status (activate/close) is a state transition');
select ok((select v from r where k = 'b.memberships')      like 'ERR 42501%permission denied%memberships%',              'memberships are not client-writable');
select ok((select v from r where k = 'b.sg_status')        like 'ERR 42501%permission denied%student_guardians%',        'student_guardians.status (unlink) is a state transition');
select ok((select v from r where k = 'b.family_code')      like 'ERR 42501%permission denied%families%',                 'M20b: families.family_code is a code — never client-writable');
select ok((select v from r where k = 'b.archive')          like 'ERR 42501%permission denied%students%',                 'archived_at is not client-writable (archive = state transition)');
select ok((select v from r where k = 'b.tenant_insert')    like 'ERR 42501%permission denied%platform_tenants%',         'platform_tenants insert only through bootstrap_tenant (§5.2)');
select ok((select v from r where k = 'b.truncate')         like 'ERR 42501%permission denied%groups%',                   'TRUNCATE (which RLS does not cover) is denied to authenticated');
select ok((select v from r where k = 'b.delete_groups')    like 'ERR 42501%permission denied%groups%',                   'DELETE denied outside the three G2 tables');
select is((select v from r where k = 'b.audit_select'),    '0',  'SELECT on audit_log is granted (M11 dependency); RLS decides the rows');
select is((select v from r where k = 'b.allowed_upd'),     '0',  'an allowed column update reaches RLS (no privilege error)');
select ok((select v from r where k = 'b.anon_select')      like 'ERR 42501%permission denied%schools%',                  'anon has no privilege on any table');
select ok((select v from r where k = 'b.anon_audit')       like 'ERR 42501%permission denied%audit_log%',                'anon cannot read audit_log');

-- ---------- الامتيازات على مستوى الجدول ----------
select is((select count(*)::int from pg_class c, unnest(array['SELECT','INSERT','UPDATE','DELETE','TRUNCATE','TRIGGER','REFERENCES']) p
            where c.relnamespace = 'public'::regnamespace and c.relkind = 'r' and has_table_privilege('anon', c.oid, p)), 0,
          'anon: no table privilege of any kind in public');
select is((select count(*)::int from pg_class c, unnest(array['TRUNCATE','TRIGGER','REFERENCES']) p
            where c.relnamespace = 'public'::regnamespace and c.relkind = 'r' and has_table_privilege('authenticated', c.oid, p)), 0,
          'authenticated: no TRUNCATE, TRIGGER or REFERENCES on any table');
select is((select string_agg(c.relname, ',' order by c.relname) from pg_class c
            where c.relnamespace = 'public'::regnamespace and c.relkind = 'r' and has_table_privilege('authenticated', c.oid, 'DELETE')),
          'membership_roles,membership_scopes,role_permissions', 'authenticated: DELETE only on the three G2 tables');
select is((select coalesce(string_agg(c.relname, ','), 'none') from pg_class c where c.relnamespace = 'public'::regnamespace and c.relkind = 'r'
            and not has_table_privilege('authenticated', c.oid, 'SELECT')), 'login_challenges',
          'authenticated: SELECT on every table (RLS decides the rows) — except login_challenges, which no client reads (M26)');
select is((select v from r where k = 'd.future'), 'authenticated:SELECT', 'default privileges: a future table gives anon nothing and authenticated SELECT only');
select ok(has_table_privilege('service_role', 'public.groups', 'INSERT') and has_table_privilege('service_role', 'public.groups', 'UPDATE'),
          'service_role keeps its privileges (FastAPI, provisioning)');
select ok(not has_table_privilege('service_role', 'public.audit_log', 'UPDATE') and not has_table_privilege('service_role', 'public.audit_log', 'DELETE'),
          'M11 unchanged: service_role cannot UPDATE/DELETE audit_log');

-- ---------- EXECUTE بفئتين ----------
select is((select v from r where k = 'x.uncategorized'), 'none',
          'EXECUTE for authenticated: every function is either an RLS helper called by a policy or an allowlisted controlled function');
select is((select v from r where k = 'x.allowlist_missing'), 'none', 'every allowlisted controlled function is executable (15 from M21 + 5 from M22 + 2 from M25)');
select is((select count(*)::int from pg_proc p where p.pronamespace = 'app'::regnamespace and has_function_privilege('anon', p.oid, 'EXECUTE')), 0,
          'anon executes no function in app');
select is((select count(*)::int from pg_proc p where p.pronamespace = 'app'::regnamespace
            and exists (select 1 from aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) x where x.grantee = 0 and x.privilege_type = 'EXECUTE')), 0,
          'PUBLIC executes no function in app');
select ok(not has_function_privilege('authenticated', 'app.auth_uid()', 'EXECUTE'), 'app.auth_uid() stays owner-only (R2)');
select is((select count(*)::int from pg_policies where schemaname = 'public' and cmd = 'INSERT'
            and not exists (select 1 from pg_class c join pg_attribute a on a.attrelid = c.oid and a.attnum > 0
                            where c.relname = pg_policies.tablename and c.relnamespace = 'public'::regnamespace
                              and has_column_privilege('authenticated', c.oid, a.attnum, 'INSERT'))), 0,
          'M20b: no INSERT policy on a table where authenticated cannot insert any column (policies match the privilege contract)');

select * from finish();
rollback;
