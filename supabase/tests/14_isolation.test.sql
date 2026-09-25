-- M14 — policies_tenancy_platform: العزل I1–I7 (RLS_MODEL §15.1) + ضوابط كل سياسة
-- كل تقييم يعمل بدور authenticated (أو anon) فعلاً، فتُطبَّق السياسات؛ ولكل رفض ضابط إيجابي.
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

create temp table ids (label text primary key, auth uuid, profile uuid, sysuser uuid) on commit drop;
grant all on ids to public;

create function pg_temp.as_(p_label text) returns void
language plpgsql as $$
declare v_sub uuid := (select auth from ids where label = p_label);
begin
  perform set_config('request.jwt.claims', json_build_object('sub', v_sub, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', coalesce(v_sub::text, ''), true);
end $$;

-- تشغيل p_sql بدور authenticated بهوية p_label (أو anon إن كان p_label = 'anon')
create function pg_temp.run(p_key text, p_label text, p_sql text) returns void
language plpgsql as $$
begin
  if p_label = 'anon' then
    perform pg_temp.as_(null);
    execute 'set local role anon';
  else
    perform pg_temp.as_(p_label);
    execute 'set local role authenticated';
  end if;
  perform pg_temp.rec(p_key, p_sql);
  execute 'reset role';
end $$;

-- ============ Fixture ============
-- T1: GA (SA1, SA2)، GB (SB1)، مستقلة SS — T2: G2 (S2A)، مستقلة S2S
insert into public.platform_tenants (id, tenant_code, name) values
  ('10000000-0000-0000-0000-000000000001', 'T1', 'T1'), ('20000000-0000-0000-0000-000000000002', 'T2', 'T2');
insert into public.groups (id, platform_tenant_id, group_code, name) values
  ('a1000000-0000-0000-0000-00000000000a', '10000000-0000-0000-0000-000000000001', 'GA', 'GA'),
  ('a2000000-0000-0000-0000-00000000000b', '10000000-0000-0000-0000-000000000001', 'GB', 'GB'),
  ('a3000000-0000-0000-0000-00000000000c', '20000000-0000-0000-0000-000000000002', 'G2', 'G2');
insert into public.schools (id, platform_tenant_id, group_id, school_code, name, slug) values
  ('5a100000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', 'a1000000-0000-0000-0000-00000000000a', 'SA1', 'SA1', 'sa1'),
  ('5a200000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001', 'a1000000-0000-0000-0000-00000000000a', 'SA2', 'SA2', 'sa2'),
  ('5b100000-0000-0000-0000-000000000003', '10000000-0000-0000-0000-000000000001', 'a2000000-0000-0000-0000-00000000000b', 'SB1', 'SB1', 'sb1'),
  ('55000000-0000-0000-0000-000000000004', '10000000-0000-0000-0000-000000000001', null,                                   'SS',  'SS',  'ss'),
  ('52a00000-0000-0000-0000-000000000005', '20000000-0000-0000-0000-000000000002', 'a3000000-0000-0000-0000-00000000000c', 'S2A', 'S2A', 's2a'),
  ('52500000-0000-0000-0000-000000000006', '20000000-0000-0000-0000-000000000002', null,                                   'S2S', 'S2S', 's2s');

-- نطاقات الهوية تُقرأ بكود مالكها
create temp view scope_label as
  select i.id, coalesce(g.group_code, s.school_code) as label
  from public.identity_scopes i
  left join public.groups g on g.id = i.group_id
  left join public.schools s on s.id = i.school_id;
grant select on scope_label to public;
create temp table scope_lbl on commit drop as select * from scope_label;   -- لقطة تُقرأ بلا RLS
grant select on scope_lbl to public;

-- الصلاحيات (البذر الحقيقي في M23) ودوران: full (كل صلاحيات M14) و reader (القراءة فقط)
insert into public.permissions (code, resource, operation, description)
  select r || '.' || o, r, o, 'test'
  from unnest(array['tenant','group','school']) r, unnest(array['read','create','update']) o on conflict (code) do nothing;
insert into public.roles (id, platform_tenant_id, code, name, is_system) values
  ('71000000-0000-0000-0000-000000000001', null, 'full',   'Full',   true),
  ('72000000-0000-0000-0000-000000000002', null, 'reader', 'Reader', true);
insert into public.role_permissions (role_id, permission_id)
  select '71000000-0000-0000-0000-000000000001'::uuid, id from public.permissions
  union all
  select '72000000-0000-0000-0000-000000000002'::uuid, id from public.permissions where operation = 'read';

-- مستخدمو Tenant: label → (tenant, scopes, role)
create function pg_temp.member(p_label text, p_tenant uuid, p_role uuid, p_scopes text[]) returns void
language plpgsql as $$
declare v_auth uuid := gen_random_uuid(); v_profile uuid; v_m uuid; s text;
begin
  insert into auth.users (id, email) values (v_auth, p_label || '@m14.invalid');
  insert into public.auth_identities values (v_auth, 'tenant');
  insert into public.profiles (platform_tenant_id, auth_user_id, display_name) values (p_tenant, v_auth, p_label) returning id into v_profile;
  insert into public.memberships (platform_tenant_id, profile_id) values (p_tenant, v_profile) returning id into v_m;
  if p_role is not null then
    insert into public.membership_roles (membership_id, role_id, platform_tenant_id, role_owner_key)
      values (v_m, p_role, p_tenant, '00000000-0000-0000-0000-000000000000');
  end if;
  foreach s in array coalesce(p_scopes, '{}') loop
    if s = 'tenant' then
      insert into public.membership_scopes (membership_id, platform_tenant_id, scope_type) values (v_m, p_tenant, 'tenant');
    elsif s like 'G%' then
      insert into public.membership_scopes (membership_id, platform_tenant_id, scope_type, group_id)
        values (v_m, p_tenant, 'group', (select id from public.groups where group_code = s));
    else
      insert into public.membership_scopes (membership_id, platform_tenant_id, scope_type, school_id)
        values (v_m, p_tenant, 'school', (select id from public.schools where school_code = s));
    end if;
  end loop;
  insert into ids values (p_label, v_auth, v_profile, null);
end $$;

select pg_temp.member('ta',      '10000000-0000-0000-0000-000000000001', '71000000-0000-0000-0000-000000000001', array['tenant']);
select pg_temp.member('gm',      '10000000-0000-0000-0000-000000000001', '71000000-0000-0000-0000-000000000001', array['GA']);
select pg_temp.member('sa1',     '10000000-0000-0000-0000-000000000001', '71000000-0000-0000-0000-000000000001', array['SA1']);
select pg_temp.member('multi',   '10000000-0000-0000-0000-000000000001', '71000000-0000-0000-0000-000000000001', array['SA2','SS']);
select pg_temp.member('noperm',  '10000000-0000-0000-0000-000000000001', null,                                   array['tenant']);  -- P2
select pg_temp.member('noscope', '10000000-0000-0000-0000-000000000001', '71000000-0000-0000-0000-000000000001', null);             -- P1
select pg_temp.member('rdr',     '10000000-0000-0000-0000-000000000001', '72000000-0000-0000-0000-000000000002', array['tenant']);
select pg_temp.member('t2a',     '20000000-0000-0000-0000-000000000002', '71000000-0000-0000-0000-000000000001', array['tenant']);

-- Platform Admins: pa (دور بمفاتيح البذر ذات الصلة)، pa0 (دور بلا صلاحيات)، parev (إسناد مسحوب)
insert into public.platform_admin_roles (id, code, name) values
  ('81000000-0000-0000-0000-000000000001', 'zt_platform_admin', 'Platform Admin'),
  ('82000000-0000-0000-0000-000000000002', 'empty_role',     'Empty');
insert into public.platform_admin_role_permissions (platform_admin_role_id, permission_id)
  select '81000000-0000-0000-0000-000000000001', id from public.permissions
  where code in ('tenant.read','tenant.create','tenant.update','group.read','group.create','school.read','school.create');   -- كما في البذر §6
create function pg_temp.padmin(p_label text, p_role uuid, p_status text) returns void
language plpgsql as $$
declare v_auth uuid := gen_random_uuid(); v_su uuid;
begin
  insert into auth.users (id, email) values (v_auth, p_label || '@m14.invalid');
  insert into public.auth_identities values (v_auth, 'platform');
  insert into public.system_users (auth_user_id, display_name) values (v_auth, p_label) returning id into v_su;
  insert into public.platform_admin_assignments (system_user_id, platform_admin_role_id, status, revoked_at)
    values (v_su, p_role, p_status, case when p_status = 'revoked' then now() end);
  insert into ids values (p_label, v_auth, null, v_su);
end $$;
select pg_temp.padmin('pa',    '81000000-0000-0000-0000-000000000001', 'active');
select pg_temp.padmin('pa0',   '82000000-0000-0000-0000-000000000002', 'active');
select pg_temp.padmin('parev', '81000000-0000-0000-0000-000000000001', 'revoked');

-- بيانات في كل جدول مملوك لـTenant، في الـTenantين — لمسح I1 (الجداول التي بلا سياسات بعد تُرجع 0 لكليهما؛
-- حين تُضاف سياساتها في M15–M18 يصبح المسح فعّالاً عليها تلقائياً)
insert into public.roles (id, platform_tenant_id, code, name) values
  ('73000000-0000-0000-0000-000000000003', '10000000-0000-0000-0000-000000000001', 'c1', 'C1'),
  ('74000000-0000-0000-0000-000000000004', '20000000-0000-0000-0000-000000000002', 'c2', 'C2');
insert into public.role_permissions (role_id, permission_id)
  select r, (select id from public.permissions where code = 'school.read')
  from unnest(array['73000000-0000-0000-0000-000000000003', '74000000-0000-0000-0000-000000000004']::uuid[]) r;

create function pg_temp.people(p_tenant uuid, p_school uuid, p_tag text) returns void
language plpgsql as $$
declare
  v_year uuid; v_stage uuid; v_grade uuid; v_sec uuid; v_fam uuid; v_st uuid; v_g uuid; v_staff uuid;
  v_scope uuid := (select scope_owner_id from public.schools where id = p_school);
  v_iscope uuid := (select id from public.identity_scopes where owner_id = v_scope);
  v_auth uuid := gen_random_uuid(); v_prof uuid;
begin
  insert into public.academic_years (school_id, name, start_date, end_date, status) values (p_school, '2026/2027', '2026-09-01', '2027-06-30', 'active') returning id into v_year;
  insert into public.terms (academic_year_id, school_id, year_start_date, year_end_date, name, sequence_no, start_date, end_date)
    values (v_year, p_school, '2026-09-01', '2027-06-30', 'T1', 1, '2026-09-01', '2026-12-15');
  insert into public.stages (school_id, name, sequence_no) values (p_school, 'Primary', 1) returning id into v_stage;
  insert into public.grade_levels (school_id, stage_id, name, sequence_no) values (p_school, v_stage, 'G1', 1) returning id into v_grade;
  insert into public.sections (school_id, academic_year_id, grade_level_id, name) values (p_school, v_year, v_grade, 'A') returning id into v_sec;
  insert into public.families (platform_tenant_id, family_name) values (p_tenant, 'F' || p_tag) returning id into v_fam;
  insert into auth.users (id, email) values (v_auth, 'st' || p_tag || '@m14.invalid');
  insert into public.auth_identities values (v_auth, 'tenant');
  insert into public.profiles (platform_tenant_id, auth_user_id, display_name) values (p_tenant, v_auth, 'st' || p_tag) returning id into v_prof;
  insert into public.students (platform_tenant_id, identity_scope_id, student_profile_id, family_id, official_id, official_id_type, first_name, family_name)
    values (p_tenant, v_iscope, v_prof, v_fam, 'N-' || p_tag, 'national_id', 'S', 'S') returning id into v_st;
  insert into public.enrollments (school_id, student_id, platform_tenant_id, academic_year_id, grade_level_id, section_id,
                                  identity_scope_id, scope_owner_id, status, effective_from)
    values (p_school, v_st, p_tenant, v_year, v_grade, v_sec, v_iscope, v_scope, 'active', '2026-09-01');
  insert into public.guardians (platform_tenant_id, first_name, family_name, phone_e164) values (p_tenant, 'G', 'G', '+2010000000' || p_tag) returning id into v_g;
  insert into public.student_guardians (student_id, guardian_id, platform_tenant_id, relationship_type) values (v_st, v_g, p_tenant, 'father');
  insert into public.staff (platform_tenant_id, employee_code, first_name, family_name) values (p_tenant, 'E' || p_tag, 'E', 'E') returning id into v_staff;
  insert into public.staff_school_assignments (staff_id, school_id, platform_tenant_id, job_title, effective_from) values (v_staff, p_school, p_tenant, 'Teacher', '2026-09-01');
end $$;
select pg_temp.people('10000000-0000-0000-0000-000000000001', '5a100000-0000-0000-0000-000000000001', '11');
select pg_temp.people('20000000-0000-0000-0000-000000000002', '52a00000-0000-0000-0000-000000000005', '22');

create temp table t2_schools on commit drop as
  select id from public.schools where platform_tenant_id = '20000000-0000-0000-0000-000000000002';
grant select on t2_schools to public;

-- ============ القراءة: قائمة كاملة لكل فاعل ============
create function pg_temp.lists(p_label text) returns void
language plpgsql as $$
begin
  perform pg_temp.run('tenants.' || p_label, p_label, $q$select string_agg(tenant_code, ',' order by tenant_code collate "C") from public.platform_tenants$q$);
  perform pg_temp.run('groups.'  || p_label, p_label, $q$select string_agg(group_code,  ',' order by group_code  collate "C") from public.groups$q$);
  perform pg_temp.run('schools.' || p_label, p_label, $q$select string_agg(school_code, ',' order by school_code collate "C") from public.schools$q$);
  perform pg_temp.run('iscopes.' || p_label, p_label, $q$select string_agg(l.label, ',' order by l.label collate "C") from public.identity_scopes i join scope_lbl l using (id)$q$);
  perform pg_temp.run('sysusers.' || p_label, p_label, $q$select string_agg(display_name, ',' order by display_name collate "C") from public.system_users$q$);
  perform pg_temp.run('assign.'  || p_label, p_label, $q$select count(*)::text from public.platform_admin_assignments$q$);
  perform pg_temp.run('paroles.' || p_label, p_label, $q$select (select count(*) from public.platform_admin_roles) || '/' || (select count(*) from public.platform_admin_role_permissions)$q$);
  perform pg_temp.run('authid.'  || p_label, p_label, $q$select count(*)::text from public.auth_identities$q$);
end $$;
select pg_temp.lists(l) from unnest(array['ta','gm','sa1','multi','noperm','noscope','rdr','t2a','pa','pa0','parev','anon']) l;

-- ============ I1: مسح كل جدول مملوك لـTenant — ta (نطاق tenant T1، كل صلاحيات M14) لا يرى صفاً من T2 ============
create function pg_temp.sweep(p_label text) returns void
language plpgsql as $$
declare t text; n bigint; v_bad text := null; v_tables int := 0;
begin
  perform pg_temp.as_(p_label);
  execute 'set local role authenticated';
  for t in
    select c.relname from pg_class c
    where c.relnamespace = 'public'::regnamespace and c.relkind = 'r'
      and exists (select 1 from pg_attribute a where a.attrelid = c.oid and a.attname in ('platform_tenant_id', 'school_id') and not a.attisdropped)
    order by 1
  loop
    begin
      if exists (select 1 from pg_attribute a where a.attrelid = ('public.' || t)::regclass and a.attname = 'platform_tenant_id') then
        execute format('select count(*) from public.%I where platform_tenant_id = %L', t, '20000000-0000-0000-0000-000000000002') into n;
      else
        execute format('select count(*) from public.%I where school_id in (select id from t2_schools)', t) into n;
      end if;
    exception when insufficient_privilege then
      n := 0;   -- لا صلاحية على الجدول أصلاً (audit_log حتى M20) = لا صف مرئي
    end;
    v_tables := v_tables + 1;
    if n > 0 then v_bad := concat_ws(',', v_bad, t || ':' || n); end if;
  end loop;
  execute 'reset role';
  insert into r values ('sweep.' || p_label, coalesce(v_bad, 'none') || '|' || v_tables);
end $$;
select pg_temp.sweep('ta');
-- الضابط العكسي: t2a يرى بيانات T2 في جداول M14 ولا شيء من T1
select pg_temp.run('sweep.t2a_own', 't2a', $q$select (select count(*) from public.platform_tenants) || '/' || (select count(*) from public.groups) || '/' || (select count(*) from public.schools)$q$);

-- البيانات موجودة فعلاً في T2 (لا مسح فارغ): عدد الجداول المسوحة التي فيها صفوف T2، مقروءة بلا RLS
create temp table populated (n int) on commit drop;
do $$
declare t text; n bigint; v int := 0;
begin
  for t in
    select c.relname from pg_class c
    where c.relnamespace = 'public'::regnamespace and c.relkind = 'r'
      and exists (select 1 from pg_attribute a where a.attrelid = c.oid and a.attname in ('platform_tenant_id','school_id') and not a.attisdropped)
  loop
    if exists (select 1 from pg_attribute a where a.attrelid = ('public.' || t)::regclass and a.attname = 'platform_tenant_id') then
      execute format('select count(*) from public.%I where platform_tenant_id = %L', t, '20000000-0000-0000-0000-000000000002') into n;
    else
      execute format('select count(*) from public.%I where school_id in (select id from t2_schools)', t) into n;
    end if;
    if n > 0 then v := v + 1; end if;
  end loop;
  insert into populated values (v);
end $$;

-- ============ الكتابة ============
-- groups
select pg_temp.run('w.ta_group_T1',   'ta',  $q$insert into public.groups (platform_tenant_id, group_code, name) values ('10000000-0000-0000-0000-000000000001','GN','GN') returning 'ok'$q$);
select pg_temp.run('w.ta_group_T2',   'ta',  $q$insert into public.groups (platform_tenant_id, group_code, name) values ('20000000-0000-0000-0000-000000000002','GX','GX') returning 'ok'$q$);
select pg_temp.run('w.gm_group',      'gm',  $q$insert into public.groups (platform_tenant_id, group_code, name) values ('10000000-0000-0000-0000-000000000001','GM','GM') returning 'ok'$q$);
select pg_temp.run('w.rdr_group',     'rdr', $q$insert into public.groups (platform_tenant_id, group_code, name) values ('10000000-0000-0000-0000-000000000001','GR','GR') returning 'ok'$q$);
select pg_temp.run('w.anon_group',    'anon',$q$insert into public.groups (platform_tenant_id, group_code, name) values ('10000000-0000-0000-0000-000000000001','GZ','GZ') returning 'ok'$q$);
select pg_temp.run('w.ta_group_move', 'ta',  $q$update public.groups set platform_tenant_id = '20000000-0000-0000-0000-000000000002' where group_code = 'GN' returning 'ok'$q$);
select pg_temp.run('w.ta_group_rename','ta', $q$update public.groups set name = 'GN2' where group_code = 'GN' returning 'ok'$q$);
select pg_temp.run('w.gm_group_rename_GB','gm',$q$with u as (update public.groups set name = 'x' where group_code = 'GB' returning 1) select count(*)::text from u$q$);
select pg_temp.run('w.ta_group_delete','ta', $q$with u as (delete from public.groups where group_code = 'GN' returning 1) select count(*)::text from u$q$);
-- schools
select pg_temp.run('w.gm_school_GA',  'gm',  $q$insert into public.schools (platform_tenant_id, group_id, school_code, name, slug) values ('10000000-0000-0000-0000-000000000001','a1000000-0000-0000-0000-00000000000a','SA3','SA3','sa3') returning 'ok'$q$);
select pg_temp.run('w.gm_school_GB',  'gm',  $q$insert into public.schools (platform_tenant_id, group_id, school_code, name, slug) values ('10000000-0000-0000-0000-000000000001','a2000000-0000-0000-0000-00000000000b','SB2','SB2','sb2') returning 'ok'$q$);
select pg_temp.run('w.gm_school_standalone','gm',$q$insert into public.schools (platform_tenant_id, group_id, school_code, name, slug) values ('10000000-0000-0000-0000-000000000001',null,'SX','SX','sx') returning 'ok'$q$);
select pg_temp.run('w.ta_school_standalone','ta',$q$insert into public.schools (platform_tenant_id, group_id, school_code, name, slug) values ('10000000-0000-0000-0000-000000000001',null,'ST','ST','st') returning 'ok'$q$);
select pg_temp.run('w.sa1_school_GA', 'sa1', $q$insert into public.schools (platform_tenant_id, group_id, school_code, name, slug) values ('10000000-0000-0000-0000-000000000001','a1000000-0000-0000-0000-00000000000a','SA4','SA4','sa4') returning 'ok'$q$);
select pg_temp.run('w.sa1_rename_SA1','sa1', $q$with u as (update public.schools set name = 'x' where school_code = 'SA1' returning 1) select count(*)::text from u$q$);
select pg_temp.run('w.sa1_rename_SA2','sa1', $q$with u as (update public.schools set name = 'x' where school_code = 'SA2' returning 1) select count(*)::text from u$q$);
select pg_temp.run('w.ta_school_move','ta',  $q$update public.schools set platform_tenant_id = '20000000-0000-0000-0000-000000000002' where school_code = 'ST' returning 'ok'$q$);
-- platform_tenants
select pg_temp.run('w.ta_tenant_insert', 'ta', $q$insert into public.platform_tenants (tenant_code, name) values ('T9','T9') returning 'ok'$q$);
select pg_temp.run('w.pa_tenant_insert', 'pa', $q$insert into public.platform_tenants (tenant_code, name) values ('T3','T3') returning 'ok'$q$);
select pg_temp.run('w.pa0_tenant_insert','pa0',$q$insert into public.platform_tenants (tenant_code, name) values ('T4','T4') returning 'ok'$q$);
select pg_temp.run('w.ta_tenant_T1',     'ta', $q$with u as (update public.platform_tenants set name = 'x' where tenant_code = 'T1' returning 1) select count(*)::text from u$q$);
select pg_temp.run('w.ta_tenant_T2',     'ta', $q$with u as (update public.platform_tenants set name = 'x' where tenant_code = 'T2' returning 1) select count(*)::text from u$q$);
select pg_temp.run('w.gm_tenant_T1',     'gm', $q$with u as (update public.platform_tenants set name = 'x' where tenant_code = 'T1' returning 1) select count(*)::text from u$q$);
-- Platform Admin: group.create نعم، group.update لا (ليست في البذر)
select pg_temp.run('w.pa_group_T2',   'pa', $q$insert into public.groups (platform_tenant_id, group_code, name) values ('20000000-0000-0000-0000-000000000002','GP','GP') returning 'ok'$q$);
select pg_temp.run('w.pa_group_rename','pa',$q$with u as (update public.groups set name = 'x' where group_code = 'GA' returning 1) select count(*)::text from u$q$);
-- identity_scopes: لا كتابة مباشرة (T9 وحده)
select pg_temp.run('w.ta_iscope',     'ta', $q$insert into public.identity_scopes (platform_tenant_id, scope_kind, group_id) values ('10000000-0000-0000-0000-000000000001','group','a2000000-0000-0000-0000-00000000000b') returning 'ok'$q$);

-- ============ I6 / I7 ============
select pg_temp.run('i6.ta', 'ta', $q$select app.current_tenant_id()::text$q$);
select pg_temp.rec('i6.second_profile', $q$insert into public.profiles (platform_tenant_id, auth_user_id, display_name)
  select '20000000-0000-0000-0000-000000000002', auth, 'dup' from ids where label = 'ta' returning 'ok'$q$);
select pg_temp.rec('i7.tenant_as_platform', $q$insert into public.system_users (auth_user_id, display_name) select auth, 'dup' from ids where label = 'ta' returning 'ok'$q$);
select pg_temp.rec('i7.platform_as_tenant', $q$insert into public.profiles (platform_tenant_id, auth_user_id, display_name)
  select '10000000-0000-0000-0000-000000000001', auth, 'dup' from ids where label = 'pa' returning 'ok'$q$);
select pg_temp.rec('i7.overlap', $q$select count(*)::text from public.profiles p join public.system_users s using (auth_user_id)$q$);

-- ============ الدوال ============
select pg_temp.rec('exec.anon', $q$select count(*)::text from pg_proc p where p.pronamespace = 'app'::regnamespace and has_function_privilege('anon', p.oid, 'EXECUTE')$q$);
select pg_temp.rec('exec.auth', $q$select bool_and(has_function_privilege('authenticated', f, 'EXECUTE'))::text
  from unnest(array['app.can_access_group(uuid)','app.can_access_identity_scope(uuid)','app.can_access_school(uuid)','app.can_access_tenant(uuid)',
                    'app.current_system_user_id()','app.current_tenant_id()','app.has_permission(text)','app.has_platform_permission(text)']::regprocedure[]) f$q$);
select pg_temp.rec('policies', $q$select string_agg(tablename || ':' || cmd, ',' order by tablename, cmd) from pg_policies
  where schemaname = 'public' and not ('authenticated' = any(roles) and cardinality(roles) = 1)$q$);
select pg_temp.rec('delete_policies', $q$select count(*)::text from pg_policies where schemaname = 'public'
  and tablename in ('platform_tenants','groups','schools','identity_scopes','system_users','platform_admin_assignments') and cmd in ('DELETE','ALL')$q$);

select plan(96);

-- ---------- platform_tenants ----------
select is((select v from r where k = 'tenants.ta'),      'T1',     'tenants: tenant scope + tenant.read → own tenant only (I1)');
select is((select v from r where k = 'tenants.gm'),      '<null>', 'tenants: group scope is not tenant scope (F1)');
select is((select v from r where k = 'tenants.sa1'),     '<null>', 'tenants: school scope is not tenant scope (F1)');
select is((select v from r where k = 'tenants.multi'),   '<null>', 'tenants: several school scopes are not tenant scope (F1)');
select is((select v from r where k = 'tenants.noperm'),  '<null>', 'tenants: scope without permission → nothing (P2)');
select is((select v from r where k = 'tenants.noscope'), '<null>', 'tenants: permission without scope → nothing (P1)');
select is((select v from r where k = 'tenants.t2a'),     'T2',     'tenants: T2 admin sees only T2 (I1)');
select is((select v from r where k = 'tenants.pa'),      'T1,T2',  'tenants: platform admin via has_platform_permission(tenant.read) (C3)');
select is((select v from r where k = 'tenants.pa0'),     '<null>', 'tenants: platform identity without the permission → nothing (C3: identity grants nothing)');
select is((select v from r where k = 'tenants.parev'),   '<null>', 'tenants: revoked platform assignment → nothing');
select ok((select v from r where k = 'tenants.anon') like 'ERR 42501%permission denied%platform_tenants%', 'tenants: anon has no privilege (M20)');

-- ---------- groups ----------
select is((select v from r where k = 'groups.ta'),      'GA,GB',    'groups: tenant scope → every group of T1');
select is((select v from r where k = 'groups.gm'),      'GA',       'groups: group scope → its group only (I3)');
select is((select v from r where k = 'groups.sa1'),     '<null>',   'groups: school scope does not grant its group');
select is((select v from r where k = 'groups.multi'),   '<null>',   'groups: several school scopes do not grant a group');
select is((select v from r where k = 'groups.noperm'),  '<null>',   'groups: scope without permission (P2)');
select is((select v from r where k = 'groups.noscope'), '<null>',   'groups: permission without scope (P1)');
select is((select v from r where k = 'groups.t2a'),     'G2',       'groups: T2 admin → T2 group only (I1)');
select is((select v from r where k = 'groups.pa'),      'G2,GA,GB', 'groups: platform admin via group.read');
select is((select v from r where k = 'groups.pa0'),     '<null>',   'groups: platform identity without the permission');
select ok((select v from r where k = 'groups.anon') like 'ERR 42501%permission denied%groups%', 'groups: anon has no privilege (M20)');

-- ---------- schools ----------
select is((select v from r where k = 'schools.ta'),      'SA1,SA2,SB1,SS',             'schools: tenant scope → every T1 school, none of T2');
select is((select v from r where k = 'schools.gm'),      'SA1,SA2',                    'schools: group scope → its schools only; not GB, not the standalone school (I3, I4)');
select is((select v from r where k = 'schools.sa1'),     'SA1',                        'schools: school scope → its school only, not SA2 in the same group and tenant (I2, §1.1 rule 5)');
select is((select v from r where k = 'schools.multi'),   'SA2,SS',                     'schools: several school scopes work together (I5)');
select is((select v from r where k = 'schools.noperm'),  '<null>',                     'schools: scope without permission (P2)');
select is((select v from r where k = 'schools.noscope'), '<null>',                     'schools: permission without scope (P1)');
select is((select v from r where k = 'schools.t2a'),     'S2A,S2S',                    'schools: T2 admin → T2 schools only (I1)');
select is((select v from r where k = 'schools.pa'),      'S2A,S2S,SA1,SA2,SB1,SS',     'schools: platform admin via school.read');
select is((select v from r where k = 'schools.pa0'),     '<null>',                     'schools: platform identity without the permission');
select ok((select v from r where k = 'schools.anon') like 'ERR 42501%permission denied%schools%', 'schools: anon has no privilege (M20)');

-- ---------- identity_scopes ----------
select is((select v from r where k = 'iscopes.ta'),     'GA,GB,SS', 'identity_scopes: tenant scope → every T1 scope');
select is((select v from r where k = 'iscopes.gm'),     'GA',       'identity_scopes: group scope → its group scope');
select is((select v from r where k = 'iscopes.sa1'),    '<null>',   'identity_scopes: a school-scoped member does not see its group scope (H1: derived inside provisioning, not read)');
select is((select v from r where k = 'iscopes.multi'),  'SS',       'identity_scopes: a school scope sees its standalone school scope');
select is((select v from r where k = 'iscopes.noperm'), '<null>',   'identity_scopes: scope without school.read (P2)');
select is((select v from r where k = 'iscopes.t2a'),    'G2,S2S',   'identity_scopes: T2 only (I1)');
select is((select v from r where k = 'iscopes.pa'),     '<null>',   'identity_scopes: no platform policy (client identity data, §11)');

-- ---------- هوية المنصة ----------
select is((select v from r where k = 'sysusers.pa'),   'pa',     'system_users: a platform admin sees only itself');
select is((select v from r where k = 'sysusers.pa0'),  'pa0',    'system_users: self, with or without permissions');
select is((select v from r where k = 'sysusers.ta'),   '<null>', 'system_users: a tenant user sees none');
select ok((select v from r where k = 'sysusers.anon') like 'ERR 42501%permission denied%system_users%', 'system_users: anon has no privilege (M20)');
select is((select v from r where k = 'assign.pa'),     '1',      'platform_admin_assignments: own assignment only');
select is((select v from r where k = 'assign.ta'),     '0',      'platform_admin_assignments: a tenant user sees none');
select is((select v from r where k = 'paroles.pa'),    '0/0',    'platform_admin_roles/_role_permissions: service only, even for a platform admin (2026-09-25)');
select is((select v from r where k = 'paroles.ta'),    '0/0',    'platform_admin_roles/_role_permissions: a tenant user sees none');
select is((select v from r where k = 'authid.pa'),     '0',      'auth_identities: no client policy by design (M13)');
select is((select v from r where k = 'authid.ta'),     '0',      'auth_identities: a tenant user sees none');

-- ---------- I1: المسح ----------
select is((select split_part(v, '|', 1) from r where k = 'sweep.ta'), 'none',
          'I1: a tenant-scoped T1 admin sees no T2 row in any table carrying platform_tenant_id or school_id');
select is((select split_part(v, '|', 2)::int from r where k = 'sweep.ta'), (select n from populated),
          'I1: every swept table holds T2 rows (the sweep is never vacuous for a table)');
select ok((select n from populated) >= 20, 'I1: the sweep is not trivial — at least 20 tenant-owned tables hold T2 rows');
select is((select v from r where k = 'sweep.t2a_own'), '1/1/2', 'I1 control: the T2 admin sees T2 tenancy rows (1 tenant, 1 group, 2 schools)');

-- ---------- الكتابة: groups ----------
select is((select v from r where k = 'w.ta_group_T1'), 'ok', 'groups insert: tenant scope + group.create in own tenant');
select ok((select v from r where k = 'w.ta_group_T2') like 'ERR 42501%row-level security%groups%', 'groups insert: never into another tenant');
select ok((select v from r where k = 'w.gm_group')    like 'ERR 42501%row-level security%groups%', 'groups insert: group scope cannot create groups (needs tenant scope, F1)');
select ok((select v from r where k = 'w.rdr_group')   like 'ERR 42501%row-level security%groups%', 'groups insert: tenant scope without group.create');
select ok((select v from r where k = 'w.anon_group') like 'ERR 42501%permission denied%groups%', 'groups insert: anon has no privilege (M20)');
select ok((select v from r where k = 'w.ta_group_move') like 'ERR 42501%permission denied%groups%', 'groups update: platform_tenant_id is not client-writable (M20); RLS WITH CHECK remains the second line (proven before M20)');
select is((select v from r where k = 'w.ta_group_rename'), 'ok', 'groups update: rename within scope (control)');
select is((select v from r where k = 'w.gm_group_rename_GB'), '0', 'groups update: another group is invisible to USING');
select ok((select v from r where k = 'w.ta_group_delete') like 'ERR 42501%permission denied%groups%', 'groups delete: no DELETE privilege (M20; no policy either, §5.2)');

-- ---------- الكتابة: schools ----------
select is((select v from r where k = 'w.gm_school_GA'), 'ok', 'schools insert: group manager inside its group (PLAN §7.9)');
select ok((select v from r where k = 'w.gm_school_GB')         like 'ERR 42501%row-level security%schools%', 'schools insert: group manager outside its group');
select ok((select v from r where k = 'w.gm_school_standalone') like 'ERR 42501%row-level security%schools%', 'schools insert: a standalone school needs tenant scope');
select is((select v from r where k = 'w.ta_school_standalone'), 'ok', 'schools insert: tenant scope creates a standalone school');
select ok((select v from r where k = 'w.sa1_school_GA')        like 'ERR 42501%row-level security%schools%', 'schools insert: school scope cannot create schools in its group');
select is((select v from r where k = 'w.sa1_rename_SA1'), '1', 'schools update: own school');
select is((select v from r where k = 'w.sa1_rename_SA2'), '0', 'schools update: a sibling school in the same group is invisible (I2)');
select ok((select v from r where k = 'w.ta_school_move') like 'ERR 42501%permission denied%schools%', 'schools update: platform_tenant_id is not client-writable (M20); RLS WITH CHECK remains the second line');

-- ---------- الكتابة: platform_tenants ----------
select ok((select v from r where k = 'w.ta_tenant_insert') like 'ERR 42501%permission denied%platform_tenants%', 'tenants insert: no client path (K4; registry §4.6 — bootstrap_tenant)');
select ok((select v from r where k = 'w.pa_tenant_insert') like 'ERR 42501%permission denied%platform_tenants%', 'tenants insert: even a platform admin with tenant.create goes through bootstrap_tenant (registry §4.6, M20)');
select ok((select v from r where k = 'w.pa0_tenant_insert') like 'ERR 42501%permission denied%platform_tenants%', 'tenants insert: platform identity without tenant.create');
select is((select v from r where k = 'w.ta_tenant_T1'), '1', 'tenants update: tenant scope + tenant.update on own tenant');
select is((select v from r where k = 'w.ta_tenant_T2'), '0', 'tenants update: never another tenant');
select is((select v from r where k = 'w.gm_tenant_T1'), '0', 'tenants update: group scope cannot update the tenant (F1)');
select is((select v from r where k = 'w.pa_group_T2'),  'ok', 'groups insert: platform admin via group.create (seed)');
select is((select v from r where k = 'w.pa_group_rename'), '0', 'groups update: platform admin lacks group.update in the seed → nothing');
select ok((select v from r where k = 'w.ta_iscope') like 'ERR 42501%permission denied%identity_scopes%', 'identity_scopes insert: no client path (T9 only, G9)');

-- ---------- I6 / I7 ----------
select is((select v from r where k = 'i6.ta'), '10000000-0000-0000-0000-000000000001', 'I6: current_tenant_id() resolves exactly the actor''s tenant');
select ok((select v from r where k = 'i6.second_profile') like 'ERR 23505%profiles_auth_user_uq%', 'I6/O1: one Auth user cannot hold a profile in a second tenant');
select ok((select v from r where k = 'i7.tenant_as_platform') like 'ERR 23503%system_users_identity_fk%', 'I7/G10: a tenant identity cannot become a system user');
select ok((select v from r where k = 'i7.platform_as_tenant') like 'ERR 23503%profiles_identity_fk%', 'I7/G10: a platform identity cannot get a profile');
select is((select v from r where k = 'i7.overlap'), '0', 'I7: no auth_user_id in both profiles and system_users');

-- ---------- الدوال والسياسات ----------
select is((select v from r where k = 'exec.anon'), '0', 'anon executes no function in schema app');
select is((select v from r where k = 'exec.auth'), 'true', 'authenticated executes every helper the M14 policies call');
select is((select v from r where k = 'policies'), '<null>', 'every policy is TO authenticated only');
select is((select v from r where k = 'delete_policies'), '0', 'no DELETE policy on the M14 tables (§5.2)');

select policies_are('public', 'platform_tenants', array['platform_tenants_tenant_select','platform_tenants_tenant_update',
  'platform_tenants_platform_select','platform_tenants_platform_update'], 'platform_tenants: exactly the M14 policies minus platform_insert (dropped in M20b — bootstrap_tenant is the only path)');
select policies_are('public', 'groups', array['groups_tenant_select','groups_tenant_insert','groups_tenant_update',
  'groups_platform_select','groups_platform_insert','groups_platform_update'], 'groups: exactly the M14 policies');
select policies_are('public', 'schools', array['schools_tenant_select','schools_tenant_insert','schools_tenant_update',
  'schools_platform_select','schools_platform_insert','schools_platform_update'], 'schools: exactly the M14 policies');
select policies_are('public', 'identity_scopes', array['identity_scopes_tenant_select'], 'identity_scopes: read only');
select policies_are('public', 'system_users', array['system_users_self_select'], 'system_users: self only');
select policies_are('public', 'platform_admin_assignments', array['platform_admin_assignments_self_select'], 'platform_admin_assignments: self only');
select is((select count(*)::int from pg_policies where schemaname = 'public'
            and tablename in ('platform_admin_roles','platform_admin_role_permissions','auth_identities')), 0,
          'platform_admin_roles, platform_admin_role_permissions, auth_identities: no client policy');

-- الفصل بين السياقين: لا سياسة تجمع has_permission و has_platform_permission (G10)
select is((select count(*)::int from pg_policies where schemaname = 'public'
            and coalesce(qual, '') || coalesce(with_check, '') like '%has_permission(%'
            and coalesce(qual, '') || coalesce(with_check, '') like '%has_platform_permission(%'), 0,
          'G10: no policy mixes tenant and platform permissions');
select is((select count(*)::int from pg_policies where schemaname = 'public'
            and coalesce(qual, '') || coalesce(with_check, '') like '%is_platform_admin()%'), 0,
          'C3: no policy relies on is_platform_admin()');

select * from finish();
rollback;
