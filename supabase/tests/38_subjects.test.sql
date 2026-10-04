-- M38 + M39 — المواد (Phase 2B / 2B-1): المفتاحان الجديدان، العزل، الحراس T13 من الجهتين، التجمّد، التدقيق.
-- الصلاحية والنطاق في RLS (subject.read / subject.manage + can_access_school) — لا في الحارس.
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
insert into public.academic_years (id, school_id, name, start_date, end_date) values
  ('c0000000-0000-0000-0000-000000000001', '5a000000-0000-0000-0000-000000000001', '2025', '2025-09-01', '2026-06-30'),
  ('ac000000-0000-0000-0000-000000000002', '5a000000-0000-0000-0000-000000000001', '2026', '2026-09-01', '2027-06-30'),
  ('b0000000-0000-0000-0000-000000000003', '5a000000-0000-0000-0000-000000000001', '2027', '2027-09-01', '2028-06-30'),
  ('bb000000-0000-0000-0000-000000000004', '5b000000-0000-0000-0000-000000000002', '2026', '2026-09-01', '2027-06-30');
insert into public.stages (id, school_id, name, sequence_no) values
  ('51000000-0000-0000-0000-000000000001', '5a000000-0000-0000-0000-000000000001', 'P', 1),
  ('5b100000-0000-0000-0000-000000000001', '5b000000-0000-0000-0000-000000000002', 'P', 1);
insert into public.grade_levels (id, school_id, stage_id, name, sequence_no, status) values
  ('61000000-0000-0000-0000-000000000001', '5a000000-0000-0000-0000-000000000001', '51000000-0000-0000-0000-000000000001', 'G1', 1, 'active'),
  ('61000000-0000-0000-0000-000000000002', '5a000000-0000-0000-0000-000000000001', '51000000-0000-0000-0000-000000000001', 'G2', 2, 'active'),
  ('61000000-0000-0000-0000-000000000003', '5a000000-0000-0000-0000-000000000001', '51000000-0000-0000-0000-000000000001', 'G3', 3, 'inactive'),
  ('61000000-0000-0000-0000-000000000004', '5a000000-0000-0000-0000-000000000001', '51000000-0000-0000-0000-000000000001', 'G4', 4, 'active'),
  ('6b100000-0000-0000-0000-000000000001', '5b000000-0000-0000-0000-000000000002', '5b100000-0000-0000-0000-000000000001', 'G1', 1, 'active');
-- مواد SA: AR، MA (مُدرَّستان في السنة النشطة)، EN (في السنة المغلقة فقط)، OLD (معطّلة)؛ SB: AR
insert into public.subjects (id, school_id, subject_code, name, status) values
  ('a5000000-0000-0000-0000-000000000001', '5a000000-0000-0000-0000-000000000001', 'AR',  'Arabic',  'active'),
  ('a5000000-0000-0000-0000-000000000002', '5a000000-0000-0000-0000-000000000001', 'MA',  'Math',    'active'),
  ('a5000000-0000-0000-0000-000000000003', '5a000000-0000-0000-0000-000000000001', 'EN',  'English', 'active'),
  ('a5000000-0000-0000-0000-000000000004', '5a000000-0000-0000-0000-000000000001', 'OLD', 'Old',     'inactive'),
  ('a5b00000-0000-0000-0000-000000000001', '5b000000-0000-0000-0000-000000000002', 'AR',  'Arabic',  'active');
