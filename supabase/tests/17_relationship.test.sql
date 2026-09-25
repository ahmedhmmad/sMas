-- M17 — policies_people_enrollment: العلاقة التشغيلية (RLS §15.3 R1–R5) + E1، E2، E7 + H2 داخل RLS
-- كل قائمة كاملة لكل فاعل، فتثبت ما يُرى وما لا يُرى معاً. H2 هو المحور: لا وصول تاريخي عبر السياسات.
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
create temp table ent (kind text, label text, id uuid, primary key (kind, label)) on commit drop;
grant all on ids, ent to public;

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

create function pg_temp.eid(p_kind text, p_label text) returns uuid language sql as $$ select id from ent where kind = p_kind and label = p_label $$;
create function pg_temp.pid(p_label text) returns uuid language sql as $$ select profile from ids where label = p_label $$;

-- ============ Fixture: البنية ============
insert into public.platform_tenants (id, tenant_code, name) values
  ('10000000-0000-0000-0000-000000000001', 'T1', 'T1'), ('20000000-0000-0000-0000-000000000002', 'T2', 'T2');
insert into public.groups (id, platform_tenant_id, group_code, name) values
  ('a1000000-0000-0000-0000-00000000000a', '10000000-0000-0000-0000-000000000001', 'GA', 'GA'),
  ('a2000000-0000-0000-0000-00000000000b', '10000000-0000-0000-0000-000000000001', 'GB', 'GB');
insert into public.schools (id, platform_tenant_id, group_id, school_code, name, slug) values
  ('5a100000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', 'a1000000-0000-0000-0000-00000000000a', 'SA1', 'SA1', 'sa1'),
  ('5a200000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001', 'a1000000-0000-0000-0000-00000000000a', 'SA2', 'SA2', 'sa2'),
  ('5b100000-0000-0000-0000-000000000003', '10000000-0000-0000-0000-000000000001', 'a2000000-0000-0000-0000-00000000000b', 'SB1', 'SB1', 'sb1'),
  ('55000000-0000-0000-0000-000000000004', '10000000-0000-0000-0000-000000000001', null,                                   'SS',  'SS',  'ss'),
  ('52000000-0000-0000-0000-000000000005', '20000000-0000-0000-0000-000000000002', null,                                   'S2',  'S2',  's2');
create temp table sch on commit drop as select id, school_code as code, scope_owner_id from public.schools;
grant select on sch to public;
create function pg_temp.sid(p_code text) returns uuid language sql as $$ select id from sch where code = p_code $$;

-- لكل مدرسة سنتان (2026/2027 نشطة، 2027/2028 مخططة) بصف وشعبة لكل سنة
create temp table ctx (school uuid, yr text, year uuid, grade uuid, sec uuid, primary key (school, yr)) on commit drop;
grant select on ctx to public;
do $$
declare s record; v_stage uuid; v_grade uuid; v_y1 uuid; v_y2 uuid; v_s1 uuid; v_s2 uuid;
begin
  for s in select id from public.schools loop
    insert into public.academic_years (school_id, name, start_date, end_date, status) values (s.id, '2026/2027', '2026-09-01', '2027-06-30', 'active') returning id into v_y1;
    insert into public.academic_years (school_id, name, start_date, end_date) values (s.id, '2027/2028', '2027-09-01', '2028-06-30') returning id into v_y2;
    insert into public.stages (school_id, name, sequence_no) values (s.id, 'P', 1) returning id into v_stage;
    insert into public.grade_levels (school_id, stage_id, name, sequence_no) values (s.id, v_stage, 'G1', 1) returning id into v_grade;
    insert into public.sections (school_id, academic_year_id, grade_level_id, name) values (s.id, v_y1, v_grade, 'A') returning id into v_s1;
    insert into public.sections (school_id, academic_year_id, grade_level_id, name) values (s.id, v_y2, v_grade, 'A') returning id into v_s2;
    insert into ctx values (s.id, 'y1', v_y1, v_grade, v_s1), (s.id, 'y2', v_y2, v_grade, v_s2);
  end loop;
end $$;

-- ============ الصلاحيات والأدوار (البذر الحقيقي في M23) ============
insert into public.permissions (code, resource, operation, description)
  select c, split_part(c, '.', 1), split_part(c, '.', 2), 'test' from unnest(array[
    'student.read','student.update','guardian.read','guardian.update','guardian.link',
    'staff.read','staff.update','staff.assign','family.read','family.update',
    'enrollment.read','enrollment.create','enrollment.update']) c;
insert into public.roles (id, platform_tenant_id, code, name, is_system) values
  ('71000000-0000-0000-0000-000000000001', null, 'admin',    'Admin',    true),
  ('72000000-0000-0000-0000-000000000002', null, 'teacher',  'Teacher',  true),
  ('73000000-0000-0000-0000-000000000003', null, 'guardian', 'Guardian', true),
  ('74000000-0000-0000-0000-000000000004', null, 'student',  'Student',  true),
  ('75000000-0000-0000-0000-000000000005', null, 'bus',      'Bus',      true);
