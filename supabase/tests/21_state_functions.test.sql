-- M21 — state_functions: الدوال المتحكَّم بها للانتقالات (§5.0.2، §5.3 + قرارات M17b، M19، 2026-09-25)
-- لكل دالة: الصلاحية (42501)، النطاق/عدم الكشف (P0002)، الانتقال الصريح (22023)، invariants (23514)، النجاح،
-- التدقيق (action + reason)، وإعادة سياق التدقيق فارغاً بعد الكتابة.
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

create temp table ids (label text primary key, auth uuid, profile uuid, membership uuid) on commit drop;
create temp table ent (kind text, label text, id uuid, primary key (kind, label)) on commit drop;
grant all on ids, ent to public;

create function pg_temp.run(p_key text, p_label text, p_sql text) returns void
language plpgsql as $$
declare v_sub uuid := (select auth from ids where label = p_label);
begin
  perform set_config('request.jwt.claims', json_build_object('sub', v_sub, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', coalesce(v_sub::text, ''), true);
  execute 'set local role authenticated';
  perform pg_temp.rec(p_key, p_sql);
  -- سياق التدقيق بعد الاستدعاء (يجب أن يكون فارغاً — متطلب M11)
  insert into r values (p_key || '#ctx', coalesce(current_setting('app.audit_action', true), '') || '|' || coalesce(current_setting('app.audit_reason', true), ''))
    on conflict (k) do update set v = excluded.v;
  execute 'reset role';
end $$;

create function pg_temp.eid(p_kind text, p_label text) returns uuid language sql as $$ select id from ent where kind = p_kind and label = p_label $$;
create function pg_temp.sid(p_code text) returns uuid language sql as $$ select id from public.schools where school_code = p_code $$;

-- ============ Fixture: البنية ============
insert into public.platform_tenants (id, tenant_code, name) values
  ('10000000-0000-0000-0000-000000000001', 'T1', 'T1'), ('20000000-0000-0000-0000-000000000002', 'T2', 'T2');
insert into public.groups (id, platform_tenant_id, group_code, name) values
  ('a1000000-0000-0000-0000-00000000000a', '10000000-0000-0000-0000-000000000001', 'GA', 'GA'),
  ('a2000000-0000-0000-0000-00000000000b', '10000000-0000-0000-0000-000000000001', 'GB', 'GB'),
  ('a3000000-0000-0000-0000-00000000000e', '10000000-0000-0000-0000-000000000001', 'GE', 'GE');   -- فارغة
insert into public.schools (id, platform_tenant_id, group_id, school_code, name, slug) values
  ('5a100000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', 'a1000000-0000-0000-0000-00000000000a', 'SA1', 'SA1', 'sa1'),
  ('5a200000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001', 'a1000000-0000-0000-0000-00000000000a', 'SA2', 'SA2', 'sa2'),
  ('5b100000-0000-0000-0000-000000000003', '10000000-0000-0000-0000-000000000001', 'a2000000-0000-0000-0000-00000000000b', 'SB1', 'SB1', 'sb1'),
  ('55000000-0000-0000-0000-000000000004', '10000000-0000-0000-0000-000000000001', null,                                   'SS',  'SS',  'ss');

-- لكل مدرسة: سنة 2026/2027 نشطة + 2027/2028 مخططة، صف، شعبة لكل سنة
create temp table ctx (code text, yr text, year uuid, sec uuid, primary key (code, yr)) on commit drop;
grant select on ctx to public;
do $$
declare s record; v_stage uuid; v_grade uuid; v_y1 uuid; v_y2 uuid;
begin
  for s in select id, school_code from public.schools loop
    insert into public.academic_years (school_id, name, start_date, end_date, status) values (s.id, '2026/2027', '2026-09-01', '2027-06-30', 'active') returning id into v_y1;
    insert into public.academic_years (school_id, name, start_date, end_date) values (s.id, '2027/2028', '2027-09-01', '2028-06-30') returning id into v_y2;
    insert into public.stages (school_id, name, sequence_no) values (s.id, 'P', 1) returning id into v_stage;
    insert into public.grade_levels (school_id, stage_id, name, sequence_no) values (s.id, v_stage, 'G1', 1) returning id into v_grade;
    with x as (insert into public.sections (school_id, academic_year_id, grade_level_id, name) values (s.id, v_y1, v_grade, 'A') returning id)
      insert into ctx select s.school_code, 'y1', v_y1, id from x;
    with x as (insert into public.sections (school_id, academic_year_id, grade_level_id, name) values (s.id, v_y2, v_grade, 'A') returning id)
      insert into ctx select s.school_code, 'y2', v_y2, id from x;
  end loop;
end $$;

-- ============ الصلاحيات والأدوار ============
insert into public.permissions (code, resource, operation, description)
  select c, split_part(c, '.', 1), split_part(c, '.', 2), 'test' from unnest(array[
    'tenant.suspend','group.archive','school.archive','membership.end','student.archive',
    'staff.update','staff.archive','staff.assign','guardian.update','guardian.unlink',
    'academic_year.activate','academic_year.close','enrollment.archive','enrollment.transfer',
    'role.update','fee.read']) c on conflict (code) do nothing;
insert into public.roles (id, platform_tenant_id, code, name, is_system) values
  ('71000000-0000-0000-0000-000000000001', null, 'tadmin', 'TA', true),
  ('72000000-0000-0000-0000-000000000002', null, 'sadmin', 'SA', true);
insert into public.role_permissions (role_id, permission_id)
  select '71000000-0000-0000-0000-000000000001'::uuid, id from public.permissions where code not in ('tenant.suspend','fee.read')
  union all
  select '72000000-0000-0000-0000-000000000002'::uuid, id from public.permissions where code in
    ('membership.end','student.archive','staff.update','staff.archive','staff.assign','guardian.update','guardian.unlink',
     'academic_year.activate','academic_year.close','enrollment.archive','enrollment.transfer');
-- أدوار مخصصة معطّلة لاختبار M19: c_ok (⊆ tadmin)، c_bad (fee.read)
insert into public.roles (id, platform_tenant_id, code, name, status) values
  ('7c100000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', 'c_ok',  'OK',  'inactive'),
  ('7c200000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001', 'c_bad', 'Bad', 'inactive');
insert into public.role_permissions values
  ('7c100000-0000-0000-0000-000000000001', (select id from public.permissions where code = 'student.archive')),
  ('7c200000-0000-0000-0000-000000000002', (select id from public.permissions where code = 'fee.read'));

create function pg_temp.person(p_label text, p_tenant uuid default '10000000-0000-0000-0000-000000000001') returns uuid
language plpgsql as $$
declare v_auth uuid := gen_random_uuid(); v_profile uuid;
begin
  insert into auth.users (id, email) values (v_auth, p_label || '@m21.invalid');
  insert into public.auth_identities values (v_auth, 'tenant');
  insert into public.profiles (platform_tenant_id, auth_user_id, display_name) values (p_tenant, v_auth, p_label) returning id into v_profile;
  insert into ids (label, auth, profile) values (p_label, v_auth, v_profile);
  return v_profile;
end $$;
create function pg_temp.member(p_label text, p_role uuid, p_scope text) returns void
language plpgsql as $$
declare v_m uuid; v_p uuid := coalesce((select profile from ids where label = p_label), pg_temp.person(p_label));
begin
  insert into public.memberships (platform_tenant_id, profile_id) values ('10000000-0000-0000-0000-000000000001', v_p) returning id into v_m;
  update ids set membership = v_m where label = p_label;
  if p_role is not null then
    insert into public.membership_roles (membership_id, role_id, platform_tenant_id, role_owner_key) values (v_m, p_role, '10000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000000');
  end if;
  if p_scope = 'tenant' then
    insert into public.membership_scopes (membership_id, platform_tenant_id, scope_type) values (v_m, '10000000-0000-0000-0000-000000000001', 'tenant');
  elsif p_scope like 'G%' then
    insert into public.membership_scopes (membership_id, platform_tenant_id, scope_type, group_id) values (v_m, '10000000-0000-0000-0000-000000000001', 'group', (select id from public.groups where group_code = p_scope));
  elsif p_scope is not null then
    insert into public.membership_scopes (membership_id, platform_tenant_id, scope_type, school_id) values (v_m, '10000000-0000-0000-0000-000000000001', 'school', pg_temp.sid(p_scope));
  end if;
end $$;

select pg_temp.member('ta',    '71000000-0000-0000-0000-000000000001', 'tenant');
select pg_temp.member('gm',    '72000000-0000-0000-0000-000000000002', 'GA');
select pg_temp.member('sa1',   '72000000-0000-0000-0000-000000000002', 'SA1');
select pg_temp.member('sb1',   '72000000-0000-0000-0000-000000000002', 'SB1');
select pg_temp.member('nop',   null,                                   'SA1');
select pg_temp.member('fresh', null,                                   'SA1');    -- هدف end_membership

-- Platform Admins: pa (tenant.suspend)، pa0 (بلا صلاحيات)
insert into public.platform_admin_roles (id, code, name) values ('81000000-0000-0000-0000-000000000001', 'ops', 'Ops'), ('82000000-0000-0000-0000-000000000002', 'none', 'None');
insert into public.platform_admin_role_permissions values ('81000000-0000-0000-0000-000000000001', (select id from public.permissions where code = 'tenant.suspend'));
do $$
declare l text; v_auth uuid; v_su uuid;
begin
  foreach l in array array['pa','pa0'] loop
    v_auth := gen_random_uuid();
    insert into auth.users (id, email) values (v_auth, l || '@m21.invalid');
    insert into public.auth_identities values (v_auth, 'platform');
    insert into public.system_users (auth_user_id, display_name) values (v_auth, l) returning id into v_su;
    insert into public.platform_admin_assignments (system_user_id, platform_admin_role_id)
      values (v_su, case l when 'pa' then '81000000-0000-0000-0000-000000000001'::uuid else '82000000-0000-0000-0000-000000000002'::uuid end);
    insert into ids (label, auth) values (l, v_auth);
  end loop;
end $$;

-- ============ الطلاب والتسجيلات (نطاق GA) ============
-- s1 SA1 نشط (رقم قيد R1) — s2 SA1 نشط — s3 SA1 نشط (للنقل) — s4 SA1 مكتمل — sd SA2 نشط برقم قيد DUP
create function pg_temp.enroll(p_student uuid, p_code text, p_yr text, p_status text, p_from date, p_to date, p_no text default null) returns uuid
language sql as $$
  insert into public.enrollments (school_id, student_id, platform_tenant_id, academic_year_id, grade_level_id, section_id, identity_scope_id, scope_owner_id, enrollment_no, status, effective_from, effective_to)
  select sc.id, st.id, st.platform_tenant_id, c.year, sec.grade_level_id, c.sec, st.identity_scope_id, sc.scope_owner_id, p_no, p_status, p_from, p_to
  from ctx c join public.schools sc on sc.school_code = c.code join public.sections sec on sec.id = c.sec, public.students st
  where c.code = p_code and c.yr = p_yr and st.id = p_student
  returning id $$;
do $$
declare l text; v uuid;
begin
  foreach l in array array['s1','s2','s3','s4','sd'] loop
    insert into public.students (platform_tenant_id, identity_scope_id, student_profile_id, official_id, official_id_type, first_name, family_name)
      values ('10000000-0000-0000-0000-000000000001', (select id from public.identity_scopes where group_id = 'a1000000-0000-0000-0000-00000000000a'),
              pg_temp.person(l), 'N-' || l, 'national_id', l, l) returning id into v;
    insert into ent values ('student', l, v);
  end loop;
  insert into ent values ('enr', 's1', pg_temp.enroll(pg_temp.eid('student','s1'), 'SA1', 'y1', 'active', '2026-09-01', null, 'R1'));
  insert into ent values ('enr', 's2', pg_temp.enroll(pg_temp.eid('student','s2'), 'SA1', 'y1', 'active', '2026-09-01', null));
  insert into ent values ('enr', 's3', pg_temp.enroll(pg_temp.eid('student','s3'), 'SA1', 'y1', 'active', '2026-09-01', null));
  insert into ent values ('enr', 's4', pg_temp.enroll(pg_temp.eid('student','s4'), 'SA1', 'y1', 'completed', '2026-09-01', '2027-06-30'));
  insert into ent values ('enr', 'sd', pg_temp.enroll(pg_temp.eid('student','sd'), 'SA2', 'y1', 'active', '2026-09-01', null, 'DUP'));
end $$;

-- أولياء الأمور: g1 و g2 مرتبطان بـs1
do $$
declare l text; v uuid; v_l uuid;
begin
  foreach l in array array['g1','g2'] loop
    insert into public.guardians (platform_tenant_id, first_name, family_name, phone_e164)
      values ('10000000-0000-0000-0000-000000000001', l, l, case l when 'g1' then '+201000000001' else '+201000000002' end) returning id into v;
    insert into ent values ('guardian', l, v);
    insert into public.student_guardians (student_id, guardian_id, platform_tenant_id, relationship_type, effective_from)
      values (pg_temp.eid('student','s1'), v, '10000000-0000-0000-0000-000000000001', 'father', '2026-01-01') returning id into v_l;
    insert into ent values ('link', l, v_l);
  end loop;
end $$;

-- الموظفون: f1 (SA1)، f2 (SA1)، f3 (SA1 + SB1)
do $$
declare l text; v uuid; v_a uuid;
begin
  foreach l in array array['f1','f2','f3'] loop
    insert into public.staff (platform_tenant_id, employee_code, first_name, family_name) values ('10000000-0000-0000-0000-000000000001', upper(l), l, l) returning id into v;
    insert into ent values ('staff', l, v);
    insert into public.staff_school_assignments (staff_id, school_id, platform_tenant_id, job_title, effective_from)
      values (v, pg_temp.sid('SA1'), '10000000-0000-0000-0000-000000000001', 'T', '2026-09-01') returning id into v_a;
    insert into ent values ('asg', l, v_a);
  end loop;
  insert into public.staff_school_assignments (staff_id, school_id, platform_tenant_id, job_title, effective_from)
    values (pg_temp.eid('staff','f3'), pg_temp.sid('SB1'), '10000000-0000-0000-0000-000000000001', 'T', '2026-09-01');
end $$;

create function pg_temp.q(p_call text) returns text language sql as $$ select format('select ''ok'' from %s', p_call) $$;
create function pg_temp.yr(p_code text, p_yr text) returns uuid language sql as $$ select year from ctx where code = p_code and yr = p_yr $$;
create function pg_temp.sec(p_code text, p_yr text) returns uuid language sql as $$ select sec from ctx where code = p_code and yr = p_yr $$;

-- ============ Tenant (سياق المنصة) ============
select pg_temp.run('t.pa0',      'pa0', pg_temp.q(format('app.suspend_tenant(%L, %L)', '20000000-0000-0000-0000-000000000002', 'r')));
select pg_temp.run('t.ta',       'ta',  pg_temp.q(format('app.suspend_tenant(%L, %L)', '20000000-0000-0000-0000-000000000002', 'r')));
select pg_temp.run('t.noreason', 'pa',  pg_temp.q(format('app.suspend_tenant(%L, %L)', '20000000-0000-0000-0000-000000000002', ' ')));
select pg_temp.run('t.suspend',  'pa',  pg_temp.q(format('app.suspend_tenant(%L, %L)', '20000000-0000-0000-0000-000000000002', 'billing')));
select pg_temp.run('t.again',    'pa',  pg_temp.q(format('app.suspend_tenant(%L, %L)', '20000000-0000-0000-0000-000000000002', 'r')));
select pg_temp.run('t.react',    'pa',  pg_temp.q(format('app.reactivate_tenant(%L, %L)', '20000000-0000-0000-0000-000000000002', 'paid')));

-- ============ Group / School ============
select pg_temp.run('g.active',   'ta', pg_temp.q(format('app.archive_group(%L, %L)', 'a2000000-0000-0000-0000-00000000000b', 'r')));   -- GB فيها SB1 نشطة
select pg_temp.run('g.gm_GB',    'gm', pg_temp.q(format('app.archive_group(%L, %L)', 'a2000000-0000-0000-0000-00000000000b', 'r')));
select pg_temp.run('g.empty',    'ta', pg_temp.q(format('app.archive_group(%L, %L)', 'a3000000-0000-0000-0000-00000000000e', 'merged')));
select pg_temp.run('sc.enr',     'ta', pg_temp.q(format('app.archive_school(%L, %L)', pg_temp.sid('SA1'), 'r')));
select pg_temp.run('sc.staff',   'ta', pg_temp.q(format('app.archive_school(%L, %L)', pg_temp.sid('SB1'), 'r')));   -- f3 نشط فيها
select pg_temp.run('sc.sa1',     'sa1',pg_temp.q(format('app.archive_school(%L, %L)', pg_temp.sid('SA1'), 'r')));   -- بلا school.archive

-- ============ Academic year (SS: بلا تسجيلات) ============
select pg_temp.run('y.act_busy', 'ta', pg_temp.q(format('app.activate_academic_year(%L, %L)', pg_temp.yr('SA1','y2'), 'r')));   -- y1 نشطة
select pg_temp.run('y.close_busy','sa1',pg_temp.q(format('app.close_academic_year(%L, %L)', pg_temp.yr('SA1','y1'), 'r')));    -- تسجيلات نشطة
select pg_temp.run('y.close_SS', 'ta', pg_temp.q(format('app.close_academic_year(%L, %L)', pg_temp.yr('SS','y1'), 'year end')));
select pg_temp.run('y.act_SS',   'ta', pg_temp.q(format('app.activate_academic_year(%L, %L)', pg_temp.yr('SS','y2'), 'new year')));
select pg_temp.run('y.reclose',  'ta', pg_temp.q(format('app.activate_academic_year(%L, %L)', pg_temp.yr('SS','y1'), 'r')));    -- closed → active
select pg_temp.run('y.sb1',      'sb1',pg_temp.q(format('app.close_academic_year(%L, %L)', pg_temp.yr('SA1','y1'), 'r')));
select pg_temp.run('sc.SS',      'ta', pg_temp.q(format('app.archive_school(%L, %L)', pg_temp.sid('SS'), 'closed down')));

-- ============ Membership ============
select pg_temp.run('m.fresh',    'sa1', pg_temp.q(format('app.end_membership(%L, %L)', (select membership from ids where label = 'fresh'), 'left')));
select pg_temp.run('m.again',    'sa1', pg_temp.q(format('app.end_membership(%L, %L)', (select membership from ids where label = 'fresh'), 'r')));
select pg_temp.run('m.self',     'sa1', pg_temp.q(format('app.end_membership(%L, %L)', (select membership from ids where label = 'sa1'), 'r')));
select pg_temp.run('m.gm',       'sa1', pg_temp.q(format('app.end_membership(%L, %L)', (select membership from ids where label = 'gm'), 'r')));
select pg_temp.run('m.nop',      'nop', pg_temp.q(format('app.end_membership(%L, %L)', (select membership from ids where label = 'fresh'), 'r')));

-- ============ Enrollment: close ============
select pg_temp.run('e.transferred', 'sa1', pg_temp.q(format('app.close_enrollment(%L, %L, %L, %L)', pg_temp.eid('enr','s2'), 'transferred', '2027-01-01', 'r')));
select pg_temp.run('e.baddate',     'sa1', pg_temp.q(format('app.close_enrollment(%L, %L, %L, %L)', pg_temp.eid('enr','s2'), 'completed', '2026-09-01', 'r')));
select pg_temp.run('e.sb1',         'sb1', pg_temp.q(format('app.close_enrollment(%L, %L, %L, %L)', pg_temp.eid('enr','s2'), 'completed', '2027-06-30', 'r')));
select pg_temp.run('e.complete',    'sa1', pg_temp.q(format('app.close_enrollment(%L, %L, %L, %L)', pg_temp.eid('enr','s2'), 'completed', '2027-06-30', 'year end')));
select pg_temp.run('e.again',       'sa1', pg_temp.q(format('app.close_enrollment(%L, %L, %L, %L)', pg_temp.eid('enr','s2'), 'withdrawn', '2027-06-30', 'r')));

-- ============ Enrollment: transfer (ذري) ============
select pg_temp.run('x.sa1',      'sa1', format($q$select app.transfer_enrollment(%L, %L, '2026-12-01', 'move')::text$q$, pg_temp.eid('enr','s3'), pg_temp.sec('SA2','y1')));  -- SA2 خارج نطاقه
select pg_temp.run('x.same',     'gm',  format($q$select app.transfer_enrollment(%L, %L, '2026-12-01', 'move')::text$q$, pg_temp.eid('enr','s3'), pg_temp.sec('SA1','y1')));
select pg_temp.run('x.group',    'ta',  format($q$select app.transfer_enrollment(%L, %L, '2026-12-01', 'move')::text$q$, pg_temp.eid('enr','s3'), pg_temp.sec('SB1','y1')));
select pg_temp.run('x.closed',   'gm',  format($q$select app.transfer_enrollment(%L, %L, '2027-09-01', 'move')::text$q$, pg_temp.eid('enr','s4'), pg_temp.sec('SA2','y2')));
select pg_temp.run('x.baddate',  'gm',  format($q$select app.transfer_enrollment(%L, %L, '2026-09-01', 'move')::text$q$, pg_temp.eid('enr','s3'), pg_temp.sec('SA2','y1')));
-- فشل في منتصف العملية (رقم قيد مكرر في المدرسة الهدف بعد إغلاق القديم) → لا شيء يتغير
select pg_temp.run('x.midfail',  'gm',  format($q$select app.transfer_enrollment(%L, %L, '2026-12-01', 'move', 'DUP')::text$q$, pg_temp.eid('enr','s1'), pg_temp.sec('SA2','y1')));
select pg_temp.rec('x.midfail_state', format($q$select status || ':' || coalesce(effective_to::text, '-') || ':' || (select count(*) from public.enrollments where student_id = %L) from public.enrollments where id = %L$q$,
                                             pg_temp.eid('student','s1'), pg_temp.eid('enr','s1')));
select pg_temp.run('x.ok',       'gm',  format($q$select case when app.transfer_enrollment(%L, %L, '2026-12-01', 'moved to SA2') is not null then 'ok' end$q$, pg_temp.eid('enr','s3'), pg_temp.sec('SA2','y1')));
select pg_temp.rec('x.state', format($q$select string_agg(sc.school_code || ':' || e.status || ':' || e.effective_from || ':' || coalesce(e.effective_to::text, '-'), ',' order by e.effective_from)
  from public.enrollments e join public.schools sc on sc.id = e.school_id where e.student_id = %L$q$, pg_temp.eid('student','s3')));
-- H2 بعد النقل: SA1 لم تعد المدرسة التشغيلية
select pg_temp.run('x.h2_sa1',   'sa1', format($q$select app.student_in_scope(%L)::text$q$, pg_temp.eid('student','s3')));
select pg_temp.run('x.old_close','sa1', pg_temp.q(format('app.close_enrollment(%L, %L, %L, %L)', pg_temp.eid('enr','s3'), 'withdrawn', '2027-01-01', 'r')));

-- ============ Student ============
select pg_temp.run('s.active',   'sa1', pg_temp.q(format('app.archive_student(%L, %L)', pg_temp.eid('student','s1'), 'r')));
select pg_temp.run('s.sb1',      'sb1', pg_temp.q(format('app.archive_student(%L, %L)', pg_temp.eid('student','s4'), 'r')));
select pg_temp.run('s.nop',      'nop', pg_temp.q(format('app.archive_student(%L, %L)', pg_temp.eid('student','s4'), 'r')));
select pg_temp.run('s.ok',       'sa1', pg_temp.q(format('app.archive_student(%L, %L)', pg_temp.eid('student','s4'), 'graduated')));
select pg_temp.run('s.again',    'sa1', pg_temp.q(format('app.archive_student(%L, %L)', pg_temp.eid('student','s4'), 'r')));

-- ============ Guardian ============
select pg_temp.run('gd.archive', 'sa1', pg_temp.q(format('app.archive_guardian(%L, %L)', pg_temp.eid('guardian','g2'), 'deceased')));
select pg_temp.run('gd.again',   'sa1', pg_temp.q(format('app.archive_guardian(%L, %L)', pg_temp.eid('guardian','g2'), 'r')));
select pg_temp.run('gd.sb1',     'sb1', pg_temp.q(format('app.archive_guardian(%L, %L)', pg_temp.eid('guardian','g1'), 'r')));
select pg_temp.run('ul.baddate', 'sa1', pg_temp.q(format('app.unlink_guardian(%L, %L, %L)', pg_temp.eid('link','g1'), '2025-01-01', 'r')));
select pg_temp.run('ul.ok',      'sa1', pg_temp.q(format('app.unlink_guardian(%L, %L, %L)', pg_temp.eid('link','g1'), '2027-01-01', 'custody')));
select pg_temp.run('ul.again',   'sa1', pg_temp.q(format('app.unlink_guardian(%L, %L, %L)', pg_temp.eid('link','g1'), '2027-02-01', 'r')));

-- ============ Staff ============
select pg_temp.run('a.sb1',      'sb1', pg_temp.q(format('app.end_staff_assignment(%L, %L, %L)', pg_temp.eid('asg','f1'), '2027-01-01', 'r')));
select pg_temp.run('a.ok',       'sa1', pg_temp.q(format('app.end_staff_assignment(%L, %L, %L)', pg_temp.eid('asg','f1'), '2027-01-01', 'resigned')));
select pg_temp.run('a.again',    'sa1', pg_temp.q(format('app.end_staff_assignment(%L, %L, %L)', pg_temp.eid('asg','f1'), '2027-02-01', 'r')));
select pg_temp.run('f.leave',    'sa1', pg_temp.q(format('app.set_staff_status(%L, %L, %L)', pg_temp.eid('staff','f2'), 'on_leave', 'maternity')));
select pg_temp.run('f.back',     'sa1', pg_temp.q(format('app.set_staff_status(%L, %L, %L)', pg_temp.eid('staff','f2'), 'active', 'returned')));
select pg_temp.run('f.skip',     'sa1', pg_temp.q(format('app.set_staff_status(%L, %L, %L)', pg_temp.eid('staff','f2'), 'archived', 'r')));
select pg_temp.run('f.end_f3',   'sa1', pg_temp.q(format('app.set_staff_status(%L, %L, %L, %L)', pg_temp.eid('staff','f3'), 'ended', 'r', '2027-01-01')));
select pg_temp.run('f.end',      'sa1', pg_temp.q(format('app.set_staff_status(%L, %L, %L, %L)', pg_temp.eid('staff','f2'), 'ended', 'contract end', '2027-01-01')));
select pg_temp.rec('f.end_asg',  format($q$select string_agg(status || ':' || coalesce(effective_to::text, '-'), ',') from public.staff_school_assignments where staff_id = %L$q$, pg_temp.eid('staff','f2')));
select pg_temp.run('f.arch_sa1', 'sa1', pg_temp.q(format('app.set_staff_status(%L, %L, %L)', pg_temp.eid('staff','f2'), 'archived', 'r')));
select pg_temp.run('f.arch_ta',  'ta',  pg_temp.q(format('app.set_staff_status(%L, %L, %L)', pg_temp.eid('staff','f2'), 'archived', 'records')));
select pg_temp.run('f.revive',   'ta',  pg_temp.q(format('app.set_staff_status(%L, %L, %L)', pg_temp.eid('staff','f2'), 'active', 'r')));

-- ============ Role (M19) ============
select pg_temp.run('ro.sa1',     'sa1', pg_temp.q(format('app.set_role_status(%L, %L, %L)', '7c100000-0000-0000-0000-000000000001', 'active', 'r')));
select pg_temp.run('ro.bad',     'ta',  pg_temp.q(format('app.set_role_status(%L, %L, %L)', '7c200000-0000-0000-0000-000000000002', 'active', 'r')));
select pg_temp.run('ro.sys',     'ta',  pg_temp.q(format('app.set_role_status(%L, %L, %L)', '72000000-0000-0000-0000-000000000002', 'inactive', 'r')));
select pg_temp.run('ro.ok',      'ta',  pg_temp.q(format('app.set_role_status(%L, %L, %L)', '7c100000-0000-0000-0000-000000000001', 'active', 'needed')));
select pg_temp.run('ro.same',    'ta',  pg_temp.q(format('app.set_role_status(%L, %L, %L)', '7c100000-0000-0000-0000-000000000001', 'active', 'r')));
select pg_temp.run('ro.off',     'ta',  pg_temp.q(format('app.set_role_status(%L, %L, %L)', '7c100000-0000-0000-0000-000000000001', 'inactive', 'unused')));

-- ============ التدقيق ============
create function pg_temp.audit(p_entity text, p_id uuid) returns text language sql as $$
  select string_agg(action || '/' || coalesce(reason, '-'), ',' order by id) from public.audit_log
  where entity_type = p_entity and entity_id = p_id::text and action <> 'insert' $$;
select pg_temp.rec('au.tenant',  format('select pg_temp.audit(%L, %L)', 'platform_tenants', '20000000-0000-0000-0000-000000000002'));
select pg_temp.rec('au.enr_s3',  format('select pg_temp.audit(%L, %L)', 'enrollments', pg_temp.eid('enr','s3')));
select pg_temp.rec('au.new_s3',  format($q$select action || '/' || coalesce(reason, '-') from public.audit_log where entity_type = 'enrollments' and action = 'insert'
  and entity_id = (select id::text from public.enrollments where student_id = %L and status = 'active')$q$, pg_temp.eid('student','s3')));
select pg_temp.rec('au.staff_f2',format('select pg_temp.audit(%L, %L)', 'staff', pg_temp.eid('staff','f2')));
select pg_temp.rec('au.actor',   format($q$select actor_type || ':' || (actor_id = (select profile from ids where label = 'gm'))::text from public.audit_log
  where entity_type = 'enrollments' and entity_id = %L and action = 'transfer'$q$, pg_temp.eid('enr','s3')));
select pg_temp.rec('au.ctx_leak', $q$select count(*)::text from r where k like '%#ctx' and v <> '|'$q$);

-- ============ البنية ============
create temp table fn (f regprocedure) on commit drop;
insert into fn values ('app.suspend_tenant(uuid,text)'), ('app.reactivate_tenant(uuid,text)'), ('app.archive_group(uuid,text)'),
  ('app.archive_school(uuid,text)'), ('app.end_membership(uuid,text)'), ('app.archive_student(uuid,text)'),
  ('app.set_staff_status(uuid,text,text,date)'), ('app.end_staff_assignment(uuid,date,text)'),
  ('app.archive_guardian(uuid,text)'), ('app.unlink_guardian(uuid,date,text)'),
  ('app.activate_academic_year(uuid,text)'), ('app.close_academic_year(uuid,text)'),
  ('app.close_enrollment(uuid,text,date,text)'), ('app.transfer_enrollment(uuid,uuid,date,text,text)'),
  ('app.set_role_status(uuid,text,text)');

select plan(84);

-- ---------- Tenant ----------
select ok((select v from r where k = 't.pa0')      like 'ERR 42501%forbidden%', 'suspend_tenant: platform identity without tenant.suspend → forbidden');
select ok((select v from r where k = 't.ta')       like 'ERR 42501%forbidden%', 'suspend_tenant: a tenant user (tenant context) → forbidden (G10)');
select ok((select v from r where k = 't.noreason') like 'ERR 22023%reason required%', 'reason is mandatory');
select is((select v from r where k = 't.suspend'), 'ok', 'suspend_tenant: platform admin with tenant.suspend');
select ok((select v from r where k = 't.again')    like 'ERR 22023%invalid transition suspended -> suspended%', 'suspend_tenant: explicit transitions only');
select is((select v from r where k = 't.react'),   'ok', 'reactivate_tenant');

-- ---------- Group / School ----------
select ok((select v from r where k = 'g.active')  like 'ERR 23514%invariant: group has active schools%', 'archive_group: a group with active schools is rejected');
select ok((select v from r where k = 'g.gm_GB')   like 'ERR 42501%forbidden%', 'archive_group: without group.archive → forbidden');
select is((select v from r where k = 'g.empty'),  'ok', 'archive_group: an empty group');
select ok((select v from r where k = 'sc.enr')    like 'ERR 23514%invariant: school has active enrollments%', 'archive_school: active enrollments block it');
select ok((select v from r where k = 'sc.staff')  like 'ERR 23514%invariant: school has active staff assignments%', 'archive_school: active assignments block it');
select ok((select v from r where k = 'sc.sa1')    like 'ERR 42501%forbidden%', 'archive_school: school admin lacks school.archive');
select is((select v from r where k = 'sc.SS'),    'ok', 'archive_school: a school with no active enrollment or assignment');

-- ---------- Academic year ----------
select ok((select v from r where k = 'y.act_busy')   like 'ERR 23514%already has an active academic year%', 'activate_academic_year: one active year per school');
select ok((select v from r where k = 'y.close_busy') like 'ERR 23514%the year has active enrollments%', 'close_academic_year: active enrollments block it');
select is((select v from r where k = 'y.close_SS'),  'ok', 'close_academic_year: active → closed');
select is((select v from r where k = 'y.act_SS'),    'ok', 'activate_academic_year: planned → active once the old year is closed');
select ok((select v from r where k = 'y.reclose')    like 'ERR 22023%invalid transition closed -> active%', 'activate_academic_year: a closed year is never reopened');
select ok((select v from r where k = 'y.sb1')        like 'ERR P0002%not found%', 'close_academic_year: another school''s year → not found (non-disclosure)');

-- ---------- Membership ----------
select is((select v from r where k = 'm.fresh'), 'ok', 'end_membership: a managed membership');
select ok((select v from r where k = 'm.again') like 'ERR 22023%invalid transition ended -> ended%', 'end_membership: ended is terminal');
select ok((select v from r where k = 'm.self')  like 'ERR P0002%not found%', 'end_membership: no self-management (F5)');
select ok((select v from r where k = 'm.gm')    like 'ERR P0002%not found%', 'end_membership: not above the actor''s scope (F4)');
select ok((select v from r where k = 'm.nop')   like 'ERR 42501%forbidden%', 'end_membership: without membership.end');

-- ---------- Enrollment close ----------
select ok((select v from r where k = 'e.transferred') like 'ERR 22023%transfer: app.transfer_enrollment%', 'close_enrollment: transferred only through the atomic transfer — no intermediate state');
select ok((select v from r where k = 'e.baddate')     like 'ERR 22023%effective_to must be after effective_from%', 'close_enrollment: B6 half-open period');
select ok((select v from r where k = 'e.sb1')         like 'ERR P0002%not found%', 'close_enrollment: another school → not found');
select is((select v from r where k = 'e.complete'),   'ok', 'close_enrollment: active → completed');
select ok((select v from r where k = 'e.again')       like 'ERR P0002%not found%' or (select v from r where k = 'e.again') like 'ERR 22023%', 'close_enrollment: a closed enrollment cannot be closed again');

-- ---------- Transfer ----------
select ok((select v from r where k = 'x.sa1')      like 'ERR P0002%not found%', 'transfer: the current school alone cannot transfer — it needs scope over the target too (decision 2026-09-25)');
select ok((select v from r where k = 'x.same')     like 'ERR 23514%transfer requires a different school%', 'transfer: same school rejected');
select ok((select v from r where k = 'x.group')    like 'ERR 23514%outside the student''s identity scope%', 'transfer: no automatic transfer outside the group (PLAN §7.10, G3)');
select ok((select v from r where k = 'x.closed')   like 'ERR P0002%not found%' or (select v from r where k = 'x.closed') like 'ERR 22023%', 'transfer: only an active enrollment');
select ok((select v from r where k = 'x.baddate')  like 'ERR 22023%transfer date must be after%', 'transfer: date after the current start');
select ok((select v from r where k = 'x.midfail')  like 'ERR 23505%', 'transfer: a failure after closing the old row (duplicate enrollment_no) aborts the whole operation');
select is((select v from r where k = 'x.midfail_state'), 'active:-:1', 'transfer atomicity: after the mid-operation failure s1 still has exactly one, active, open enrollment');
select is((select v from r where k = 'x.ok'),       'ok', 'transfer: group manager over both schools');
select is((select v from r where k = 'x.state'),    'SA1:transferred:2026-09-01:2026-12-01,SA2:active:2026-12-01:-', 'transfer: old closed at d, new opened from d — no gap, no overlap (B6, G6)');
select is((select v from r where k = 'x.h2_sa1'),   'false', 'H2: after the transfer the old school no longer has operational scope');
select ok((select v from r where k = 'x.old_close') like 'ERR P0002%not found%', 'H2: the old school cannot act on the transferred row afterwards');

-- ---------- Student ----------
select ok((select v from r where k = 's.active') like 'ERR 23514%active enrollment%', 'archive_student: an actively enrolled student cannot be archived');
select ok((select v from r where k = 's.sb1')    like 'ERR P0002%not found%', 'archive_student: another group → not found');
select ok((select v from r where k = 's.nop')    like 'ERR 42501%forbidden%', 'archive_student: without student.archive');
select is((select v from r where k = 's.ok'),    'ok', 'archive_student: year-end completed student (latest enrollment in SA1)');
select ok((select v from r where k = 's.again')  like 'ERR 22023%invalid transition archived -> archived%', 'archive_student: archived is terminal');

-- ---------- Guardian ----------
select is((select v from r where k = 'gd.archive'), 'ok', 'archive_guardian: guardian.update (G8)');
select ok((select v from r where k = 'gd.again')    like 'ERR 22023%invalid transition archived -> archived%', 'archive_guardian: terminal');
select ok((select v from r where k = 'gd.sb1')      like 'ERR P0002%not found%', 'archive_guardian: another group → not found');
select ok((select v from r where k = 'ul.baddate')  like 'ERR 22023%effective_to must be after%', 'unlink_guardian: B6 period');
select is((select v from r where k = 'ul.ok'),      'ok', 'unlink_guardian: active → ended');
select ok((select v from r where k = 'ul.again')    like 'ERR 22023%invalid transition ended -> ended%', 'unlink_guardian: terminal');

-- ---------- Staff ----------
select ok((select v from r where k = 'a.sb1')     like 'ERR P0002%not found%', 'end_staff_assignment: another school''s assignment → not found');
select is((select v from r where k = 'a.ok'),     'ok', 'end_staff_assignment: active → ended');
select ok((select v from r where k = 'a.again')   like 'ERR 22023%invalid transition ended -> ended%', 'end_staff_assignment: no reopening — ended is terminal (decision 2026-09-25)');
select is((select v from r where k = 'f.leave'),  'ok', 'set_staff_status: active → on_leave');
select is((select v from r where k = 'f.back'),   'ok', 'set_staff_status: on_leave → active');
select ok((select v from r where k = 'f.skip')    like 'ERR 22023%invalid transition active -> archived%', 'set_staff_status: archive only from ended');
select ok((select v from r where k = 'f.end_f3')  like 'ERR 23514%active assignments outside the actor''s scope%', 'set_staff_status: cannot end a member still active in a school outside the actor''s scope');
select is((select v from r where k = 'f.end'),    'ok', 'set_staff_status: active → ended');
select is((select v from r where k = 'f.end_asg'),'ended:2027-01-01', 'ending the staff member closes its active assignments in the same operation');
select ok((select v from r where k = 'f.arch_sa1')like 'ERR P0002%not found%', 'H2: with no active assignment the school no longer reaches the ended staff member');
select is((select v from r where k = 'f.arch_ta'),'ok', 'set_staff_status: tenant scope archives the ended staff member');
select ok((select v from r where k = 'f.revive')  like 'ERR 22023%invalid transition archived -> active%', 'set_staff_status: no return from archived (decision 2026-09-25)');

-- ---------- Role (M19) ----------
select ok((select v from r where k = 'ro.sa1')  like 'ERR 42501%forbidden%', 'set_role_status: without role.update');
select ok((select v from r where k = 'ro.bad')  like 'ERR 42501%T8: role status change would affect permissions the actor does not hold: fee.read%', 'M19: activating a role with a permission the actor lacks is rejected');
select ok((select v from r where k = 'ro.sys')  like 'ERR P0002%not found%', 'set_role_status: system roles are out of reach');
select is((select v from r where k = 'ro.ok'),  'ok', 'set_role_status: inactive → active within the actor''s permissions');
select ok((select v from r where k = 'ro.same') like 'ERR 22023%invalid transition active -> active%', 'set_role_status: explicit transitions only');
select is((select v from r where k = 'ro.off'), 'ok', 'set_role_status: active → inactive');

-- ---------- التدقيق ----------
select is((select v from r where k = 'au.tenant'),   'suspend/billing,reactivate/paid', 'audit: action and reason recorded per transition');
select is((select v from r where k = 'au.enr_s3'),   'transfer/moved to SA2', 'audit: the closed side of the transfer');
select is((select v from r where k = 'au.new_s3'),   'insert/moved to SA2', 'audit: the new enrollment carries the same reason');
select is((select v from r where k = 'au.staff_f2'), 'set_status/maternity,set_status/returned,end/contract end,archive/records', 'audit: every staff transition with its reason');
select is((select v from r where k = 'au.actor'),    'tenant_user:true', 'audit: the actor is the caller (auth.uid()), not a parameter');
select is((select v from r where k = 'au.ctx_leak'), '0', 'app.audit_action/app.audit_reason are empty after every call — no leak into later writes (M11)');

-- ---------- البنية ----------
select is((select count(*)::int from fn f join pg_proc p on p.oid = f.f
            where pg_get_userbyid(p.proowner) = 'app_owner' and p.prosecdef and array_to_string(p.proconfig, ',') like 'search_path=%'), 15,
          'all 15 functions: SECURITY DEFINER, owner app_owner, pinned search_path');
select is((select count(*)::int from fn f join pg_proc p on p.oid = f.f where p.prosrc ~* 'for\s+update'), 15, 'all 15 functions lock the target row FOR UPDATE');
select is((select count(*)::int from fn f join pg_proc p on p.oid = f.f where p.prosrc ~* 'set_audit_context\(null, null\)'), 15, 'all 15 functions reset the audit context after writing');
select is((select count(*)::int from fn f join pg_proc p on p.oid = f.f where p.prosrc ~* 'p_actor|auth\.uid\(\)'), 0, 'no p_actor parameter and no direct auth.uid() (R2)');
select is((select count(*)::int from fn where has_function_privilege('authenticated', f, 'EXECUTE')), 15, 'EXECUTE for authenticated on all 15 (M20 allowlist)');
select is((select count(*)::int from fn, unnest(array['anon','public']) g where has_function_privilege(g, f, 'EXECUTE')), 0, 'no EXECUTE for anon or PUBLIC');
select is((select count(*)::int from unnest(array['anon','authenticated','public']) g, unnest(array['app.set_audit_context(text,text)','app.require_reason(text)']::regprocedure[]) f
            where has_function_privilege(g, f, 'EXECUTE')), 0, 'internal helpers (audit context, reason check) are executable by no client');
select is((select count(*)::int from fn f join pg_proc p on p.oid = f.f where p.prosrc ~* 'execute\s'), 0, 'no dynamic SQL in any state function');

-- مسارات الكتابة المباشرة التي أُغلقت تبقى مغلقة (M17b، M19، M20)
select ok(not has_column_privilege('authenticated', 'public.staff_school_assignments', 'status', 'UPDATE')
          and not has_column_privilege('authenticated', 'public.roles', 'status', 'UPDATE')
          and not has_column_privilege('authenticated', 'public.enrollments', 'status', 'UPDATE'),
          'no direct privilege path reopens what M17b/M19/M20 closed');

select * from finish();
rollback;