insert into public.grade_subjects (id, school_id, academic_year_id, grade_level_id, subject_id, weekly_periods) values
  ('65000000-0000-0000-0000-000000000001', '5a000000-0000-0000-0000-000000000001', 'c0000000-0000-0000-0000-000000000001', '61000000-0000-0000-0000-000000000004', 'a5000000-0000-0000-0000-000000000003', 3),   -- yC: G4/EN
  ('65000000-0000-0000-0000-000000000002', '5a000000-0000-0000-0000-000000000001', 'ac000000-0000-0000-0000-000000000002', '61000000-0000-0000-0000-000000000001', 'a5000000-0000-0000-0000-000000000001', 5),   -- yA: G1/AR
  ('65000000-0000-0000-0000-000000000003', '5a000000-0000-0000-0000-000000000001', 'ac000000-0000-0000-0000-000000000002', '61000000-0000-0000-0000-000000000001', 'a5000000-0000-0000-0000-000000000002', 4),   -- yA: G1/MA
  ('65000000-0000-0000-0000-000000000004', '5a000000-0000-0000-0000-000000000001', 'b0000000-0000-0000-0000-000000000003', '61000000-0000-0000-0000-000000000002', 'a5000000-0000-0000-0000-000000000002', 6),   -- yP: G2/MA
  ('6b500000-0000-0000-0000-000000000001', '5b000000-0000-0000-0000-000000000002', 'bb000000-0000-0000-0000-000000000004', '6b100000-0000-0000-0000-000000000001', 'a5b00000-0000-0000-0000-000000000001', 5);
update public.academic_years set status = 'active' where id = 'c0000000-0000-0000-0000-000000000001';
update public.academic_years set status = 'closed' where id = 'c0000000-0000-0000-0000-000000000001';
update public.academic_years set status = 'active' where id in ('ac000000-0000-0000-0000-000000000002', 'bb000000-0000-0000-0000-000000000004');

-- الفاعلون: أدوار مبذورة + دور مخصص يملك subject.* وحده (لا يقرأ السنة ولا الصف)
insert into public.roles (id, platform_tenant_id, code, name) values ('7f000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', 'zt_subject_only', 'subject only');
insert into public.role_permissions (role_id, permission_id) select '7f000000-0000-0000-0000-000000000001', id from public.permissions where code in ('subject.manage', 'subject.read');
create function pg_temp.member(p_label text, p_role text, p_tenant uuid, p_school uuid) returns void
language plpgsql as $$
declare v_a uuid := gen_random_uuid(); v_p uuid; v_m uuid; v_role uuid; v_key uuid;
begin
  select id, coalesce(platform_tenant_id, '00000000-0000-0000-0000-000000000000') into v_role, v_key from public.roles where code = p_role;
  insert into auth.users (id, email) values (v_a, p_label || '@m39.invalid');
  insert into public.auth_identities (auth_user_id, kind) values (v_a, 'tenant');
  insert into public.profiles (platform_tenant_id, auth_user_id, display_name) values (p_tenant, v_a, p_label) returning id into v_p;
  insert into public.memberships (platform_tenant_id, profile_id) values (p_tenant, v_p) returning id into v_m;
  insert into public.membership_roles (membership_id, role_id, platform_tenant_id, role_owner_key) values (v_m, v_role, p_tenant, v_key);
  insert into public.membership_scopes (membership_id, platform_tenant_id, scope_type, school_id) values (v_m, p_tenant, 'school', p_school);
  insert into actors values (p_label, v_a);
end $$;
select pg_temp.member('sa',  'school_admin',    '10000000-0000-0000-0000-000000000001', '5a000000-0000-0000-0000-000000000001');
select pg_temp.member('sb',  'school_admin',    '10000000-0000-0000-0000-000000000001', '5b000000-0000-0000-0000-000000000002');
select pg_temp.member('sec', 'secretary',       '10000000-0000-0000-0000-000000000001', '5a000000-0000-0000-0000-000000000001');
select pg_temp.member('tch', 'teacher',         '10000000-0000-0000-0000-000000000001', '5a000000-0000-0000-0000-000000000001');
select pg_temp.member('bus', 'bus_supervisor',  '10000000-0000-0000-0000-000000000001', '5a000000-0000-0000-0000-000000000001');
select pg_temp.member('so',  'zt_subject_only', '10000000-0000-0000-0000-000000000001', '5a000000-0000-0000-0000-000000000001');
select pg_temp.member('x',   'school_admin',    '20000000-0000-0000-0000-000000000002', '5c000000-0000-0000-0000-000000000003');

