-- M46 — staff_profile (Phase 3A / 3-1، P12): تخصصات الموظف ومؤهلاته [I] — تُرى وتُكتب **بالعلاقة** كـstaff:
-- Tenant ∧ المفتاح (staff.read / staff.update) ∧ app.staff_in_scope(staff_id) (تكليف نشط في نطاق الفاعل — H2).
-- لا DELETE؛ staff_id و platform_tenant_id ثابتان؛ الصف يولد active؛ T7 يدقّق.
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

create temp table actors (label text primary key, auth uuid) on commit drop;
grant select on actors to public;

create function pg_temp.run(p_key text, p_label text, p_sql text) returns void
language plpgsql as $$
declare v_sub uuid := (select auth from actors where label = p_label);
begin
  perform set_config('request.jwt.claims', json_build_object('sub', v_sub, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', v_sub::text, true);
  execute 'set local role authenticated';
  perform pg_temp.rec(p_key, p_sql);
  execute 'reset role';
end $$;

-- ============ Fixture ============
insert into public.platform_tenants (id, tenant_code, host_label, name) values
  ('10000000-0000-0000-0000-000000000001', 'T1', 't1', 'T1'), ('20000000-0000-0000-0000-000000000002', 'T2', 't2', 'T2');
insert into public.groups (id, platform_tenant_id, group_code, name) values ('a1000000-0000-0000-0000-00000000000a', '10000000-0000-0000-0000-000000000001', 'GA', 'GA');
insert into public.schools (id, platform_tenant_id, group_id, school_code, name, slug) values
  ('5a000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', 'a1000000-0000-0000-0000-00000000000a', 'SA', 'SA', 'sa'),
  ('5b000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001', 'a1000000-0000-0000-0000-00000000000a', 'SB', 'SB', 'sb'),
  ('5c000000-0000-0000-0000-000000000003', '20000000-0000-0000-0000-000000000002', null,                                   'SX', 'SX', 'sx');

-- E1: SA نشط · E2: SB نشط · E3: كان في SA وانتهى تكليفه · E4: T2 (SX)
insert into public.staff (id, platform_tenant_id, employee_code, first_name, family_name) values
  ('e1000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', 'E1', 'E', 'One'),
  ('e2000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001', 'E2', 'E', 'Two'),
  ('e3000000-0000-0000-0000-000000000003', '10000000-0000-0000-0000-000000000001', 'E3', 'E', 'Three'),
  ('e4000000-0000-0000-0000-000000000004', '20000000-0000-0000-0000-000000000002', 'E4', 'E', 'Four');
insert into public.staff_school_assignments (staff_id, school_id, platform_tenant_id, job_title, effective_from) values
  ('e1000000-0000-0000-0000-000000000001', '5a000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', 'Teacher', '2026-09-01'),
  ('e2000000-0000-0000-0000-000000000002', '5b000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001', 'Teacher', '2026-09-01'),
  ('e4000000-0000-0000-0000-000000000004', '5c000000-0000-0000-0000-000000000003', '20000000-0000-0000-0000-000000000002', 'Teacher', '2026-09-01');
insert into public.staff_school_assignments (staff_id, school_id, platform_tenant_id, job_title, effective_from, status, effective_to) values
  ('e3000000-0000-0000-0000-000000000003', '5a000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', 'Teacher', '2025-09-01', 'ended', '2026-06-30');

insert into public.staff_specialties (id, platform_tenant_id, staff_id, name) values
  ('51000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', 'e1000000-0000-0000-0000-000000000001', 'Math'),
  ('52000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001', 'e2000000-0000-0000-0000-000000000002', 'Physics'),
  ('53000000-0000-0000-0000-000000000003', '10000000-0000-0000-0000-000000000001', 'e3000000-0000-0000-0000-000000000003', 'Chemistry'),
  ('54000000-0000-0000-0000-000000000004', '20000000-0000-0000-0000-000000000002', 'e4000000-0000-0000-0000-000000000004', 'Biology');
insert into public.staff_qualifications (id, platform_tenant_id, staff_id, degree, field) values
  ('91000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', 'e1000000-0000-0000-0000-000000000001', 'bachelor', 'Math'),
  ('92000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001', 'e2000000-0000-0000-0000-000000000002', 'master', 'Physics'),
  ('93000000-0000-0000-0000-000000000003', '10000000-0000-0000-0000-000000000001', 'e3000000-0000-0000-0000-000000000003', 'bachelor', 'Chemistry'),
  ('94000000-0000-0000-0000-000000000004', '20000000-0000-0000-0000-000000000002', 'e4000000-0000-0000-0000-000000000004', 'doctorate', 'Biology');

create function pg_temp.member(p_label text, p_role text, p_tenant uuid, p_scope text, p_target uuid) returns void
language plpgsql as $$
declare v_a uuid := gen_random_uuid(); v_p uuid; v_m uuid;
begin
  insert into auth.users (id, email) values (v_a, p_label || '@m46.invalid');
  insert into public.auth_identities (auth_user_id, kind) values (v_a, 'tenant');
  insert into public.profiles (platform_tenant_id, auth_user_id, display_name) values (p_tenant, v_a, p_label) returning id into v_p;
  insert into public.memberships (platform_tenant_id, profile_id) values (p_tenant, v_p) returning id into v_m;
  insert into public.membership_roles (membership_id, role_id, platform_tenant_id, role_owner_key)
    values (v_m, (select id from public.roles where code = p_role and platform_tenant_id is null), p_tenant, '00000000-0000-0000-0000-000000000000');
  insert into public.membership_scopes (membership_id, platform_tenant_id, scope_type, school_id)
    values (v_m, p_tenant, p_scope, case when p_scope = 'school' then p_target end);
  insert into actors values (p_label, v_a);
end $$;
select pg_temp.member('sa',  'school_admin', '10000000-0000-0000-0000-000000000001', 'school', '5a000000-0000-0000-0000-000000000001');
select pg_temp.member('sb',  'school_admin', '10000000-0000-0000-0000-000000000001', 'school', '5b000000-0000-0000-0000-000000000002');
select pg_temp.member('tch', 'teacher',      '10000000-0000-0000-0000-000000000001', 'school', '5a000000-0000-0000-0000-000000000001');   -- staff.read بلا staff.update (PD1)
select pg_temp.member('sec', 'secretary',    '10000000-0000-0000-0000-000000000001', 'school', '5a000000-0000-0000-0000-000000000001');   -- بلا staff.read
select pg_temp.member('ta',  'tenant_admin', '10000000-0000-0000-0000-000000000001', 'tenant', null);
select pg_temp.member('x',   'school_admin', '20000000-0000-0000-0000-000000000002', 'school', '5c000000-0000-0000-0000-000000000003');

-- ============ القراءة: قائمة كاملة لكل فاعل ============
create function pg_temp.reads(p_label text) returns void language plpgsql as $$
begin
  perform pg_temp.run('spec.' || p_label, p_label, $q$select coalesce(string_agg(name, ',' order by name), '') from public.staff_specialties$q$);
  perform pg_temp.run('qual.' || p_label, p_label, $q$select coalesce(string_agg(field, ',' order by field), '') from public.staff_qualifications$q$);
end $$;
select pg_temp.reads(l) from unnest(array['sa','sb','tch','sec','ta','x']) l;

-- ============ الكتابة ============
-- مسموح: sa لموظف SA
select pg_temp.run('w.sa_insert',      'sa', $q$insert into public.staff_specialties (platform_tenant_id, staff_id, name) values ('10000000-0000-0000-0000-000000000001', 'e1000000-0000-0000-0000-000000000001', 'Statistics') returning 'ok'$q$);
select pg_temp.run('w.sa_qual',        'sa', $q$insert into public.staff_qualifications (platform_tenant_id, staff_id, degree, field, institution, graduation_year) values ('10000000-0000-0000-0000-000000000001', 'e1000000-0000-0000-0000-000000000001', 'master', 'Education', 'Cairo University', 2015) returning 'ok'$q$);
select pg_temp.run('w.sa_disable',     'sa', $q$update public.staff_specialties set status = 'inactive' where id = '51000000-0000-0000-0000-000000000001' returning status$q$);
select pg_temp.run('w.sa_qual_fix',    'sa', $q$update public.staff_qualifications set field = 'Mathematics', graduation_year = 2010 where id = '91000000-0000-0000-0000-000000000001' returning field$q$);
-- مرفوض: خارج العلاقة
select pg_temp.run('w.sa_other_school','sa', $q$insert into public.staff_specialties (platform_tenant_id, staff_id, name) values ('10000000-0000-0000-0000-000000000001', 'e2000000-0000-0000-0000-000000000002', 'X') returning 'ok'$q$);
select pg_temp.run('w.sa_ended',       'sa', $q$insert into public.staff_specialties (platform_tenant_id, staff_id, name) values ('10000000-0000-0000-0000-000000000001', 'e3000000-0000-0000-0000-000000000003', 'X') returning 'ok'$q$);
select pg_temp.run('w.sa_cross_tenant','sa', $q$insert into public.staff_specialties (platform_tenant_id, staff_id, name) values ('20000000-0000-0000-0000-000000000002', 'e4000000-0000-0000-0000-000000000004', 'X') returning 'ok'$q$);
select pg_temp.run('w.sa_mixed_tenant','sa', $q$insert into public.staff_specialties (platform_tenant_id, staff_id, name) values ('10000000-0000-0000-0000-000000000001', 'e4000000-0000-0000-0000-000000000004', 'X') returning 'ok'$q$);
select pg_temp.run('w.tch_insert',     'tch', $q$insert into public.staff_specialties (platform_tenant_id, staff_id, name) values ('10000000-0000-0000-0000-000000000001', 'e1000000-0000-0000-0000-000000000001', 'X') returning 'ok'$q$);
select pg_temp.run('w.tch_qual',       'tch', $q$insert into public.staff_qualifications (platform_tenant_id, staff_id, degree, field) values ('10000000-0000-0000-0000-000000000001', 'e1000000-0000-0000-0000-000000000001', 'other', 'X') returning 'ok'$q$);
select pg_temp.run('w.tch_qual_upd',   'tch', $q$update public.staff_qualifications set field = 'Hacked' where id = '91000000-0000-0000-0000-000000000001' returning field$q$);
select pg_temp.run('w.sec_insert',     'sec', $q$insert into public.staff_specialties (platform_tenant_id, staff_id, name) values ('10000000-0000-0000-0000-000000000001', 'e1000000-0000-0000-0000-000000000001', 'X') returning 'ok'$q$);
-- مرفوض: الأعمدة
select pg_temp.run('w.status_insert',  'sa', $q$insert into public.staff_specialties (platform_tenant_id, staff_id, name, status) values ('10000000-0000-0000-0000-000000000001', 'e1000000-0000-0000-0000-000000000001', 'Y', 'inactive') returning 'ok'$q$);
select pg_temp.run('w.move_staff',     'sa', $q$update public.staff_specialties set staff_id = 'e2000000-0000-0000-0000-000000000002' where id = '51000000-0000-0000-0000-000000000001' returning 'ok'$q$);
select pg_temp.run('w.move_tenant',    'sa', $q$update public.staff_qualifications set platform_tenant_id = '20000000-0000-0000-0000-000000000002' where id = '91000000-0000-0000-0000-000000000001' returning 'ok'$q$);
select pg_temp.run('w.delete_spec',    'sa', $q$delete from public.staff_specialties where id = '51000000-0000-0000-0000-000000000001' returning 'ok'$q$);
select pg_temp.run('w.delete_qual',    'sa', $q$delete from public.staff_qualifications where id = '91000000-0000-0000-0000-000000000001' returning 'ok'$q$);
-- UPDATE أعمى (بلا WHERE ولا RETURNING، قيمة ثابتة): سياسة UPDATE تحمل العلاقة بنفسها
select pg_temp.run('w.blind_sb',       'sb',  $q$with u as (update public.staff_specialties set name = 'Hacked') select 'done'$q$);
select pg_temp.run('w.blind_tch',      'tch', $q$with u as (update public.staff_specialties set name = 'Hacked') select 'done'$q$);
select pg_temp.run('w.blind_qual_tch', 'tch', $q$with u as (update public.staff_qualifications set field = 'Hacked') select 'done'$q$);
select pg_temp.run('w.blind_qual_x',   'x',   $q$with u as (update public.staff_qualifications set field = 'Hacked') select 'done'$q$);

-- القيود بأسمائها (المسار المميّز — القيد يسري على كل مسار)
select pg_temp.rec('c.dup',     $q$insert into public.staff_specialties (platform_tenant_id, staff_id, name) values ('10000000-0000-0000-0000-000000000001', 'e1000000-0000-0000-0000-000000000001', 'Math') returning 'ok'$q$);
select pg_temp.rec('c.blank',   $q$insert into public.staff_specialties (platform_tenant_id, staff_id, name) values ('10000000-0000-0000-0000-000000000001', 'e1000000-0000-0000-0000-000000000001', '  ') returning 'ok'$q$);
select pg_temp.rec('c.padded',  $q$insert into public.staff_specialties (platform_tenant_id, staff_id, name) values ('10000000-0000-0000-0000-000000000001', 'e1000000-0000-0000-0000-000000000001', ' Math ') returning 'ok'$q$);
select pg_temp.rec('c.tenant',  $q$insert into public.staff_specialties (platform_tenant_id, staff_id, name) values ('20000000-0000-0000-0000-000000000002', 'e1000000-0000-0000-0000-000000000001', 'Z') returning 'ok'$q$);
select pg_temp.rec('c.degree',  $q$insert into public.staff_qualifications (platform_tenant_id, staff_id, degree, field) values ('10000000-0000-0000-0000-000000000001', 'e1000000-0000-0000-0000-000000000001', 'phd', 'X') returning 'ok'$q$);
select pg_temp.rec('c.year',    $q$insert into public.staff_qualifications (platform_tenant_id, staff_id, degree, field, graduation_year) values ('10000000-0000-0000-0000-000000000001', 'e1000000-0000-0000-0000-000000000001', 'other', 'X', 1800) returning 'ok'$q$);
select pg_temp.rec('c.field',   $q$insert into public.staff_qualifications (platform_tenant_id, staff_id, degree, field) values ('10000000-0000-0000-0000-000000000001', 'e1000000-0000-0000-0000-000000000001', 'other', '') returning 'ok'$q$);
select pg_temp.rec('c.qstaff',  $q$insert into public.staff_qualifications (platform_tenant_id, staff_id, degree, field) values ('20000000-0000-0000-0000-000000000002', 'e1000000-0000-0000-0000-000000000001', 'other', 'X') returning 'ok'$q$);
select pg_temp.rec('c.status',  $q$update public.staff_qualifications set status = 'deleted' where id = '91000000-0000-0000-0000-000000000001' returning 'ok'$q$);

-- انتهاء التكليف يسحب الرؤية والكتابة فوراً (H2: staff_in_scope = تكليف نشط)
update public.staff_school_assignments set status = 'ended', effective_to = '2026-12-31' where staff_id = 'e1000000-0000-0000-0000-000000000001';
select pg_temp.run('after_end.sa_read',  'sa', $q$select count(*)::text from public.staff_specialties$q$);
select pg_temp.run('after_end.sa_write', 'sa', $q$insert into public.staff_specialties (platform_tenant_id, staff_id, name) values ('10000000-0000-0000-0000-000000000001', 'e1000000-0000-0000-0000-000000000001', 'Late') returning 'ok'$q$);

select plan(4 + 12 + 4 + 9 + 6 + 4 + 4 + 9 + 1 + 2);

-- البنية
select ok((select bool_and(relrowsecurity and relforcerowsecurity) from pg_class where oid in ('public.staff_specialties'::regclass, 'public.staff_qualifications'::regclass)),
          'RLS enabled and forced on both tables');
select is((select string_agg(tablename || '.' || cmd, ',' order by tablename, cmd) from pg_policies where schemaname = 'public' and tablename in ('staff_specialties', 'staff_qualifications')),
          'staff_qualifications.INSERT,staff_qualifications.SELECT,staff_qualifications.UPDATE,staff_specialties.INSERT,staff_specialties.SELECT,staff_specialties.UPDATE',
          'three policies per table — no DELETE, no ALL');
select is((select count(*)::int from pg_policies where schemaname = 'public' and tablename in ('staff_specialties', 'staff_qualifications')
            and (qual ~ 'staff_in_scope\(staff_id\)' or with_check ~ 'staff_in_scope\(staff_id\)')), 6,
          'every policy evaluates the relationship (staff_in_scope), not the tenant alone');
select is((select count(*)::int from pg_policies where schemaname = 'public' and tablename in ('staff_specialties', 'staff_qualifications')
            and coalesce(qual, '') || coalesce(with_check, '') ~ '(staff_school_assignments|memberships)'), 0,
          'no policy queries a relationship table directly (§1.1 rule 6)');

-- القراءة بالعلاقة
select is((select v from r where k = 'spec.sa'),  'Math',          'school admin SA sees the specialties of SA staff only (not SB, not ended, not T2)');
select is((select v from r where k = 'qual.sa'),  'Math',          'school admin SA sees the qualifications of SA staff only');
select is((select v from r where k = 'spec.sb'),  'Physics',       'school admin SB (same tenant) sees SB staff only — tenant match is not enough');
select is((select v from r where k = 'qual.sb'),  'Physics',       'school admin SB sees SB qualifications only');
select is((select v from r where k = 'spec.tch'), 'Math',          'teacher (staff.read — PD1) sees SA staff only');
select is((select v from r where k = 'qual.tch'), 'Math',          'teacher sees SA qualifications only');
select is((select v from r where k = 'spec.sec'), '',              'secretary without staff.read sees nothing');
select is((select v from r where k = 'qual.sec'), '',              'secretary without staff.read sees no qualifications');
select is((select v from r where k = 'spec.ta'),  'Math,Physics',  'tenant admin sees staff with an active assignment in any school — the ended one stays hidden (H2)');
select is((select v from r where k = 'qual.ta'),  'Math,Physics',  'tenant admin: qualifications follow the same relationship');
select is((select v from r where k = 'spec.x'),   'Biology',       'T2 admin sees T2 only');
select is((select v from r where k = 'qual.x'),   'Biology',       'T2 admin sees T2 qualifications only');

-- الكتابة المسموحة
select is((select v from r where k = 'w.sa_insert'),  'ok',          'school admin adds a specialty to SA staff');
select is((select v from r where k = 'w.sa_qual'),    'ok',          'school admin adds a qualification to SA staff');
select is((select v from r where k = 'w.sa_disable'),  'inactive',    'school admin disables a specialty (no delete)');
select is((select v from r where k = 'w.sa_qual_fix'), 'Mathematics', 'school admin corrects a qualification');

-- الكتابة المرفوضة — العلاقة والمفتاح
select ok((select v from r where k = 'w.sa_other_school') like 'ERR 42501%row-level security%staff_specialties%', 'SA cannot write for SB staff (same tenant)');
select ok((select v from r where k = 'w.sa_ended')        like 'ERR 42501%row-level security%staff_specialties%', 'SA cannot write for staff whose assignment ended (H2)');
select ok((select v from r where k = 'w.sa_cross_tenant') like 'ERR 42501%row-level security%staff_specialties%', 'SA cannot write into another tenant');
select ok((select v from r where k = 'w.sa_mixed_tenant') like 'ERR 42501%row-level security%staff_specialties%', 'SA cannot attach a row to another tenant''s staff');
select ok((select v from r where k = 'w.tch_insert')      like 'ERR 42501%row-level security%staff_specialties%', 'teacher (no staff.update) cannot add a specialty');
select ok((select v from r where k = 'w.tch_qual')        like 'ERR 42501%row-level security%staff_qualifications%', 'teacher cannot add a qualification');
select is((select v from r where k = 'w.tch_qual_upd'), '<null>', 'teacher (staff.read only) updates no qualification — targeted update reaches no row');
select ok((select v from r where k = 'w.sec_insert')      like 'ERR 42501%row-level security%staff_specialties%', 'secretary cannot add a specialty');
select is((select v from r where k = 'after_end.sa_write') like 'ERR 42501%row-level security%staff_specialties%', true, 'after the assignment ends SA can no longer write');

-- الأعمدة
select ok((select v from r where k = 'w.status_insert') like 'ERR 42501%permission denied%staff_specialties%',    'a row cannot be inserted with a chosen status (born active)');
select ok((select v from r where k = 'w.move_staff')    like 'ERR 42501%permission denied%staff_specialties%',    'staff_id is not updatable');
select ok((select v from r where k = 'w.move_tenant')   like 'ERR 42501%permission denied%staff_qualifications%', 'platform_tenant_id is not updatable');
select ok((select v from r where k = 'w.delete_spec')   like 'ERR 42501%permission denied%staff_specialties%',    'no DELETE on specialties');
select ok((select v from r where k = 'w.delete_qual')   like 'ERR 42501%permission denied%staff_qualifications%', 'no DELETE on qualifications');
select is((select count(*)::int from public.staff_specialties where id = '51000000-0000-0000-0000-000000000001'), 1, 'the specialty still exists');

-- UPDATE الأعمى
select ok((select string_agg(v, ',' order by k) from r where k like 'w.blind%') = 'done,done,done,done', 'the four blind updates executed (no error masks them)');
select is((select string_agg(staff_id::text, ',') from public.staff_specialties where name = 'Hacked'), 'e2000000-0000-0000-0000-000000000002',
          'blind updates by SB and the teacher changed only SB''s own staff row — none of SA, the ended staff or T2');
select is((select count(*)::int from public.staff_qualifications where field = 'Hacked' and platform_tenant_id = '10000000-0000-0000-0000-000000000001'), 0,
          'blind updates by the teacher and the T2 admin changed no T1 qualification');
select is((select field from public.staff_qualifications where id = '94000000-0000-0000-0000-000000000004'), 'Hacked',
          'control: the blind update did reach the T2 admin''s own row');

-- التدقيق (T7) والختم (T6)
select is((select count(*)::int from public.audit_log where entity_type = 'staff_specialties' and action = 'insert' and actor_type = 'tenant_user'
            and platform_tenant_id = '10000000-0000-0000-0000-000000000001'), 1, 'T7: the specialty insert by SA is audited as a tenant user');
select is((select count(*)::int from public.audit_log where entity_type = 'staff_qualifications' and action = 'update'
            and entity_id = '91000000-0000-0000-0000-000000000001'), 1, 'T7: the qualification correction is audited');
select ok((select created_by is not null from public.staff_specialties where name = 'Statistics'), 'T6: created_by stamped from the actor');
select is((select new_values->>'status' from public.audit_log where entity_type = 'staff_specialties' and action = 'update'
            and entity_id = '51000000-0000-0000-0000-000000000001' order by id desc limit 1), 'inactive', 'T7: the disable is audited with its new value');

-- القيود بأسمائها
select ok((select v from r where k = 'c.dup')    like 'ERR 23505%staff_specialties_name_uq%',         'duplicate specialty for the same staff → staff_specialties_name_uq');
select ok((select v from r where k = 'c.blank')  like 'ERR 23514%staff_specialties_name_chk%',        'blank specialty → staff_specialties_name_chk');
select ok((select v from r where k = 'c.padded') like 'ERR 23514%staff_specialties_name_chk%',        'untrimmed specialty → staff_specialties_name_chk');
select ok((select v from r where k = 'c.tenant') like 'ERR 23503%staff_specialties_staff_fk%',        'staff of another tenant → staff_specialties_staff_fk (§0.6)');
select ok((select v from r where k = 'c.degree') like 'ERR 23514%staff_qualifications_degree_chk%',   'unknown degree → staff_qualifications_degree_chk');
select ok((select v from r where k = 'c.year')   like 'ERR 23514%staff_qualifications_year_chk%',     'graduation year 1800 → staff_qualifications_year_chk');
select ok((select v from r where k = 'c.field')  like 'ERR 23514%staff_qualifications_field_chk%',    'empty field → staff_qualifications_field_chk');
select ok((select v from r where k = 'c.qstaff') like 'ERR 23503%staff_qualifications_staff_fk%',     'qualification for another tenant''s staff → staff_qualifications_staff_fk');
select ok((select v from r where k = 'c.status') like 'ERR 23514%staff_qualifications_status_chk%',   'unknown status → staff_qualifications_status_chk');

-- انتهاء التكليف
select is((select v from r where k = 'after_end.sa_read'), '0', 'after the assignment ends SA sees none of the staff member''s rows');

-- PD1: لا عمود شخصي جديد تحت staff.read
select is((select string_agg(column_name::text, ',' order by column_name) from information_schema.columns
            where table_schema = 'public' and table_name in ('staff_specialties', 'staff_qualifications')
              and column_name::text in ('national_id', 'birth_date', 'phone_e164', 'email', 'address', 'gender')), null,
          'PD1: the new tables carry no personal column');
select is((select string_agg(column_name::text, ',' order by column_name) from information_schema.columns
            where table_schema = 'public' and table_name = 'staff'),
          'archived_at,birth_date,created_at,created_by,email,employee_code,failed_login_count,family_name,father_name,first_name,full_name,gender,grandfather_name,hire_date,id,last_login_at,locked_until,national_id,phone_e164,platform_tenant_id,profile_id,status,updated_at,updated_by',
          'PD1: staff gained no column in Phase 3');

select * from finish();
rollback;