insert into public.role_permissions (role_id, permission_id)
  select '71000000-0000-0000-0000-000000000001'::uuid, id from public.permissions
  union all select '72000000-0000-0000-0000-000000000002'::uuid, id from public.permissions where code in ('student.read','enrollment.read')
  union all select '73000000-0000-0000-0000-000000000003'::uuid, id from public.permissions where code in ('student.read','enrollment.read','family.read','guardian.read')
  union all select '74000000-0000-0000-0000-000000000004'::uuid, id from public.permissions where code in ('student.read','enrollment.read')
  union all select '75000000-0000-0000-0000-000000000005'::uuid, id from public.permissions where code in ('guardian.read');   -- R4: لا student.read

create function pg_temp.person(p_label text, p_tenant uuid default '10000000-0000-0000-0000-000000000001') returns uuid
language plpgsql as $$
declare v_auth uuid := gen_random_uuid(); v_profile uuid;
begin
  insert into auth.users (id, email) values (v_auth, p_label || '@m17.invalid');
  insert into public.auth_identities values (v_auth, 'tenant');
  insert into public.profiles (platform_tenant_id, auth_user_id, display_name) values (p_tenant, v_auth, p_label) returning id into v_profile;
  insert into ids values (p_label, v_auth, v_profile);
  return v_profile;
end $$;

create function pg_temp.grant_(p_label text, p_role uuid, p_scopes text[], p_tenant uuid default '10000000-0000-0000-0000-000000000001') returns void
language plpgsql as $$
declare v_m uuid; s text;
begin
  insert into public.memberships (platform_tenant_id, profile_id) values (p_tenant, pg_temp.pid(p_label)) returning id into v_m;
  if p_role is not null then
    insert into public.membership_roles (membership_id, role_id, platform_tenant_id, role_owner_key)
      values (v_m, p_role, p_tenant, '00000000-0000-0000-0000-000000000000');
  end if;
  foreach s in array coalesce(p_scopes, '{}') loop
    if s = 'tenant' then
      insert into public.membership_scopes (membership_id, platform_tenant_id, scope_type) values (v_m, p_tenant, 'tenant');
    elsif s like 'G%' then
      insert into public.membership_scopes (membership_id, platform_tenant_id, scope_type, group_id) values (v_m, p_tenant, 'group', (select id from public.groups where group_code = s));
    else
      insert into public.membership_scopes (membership_id, platform_tenant_id, scope_type, school_id) values (v_m, p_tenant, 'school', pg_temp.sid(s));
    end if;
  end loop;
end $$;

-- ============ الأشخاص ============
-- الأسر
insert into ent select 'family', l, gen_random_uuid() from unnest(array['fama','famm','famx']) l;
insert into public.families (id, platform_tenant_id, family_name) select id, '10000000-0000-0000-0000-000000000001', label from ent where kind = 'family';

-- الطلاب (نطاق GA إلا sts/st2):
--   sa  SA1 نشط (أسرة fama)          sx  SA1 نشط (أسرة famx) — زميل sa، ليس ابن gp
--   sc  SA1 مكتمل فقط (نهاية سنة)     sm  انتقل SA1 → SA2 (أسرة famm)
--   sb  SA2 نشط                        sn  بلا أي تسجيل (R3)
--   st2 T2
insert into ent select 'student', l, gen_random_uuid() from unnest(array['sa','sx','sc','sm','sb','sn','st2']) l;
select pg_temp.person(l) from unnest(array['sa','sx','sc','sm','sb','sn']) l;
select pg_temp.person('st2', '20000000-0000-0000-0000-000000000002');
insert into public.students (id, platform_tenant_id, identity_scope_id, student_profile_id, family_id, official_id, official_id_type, first_name, family_name)
  select e.id, p.platform_tenant_id,
         case when e.label = 'st2' then (select id from public.identity_scopes where school_id = pg_temp.sid('S2'))
              else (select id from public.identity_scopes where group_id = 'a1000000-0000-0000-0000-00000000000a') end,
         p.id,
         case e.label when 'sa' then pg_temp.eid('family','fama') when 'sm' then pg_temp.eid('family','famm') when 'sx' then pg_temp.eid('family','famx') end,
         'N-' || e.label, 'national_id', e.label, e.label
  from ent e join public.profiles p on p.id = pg_temp.pid(e.label) where e.kind = 'student';

create function pg_temp.enroll_sql(p_student text, p_school text, p_yr text, p_status text, p_from date, p_to date) returns text
language sql as $$
  select format($f$insert into public.enrollments (school_id, student_id, platform_tenant_id, academic_year_id, grade_level_id, section_id,
                   identity_scope_id, scope_owner_id, status, effective_from, effective_to)
                   values (%L,%L,%L,%L,%L,%L,%L,%L,%L,%L,%L) returning 'ok'$f$,
    c.school, st.id, st.platform_tenant_id, c.year, c.grade, c.sec, st.identity_scope_id, s.scope_owner_id, p_status, p_from, p_to)
  from ctx c join sch s on s.id = c.school, public.students st
  where s.code = p_school and c.yr = p_yr and st.id = pg_temp.eid('student', p_student) $$;
do $$ begin
  execute pg_temp.enroll_sql('sa',  'SA1', 'y1', 'active',      '2026-09-01', null);
  execute pg_temp.enroll_sql('sx',  'SA1', 'y1', 'active',      '2026-09-01', null);
  execute pg_temp.enroll_sql('sc',  'SA1', 'y1', 'completed',   '2026-09-01', '2027-06-30');
  execute pg_temp.enroll_sql('sm',  'SA1', 'y1', 'transferred', '2026-09-01', '2026-12-01');
  execute pg_temp.enroll_sql('sm',  'SA2', 'y1', 'active',      '2026-12-01', null);
  execute pg_temp.enroll_sql('sb',  'SA2', 'y1', 'active',      '2026-09-01', null);
  execute pg_temp.enroll_sql('st2', 'S2',  'y1', 'active',      '2026-09-01', null);