-- ============ القراءة حسب المفتاحين والنطاق ============
select pg_temp.run('read.sa',   'sa',  $q$select (select count(*) from public.subjects) || '|' || (select count(*) from public.grade_subjects)$q$);
select pg_temp.run('read.sec',  'sec', $q$select (select count(*) from public.subjects) || '|' || (select count(*) from public.grade_subjects)$q$);
select pg_temp.run('read.tch',  'tch', $q$select (select count(*) from public.subjects) || '|' || (select count(*) from public.grade_subjects)$q$);
select pg_temp.run('read.bus',  'bus', $q$select (select count(*) from public.subjects) || '|' || (select count(*) from public.grade_subjects)$q$);
select pg_temp.run('read.sb',   'sb',  $q$select string_agg(distinct school_id::text, ',') from public.subjects$q$);
select pg_temp.run('read.x',    'x',   $q$select (select count(*) from public.subjects) || '|' || (select count(*) from public.grade_subjects)$q$);

-- ============ الكتابة: subject.manage + النطاق (RLS) ============
select pg_temp.run('w.sec_insert', 'sec', $q$insert into public.subjects (school_id, subject_code, name) values ('5a000000-0000-0000-0000-000000000001', 'SC', 'Science') returning 'ok'$q$);
select pg_temp.run('w.sec_update', 'sec', $q$with u as (update public.subjects set name = 'h' where id = 'a5000000-0000-0000-0000-000000000001' returning 1) select count(*)::text from u$q$);
select pg_temp.run('w.sb_insert',  'sb',  $q$insert into public.subjects (school_id, subject_code, name) values ('5a000000-0000-0000-0000-000000000001', 'SC', 'Science') returning 'ok'$q$);
select pg_temp.run('w.sb_update',  'sb',  $q$with u as (update public.subjects set name = 'h' where id = 'a5000000-0000-0000-0000-000000000001' returning 1) select count(*)::text from u$q$);
select pg_temp.run('w.x_update',   'x',   $q$with u as (update public.grade_subjects set weekly_periods = 1 where id = '65000000-0000-0000-0000-000000000002' returning 1) select count(*)::text from u$q$);
select pg_temp.run('w.sb_gs_insert', 'sb', $q$insert into public.grade_subjects (school_id, academic_year_id, grade_level_id, subject_id, weekly_periods)
  values ('5a000000-0000-0000-0000-000000000001', 'ac000000-0000-0000-0000-000000000002', '61000000-0000-0000-0000-000000000002', 'a5000000-0000-0000-0000-000000000001', 2) returning 'ok'$q$);

-- ============ subjects: الإنشاء والقيود ============
select pg_temp.run('s.insert',    'sa', $q$insert into public.subjects (school_id, subject_code, name) values ('5a000000-0000-0000-0000-000000000001', 'SC', 'Science') returning status$q$);
select pg_temp.run('s.dup_code',  'sa', $q$insert into public.subjects (school_id, subject_code, name) values ('5a000000-0000-0000-0000-000000000001', 'AR', 'Arabic 2') returning 'ok'$q$);
select pg_temp.run('s.dup_name',  'sa', $q$insert into public.subjects (school_id, subject_code, name) values ('5a000000-0000-0000-0000-000000000001', 'AR2', 'Arabic') returning 'ok'$q$);
select pg_temp.run('s.bad_code',  'sa', $q$insert into public.subjects (school_id, subject_code, name) values ('5a000000-0000-0000-0000-000000000001', 'ar', 'x') returning 'ok'$q$);
select pg_temp.run('s.same_code_sb', 'sb', $q$insert into public.subjects (school_id, subject_code, name) values ('5b000000-0000-0000-0000-000000000002', 'MA', 'Math') returning 'ok'$q$);
select pg_temp.run('s.col_code',  'sa', $q$update public.subjects set subject_code = 'ARB' where id = 'a5000000-0000-0000-0000-000000000001' returning 'ok'$q$);
select pg_temp.rec('s.x_code',    $q$update public.subjects set subject_code = 'ARB' where id = 'a5000000-0000-0000-0000-000000000001' returning 'ok'$q$);
select pg_temp.rec('s.x_school',  $q$update public.subjects set school_id = '5b000000-0000-0000-0000-000000000002' where id = 'a5000000-0000-0000-0000-000000000004' returning 'ok'$q$);
select pg_temp.run('s.rename',    'sa', $q$update public.subjects set name = 'Arabic Language' where id = 'a5000000-0000-0000-0000-000000000001' returning name$q$);

