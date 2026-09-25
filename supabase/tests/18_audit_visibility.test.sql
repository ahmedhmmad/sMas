-- M18 — policies_audit: رؤية audit_log (RLS §13، F10، F11، E15، E16) + H2
-- صفوف التدقيق يكتبها T7 من إدراجات الـfixture نفسها. SELECT لـauthenticated يُمنح في M20 (تبعية M11):
-- هنا يُمنح مؤقتاً داخل المعاملة (يُلغى بالـrollback) لتقييم السياسة، ويُثبت أولاً أنه غائب الآن.
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

create temp table ids (label text primary key, auth uuid, profile uuid) on commit drop;
create temp table lbl (id text primary key, label text) on commit drop;   -- entity_id → تسمية
grant all on ids, lbl to public;

create function pg_temp.run(p_key text, p_label text, p_sql text) returns void
language plpgsql as $$
declare v_sub uuid := (select auth from ids where label = p_label);
begin
  perform set_config('request.jwt.claims', json_build_object('sub', v_sub, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', coalesce(v_sub::text, ''), true);
  if p_label = 'anon' then execute 'set local role anon'; else execute 'set local role authenticated'; end if;
  perform pg_temp.rec(p_key, p_sql);
  execute 'reset role';
end $$;

create function pg_temp.person(p_label text, p_tenant uuid) returns uuid
language plpgsql as $$
declare v_auth uuid := gen_random_uuid(); v_profile uuid;
begin
  insert into auth.users (id, email) values (v_auth, p_label || '@m18.invalid');
  insert into public.auth_identities values (v_auth, 'tenant');
  insert into public.profiles (platform_tenant_id, auth_user_id, display_name) values (p_tenant, v_auth, p_label) returning id into v_profile;
  insert into ids values (p_label, v_auth, v_profile);
  return v_profile;
end $$;

-- ============ Fixture ============
-- T1: GA (SA1, SA2)، GB (SB1) — T2: مستقلة S2
insert into public.platform_tenants (id, tenant_code, name) values
  ('10000000-0000-0000-0000-000000000001', 'T1', 'T1'), ('20000000-0000-0000-0000-000000000002', 'T2', 'T2');
insert into public.groups (id, platform_tenant_id, group_code, name) values
  ('a1000000-0000-0000-0000-00000000000a', '10000000-0000-0000-0000-000000000001', 'GA', 'GA'),
  ('a2000000-0000-0000-0000-00000000000b', '10000000-0000-0000-0000-000000000001', 'GB', 'GB');
insert into public.schools (id, platform_tenant_id, group_id, school_code, name, slug) values
  ('5a100000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', 'a1000000-0000-0000-0000-00000000000a', 'SA1', 'SA1', 'sa1'),
  ('5a200000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001', 'a1000000-0000-0000-0000-00000000000a', 'SA2', 'SA2', 'sa2'),
  ('5b100000-0000-0000-0000-000000000003', '10000000-0000-0000-0000-000000000001', 'a2000000-0000-0000-0000-00000000000b', 'SB1', 'SB1', 'sb1'),
  ('52000000-0000-0000-0000-000000000005', '20000000-0000-0000-0000-000000000002', null,                                   'S2',  'S2',  's2');
insert into lbl select id::text, tenant_code from public.platform_tenants;
insert into lbl select id::text, group_code  from public.groups;
insert into lbl select id::text, school_code from public.schools;

create temp table ctx (school uuid primary key, code text, year uuid, grade uuid, sec uuid, iscope uuid, owner uuid) on commit drop;
do $$
declare s record; v_stage uuid; v_grade uuid; v_y uuid; v_sec uuid;
begin
  for s in select id, school_code, scope_owner_id from public.schools loop
    insert into public.academic_years (school_id, name, start_date, end_date, status) values (s.id, 'Y', '2026-09-01', '2027-06-30', 'active') returning id into v_y;
    insert into public.stages (school_id, name, sequence_no) values (s.id, 'P', 1) returning id into v_stage;
    insert into public.grade_levels (school_id, stage_id, name, sequence_no) values (s.id, v_stage, 'G1', 1) returning id into v_grade;
    insert into public.sections (school_id, academic_year_id, grade_level_id, name) values (s.id, v_y, v_grade, 'A') returning id into v_sec;
    insert into ctx values (s.id, s.school_code, v_y, v_grade, v_sec, (select id from public.identity_scopes where owner_id = s.scope_owner_id), s.scope_owner_id);
    insert into lbl values (v_y::text, s.school_code);
  end loop;
end $$;

-- الطلاب: sa (SA1)، sm (SA1 → SA2)، sb (SB1)، st2 (T2)
create function pg_temp.student(p_label text, p_tenant uuid, p_school text, p_family uuid default null) returns uuid
language plpgsql as $$
declare v_id uuid;
begin
  insert into public.students (platform_tenant_id, identity_scope_id, student_profile_id, family_id, official_id, official_id_type, first_name, family_name)
    values (p_tenant, (select iscope from ctx where code = p_school), pg_temp.person(p_label, p_tenant), p_family, 'N-' || p_label, 'national_id', p_label, p_label)
    returning id into v_id;
  insert into lbl values (v_id::text, p_label);
  return v_id;
end $$;
create function pg_temp.enroll(p_student uuid, p_label text, p_school text, p_status text, p_from date, p_to date) returns void
language plpgsql as $$
declare v_id uuid;
begin
  insert into public.enrollments (school_id, student_id, platform_tenant_id, academic_year_id, grade_level_id, section_id, identity_scope_id, scope_owner_id, status, effective_from, effective_to)
    select c.school, p_student, s.platform_tenant_id, c.year, c.grade, c.sec, s.identity_scope_id, c.owner, p_status, p_from, p_to
    from ctx c, public.students s where c.code = p_school and s.id = p_student
    returning id into v_id;
  insert into lbl values (v_id::text, p_label || ':' || p_school);
end $$;

do $$
declare v_fa uuid; v_fb uuid; v_sa uuid; v_sm uuid; v_sb uuid; v_st2 uuid; v_g uuid; v_f uuid;
begin
  insert into public.families (platform_tenant_id, family_name) values ('10000000-0000-0000-0000-000000000001', 'fama') returning id into v_fa;
  insert into public.families (platform_tenant_id, family_name) values ('10000000-0000-0000-0000-000000000001', 'famb') returning id into v_fb;
  insert into lbl values (v_fa::text, 'fama'), (v_fb::text, 'famb');
  v_sa  := pg_temp.student('sa',  '10000000-0000-0000-0000-000000000001', 'SA1', v_fa);
  v_sm  := pg_temp.student('sm',  '10000000-0000-0000-0000-000000000001', 'SA1');
  v_sb  := pg_temp.student('sb',  '10000000-0000-0000-0000-000000000001', 'SB1', v_fb);
  v_st2 := pg_temp.student('st2', '20000000-0000-0000-0000-000000000002', 'S2');
  perform pg_temp.enroll(v_sa,  'sa',  'SA1', 'active',      '2026-09-01', null);
  perform pg_temp.enroll(v_sm,  'sm',  'SA1', 'transferred', '2026-09-01', '2026-12-01');
  perform pg_temp.enroll(v_sm,  'sm',  'SA2', 'active',      '2026-12-01', null);
  perform pg_temp.enroll(v_sb,  'sb',  'SB1', 'active',      '2026-09-01', null);
  perform pg_temp.enroll(v_st2, 'st2', 'S2',  'active',      '2026-09-01', null);
  -- أولياء الأمور والموظفون: gsa/fsa لـSA1، gsb/fsb لـSB1
  insert into public.guardians (platform_tenant_id, first_name, family_name, phone_e164) values ('10000000-0000-0000-0000-000000000001', 'g', 'g', '+201000000001') returning id into v_g;
  insert into lbl values (v_g::text, 'gsa');
  insert into public.student_guardians (student_id, guardian_id, platform_tenant_id, relationship_type) values (v_sa, v_g, '10000000-0000-0000-0000-000000000001', 'father');
  insert into public.guardians (platform_tenant_id, first_name, family_name, phone_e164) values ('10000000-0000-0000-0000-000000000001', 'g', 'g', '+201000000002') returning id into v_g;
  insert into lbl values (v_g::text, 'gsb');
  insert into public.student_guardians (student_id, guardian_id, platform_tenant_id, relationship_type) values (v_sb, v_g, '10000000-0000-0000-0000-000000000001', 'father');
  insert into public.staff (platform_tenant_id, employee_code, first_name, family_name) values ('10000000-0000-0000-0000-000000000001', 'E1', 'f', 'f') returning id into v_f;
  insert into lbl values (v_f::text, 'fsa');
  insert into public.staff_school_assignments (staff_id, school_id, platform_tenant_id, job_title, effective_from) values (v_f, (select school from ctx where code = 'SA1'), '10000000-0000-0000-0000-000000000001', 'T', '2026-09-01');
  insert into public.staff (platform_tenant_id, employee_code, first_name, family_name) values ('10000000-0000-0000-0000-000000000001', 'E2', 'f', 'f') returning id into v_f;
  insert into lbl values (v_f::text, 'fsb');
  insert into public.staff_school_assignments (staff_id, school_id, platform_tenant_id, job_title, effective_from) values (v_f, (select school from ctx where code = 'SB1'), '10000000-0000-0000-0000-000000000001', 'T', '2026-09-01');
end $$;

-- الصلاحيات والأدوار
insert into public.permissions (code, resource, operation, description) values ('audit.read', 'audit', 'read', 'test'), ('student.read', 'student', 'read', 'test');
insert into public.roles (id, platform_tenant_id, code, name, is_system) values
  ('71000000-0000-0000-0000-000000000001', null, 'auditor', 'Auditor', true),
  ('72000000-0000-0000-0000-000000000002', null, 'reader',  'Reader',  true);
insert into public.role_permissions select '71000000-0000-0000-0000-000000000001', id from public.permissions where code = 'audit.read';
insert into public.role_permissions select '72000000-0000-0000-0000-000000000002', id from public.permissions where code = 'student.read';

create function pg_temp.member(p_label text, p_tenant uuid, p_role uuid, p_scope text) returns void
language plpgsql as $$
declare v_m uuid;
begin
  perform pg_temp.person(p_label, p_tenant);
  insert into public.memberships (platform_tenant_id, profile_id) values (p_tenant, (select profile from ids where label = p_label)) returning id into v_m;
  insert into public.membership_roles (membership_id, role_id, platform_tenant_id, role_owner_key) values (v_m, p_role, p_tenant, '00000000-0000-0000-0000-000000000000');
  if p_scope = 'tenant' then
    insert into public.membership_scopes (membership_id, platform_tenant_id, scope_type) values (v_m, p_tenant, 'tenant');
  elsif p_scope like 'G%' then
    insert into public.membership_scopes (membership_id, platform_tenant_id, scope_type, group_id) values (v_m, p_tenant, 'group', (select id from public.groups where group_code = p_scope));
  else
    insert into public.membership_scopes (membership_id, platform_tenant_id, scope_type, school_id) values (v_m, p_tenant, 'school', (select school from ctx where code = p_scope));
  end if;
end $$;
select pg_temp.member('ta',      '10000000-0000-0000-0000-000000000001', '71000000-0000-0000-0000-000000000001', 'tenant');
select pg_temp.member('gm',      '10000000-0000-0000-0000-000000000001', '71000000-0000-0000-0000-000000000001', 'GA');
select pg_temp.member('acc',     '10000000-0000-0000-0000-000000000001', '71000000-0000-0000-0000-000000000001', 'SA1');   -- المحاسب (E15)
select pg_temp.member('sa2',     '10000000-0000-0000-0000-000000000001', '71000000-0000-0000-0000-000000000001', 'SA2');
select pg_temp.member('noaudit', '10000000-0000-0000-0000-000000000001', '72000000-0000-0000-0000-000000000002', 'tenant');
select pg_temp.member('t2a',     '20000000-0000-0000-0000-000000000002', '71000000-0000-0000-0000-000000000001', 'tenant');

-- Platform Admins: pa (audit.read + student.read في سياق المنصة)، pa0 (بلا صلاحيات)
insert into public.platform_admin_roles (id, code, name) values ('81000000-0000-0000-0000-000000000001', 'pa_audit', 'A'), ('82000000-0000-0000-0000-000000000002', 'pa_none', 'N');
insert into public.platform_admin_role_permissions select '81000000-0000-0000-0000-000000000001', id from public.permissions;
do $$
declare l text; v_auth uuid; v_su uuid;
begin
  foreach l in array array['pa','pa0'] loop
    v_auth := gen_random_uuid();
    insert into auth.users (id, email) values (v_auth, l || '@m18.invalid');
    insert into public.auth_identities values (v_auth, 'platform');
    insert into public.system_users (auth_user_id, display_name) values (v_auth, l) returning id into v_su;
    insert into public.platform_admin_assignments (system_user_id, platform_admin_role_id)
      values (v_su, case l when 'pa' then '81000000-0000-0000-0000-000000000001'::uuid else '82000000-0000-0000-0000-000000000002'::uuid end);
    insert into ids values (l, v_auth, null);
  end loop;
end $$;

-- ============ القراءة ============
-- قبل منح SELECT (الحالة المنشورة حتى M20): الرفض بالصلاحية لا بالسياسة
select pg_temp.run('pre.ta',   'ta',   'select count(*)::text from public.audit_log');
select pg_temp.run('pre.anon', 'anon', 'select count(*)::text from public.audit_log');

grant select on public.audit_log to authenticated;   -- مؤقت: M20 يمنحه فعلياً

create function pg_temp.vis() returns text language sql as $$
  select string_agg(distinct (a.entity_type || ':' || l.label) collate "C", ',' order by (a.entity_type || ':' || l.label) collate "C")
  from public.audit_log a join lbl l on l.id = a.entity_id
  where a.entity_type in ('platform_tenants','groups','schools','academic_years','students','enrollments','guardians','staff','families') $$;
select pg_temp.run('vis.' || l, l, 'select pg_temp.vis()')
  from unnest(array['ta','gm','acc','sa2','noaudit','t2a','pa','pa0']) l;

-- F10: صفوف tenant-level أخرى (profiles، memberships) — تحتاج نطاق tenant
select pg_temp.run('tl.ta',  'ta',  $q$select (count(*) > 0)::text from public.audit_log where entity_type in ('profiles','memberships')$q$);
select pg_temp.run('tl.acc', 'acc', $q$select count(*)::text from public.audit_log where entity_type in ('profiles','memberships')$q$);
-- E16: لا صف تدقيق طالب للـPlatform Admin، ولا أي نوع خارج قائمة المنصة
select pg_temp.run('e16.students', 'pa', $q$select count(*)::text from public.audit_log where entity_type = 'students'$q$);
select pg_temp.run('e16.other',    'pa', $q$select coalesce(string_agg(distinct entity_type, ','), 'none') from public.audit_log
  where entity_type not in ('platform_tenants','groups','schools','system_users','platform_admin_roles','platform_admin_assignments','platform_admin_role_permissions')$q$);
-- الكتابة: لا مسار للعميل (T7 وحده؛ T5 يرفض)
select pg_temp.run('w.insert', 'ta', $q$insert into public.audit_log (actor_type, action, entity_type, entity_id) values ('system','insert','x','x') returning 'ok'$q$);
select pg_temp.run('w.update', 'ta', $q$with u as (update public.audit_log set reason = 'x' returning 1) select count(*)::text from u$q$);
select pg_temp.run('w.delete', 'ta', $q$with u as (delete from public.audit_log returning 1) select count(*)::text from u$q$);

select plan(24);

select ok((select v from r where k = 'pre.ta')   like 'ERR 42501%permission denied%audit_log%', 'deployed state until M20: authenticated has no SELECT on audit_log (M11 dependency)');
select ok((select v from r where k = 'pre.anon') like 'ERR 42501%permission denied%audit_log%', 'anon has no SELECT on audit_log');

-- ---------- الرؤية ----------
select is((select v from r where k = 'vis.ta'),
  'academic_years:SA1,academic_years:SA2,academic_years:SB1,enrollments:sa:SA1,enrollments:sb:SB1,enrollments:sm:SA1,enrollments:sm:SA2,families:fama,families:famb,groups:GA,groups:GB,guardians:gsa,guardians:gsb,platform_tenants:T1,schools:SA1,schools:SA2,schools:SB1,staff:fsa,staff:fsb,students:sa,students:sb,students:sm',
  'tenant scope + audit.read → every T1 audit row, nothing of T2');
select is((select v from r where k = 'vis.gm'),
  'academic_years:SA1,academic_years:SA2,enrollments:sa:SA1,enrollments:sm:SA1,enrollments:sm:SA2,families:fama,guardians:gsa,staff:fsa,students:sa,students:sm',
  'group scope → school rows of GA and identity rows of GA-current people; no tenant-level rows (F10)');
select is((select v from r where k = 'vis.acc'),
  'academic_years:SA1,enrollments:sa:SA1,enrollments:sm:SA1,families:fama,guardians:gsa,staff:fsa,students:sa',
  'E15/F10: the SA1 accountant sees SA1 rows and its current people only — not sb (SB1), not sm''s identity (moved, H2)');
select is((select v from r where k = 'vis.sa2'),
  'academic_years:SA2,enrollments:sm:SA2,students:sm',
  'H2: SA2 sees the moved student''s identity audit — and only its own enrollment row, not SA1''s');
select is((select v from r where k = 'vis.noaudit'), '<null>', 'without audit.read nothing, even with tenant scope');
select is((select v from r where k = 'vis.t2a'),
  'academic_years:S2,enrollments:st2:S2,platform_tenants:T2,schools:S2,students:st2',
  'T2 admin sees only T2 rows (I1)');
select is((select v from r where k = 'vis.pa'),
  'groups:GA,groups:GB,platform_tenants:T1,platform_tenants:T2,schools:S2,schools:SA1,schools:SA2,schools:SB1',
  'F11: platform admin sees platform-level entities only');
select is((select v from r where k = 'vis.pa0'), '<null>', 'C3: platform identity without audit.read sees nothing');

-- ---------- F10، E16 ----------
select is((select v from r where k = 'tl.ta'),  'true', 'F10: tenant scope sees other tenant-level rows (profiles, memberships)');
select is((select v from r where k = 'tl.acc'), '0',    'F10: a school-scoped auditor sees no other tenant-level row');
select is((select v from r where k = 'e16.students'), '0',    'E16: platform admin — holding student.read too — sees no students audit row');
select is((select v from r where k = 'e16.other'),    'none', 'F11: platform admin sees no entity type outside the platform list');

-- ---------- الكتابة ----------
select ok((select v from r where k = 'w.insert') like 'ERR 42501%audit_log%', 'no client INSERT into audit_log');
select ok((select v from r where k = 'w.update') like 'ERR 42501%audit_log%', 'no client UPDATE of audit_log');
select ok((select v from r where k = 'w.delete') like 'ERR 42501%audit_log%', 'no client DELETE from audit_log');

-- ---------- السياسات ----------
select policies_are('public', 'audit_log', array['audit_log_tenant_select','audit_log_platform_select'], 'audit_log: exactly two SELECT policies (tenant and platform contexts separate)');
select is((select count(*)::int from pg_policies where schemaname = 'public' and tablename = 'audit_log' and cmd <> 'SELECT'), 0, 'audit_log: no write policy');
select is((select count(*)::int from pg_policies where schemaname = 'public' and tablename = 'audit_log'
            and not ('authenticated' = any(roles) and cardinality(roles) = 1)), 0, 'audit_log policies are TO authenticated only');
select is((select count(*)::int from pg_policies where schemaname = 'public'
            and coalesce(qual, '') like '%has_permission(%' and coalesce(qual, '') like '%has_platform_permission(%'), 0,
          'G10: the two contexts are never OR-ed in one policy');
select is((select count(*)::int from pg_policies where schemaname = 'public' and coalesce(qual, '') like '%is_platform_admin()%'), 0,
          'C3/F11: no policy relies on is_platform_admin()');
select is((select count(*)::int from pg_policies where schemaname = 'public' and tablename = 'audit_log'
            and qual ~ 'entity_id\)?::uuid' and qual !~ 'CASE'), 0, 'entity_id is cast to uuid only inside CASE (composite link keys never reach the cast)');
select ok(has_table_privilege('authenticated', 'public.audit_log', 'SELECT') , 'sanity: the temporary grant is active for this test');

select * from finish();
rollback;