end $$;

-- أولياء الأمور: gp (sa نشط، sm نشط، sb منتهٍ)، gy (sx نشط)، gx (sb منتهٍ فقط)
insert into ent select 'guardian', l, gen_random_uuid() from unnest(array['gp','gy','gx']) l;
select pg_temp.person('gp');
insert into public.guardians (id, platform_tenant_id, profile_id, first_name, family_name, phone_e164)
  select id, '10000000-0000-0000-0000-000000000001', pg_temp.pid(label), label, label,
         case label when 'gp' then '+201000000001' when 'gy' then '+201000000002' else '+201000000003' end
  from ent where kind = 'guardian';
insert into public.student_guardians (student_id, guardian_id, platform_tenant_id, relationship_type, status, effective_from, effective_to) values
  (pg_temp.eid('student','sa'), pg_temp.eid('guardian','gp'), '10000000-0000-0000-0000-000000000001', 'father', 'active', '2026-01-01', null),
  (pg_temp.eid('student','sm'), pg_temp.eid('guardian','gp'), '10000000-0000-0000-0000-000000000001', 'father', 'active', '2026-01-01', null),
  (pg_temp.eid('student','sb'), pg_temp.eid('guardian','gp'), '10000000-0000-0000-0000-000000000001', 'father', 'ended',  '2026-01-01', '2026-06-01'),
  (pg_temp.eid('student','sx'), pg_temp.eid('guardian','gy'), '10000000-0000-0000-0000-000000000001', 'mother', 'active', '2026-01-01', null),
  (pg_temp.eid('student','sb'), pg_temp.eid('guardian','gx'), '10000000-0000-0000-0000-000000000001', 'mother', 'ended',  '2026-01-01', '2026-06-01');

-- الموظفون: fa1 (SA1 نشط — هو المعلم tch)، fmv (SA1 منتهٍ → SA2 نشط)، fend (SB1 منتهٍ فقط)
insert into ent select 'staff', l, gen_random_uuid() from unnest(array['fa1','fmv','fend']) l;
select pg_temp.person('tch');
insert into public.staff (id, platform_tenant_id, profile_id, employee_code, first_name, family_name)
  select id, '10000000-0000-0000-0000-000000000001', case when label = 'fa1' then pg_temp.pid('tch') end, upper(label), label, label
  from ent where kind = 'staff';
insert into public.staff_school_assignments (staff_id, school_id, platform_tenant_id, job_title, status, effective_from, effective_to) values
  (pg_temp.eid('staff','fa1'),  pg_temp.sid('SA1'), '10000000-0000-0000-0000-000000000001', 'Teacher', 'active', '2026-09-01', null),
  (pg_temp.eid('staff','fmv'),  pg_temp.sid('SA1'), '10000000-0000-0000-0000-000000000001', 'Teacher', 'ended',  '2025-09-01', '2026-06-30'),
  (pg_temp.eid('staff','fmv'),  pg_temp.sid('SA2'), '10000000-0000-0000-0000-000000000001', 'Teacher', 'active', '2026-09-01', null),
  (pg_temp.eid('staff','fend'), pg_temp.sid('SB1'), '10000000-0000-0000-0000-000000000001', 'Teacher', 'ended',  '2025-09-01', '2026-06-30');

-- الفاعلون
select pg_temp.person(l) from unnest(array['ta','gm','sa1','sa2','sb1','bus','noperm']) l;
select pg_temp.person('t2a', '20000000-0000-0000-0000-000000000002');
select pg_temp.grant_('ta',     '71000000-0000-0000-0000-000000000001', array['tenant']);
select pg_temp.grant_('gm',     '71000000-0000-0000-0000-000000000001', array['GA']);
select pg_temp.grant_('sa1',    '71000000-0000-0000-0000-000000000001', array['SA1']);
select pg_temp.grant_('sa2',    '71000000-0000-0000-0000-000000000001', array['SA2']);
select pg_temp.grant_('sb1',    '71000000-0000-0000-0000-000000000001', array['SB1']);
select pg_temp.grant_('tch',    '72000000-0000-0000-0000-000000000002', array['SA1']);
select pg_temp.grant_('bus',    '75000000-0000-0000-0000-000000000005', array['SA1']);
select pg_temp.grant_('noperm', null,                                   array['SA1']);
select pg_temp.grant_('gp',     '73000000-0000-0000-0000-000000000003', null);
select pg_temp.grant_('sa',     '74000000-0000-0000-0000-000000000004', null);
select pg_temp.grant_('t2a',    '71000000-0000-0000-0000-000000000001', array['tenant'], '20000000-0000-0000-0000-000000000002');