-- ============ subjects: التعطيل (الجهة الأولى) ============
select pg_temp.run('s.off_taught',   'sa', $q$update public.subjects set status = 'inactive' where id = 'a5000000-0000-0000-0000-000000000002' returning 'ok'$q$);
select pg_temp.rec('s.x_off_taught', $q$update public.subjects set status = 'inactive' where id = 'a5000000-0000-0000-0000-000000000002' returning 'ok'$q$);
select pg_temp.run('s.off_closed_only', 'sa', $q$update public.subjects set status = 'inactive' where id = 'a5000000-0000-0000-0000-000000000003' returning status$q$);

-- ============ grade_subjects ============
select pg_temp.run('g.insert',        'sa', $q$insert into public.grade_subjects (school_id, academic_year_id, grade_level_id, subject_id, weekly_periods, counts_toward_total)
  values ('5a000000-0000-0000-0000-000000000001', 'ac000000-0000-0000-0000-000000000002', '61000000-0000-0000-0000-000000000002', 'a5000000-0000-0000-0000-000000000001', 5, false) returning status || '|' || counts_toward_total$q$);
select pg_temp.run('g.dup',           'sa', $q$insert into public.grade_subjects (school_id, academic_year_id, grade_level_id, subject_id, weekly_periods)
  values ('5a000000-0000-0000-0000-000000000001', 'ac000000-0000-0000-0000-000000000002', '61000000-0000-0000-0000-000000000001', 'a5000000-0000-0000-0000-000000000001', 2) returning 'ok'$q$);
select pg_temp.run('g.zero',          'sa', $q$insert into public.grade_subjects (school_id, academic_year_id, grade_level_id, subject_id, weekly_periods)
  values ('5a000000-0000-0000-0000-000000000001', 'b0000000-0000-0000-0000-000000000003', '61000000-0000-0000-0000-000000000001', 'a5000000-0000-0000-0000-000000000001', 0) returning 'ok'$q$);
select pg_temp.run('g.closed_year',   'sa', $q$insert into public.grade_subjects (school_id, academic_year_id, grade_level_id, subject_id, weekly_periods)
  values ('5a000000-0000-0000-0000-000000000001', 'c0000000-0000-0000-0000-000000000001', '61000000-0000-0000-0000-000000000001', 'a5000000-0000-0000-0000-000000000001', 2) returning 'ok'$q$);
select pg_temp.run('g.inactive_grade','sa', $q$insert into public.grade_subjects (school_id, academic_year_id, grade_level_id, subject_id, weekly_periods)
  values ('5a000000-0000-0000-0000-000000000001', 'ac000000-0000-0000-0000-000000000002', '61000000-0000-0000-0000-000000000003', 'a5000000-0000-0000-0000-000000000001', 2) returning 'ok'$q$);
select pg_temp.run('g.inactive_subj', 'sa', $q$insert into public.grade_subjects (school_id, academic_year_id, grade_level_id, subject_id, weekly_periods)
  values ('5a000000-0000-0000-0000-000000000001', 'ac000000-0000-0000-0000-000000000002', '61000000-0000-0000-0000-000000000002', 'a5000000-0000-0000-0000-000000000004', 2) returning 'ok'$q$);
select pg_temp.run('g.other_school_subj', 'sa', $q$insert into public.grade_subjects (school_id, academic_year_id, grade_level_id, subject_id, weekly_periods)
  values ('5a000000-0000-0000-0000-000000000001', 'b0000000-0000-0000-0000-000000000003', '61000000-0000-0000-0000-000000000001', 'a5b00000-0000-0000-0000-000000000001', 2) returning 'ok'$q$);
select pg_temp.run('g.blind_closed', 'so', $q$insert into public.grade_subjects (school_id, academic_year_id, grade_level_id, subject_id, weekly_periods)
  values ('5a000000-0000-0000-0000-000000000001', 'c0000000-0000-0000-0000-000000000001', '61000000-0000-0000-0000-000000000002', 'a5000000-0000-0000-0000-000000000001', 2) returning 'ok'$q$);
select pg_temp.run('g.blind_view', 'so', $q$select (select count(*) from public.academic_years) || '|' || (select count(*) from public.grade_levels)$q$);
select pg_temp.run('g.edit',          'sa', $q$update public.grade_subjects set weekly_periods = 6, counts_toward_total = false where id = '65000000-0000-0000-0000-000000000002' returning weekly_periods || '|' || counts_toward_total$q$);
select pg_temp.run('g.col_subject',   'sa', $q$update public.grade_subjects set subject_id = 'a5000000-0000-0000-0000-000000000003' where id = '65000000-0000-0000-0000-000000000002' returning 'ok'$q$);
select pg_temp.rec('g.x_identity',    $q$update public.grade_subjects set grade_level_id = '61000000-0000-0000-0000-000000000002' where id = '65000000-0000-0000-0000-000000000003' returning 'ok'$q$);
select pg_temp.run('g.closed_edit',   'sa', $q$update public.grade_subjects set weekly_periods = 1 where id = '65000000-0000-0000-0000-000000000001' returning 'ok'$q$);
select pg_temp.rec('g.x_closed_noop', $q$update public.grade_subjects set weekly_periods = weekly_periods where id = '65000000-0000-0000-0000-000000000001' returning 'ok'$q$);
select pg_temp.run('g.off',           'sa', $q$update public.grade_subjects set status = 'inactive' where id = '65000000-0000-0000-0000-000000000004' returning status$q$);
-- إعادة تفعيل ربط مادته معطّلة: OLD تُربط أولاً وهي نشطة؟ لا — تُفعَّل OLD، يُنشأ الربط، تُعطَّل الربط ثم المادة، ثم محاولة إعادة الربط
select pg_temp.run('g.re_setup1', 'sa', $q$update public.subjects set status = 'active' where id = 'a5000000-0000-0000-0000-000000000004' returning status$q$);
select pg_temp.run('g.re_setup2', 'sa', $q$insert into public.grade_subjects (school_id, academic_year_id, grade_level_id, subject_id, weekly_periods)
  values ('5a000000-0000-0000-0000-000000000001', 'b0000000-0000-0000-0000-000000000003', '61000000-0000-0000-0000-000000000001', 'a5000000-0000-0000-0000-000000000004', 1) returning status$q$);
select pg_temp.run('g.re_setup3', 'sa', $q$update public.grade_subjects set status = 'inactive' where academic_year_id = 'b0000000-0000-0000-0000-000000000003' and subject_id = 'a5000000-0000-0000-0000-000000000004' returning status$q$);
select pg_temp.run('g.re_setup4', 'sa', $q$update public.subjects set status = 'inactive' where id = 'a5000000-0000-0000-0000-000000000004' returning status$q$);
select pg_temp.run('g.reactivate_inactive_subject', 'sa', $q$update public.grade_subjects set status = 'active' where academic_year_id = 'b0000000-0000-0000-0000-000000000003' and subject_id = 'a5000000-0000-0000-0000-000000000004' returning 'ok'$q$);