-- Platform Admin بكل صلاحيات الأشخاص في سياق المنصة (E7)
insert into public.platform_admin_roles (id, code, name) values ('81000000-0000-0000-0000-000000000001', 'pa_all', 'All');
insert into public.platform_admin_role_permissions select '81000000-0000-0000-0000-000000000001', id from public.permissions;
insert into auth.users (id, email) values ('c7000000-0000-0000-0000-000000000007', 'pa@m17.invalid');
insert into public.auth_identities values ('c7000000-0000-0000-0000-000000000007', 'platform');
insert into public.system_users (id, auth_user_id, display_name) values ('d7000000-0000-0000-0000-000000000007', 'c7000000-0000-0000-0000-000000000007', 'pa');
insert into public.platform_admin_assignments (system_user_id, platform_admin_role_id) values ('d7000000-0000-0000-0000-000000000007', '81000000-0000-0000-0000-000000000001');
insert into ids values ('pa', 'c7000000-0000-0000-0000-000000000007', null);

-- ============ القراءة ============
create temp table lbl_asg on commit drop as
  select a.id, e.label || ':' || s.code as label from public.staff_school_assignments a join ent e on e.kind = 'staff' and e.id = a.staff_id join sch s on s.id = a.school_id;
create temp table lbl_enr on commit drop as
  select x.id, e.label || ':' || s.code as label from public.enrollments x join ent e on e.kind = 'student' and e.id = x.student_id join sch s on s.id = x.school_id;
create temp table lbl_sg on commit drop as
  select x.id, s.label || ':' || g.label as label from public.student_guardians x
  join ent s on s.kind = 'student' and s.id = x.student_id join ent g on g.kind = 'guardian' and g.id = x.guardian_id;
grant select on lbl_asg, lbl_enr, lbl_sg to public;

create function pg_temp.lists(p_label text) returns void
language plpgsql as $$
begin
  perform pg_temp.run('students.' || p_label, p_label, $q$select string_agg(e.label, ',' order by e.label collate "C") from public.students x join ent e on e.kind = 'student' and e.id = x.id$q$);
  perform pg_temp.run('enr.'      || p_label, p_label, $q$select string_agg(l.label, ',' order by l.label collate "C") from public.enrollments x join lbl_enr l using (id)$q$);
  perform pg_temp.run('guard.'    || p_label, p_label, $q$select string_agg(e.label, ',' order by e.label collate "C") from public.guardians x join ent e on e.kind = 'guardian' and e.id = x.id$q$);
  perform pg_temp.run('sg.'       || p_label, p_label, $q$select string_agg(l.label, ',' order by l.label collate "C") from public.student_guardians x join lbl_sg l using (id)$q$);
  perform pg_temp.run('staff.'    || p_label, p_label, $q$select string_agg(e.label, ',' order by e.label collate "C") from public.staff x join ent e on e.kind = 'staff' and e.id = x.id$q$);
  perform pg_temp.run('asg.'      || p_label, p_label, $q$select string_agg(l.label, ',' order by l.label collate "C") from public.staff_school_assignments x join lbl_asg l using (id)$q$);
  perform pg_temp.run('fam.'      || p_label, p_label, $q$select string_agg(e.label, ',' order by e.label collate "C") from public.families x join ent e on e.kind = 'family' and e.id = x.id$q$);
end $$;
select pg_temp.lists(l) from unnest(array['ta','gm','sa1','sa2','sb1','tch','bus','noperm','gp','sa','t2a','pa','anon']) l;

-- ============ الكتابة ============
create function pg_temp.upd(p_table text, p_col text, p_where text) returns text language sql as $$
  select format('with u as (update public.%I set %s = %s where %s returning 1) select count(*)::text from u', p_table, p_col, p_col, p_where) $$;

-- students — E2، H2
select pg_temp.run('u.sa1_student_sa', 'sa1', pg_temp.upd('students', 'first_name', format('id = %L', pg_temp.eid('student','sa'))));
select pg_temp.run('u.sa1_student_sm', 'sa1', pg_temp.upd('students', 'first_name', format('id = %L', pg_temp.eid('student','sm'))));
select pg_temp.run('u.sa2_student_sm', 'sa2', pg_temp.upd('students', 'first_name', format('id = %L', pg_temp.eid('student','sm'))));
select pg_temp.run('u.tch_student_sa', 'tch', pg_temp.upd('students', 'first_name', format('id = %L', pg_temp.eid('student','sa'))));
select pg_temp.run('u.gp_student_sa',  'gp',  pg_temp.upd('students', 'first_name', format('id = %L', pg_temp.eid('student','sa'))));
select pg_temp.run('u.sa1_student_tenant', 'sa1', format($q$update public.students set platform_tenant_id = '20000000-0000-0000-0000-000000000002' where id = %L returning 'ok'$q$, pg_temp.eid('student','sa')));

-- enrollments — E1، قرار 2026-09-25
select pg_temp.run('u.sa1_enr_move', 'sa1', format($q$update public.enrollments set school_id = %L where student_id = %L returning 'ok'$q$, pg_temp.sid('SB1'), pg_temp.eid('student','sa')));
select pg_temp.run('u.sa1_enr_sa',   'sa1', pg_temp.upd('enrollments', 'enrollment_no', format('student_id = %L', pg_temp.eid('student','sa'))));
select pg_temp.run('u.sa1_enr_sm_hist', 'sa1', pg_temp.upd('enrollments', 'enrollment_no', format('student_id = %L and school_id = %L', pg_temp.eid('student','sm'), pg_temp.sid('SA1'))));
select pg_temp.run('u.sa2_enr_sm',   'sa2', pg_temp.upd('enrollments', 'enrollment_no', format('student_id = %L and school_id = %L', pg_temp.eid('student','sm'), pg_temp.sid('SA2'))));
select pg_temp.run('w.sa2_enr_sc_takeover', 'sa2', pg_temp.enroll_sql('sc', 'SA2', 'y2', 'active', '2027-09-01', null));
select pg_temp.run('w.sa1_enr_sn_first',    'sa1', pg_temp.enroll_sql('sn', 'SA1', 'y1', 'active', '2026-09-01', null));
select pg_temp.run('w.tch_enr_sc',          'tch', pg_temp.enroll_sql('sc', 'SA1', 'y2', 'active', '2027-09-01', null));
select pg_temp.run('w.sa1_enr_sc_next',     'sa1', pg_temp.enroll_sql('sc', 'SA1', 'y2', 'active', '2027-09-01', null));

-- student_guardians
select pg_temp.run('w.sa1_link_sa_gx', 'sa1', format($q$insert into public.student_guardians (student_id, guardian_id, platform_tenant_id, relationship_type) values (%L, %L, '10000000-0000-0000-0000-000000000001', 'other') returning 'ok'$q$, pg_temp.eid('student','sa'), pg_temp.eid('guardian','gx')));
select pg_temp.run('w.sa1_link_sm_gx', 'sa1', format($q$insert into public.student_guardians (student_id, guardian_id, platform_tenant_id, relationship_type) values (%L, %L, '10000000-0000-0000-0000-000000000001', 'other') returning 'ok'$q$, pg_temp.eid('student','sm'), pg_temp.eid('guardian','gx')));
select pg_temp.run('w.sb1_link_sa_gy', 'sb1', format($q$insert into public.student_guardians (student_id, guardian_id, platform_tenant_id, relationship_type) values (%L, %L, '10000000-0000-0000-0000-000000000001', 'other') returning 'ok'$q$, pg_temp.eid('student','sa'), pg_temp.eid('guardian','gy')));
select pg_temp.run('u.sa1_sg_sa', 'sa1', pg_temp.upd('student_guardians', 'is_primary', format('student_id = %L and guardian_id = %L', pg_temp.eid('student','sa'), pg_temp.eid('guardian','gp'))));
select pg_temp.run('u.sa1_sg_sm', 'sa1', pg_temp.upd('student_guardians', 'is_primary', format('student_id = %L', pg_temp.eid('student','sm'))));

-- guardians، staff، assignments، families
select pg_temp.run('u.sa1_guard_gp', 'sa1', pg_temp.upd('guardians', 'first_name', format('id = %L', pg_temp.eid('guardian','gp'))));
select pg_temp.run('u.sb1_guard_gp', 'sb1', pg_temp.upd('guardians', 'first_name', format('id = %L', pg_temp.eid('guardian','gp'))));
select pg_temp.run('u.sa2_guard_gx', 'sa2', pg_temp.upd('guardians', 'first_name', format('id = %L', pg_temp.eid('guardian','gx'))));
select pg_temp.run('u.sa1_staff_fa1', 'sa1', pg_temp.upd('staff', 'first_name', format('id = %L', pg_temp.eid('staff','fa1'))));
select pg_temp.run('u.sa1_staff_fmv', 'sa1', pg_temp.upd('staff', 'first_name', format('id = %L', pg_temp.eid('staff','fmv'))));
select pg_temp.run('u.sa2_staff_fmv', 'sa2', pg_temp.upd('staff', 'first_name', format('id = %L', pg_temp.eid('staff','fmv'))));
select pg_temp.run('w.sa1_asg_fend_SA1', 'sa1', format($q$insert into public.staff_school_assignments (staff_id, school_id, platform_tenant_id, job_title, effective_from) values (%L, %L, '10000000-0000-0000-0000-000000000001', 'Teacher', '2026-10-01') returning 'ok'$q$, pg_temp.eid('staff','fend'), pg_temp.sid('SA1')));
select pg_temp.run('w.sa1_asg_fend_SA2', 'sa1', format($q$insert into public.staff_school_assignments (staff_id, school_id, platform_tenant_id, job_title, effective_from) values (%L, %L, '10000000-0000-0000-0000-000000000001', 'Teacher', '2026-10-01') returning 'ok'$q$, pg_temp.eid('staff','fend'), pg_temp.sid('SA2')));
select pg_temp.run('u.sa1_asg_SA2', 'sa1', pg_temp.upd('staff_school_assignments', 'job_title', format('school_id = %L', pg_temp.sid('SA2'))));
select pg_temp.run('u.sa1_fam_a', 'sa1', pg_temp.upd('families', 'family_name', format('id = %L', pg_temp.eid('family','fama'))));
select pg_temp.run('u.sa1_fam_m', 'sa1', pg_temp.upd('families', 'family_name', format('id = %L', pg_temp.eid('family','famm'))));
select pg_temp.run('u.gp_fam_a',  'gp',  pg_temp.upd('families', 'family_name', format('id = %L', pg_temp.eid('family','fama'))));

-- G4: لا إنشاء مباشر لصفوف الهوية
select pg_temp.run('w.g4_student',  'ta', format($q$insert into public.students (platform_tenant_id, identity_scope_id, student_profile_id, official_id, official_id_type, first_name, family_name) values ('10000000-0000-0000-0000-000000000001', %L, %L, 'N-new', 'national_id', 'N', 'N') returning 'ok'$q$,
                                              (select id from public.identity_scopes where group_id = 'a1000000-0000-0000-0000-00000000000a'), pg_temp.pid('noperm')));