-- ============ grade_levels: الجهة الثانية (استبدال T12) ============
select pg_temp.run('gl.off_with_subjects', 'sa', $q$update public.grade_levels set status = 'inactive' where id = '61000000-0000-0000-0000-000000000001' returning 'ok'$q$);
select pg_temp.run('gl.off_closed_only',   'sa', $q$update public.grade_levels set status = 'inactive' where id = '61000000-0000-0000-0000-000000000004' returning status$q$);
select pg_temp.run('gl.prep', 'sa', $q$update public.grade_subjects set status = 'inactive' where academic_year_id = 'ac000000-0000-0000-0000-000000000002' and grade_level_id = '61000000-0000-0000-0000-000000000002' returning status$q$);
select pg_temp.run('gl.off_after',         'sa', $q$update public.grade_levels set status = 'inactive' where id = '61000000-0000-0000-0000-000000000002' returning status$q$);

-- ============ UPDATE أعمى (بلا WHERE ولا RETURNING): سياسة UPDATE وحدها تحكم — سياسة SELECT لا تُطبَّق ============
select pg_temp.rec('blind.before', $q$select md5(string_agg(to_jsonb(t)::text, ';' order by t.id)) from (
  select id, weekly_periods::text as v from public.grade_subjects where school_id = '5a000000-0000-0000-0000-000000000001'
  union all select id, status from public.subjects where school_id = '5a000000-0000-0000-0000-000000000001') t$q$);
select pg_temp.run('blind.gs', 'sb', $q$with u as (update public.grade_subjects set weekly_periods = 59) select 'done'$q$);
select pg_temp.run('blind.s',  'sb', $q$with u as (update public.subjects set status = 'active') select 'done'$q$);
select pg_temp.rec('blind.after', $q$select md5(string_agg(to_jsonb(t)::text, ';' order by t.id)) from (
  select id, weekly_periods::text as v from public.grade_subjects where school_id = '5a000000-0000-0000-0000-000000000001'
  union all select id, status from public.subjects where school_id = '5a000000-0000-0000-0000-000000000001') t$q$);

-- ============ التدقيق ============
select pg_temp.rec('audit.insert', $q$select actor_type || '|' || action || '|' || (school_id = '5a000000-0000-0000-0000-000000000001')::text || '|' ||
    (actor_id = (select p.id from public.profiles p join actors a on a.auth = p.auth_user_id where a.label = 'sa'))::text
  from public.audit_log where entity_type = 'subjects' and new_values ->> 'subject_code' = 'SC' and action = 'insert'$q$);
select pg_temp.rec('audit.rejected', $q$select (select count(*) from public.audit_log where entity_type = 'subjects' and entity_id = 'a5000000-0000-0000-0000-000000000002' and action <> 'insert')
  || '|' || (select count(*) from public.audit_log where entity_type = 'grade_subjects' and entity_id = '65000000-0000-0000-0000-000000000001' and action <> 'insert')$q$);

-- =====================================================================
select plan(6 + 6 + 9 + 3 + 17 + 3 + 2 + 7 + 1);

select ok((select v from r where k = 'blind.gs') = 'done' and (select v from r where k = 'blind.s') = 'done'
          and (select v from r where k = 'blind.after') = (select v from r where k = 'blind.before'),
          'a blind UPDATE (no WHERE, no RETURNING) by a sibling school''s admin touches none of SA''s subjects or links — the UPDATE policy carries the scope');

-- القراءة
select is((select v from r where k = 'read.sa'),  '4|4', 'school_admin reads its school''s subjects and grade subjects');
select is((select v from r where k = 'read.sec'), '4|4', 'secretary: subject.read (B15)');
select is((select v from r where k = 'read.tch'), '4|4', 'teacher: subject.read (B15)');
select is((select v from r where k = 'read.bus'), '0|0', 'bus_supervisor: no subject.read → nothing');
select is((select v from r where k = 'read.sb'),  '5b000000-0000-0000-0000-000000000002', 'a sibling school''s admin sees only its own subjects (§1.1 rule 5)');
select is((select v from r where k = 'read.x'),   '0|0', 'another tenant sees nothing (I1)');