select pg_temp.run('w.g4_guardian', 'ta', $q$insert into public.guardians (platform_tenant_id, first_name, family_name, phone_e164) values ('10000000-0000-0000-0000-000000000001', 'N', 'N', '+201000000099') returning 'ok'$q$);
select pg_temp.run('w.g4_staff',    'ta', $q$insert into public.staff (platform_tenant_id, employee_code, first_name, family_name) values ('10000000-0000-0000-0000-000000000001', 'NEW', 'N', 'N') returning 'ok'$q$);
select pg_temp.run('w.g4_family',   'ta', $q$insert into public.families (platform_tenant_id, family_name) values ('10000000-0000-0000-0000-000000000001', 'N') returning 'ok'$q$);

-- E6: DELETE على الجداول السبعة — مدير Tenant بكل الصلاحيات
select pg_temp.run('d.all', 'ta', $q$
  with a as (delete from public.enrollments returning 1), b as (delete from public.student_guardians returning 1),
       c as (delete from public.staff_school_assignments returning 1), d as (delete from public.students returning 1),
       e as (delete from public.guardians returning 1), f as (delete from public.staff returning 1), g as (delete from public.families returning 1)
  select ((select count(*) from a) + (select count(*) from b) + (select count(*) from c) + (select count(*) from d)
        + (select count(*) from e) + (select count(*) from f) + (select count(*) from g))::text$q$);

select plan(97);

-- ---------- students: المسارات الثلاثة + H2 ----------
select is((select v from r where k = 'students.ta'),     'sa,sb,sc,sm,sx', 'students: tenant scope → every enrolled T1 student; not sn (no enrollment, R3), not T2');
select is((select v from r where k = 'students.gm'),     'sa,sb,sc,sm,sx', 'students: group scope → students whose latest enrollment is in GA');
select is((select v from r where k = 'students.sa1'),    'sa,sc,sx',       'H2: SA1 sees its current students incl. year-end completed sc — NOT sm, who moved to SA2');
select is((select v from r where k = 'students.sa2'),    'sb,sm',          'H2: SA2 sees sm (latest enrollment) and sb');
select is((select v from r where k = 'students.sb1'),    '<null>',         'students: another group sees nothing');
select is((select v from r where k = 'students.bus'),    '<null>',         'R4: without student.read (bus supervisor) → no student');
select is((select v from r where k = 'students.noperm'), '<null>',         'students: scope without permission (P2)');
select is((select v from r where k = 'students.gp'),     'sa,sm',          'R1: a guardian sees only its children with an active link — not sx (same school), not sb (ended link)');
select is((select v from r where k = 'students.sa'),     'sa',             'R2: a student sees only itself');
select is((select v from r where k = 'students.t2a'),    'st2',            'students: never across tenants');
select is((select v from r where k = 'students.pa'),     '<null>',         'E7: platform admin — even with student.read in the platform context — reads no student');
select is((select v from r where k = 'students.anon'),   '<null>',         'students: anon');

-- R5 — دين D1: المعلم يرى طلاب شعبه فقط. لا teaching_assignments بعد، فالمعلم يرى كل مدرسته — TODO يفشل عمداً.
select todo_start('D1: teaching_assignments not implemented — a teacher currently sees its whole school (R5)');
select is((select v from r where k = 'students.tch'), '<null>', 'R5: a teacher with no teaching assignment sees no student');
select todo_end();
select is((select v from r where k = 'students.tch'), 'sa,sc,sx', 'R5 (current state, documented): the teacher sees its school''s current students — H2 applies, sm excluded');

-- ---------- enrollments ----------
select is((select v from r where k = 'enr.sa1'), 'sa:SA1,sc:SA1,sm:SA1,sx:SA1', 'enrollments: SA1 reads its own rows incl. sm''s historical SA1 row (historical access approved in H2)');
select is((select v from r where k = 'enr.sa2'), 'sb:SA2,sm:SA2', 'enrollments: SA2 reads its own rows only — not sm''s SA1 row');
select is((select v from r where k = 'enr.ta'),  'sa:SA1,sb:SA2,sc:SA1,sm:SA1,sm:SA2,sx:SA1', 'enrollments: tenant scope reads every T1 row');
select is((select v from r where k = 'enr.gp'),  'sa:SA1,sm:SA1,sm:SA2', 'enrollments: guardian reads its children''s rows (active links), across schools');
select is((select v from r where k = 'enr.sa'),  'sa:SA1', 'enrollments: a student reads its own');
select is((select v from r where k = 'enr.sb1'), '<null>', 'enrollments: another group reads nothing');
select is((select v from r where k = 'enr.bus'), '<null>', 'enrollments: without enrollment.read nothing');
select is((select v from r where k = 'enr.pa'),  '<null>', 'E7: platform admin reads no enrollment');
select is((select v from r where k = 'enr.t2a'), 'st2:S2', 'enrollments: never across tenants');

-- ---------- guardians ----------
select is((select v from r where k = 'guard.ta'),  'gp,gy',  'guardians: tenant scope → guardians with an active link to a current student; not gx (ended links only, H2)');
select is((select v from r where k = 'guard.sa1'), 'gp,gy',  'guardians: SA1 reaches gp (child sa) and gy (child sx)');
select is((select v from r where k = 'guard.sa2'), 'gp',     'guardians: SA2 reaches gp through sm (current in SA2) — not gx (ended link to sb)');
select is((select v from r where k = 'guard.sb1'), '<null>', 'guardians: another group');
select is((select v from r where k = 'guard.gp'),  'gp',     'guardians: a guardian sees itself only');
select is((select v from r where k = 'guard.bus'), 'gp,gy',  'guardians: guardian.read with SA1 scope (bus supervisor) — contacts only, no student row (R4)');
select is((select v from r where k = 'guard.pa'),  '<null>', 'E7: platform admin reads no guardian');

-- ---------- student_guardians ----------
select is((select v from r where k = 'sg.sa1'), 'sa:gp,sx:gy',             'student_guardians: SA1 reads links of its current students; not sm''s (moved)');
select is((select v from r where k = 'sg.sa2'), 'sb:gp,sb:gx,sm:gp',       'student_guardians: SA2 reads all links of its current students, ended ones included (the student''s history)');
select is((select v from r where k = 'sg.gp'),  'sa:gp,sb:gp,sm:gp',       'student_guardians: a guardian reads its own link rows, ended included — no access to sb itself');
select is((select v from r where k = 'sg.sa'),  'sa:gp',                   'student_guardians: a student reads its own links');
select is((select v from r where k = 'sg.sb1'), '<null>',                  'student_guardians: another group');

-- ---------- staff / assignments ----------
select is((select v from r where k = 'staff.ta'),  'fa1,fmv',  'staff: tenant scope → staff with an active assignment; not fend (ended only, H2)');
select is((select v from r where k = 'staff.sa1'), 'fa1',      'H2 staff: SA1 does not reach fmv through its ended SA1 assignment');
select is((select v from r where k = 'staff.sa2'), 'fmv',      'H2 staff: SA2 reaches fmv through the active assignment');
select is((select v from r where k = 'staff.sb1'), '<null>',   'H2 staff: SB1 does not reach fend through an ended assignment');
select is((select v from r where k = 'staff.tch'), 'fa1',      'staff: self path without staff.read');
select is((select v from r where k = 'staff.pa'),  '<null>',   'E7: platform admin reads no staff');
select is((select v from r where k = 'asg.sa1'),   'fa1:SA1,fmv:SA1', 'assignments: SA1 reads its own rows incl. the ended one (school-level record)');
select is((select v from r where k = 'asg.sb1'),   'fend:SB1',  'assignments: SB1 reads its own ended row — the record, not the person');
select is((select v from r where k = 'asg.ta'),    'fa1:SA1,fend:SB1,fmv:SA1,fmv:SA2', 'assignments: tenant scope reads every T1 row');
select is((select v from r where k = 'asg.tch'),   '<null>',   'assignments: without staff.read nothing');

-- ---------- families ----------
select is((select v from r where k = 'fam.ta'),  'fama,famm,famx', 'families: tenant scope');
select is((select v from r where k = 'fam.sa1'), 'fama,famx',      'H2 families: SA1 does not reach famm (its student moved)');
select is((select v from r where k = 'fam.sa2'), 'famm',           'families: SA2 reaches famm through sm');
select is((select v from r where k = 'fam.gp'),  'fama,famm',      'families: a guardian reaches its children''s families (active links)');
select is((select v from r where k = 'fam.sa'),  '<null>',         'families: without family.read nothing');
select is((select v from r where k = 'fam.pa'),  '<null>',         'E7: platform admin reads no family');

-- ---------- الكتابة: students ----------
select is((select v from r where k = 'u.sa1_student_sa'), '1', 'students update: current school');
select is((select v from r where k = 'u.sa1_student_sm'), '0', 'H2: the former school cannot update the moved student');
select is((select v from r where k = 'u.sa2_student_sm'), '1', 'H2: the new school can');
select is((select v from r where k = 'u.tch_student_sa'), '0', 'students update: student.read does not grant update');
select is((select v from r where k = 'u.gp_student_sa'),  '0', 'students update: a guardian cannot update its child');
select ok((select v from r where k = 'u.sa1_student_tenant') like 'ERR 42501%row-level security%students%', 'E2: UPDATE students SET platform_tenant_id → rejected');

-- ---------- الكتابة: enrollments ----------
select ok((select v from r where k = 'u.sa1_enr_move') like 'ERR 42501%row-level security%enrollments%', 'E1: UPDATE enrollments SET school_id to an out-of-scope school → rejected');
select is((select v from r where k = 'u.sa1_enr_sa'),       '1', 'enrollments update: current school on its current student');
select is((select v from r where k = 'u.sa1_enr_sm_hist'),  '0', '2026-09-25: the former school cannot modify its historical row of a moved student');
select is((select v from r where k = 'u.sa2_enr_sm'),       '1', 'enrollments update: the current school can');
select ok((select v from r where k = 'w.sa2_enr_sc_takeover') like 'ERR 42501%row-level security%enrollments%', '2026-09-25: another school cannot take a student over by inserting a later enrollment');
select ok((select v from r where k = 'w.sa1_enr_sn_first')    like 'ERR 42501%row-level security%enrollments%', 'enrollments insert: a first enrollment only through provision_student (M22)');
select ok((select v from r where k = 'w.tch_enr_sc')          like 'ERR 42501%row-level security%enrollments%', 'enrollments insert: without enrollment.create');
select is((select v from r where k = 'w.sa1_enr_sc_next'), 'ok', 'enrollments insert: the current school re-enrolls its year-end student for the next year (control)');