-- الكتابة (RLS)
select ok((select v from r where k = 'w.sec_insert') like 'ERR 42501%row-level security%subjects%', 'subject.read does not grant subject.manage (insert)');
select is((select v from r where k = 'w.sec_update'), '0', 'subject.read does not grant subject.manage (update)');
select ok((select v from r where k = 'w.sb_insert') like 'ERR 42501%row-level security%subjects%', 'a sibling school''s admin cannot create a subject in SA');
select is((select v from r where k = 'w.sb_update'), '0', 'a sibling school''s admin cannot update SA''s subjects');
select is((select v from r where k = 'w.x_update'),  '0', 'another tenant cannot update a grade subject');
select ok((select v from r where k = 'w.sb_gs_insert') like 'ERR 42501%row-level security%grade_subjects%', 'a sibling school''s admin cannot link a subject in SA — the SECURITY DEFINER guard grants nothing');

-- subjects
select is((select v from r where k = 's.insert'),   'active', 'a subject is created active');
select ok((select v from r where k = 's.dup_code') like 'ERR 23505%subjects_school_code_uq%', 'subject code unique within the school');
select ok((select v from r where k = 's.dup_name') like 'ERR 23505%subjects_school_name_uq%', 'subject name unique within the school');
select ok((select v from r where k = 's.bad_code') like 'ERR 23514%subjects_code_chk%', 'subject code format');
select is((select v from r where k = 's.same_code_sb'), 'ok', 'the same code in another school is allowed');
select ok((select v from r where k = 's.col_code') like 'ERR 42501%permission denied%', 'the client cannot change a subject code (column grant)');
select ok((select v from r where k = 's.x_code')   like 'ERR 23514%cannot change its school or code%', 'guard: a subject code is fixed for every role');
select ok((select v from r where k = 's.x_school') like 'ERR 23514%cannot change its school or code%', 'guard: a subject cannot move to another school');
select is((select v from r where k = 's.rename'),  'Arabic Language', 'a subject can be renamed');

-- التعطيل (الجهة الأولى)
select ok((select v from r where k = 's.off_taught')   like 'ERR 23514%taught in a non-closed year%', 'a subject taught in a non-closed year cannot be deactivated');
select ok((select v from r where k = 's.x_off_taught') like 'ERR 23514%taught in a non-closed year%', '… for every role (privileged path)');
select is((select v from r where k = 's.off_closed_only'), 'inactive', 'a subject taught only in a closed year can be deactivated');

-- grade_subjects
select is((select v from r where k = 'g.insert'),      'active|false', 'a grade subject is born active with its periods and total flag');
select ok((select v from r where k = 'g.dup')          like 'ERR 23505%grade_subjects_key_uq%', 'one link per (year, grade level, subject)');
select ok((select v from r where k = 'g.zero')         like 'ERR 23514%grade_subjects_periods_chk%', 'weekly periods must be positive');
select ok((select v from r where k = 'g.closed_year')  like 'ERR 23514%academic year is closed — no new grade subjects%', 'no new link in a closed year');
select ok((select v from r where k = 'g.inactive_grade') like 'ERR 23514%active only under an active grade level%', 'no active link under an inactive grade level');
select ok((select v from r where k = 'g.inactive_subj')  like 'ERR 23514%active only for an active subject%', 'no active link to an inactive subject');
select ok((select v from r where k = 'g.other_school_subj') like 'ERR 23503%grade_subjects_subject_fk%', 'a subject of another school cannot be linked (composite FK)');
select ok((select v from r where k = 'g.blind_closed') like 'ERR 23514%academic year is closed — no new grade subjects%', 'an actor who cannot read years is still stopped by the guard (SECURITY DEFINER)');
select is((select v from r where k = 'g.blind_view'),   '0|0', 'control: that actor reads no year and no grade level');
select is((select v from r where k = 'g.edit'),         '6|false', 'periods and the total flag are editable in an active year');
select ok((select v from r where k = 'g.col_subject')  like 'ERR 42501%permission denied%', 'the client cannot change a link''s subject (column grant)');
select ok((select v from r where k = 'g.x_identity')   like 'ERR 23514%cannot move to another school, year, grade level or subject%', 'guard: a link''s identity is fixed for every role');
select ok((select v from r where k = 'g.closed_edit')  like 'ERR 23514%academic year is closed — its grade subjects cannot be modified%', 'a closed year''s links are frozen');
select ok((select v from r where k = 'g.x_closed_noop') like 'ERR 23514%academic year is closed — its grade subjects cannot be modified%', '… for every role, even a no-op UPDATE');
select is((select v from r where k = 'g.off'),         'inactive', 'a link can be deactivated');
select is((select v from r where k = 'g.re_setup1') || (select v from r where k = 'g.re_setup2') || (select v from r where k = 'g.re_setup3') || (select v from r where k = 'g.re_setup4'),
          'activeactiveinactiveinactive', 'setup: link a reactivated subject, then deactivate the link and the subject');