-- ---------- الكتابة: student_guardians ----------
select is((select v from r where k = 'w.sa1_link_sa_gx'), 'ok', 'link: a guardian from elsewhere to a current student (§10.5: phone match, Phase 4)');
select ok((select v from r where k = 'w.sa1_link_sm_gx') like 'ERR 42501%row-level security%student_guardians%', 'H2 link: never to a student who moved away');
select ok((select v from r where k = 'w.sb1_link_sa_gy') like 'ERR 42501%row-level security%student_guardians%', 'link: never to another group''s student');
select is((select v from r where k = 'u.sa1_sg_sa'), '1', 'link update: current student');
select is((select v from r where k = 'u.sa1_sg_sm'), '0', 'H2 link update: not a moved student''s links');

-- ---------- الكتابة: guardians، staff، assignments، families ----------
select is((select v from r where k = 'u.sa1_guard_gp'),  '1', 'guardians update: through a current child');
select is((select v from r where k = 'u.sb1_guard_gp'),  '0', 'guardians update: another group');
select is((select v from r where k = 'u.sa2_guard_gx'),  '0', 'H2 guardians update: an ended link grants nothing');
select is((select v from r where k = 'u.sa1_staff_fa1'), '1', 'staff update: active assignment');
select is((select v from r where k = 'u.sa1_staff_fmv'), '0', 'H2 staff update: the former school cannot manage a moved staff member');
select is((select v from r where k = 'u.sa2_staff_fmv'), '1', 'H2 staff update: the current school can');
select is((select v from r where k = 'w.sa1_asg_fend_SA1'), 'ok', 'assignment insert: own school with staff.assign');
select ok((select v from r where k = 'w.sa1_asg_fend_SA2') like 'ERR 42501%row-level security%staff_school_assignments%', 'assignment insert: never a sibling school');
select is((select v from r where k = 'u.sa1_asg_SA2'), '0', 'assignment update: another school''s rows are invisible');
select is((select v from r where k = 'u.sa1_fam_a'), '1', 'families update: family of a current student');
select is((select v from r where k = 'u.sa1_fam_m'), '0', 'H2 families update: not the family of a moved student');
select is((select v from r where k = 'u.gp_fam_a'),  '0', 'families update: a guardian reads but cannot update');

-- ---------- G4 و E6 ----------
select ok((select v from r where k = 'w.g4_student')  like 'ERR 42501%row-level security%students%',  'G4: no direct student insert (provisioning functions only)');
select ok((select v from r where k = 'w.g4_guardian') like 'ERR 42501%row-level security%guardians%', 'G4: no direct guardian insert');
select ok((select v from r where k = 'w.g4_staff')    like 'ERR 42501%row-level security%staff%',     'G4: no direct staff insert');
select ok((select v from r where k = 'w.g4_family')   like 'ERR 42501%row-level security%families%',  'G4: no direct family insert');
select is((select v from r where k = 'd.all'), '0', 'E6: DELETE on the seven tables removes nothing, even for a tenant-scoped admin');

-- ---------- السياسات ----------
select policies_are('public', 'staff',                    array['staff_select','staff_update'], 'staff: exactly the M17 policies (no INSERT — G4)');
select policies_are('public', 'staff_school_assignments', array['staff_school_assignments_select','staff_school_assignments_insert','staff_school_assignments_update'], 'staff_school_assignments: exactly the M17 policies');
select policies_are('public', 'families',                 array['families_select','families_update'], 'families: exactly the M17 policies (no INSERT — G4)');
select policies_are('public', 'students',                 array['students_select','students_update'], 'students: exactly the M17 policies (no INSERT — G4)');
select policies_are('public', 'guardians',                array['guardians_select','guardians_update'], 'guardians: exactly the M17 policies (no INSERT — G4)');
select policies_are('public', 'student_guardians',        array['student_guardians_select','student_guardians_insert','student_guardians_update'], 'student_guardians: exactly the M17 policies');
select policies_are('public', 'enrollments',              array['enrollments_select','enrollments_insert','enrollments_update'], 'enrollments: exactly the M17 policies');
select is((select count(*)::int from pg_policies where schemaname = 'public'
            and tablename in ('staff','staff_school_assignments','families','students','guardians','student_guardians','enrollments')
            and not ('authenticated' = any(roles) and cardinality(roles) = 1)), 0, 'every M17 policy is TO authenticated only');
-- H2 داخل RLS: لا سياسة تستعلم enrollments أو assignments أو student_guardians مباشرة — العلاقة عبر الدوال وحدها
select is((select count(*)::int from pg_policies where schemaname = 'public'
            and (coalesce(qual, '') || coalesce(with_check, '')) ~ 'from\s+(public\.)?(enrollments|staff_school_assignments|student_guardians|memberships)\M'), 0,
          'H2 in RLS: no policy reads a relationship table directly — relationships only through the M12b helpers');
select is((select count(*)::int from pg_policies where schemaname = 'public'
            and coalesce(qual, '') || coalesce(with_check, '') ~ 'has_platform_permission'
            and tablename in ('staff','staff_school_assignments','families','students','guardians','student_guardians','enrollments')), 0,
          'E7: no platform policy on customer people data');

select * from finish();
rollback;