select ok((select v from r where k = 'g.reactivate_inactive_subject') like 'ERR 23514%active only for an active subject%', 'a link cannot be reactivated while its subject is inactive');

-- grade_levels (الجهة الثانية)
select ok((select v from r where k = 'gl.off_with_subjects') like 'ERR 23514%the grade level has active subjects%', 'a grade level with active links in a non-closed year cannot be deactivated');
select is((select v from r where k = 'gl.off_closed_only'), 'inactive', 'links in a closed year do not block deactivating a grade level');
select is((select v from r where k = 'gl.off_after'),       'inactive', 'G2 deactivates once its links are inactive or in a closed year');

-- التدقيق
select is((select v from r where k = 'audit.insert'),   'tenant_user|insert|true|true', 'a created subject is audited with actor and school');
select is((select v from r where k = 'audit.rejected'), '0|0', 'refused changes leave no audit row');

-- البنية
select is((select count(*)::int from public.permissions), 75, 'catalog: 75 keys (B10)');
select is((select string_agg(r.code, ',' order by r.code) from public.role_permissions rp join public.roles r on r.id = rp.role_id
             join public.permissions p on p.id = rp.permission_id where p.code = 'subject.manage' and r.platform_tenant_id is null),
          'group_manager,school_admin,tenant_admin', 'subject.manage: the three administrators (B15)');
select is((select string_agg(r.code, ',' order by r.code) from public.role_permissions rp join public.roles r on r.id = rp.role_id
             join public.permissions p on p.id = rp.permission_id where p.code = 'subject.read' and r.platform_tenant_id is null),
          'accountant,counselor,group_manager,school_admin,secretary,teacher,tenant_admin', 'subject.read: administrators + secretary, accountant, teacher, counselor (B15)');
select ok((select bool_and(relrowsecurity and relforcerowsecurity) from pg_class where oid in ('public.subjects'::regclass, 'public.grade_subjects'::regclass)), 'RLS enabled and forced on both tables');
select ok(not has_table_privilege('authenticated', 'public.subjects', 'DELETE') and not has_table_privilege('authenticated', 'public.grade_subjects', 'DELETE')
      and not has_table_privilege('anon', 'public.subjects', 'SELECT') and not has_table_privilege('anon', 'public.grade_subjects', 'SELECT'), 'no DELETE for authenticated, nothing for anon');
select is((select string_agg(c.relname || ':' || substring(pg_get_triggerdef(t.oid) from 'TRIGGER \S+ (.*?) ON '), ', ' order by c.relname)
             from pg_trigger t join pg_class c on c.oid = t.tgrelid where t.tgname = 'guard' and c.relname in ('subjects', 'grade_subjects')),
          'grade_subjects:BEFORE INSERT OR UPDATE, subjects:BEFORE UPDATE', 'T13: the two guards');
select is((select count(*)::int from pg_proc p where p.pronamespace = 'app'::regnamespace and p.proname in ('tg_subject_guard', 'tg_grade_subject_guard')
            and p.prosecdef and not has_function_privilege('authenticated', p.oid, 'EXECUTE')), 2, 'guard functions: SECURITY DEFINER, not callable by API roles');

select * from finish();
rollback;
