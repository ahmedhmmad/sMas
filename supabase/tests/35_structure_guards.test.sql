-- M35 — structure_guards (Phase 2A، ف6 + Q7): T12 على sections / grade_levels / stages.
-- شعبة نشطة (في سنة غير مغلقة) ⇒ صف نشط ⇒ مرحلة نشطة، من الجهتين؛ هوية الشعبة ثابتة؛ بنية السنة المغلقة مجمدة؛
-- لا تعطيل لشعبة فيها تسجيلات نشطة. الصلاحية والنطاق تحكمهما RLS — لا الحارس.
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

-- SA: سنة تُغلق (yC)، سنة نشطة (yA)، سنة مخططة (yP)؛ SB: سنة نشطة
insert into public.academic_years (id, school_id, name, start_date, end_date) values
  ('c0000000-0000-0000-0000-000000000001', '5a000000-0000-0000-0000-000000000001', '2025/2026', '2025-09-01', '2026-06-30'),
  ('ac000000-0000-0000-0000-000000000002', '5a000000-0000-0000-0000-000000000001', '2026/2027', '2026-09-01', '2027-06-30'),
  ('b0000000-0000-0000-0000-000000000003', '5a000000-0000-0000-0000-000000000001', '2027/2028', '2027-09-01', '2028-06-30'),
  ('bb000000-0000-0000-0000-000000000004', '5b000000-0000-0000-0000-000000000002', '2026/2027', '2026-09-01', '2027-06-30');

-- المراحل: P (صفوف نشطة)، K (صف واحد g3)، E (فارغة)، X (صف gX)، OFF (معطّلة منذ الإنشاء)؛ SB: مرحلة
insert into public.stages (id, school_id, name, sequence_no, status) values
  ('51000000-0000-0000-0000-000000000001', '5a000000-0000-0000-0000-000000000001', 'P',   1, 'active'),
  ('51000000-0000-0000-0000-000000000002', '5a000000-0000-0000-0000-000000000001', 'K',   2, 'active'),
  ('51000000-0000-0000-0000-000000000003', '5a000000-0000-0000-0000-000000000001', 'E',   3, 'active'),
  ('51000000-0000-0000-0000-000000000004', '5a000000-0000-0000-0000-000000000001', 'X',   4, 'active'),
  ('51000000-0000-0000-0000-000000000005', '5a000000-0000-0000-0000-000000000001', 'OFF', 5, 'inactive'),
  ('5b100000-0000-0000-0000-000000000001', '5b000000-0000-0000-0000-000000000002', 'P',   1, 'active');
-- الصفوف: g1، g2 (P)؛ g3 (K)؛ gH (P) شعبته في السنة المغلقة فقط؛ gX (X)؛ gOff معطّل منذ الإنشاء (P)؛ SB: صف
insert into public.grade_levels (id, school_id, stage_id, name, sequence_no, status) values
  ('61000000-0000-0000-0000-000000000001', '5a000000-0000-0000-0000-000000000001', '51000000-0000-0000-0000-000000000001', 'G1',   1, 'active'),
  ('61000000-0000-0000-0000-000000000002', '5a000000-0000-0000-0000-000000000001', '51000000-0000-0000-0000-000000000001', 'G2',   2, 'active'),
  ('61000000-0000-0000-0000-000000000003', '5a000000-0000-0000-0000-000000000001', '51000000-0000-0000-0000-000000000002', 'G3',   3, 'active'),
  ('61000000-0000-0000-0000-000000000004', '5a000000-0000-0000-0000-000000000001', '51000000-0000-0000-0000-000000000001', 'GH',   4, 'active'),
  ('61000000-0000-0000-0000-000000000005', '5a000000-0000-0000-0000-000000000001', '51000000-0000-0000-0000-000000000004', 'GX',   5, 'active'),
  ('61000000-0000-0000-0000-000000000006', '5a000000-0000-0000-0000-000000000001', '51000000-0000-0000-0000-000000000001', 'GOFF', 6, 'inactive'),
  ('6b100000-0000-0000-0000-000000000001', '5b000000-0000-0000-0000-000000000002', '5b100000-0000-0000-0000-000000000001', 'G1',   1, 'active');
-- الشعب
insert into public.sections (id, school_id, academic_year_id, grade_level_id, name) values
  ('71000000-0000-0000-0000-000000000001', '5a000000-0000-0000-0000-000000000001', 'ac000000-0000-0000-0000-000000000002', '61000000-0000-0000-0000-000000000001', 'A'),   -- secA1: فيها تسجيل نشط
  ('71000000-0000-0000-0000-000000000002', '5a000000-0000-0000-0000-000000000001', 'ac000000-0000-0000-0000-000000000002', '61000000-0000-0000-0000-000000000001', 'B'),   -- secA2: بلا تسجيلات
  ('71000000-0000-0000-0000-000000000003', '5a000000-0000-0000-0000-000000000001', 'ac000000-0000-0000-0000-000000000002', '61000000-0000-0000-0000-000000000003', 'A'),   -- secG3
  ('71000000-0000-0000-0000-000000000004', '5a000000-0000-0000-0000-000000000001', 'b0000000-0000-0000-0000-000000000003', '61000000-0000-0000-0000-000000000001', 'A'),   -- secP: سنة مخططة
  ('71000000-0000-0000-0000-000000000005', '5a000000-0000-0000-0000-000000000001', 'c0000000-0000-0000-0000-000000000001', '61000000-0000-0000-0000-000000000004', 'A'),   -- secC: ستصير في سنة مغلقة
  ('7b100000-0000-0000-0000-000000000001', '5b000000-0000-0000-0000-000000000002', 'bb000000-0000-0000-0000-000000000004', '6b100000-0000-0000-0000-000000000001', 'A');
-- yC تُغلق بمسارها المشروع، ثم yA و yB نشطتان
update public.academic_years set status = 'active' where id = 'c0000000-0000-0000-0000-000000000001';
update public.academic_years set status = 'closed' where id = 'c0000000-0000-0000-0000-000000000001';
update public.academic_years set status = 'active' where id in ('ac000000-0000-0000-0000-000000000002', 'bb000000-0000-0000-0000-000000000004');

-- طالب بتسجيل نشط في secA1
do $$
declare v_a uuid := 'e9000000-0000-0000-0000-000000000009'; v_p uuid; v_scope uuid;
begin
  insert into auth.users (id, email) values (v_a, 'st@m35.invalid');
  insert into public.auth_identities (auth_user_id, kind) values (v_a, 'tenant');
  insert into public.profiles (platform_tenant_id, auth_user_id, display_name) values ('10000000-0000-0000-0000-000000000001', v_a, 'st') returning id into v_p;
  select i.id into v_scope from public.identity_scopes i where i.owner_id = 'a1000000-0000-0000-0000-00000000000a';
  insert into public.students (id, platform_tenant_id, identity_scope_id, student_profile_id, official_id, official_id_type, first_name, family_name)
    values (v_a, '10000000-0000-0000-0000-000000000001', v_scope, v_p, 'N1', 'national_id', 'S', 'T');
  insert into public.enrollments (school_id, student_id, platform_tenant_id, academic_year_id, grade_level_id, section_id, identity_scope_id, scope_owner_id, effective_from)
    values ('5a000000-0000-0000-0000-000000000001', v_a, '10000000-0000-0000-0000-000000000001', 'ac000000-0000-0000-0000-000000000002',
            '61000000-0000-0000-0000-000000000001', '71000000-0000-0000-0000-000000000001', v_scope, 'a1000000-0000-0000-0000-00000000000a', '2026-09-01');
end $$;

-- الفاعلون: أدوار مبذورة + دور مخصص يملك section.manage و section.read وحدهما (لا يقرأ سنة ولا صفاً ولا تسجيلاً)
insert into public.roles (id, platform_tenant_id, code, name) values ('7f000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', 'zt_section_only', 'section only');
insert into public.role_permissions (role_id, permission_id) select '7f000000-0000-0000-0000-000000000001', id from public.permissions where code in ('section.manage', 'section.read');
create function pg_temp.member(p_label text, p_role text, p_tenant uuid, p_school uuid) returns void
language plpgsql as $$
declare v_a uuid := gen_random_uuid(); v_p uuid; v_m uuid; v_role uuid; v_key uuid;
begin
  select id, coalesce(platform_tenant_id, '00000000-0000-0000-0000-000000000000') into v_role, v_key from public.roles where code = p_role;
  insert into auth.users (id, email) values (v_a, p_label || '@m35.invalid');
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
select pg_temp.member('so',  'zt_section_only', '10000000-0000-0000-0000-000000000001', '5a000000-0000-0000-0000-000000000001');
select pg_temp.member('x',   'school_admin',    '20000000-0000-0000-0000-000000000002', '5c000000-0000-0000-0000-000000000003');

-- ============ RLS: الصلاحية والنطاق (لا الحارس) ============
select pg_temp.run('rls.sec_section', 'sec', $q$with u as (update public.sections set name = 'h' where id = '71000000-0000-0000-0000-000000000002' returning 1) select count(*)::text from u$q$);
select pg_temp.run('rls.sb_section',  'sb',  $q$with u as (update public.sections set status = 'inactive' where id = '71000000-0000-0000-0000-000000000002' returning 1) select count(*)::text from u$q$);
select pg_temp.run('rls.x_section',   'x',   $q$with u as (update public.sections set status = 'inactive' where id = '71000000-0000-0000-0000-000000000002' returning 1) select count(*)::text from u$q$);
select pg_temp.run('rls.sb_grade',    'sb',  $q$with u as (update public.grade_levels set status = 'inactive' where id = '61000000-0000-0000-0000-000000000005' returning 1) select count(*)::text from u$q$);
select pg_temp.run('rls.sb_stage',    'sb',  $q$with u as (update public.stages set status = 'inactive' where id = '51000000-0000-0000-0000-000000000003' returning 1) select count(*)::text from u$q$);
select pg_temp.run('rls.sb_insert',   'sb',  $q$insert into public.sections (school_id, academic_year_id, grade_level_id, name)
  values ('5a000000-0000-0000-0000-000000000001', 'ac000000-0000-0000-0000-000000000002', '61000000-0000-0000-0000-000000000002', 'hijack') returning 'ok'$q$);
select pg_temp.run('rls.sec_read',    'sec', $q$select count(*)::text from public.sections$q$);

-- ============ sections: الهوية ثابتة ============
select pg_temp.run('s.col_year',   'sa', $q$update public.sections set academic_year_id = 'b0000000-0000-0000-0000-000000000003' where id = '71000000-0000-0000-0000-000000000002' returning 'ok'$q$);
select pg_temp.run('s.col_grade',  'sa', $q$update public.sections set grade_level_id = '61000000-0000-0000-0000-000000000002' where id = '71000000-0000-0000-0000-000000000002' returning 'ok'$q$);
select pg_temp.run('s.col_school', 'sa', $q$update public.sections set school_id = '5b000000-0000-0000-0000-000000000002' where id = '71000000-0000-0000-0000-000000000002' returning 'ok'$q$);
select pg_temp.rec('s.x_year',     $q$update public.sections set academic_year_id = 'b0000000-0000-0000-0000-000000000003', name = 'Z' where id = '71000000-0000-0000-0000-000000000002' returning 'ok'$q$);
select pg_temp.rec('s.x_grade',    $q$update public.sections set grade_level_id = '61000000-0000-0000-0000-000000000002' where id = '71000000-0000-0000-0000-000000000002' returning 'ok'$q$);

-- ============ sections: الإنشاء وفق حالة السنة والصف ============
select pg_temp.run('s.ins_active_year',  'sa', $q$insert into public.sections (school_id, academic_year_id, grade_level_id, name, capacity, gender_policy)
  values ('5a000000-0000-0000-0000-000000000001', 'ac000000-0000-0000-0000-000000000002', '61000000-0000-0000-0000-000000000002', 'A', 25, 'female_only') returning status$q$);
select pg_temp.run('s.ins_planned_year', 'sa', $q$insert into public.sections (school_id, academic_year_id, grade_level_id, name)
  values ('5a000000-0000-0000-0000-000000000001', 'b0000000-0000-0000-0000-000000000003', '61000000-0000-0000-0000-000000000002', 'A') returning status$q$);
select pg_temp.run('s.ins_closed_year',  'sa', $q$insert into public.sections (school_id, academic_year_id, grade_level_id, name)
  values ('5a000000-0000-0000-0000-000000000001', 'c0000000-0000-0000-0000-000000000001', '61000000-0000-0000-0000-000000000001', 'A') returning 'ok'$q$);
select pg_temp.run('s.ins_inactive_grade', 'sa', $q$insert into public.sections (school_id, academic_year_id, grade_level_id, name)
  values ('5a000000-0000-0000-0000-000000000001', 'ac000000-0000-0000-0000-000000000002', '61000000-0000-0000-0000-000000000006', 'A') returning 'ok'$q$);
-- فاعل لا يرى السنة ولا الصف: الحارس يراهما (SECURITY DEFINER)
select pg_temp.run('s.blind_view',        'so', $q$select (select count(*) from public.academic_years) || '|' || (select count(*) from public.grade_levels) || '|' || (select count(*) from public.enrollments)$q$);
select pg_temp.run('s.blind_closed_year', 'so', $q$insert into public.sections (school_id, academic_year_id, grade_level_id, name)
  values ('5a000000-0000-0000-0000-000000000001', 'c0000000-0000-0000-0000-000000000001', '61000000-0000-0000-0000-000000000001', 'B') returning 'ok'$q$);
select pg_temp.run('s.blind_inactive_grade', 'so', $q$insert into public.sections (school_id, academic_year_id, grade_level_id, name)
  values ('5a000000-0000-0000-0000-000000000001', 'ac000000-0000-0000-0000-000000000002', '61000000-0000-0000-0000-000000000006', 'B') returning 'ok'$q$);

-- ============ sections: السنة المغلقة مجمدة ============
select pg_temp.run('s.closed_edit',  'sa', $q$update public.sections set name = 'late' where id = '71000000-0000-0000-0000-000000000005' returning 'ok'$q$);
select pg_temp.run('s.closed_off',   'sa', $q$update public.sections set status = 'inactive' where id = '71000000-0000-0000-0000-000000000005' returning 'ok'$q$);
select pg_temp.rec('s.x_closed_noop', $q$update public.sections set name = name where id = '71000000-0000-0000-0000-000000000005' returning 'ok'$q$);

-- ============ sections: التعطيل وإعادة التفعيل ============
select pg_temp.run('s.off_enrolled',   'sa', $q$update public.sections set status = 'inactive' where id = '71000000-0000-0000-0000-000000000001' returning 'ok'$q$);
select pg_temp.run('s.blind_enrolled', 'so', $q$update public.sections set status = 'inactive' where id = '71000000-0000-0000-0000-000000000001' returning 'ok'$q$);
select pg_temp.rec('s.x_off_enrolled', $q$update public.sections set status = 'inactive' where id = '71000000-0000-0000-0000-000000000001' returning 'ok'$q$);
select pg_temp.run('s.edit_enrolled',  'sa', $q$update public.sections set name = 'A*', capacity = 30, gender_policy = 'male_only' where id = '71000000-0000-0000-0000-000000000001' returning name || '|' || capacity || '|' || gender_policy || '|' || status$q$);
select pg_temp.run('s.off_empty',      'sa', $q$update public.sections set status = 'inactive' where id = '71000000-0000-0000-0000-000000000002' returning status$q$);
select pg_temp.run('s.on_again',       'sa', $q$update public.sections set status = 'active' where id = '71000000-0000-0000-0000-000000000002' returning status$q$);
select pg_temp.run('s.planned_edit',   'sa', $q$update public.sections set name = 'A-next', status = 'inactive' where id = '71000000-0000-0000-0000-000000000004' returning name || '|' || status$q$);
select pg_temp.run('s.planned_on',     'sa', $q$update public.sections set status = 'active' where id = '71000000-0000-0000-0000-000000000004' returning status$q$);

-- ============ grade_levels ============
select pg_temp.run('g.off_with_sections', 'sa', $q$update public.grade_levels set status = 'inactive' where id = '61000000-0000-0000-0000-000000000001' returning 'ok'$q$);
select pg_temp.rec('g.x_off_with_sections', $q$update public.grade_levels set status = 'inactive' where id = '61000000-0000-0000-0000-000000000001' returning 'ok'$q$);
-- gH: شعبته الوحيدة في السنة المغلقة — لا تمنع
select pg_temp.run('g.off_closed_only', 'sa', $q$update public.grade_levels set status = 'inactive' where id = '61000000-0000-0000-0000-000000000004' returning status$q$);
-- g3: شعبته نشطة ← يُرفض؛ تُعطَّل الشعبة ← يُقبل؛ ثم الشعبة لا تُفعَّل تحت صف معطَّل
select pg_temp.run('g3.off_blocked',   'sa', $q$update public.grade_levels set status = 'inactive' where id = '61000000-0000-0000-0000-000000000003' returning 'ok'$q$);
select pg_temp.run('g3.section_off',   'sa', $q$update public.sections set status = 'inactive' where id = '71000000-0000-0000-0000-000000000003' returning status$q$);
select pg_temp.run('g3.off',           'sa', $q$update public.grade_levels set status = 'inactive' where id = '61000000-0000-0000-0000-000000000003' returning status$q$);
select pg_temp.run('g3.section_on',    'sa', $q$update public.sections set status = 'active' where id = '71000000-0000-0000-0000-000000000003' returning 'ok'$q$);
select pg_temp.run('g3.section_edit',  'sa', $q$update public.sections set name = 'A-old' where id = '71000000-0000-0000-0000-000000000003' returning name$q$);
-- الصف والمرحلة
select pg_temp.run('g.col_school',     'sa', $q$update public.grade_levels set school_id = '5b000000-0000-0000-0000-000000000002' where id = '61000000-0000-0000-0000-000000000002' returning 'ok'$q$);
select pg_temp.rec('g.x_school',       $q$update public.grade_levels set school_id = '5b000000-0000-0000-0000-000000000002', stage_id = '5b100000-0000-0000-0000-000000000001' where id = '61000000-0000-0000-0000-000000000002' returning 'ok'$q$);
select pg_temp.run('g.ins_inactive_stage', 'sa', $q$insert into public.grade_levels (school_id, stage_id, name, sequence_no) values ('5a000000-0000-0000-0000-000000000001', '51000000-0000-0000-0000-000000000005', 'G9', 9) returning 'ok'$q$);
select pg_temp.run('g.move_inactive_stage', 'sa', $q$update public.grade_levels set stage_id = '51000000-0000-0000-0000-000000000005' where id = '61000000-0000-0000-0000-000000000002' returning 'ok'$q$);
select pg_temp.run('g.move_active_stage',  'sa', $q$update public.grade_levels set stage_id = '51000000-0000-0000-0000-000000000003' where id = '61000000-0000-0000-0000-000000000002' returning stage_id::text$q$);
select pg_temp.run('g.on_inactive_stage',  'sa', $q$update public.grade_levels set status = 'active', stage_id = '51000000-0000-0000-0000-000000000005' where id = '61000000-0000-0000-0000-000000000006' returning 'ok'$q$);
select pg_temp.run('g.on_active_stage',    'sa', $q$update public.grade_levels set status = 'active' where id = '61000000-0000-0000-0000-000000000006' returning status$q$);
select pg_temp.run('g.ins_ok',             'sa', $q$insert into public.grade_levels (school_id, stage_id, name, sequence_no) values ('5a000000-0000-0000-0000-000000000001', '51000000-0000-0000-0000-000000000001', 'G7', 7) returning status$q$);

-- ============ stages ============
select pg_temp.run('st.off_with_grades', 'sa', $q$update public.stages set status = 'inactive' where id = '51000000-0000-0000-0000-000000000001' returning 'ok'$q$);
select pg_temp.rec('st.x_off_with_grades', $q$update public.stages set status = 'inactive' where id = '51000000-0000-0000-0000-000000000001' returning 'ok'$q$);
-- X: صفها gX نشط ← يُرفض؛ يُعطَّل الصف ← يُقبل؛ ثم الصف لا يُفعَّل تحت مرحلة معطّلة
select pg_temp.run('stx.off_blocked', 'sa', $q$update public.stages set status = 'inactive' where id = '51000000-0000-0000-0000-000000000004' returning 'ok'$q$);
select pg_temp.run('stx.grade_off',   'sa', $q$update public.grade_levels set status = 'inactive' where id = '61000000-0000-0000-0000-000000000005' returning status$q$);
select pg_temp.run('stx.off',         'sa', $q$update public.stages set status = 'inactive' where id = '51000000-0000-0000-0000-000000000004' returning status$q$);
select pg_temp.run('stx.grade_on',    'sa', $q$update public.grade_levels set status = 'active' where id = '61000000-0000-0000-0000-000000000005' returning 'ok'$q$);
select pg_temp.run('stx.on',          'sa', $q$update public.stages set status = 'active' where id = '51000000-0000-0000-0000-000000000004' returning status$q$);
select pg_temp.run('st.rename',       'sa', $q$update public.stages set name = 'Primary', sequence_no = 11 where id = '51000000-0000-0000-0000-000000000001' returning name || '|' || sequence_no$q$);
select pg_temp.run('st.col_school',   'sa', $q$update public.stages set school_id = '5b000000-0000-0000-0000-000000000002' where id = '51000000-0000-0000-0000-000000000003' returning 'ok'$q$);
select pg_temp.rec('st.x_school',     $q$update public.stages set school_id = '5b000000-0000-0000-0000-000000000002' where id = '51000000-0000-0000-0000-000000000003' returning 'ok'$q$);

-- ============ التدقيق ============
select pg_temp.rec('audit.section_off', $q$select actor_type || '|' || action || '|' || (old_values ->> 'status') || '>' || (new_values ->> 'status') || '|' || (school_id = '5a000000-0000-0000-0000-000000000001')::text || '|' ||
    (actor_id = (select p.id from public.profiles p join actors a on a.auth = p.auth_user_id where a.label = 'sa'))::text
  from public.audit_log where entity_type = 'sections' and entity_id = '71000000-0000-0000-0000-000000000002' and new_values ->> 'status' = 'inactive'$q$);
select pg_temp.rec('audit.grade_off', $q$select actor_type || '|' || action || '|' || (old_values ->> 'status') || '>' || (new_values ->> 'status')
  from public.audit_log where entity_type = 'grade_levels' and entity_id = '61000000-0000-0000-0000-000000000003' and action = 'update'$q$);
select pg_temp.rec('audit.stage_off', $q$select string_agg((old_values ->> 'status') || '>' || (new_values ->> 'status'), ',' order by id)
  from public.audit_log where entity_type = 'stages' and entity_id = '51000000-0000-0000-0000-000000000004' and action = 'update'$q$);
select pg_temp.rec('audit.rejected', $q$select (select count(*) from public.audit_log where entity_type = 'sections' and entity_id = '71000000-0000-0000-0000-000000000005' and action <> 'insert')
  || '|' || (select count(*) from public.audit_log where entity_type = 'sections' and entity_id = '71000000-0000-0000-0000-000000000001' and new_values ->> 'status' = 'inactive')
  || '|' || (select count(*) from public.audit_log where entity_type = 'stages' and entity_id = '51000000-0000-0000-0000-000000000001' and new_values ->> 'status' = 'inactive')$q$);

-- =====================================================================
select plan(7 + 5 + 7 + 3 + 8 + 16 + 10 + 4 + 6);

-- RLS
select is((select v from r where k = 'rls.sec_section'), '0', 'RLS: section.read without section.manage updates nothing');
select is((select v from r where k = 'rls.sb_section'),  '0', 'RLS: a sibling school''s admin cannot touch a section (§1.1 rule 5)');
select is((select v from r where k = 'rls.x_section'),   '0', 'RLS: another tenant cannot touch a section (I1)');
select is((select v from r where k = 'rls.sb_grade'),    '0', 'RLS: a sibling school''s admin cannot touch a grade level');
select is((select v from r where k = 'rls.sb_stage'),    '0', 'RLS: a sibling school''s admin cannot touch a stage');
select ok((select v from r where k = 'rls.sb_insert') like 'ERR 42501%row-level security%sections%', 'RLS: a valid section in another school is rejected — the SECURITY DEFINER guard grants nothing');
select is((select v from r where k = 'rls.sec_read'),    '5', 'section.read still reads the school''s sections');

-- sections: identity
select ok((select v from r where k = 's.col_year')   like 'ERR 42501%permission denied%', 'the client cannot change a section''s year (column grant)');
select ok((select v from r where k = 's.col_grade')  like 'ERR 42501%permission denied%', 'the client cannot change a section''s grade level');
select ok((select v from r where k = 's.col_school') like 'ERR 42501%permission denied%', 'the client cannot change a section''s school');
select ok((select v from r where k = 's.x_year')     like 'ERR 23514%cannot move to another school, year or grade level%', 'guard: a section cannot move to another year (privileged path)');
select ok((select v from r where k = 's.x_grade')    like 'ERR 23514%cannot move to another school, year or grade level%', 'guard: a section cannot move to another grade level (privileged path)');

-- sections: creation
select is((select v from r where k = 's.ins_active_year'),  'active', 'a section can be created in an active year');
select is((select v from r where k = 's.ins_planned_year'), 'active', 'a section can be created in a planned year');
select ok((select v from r where k = 's.ins_closed_year')    like 'ERR 23514%academic year is closed — no new sections%', 'no new section in a closed year');
select ok((select v from r where k = 's.ins_inactive_grade') like 'ERR 23514%active only under an active grade level%', 'no active section under an inactive grade level');
select is((select v from r where k = 's.blind_view'), '0|0|0', 'control: an actor with section.manage/read only reads no year, grade level or enrollment');
select ok((select v from r where k = 's.blind_closed_year')    like 'ERR 23514%academic year is closed — no new sections%', '… yet the guard sees the closed year for that actor (SECURITY DEFINER)');
select ok((select v from r where k = 's.blind_inactive_grade') like 'ERR 23514%active only under an active grade level%', '… and the inactive grade level');

-- sections: closed year
select ok((select v from r where k = 's.closed_edit')   like 'ERR 23514%academic year is closed — its sections cannot be modified%', 'closed year: its sections cannot be renamed');
select ok((select v from r where k = 's.closed_off')    like 'ERR 23514%academic year is closed — its sections cannot be modified%', 'closed year: its sections cannot be deactivated');
select ok((select v from r where k = 's.x_closed_noop') like 'ERR 23514%academic year is closed — its sections cannot be modified%', 'closed year: frozen for every role, even a no-op UPDATE');

-- sections: deactivate / reactivate
select ok((select v from r where k = 's.off_enrolled')   like 'ERR 23514%the section has active enrollments%', 'a section with active enrollments cannot be deactivated');
select ok((select v from r where k = 's.blind_enrolled') like 'ERR 23514%the section has active enrollments%', '… even for an actor who cannot read enrollments (SECURITY DEFINER)');
select ok((select v from r where k = 's.x_off_enrolled') like 'ERR 23514%the section has active enrollments%', '… and for every role (privileged path)');
select is((select v from r where k = 's.edit_enrolled'), 'A*|30|male_only|active', 'enrollments do not block ordinary edits: name, capacity, gender policy');
select is((select v from r where k = 's.off_empty'),     'inactive', 'a section without active enrollments can be deactivated');
select is((select v from r where k = 's.on_again'),      'active',   '… and reactivated');
select is((select v from r where k = 's.planned_edit'),  'A-next|inactive', 'planned year: its sections are editable');
select is((select v from r where k = 's.planned_on'),    'active',   'planned year: a section can be reactivated');

-- grade levels
select ok((select v from r where k = 'g.off_with_sections')   like 'ERR 23514%the grade level has active sections%', 'a grade level with active sections cannot be deactivated');
select ok((select v from r where k = 'g.x_off_with_sections') like 'ERR 23514%the grade level has active sections%', '… for every role (privileged path)');
select is((select v from r where k = 'g.off_closed_only'), 'inactive', 'sections of a closed year do not block deactivating a grade level');
select ok((select v from r where k = 'g3.off_blocked') like 'ERR 23514%the grade level has active sections%', 'G3: blocked while its section is active');
select is((select v from r where k = 'g3.section_off'), 'inactive', 'G3: its section is deactivated first');
select is((select v from r where k = 'g3.off'),         'inactive', 'G3: then the grade level can be deactivated');
select ok((select v from r where k = 'g3.section_on') like 'ERR 23514%active only under an active grade level%', 'a section cannot be reactivated under an inactive grade level');
select is((select v from r where k = 'g3.section_edit'), 'A-old', '… but an inactive section there can still be edited');
select ok((select v from r where k = 'g.col_school') like 'ERR 42501%permission denied%', 'the client cannot change a grade level''s school');
select ok((select v from r where k = 'g.x_school')   like 'ERR 23514%a grade level cannot move to another school%', 'guard: a grade level cannot move to another school (privileged path)');
select ok((select v from r where k = 'g.ins_inactive_stage')  like 'ERR 23514%active only under an active stage%', 'no active grade level is created under an inactive stage');
select ok((select v from r where k = 'g.move_inactive_stage') like 'ERR 23514%active only under an active stage%', 'an active grade level cannot move to an inactive stage');
select is((select v from r where k = 'g.move_active_stage'), '51000000-0000-0000-0000-000000000003', 'a grade level can move to another active stage of its school');
select ok((select v from r where k = 'g.on_inactive_stage')   like 'ERR 23514%active only under an active stage%', 'a grade level cannot be activated under an inactive stage');
select is((select v from r where k = 'g.on_active_stage'), 'active', 'an inactive grade level is reactivated under its active stage');
select is((select v from r where k = 'g.ins_ok'),          'active', 'a grade level is created under an active stage');

-- stages
select ok((select v from r where k = 'st.off_with_grades')   like 'ERR 23514%the stage has active grade levels%', 'a stage with active grade levels cannot be deactivated');
select ok((select v from r where k = 'st.x_off_with_grades') like 'ERR 23514%the stage has active grade levels%', '… for every role (privileged path)');
select ok((select v from r where k = 'stx.off_blocked') like 'ERR 23514%the stage has active grade levels%', 'stage X: blocked while its grade level is active');
select is((select v from r where k = 'stx.grade_off'), 'inactive', 'stage X: its grade level is deactivated first');
select is((select v from r where k = 'stx.off'),       'inactive', 'stage X: then the stage can be deactivated');
select ok((select v from r where k = 'stx.grade_on') like 'ERR 23514%active only under an active stage%', 'a grade level cannot be reactivated under an inactive stage');
select is((select v from r where k = 'stx.on'),        'active',   'a stage can be reactivated');
select is((select v from r where k = 'st.rename'),     'Primary|11', 'a stage with active grade levels can still be renamed and reordered');
select ok((select v from r where k = 'st.col_school') like 'ERR 42501%permission denied%', 'the client cannot change a stage''s school');
select ok((select v from r where k = 'st.x_school')   like 'ERR 23514%a stage cannot move to another school%', 'guard: a stage cannot move to another school (privileged path)');

-- audit
select is((select v from r where k = 'audit.section_off'), 'tenant_user|update|active>inactive|true|true', 'an allowed deactivation is audited: actor, old/new state, school');
select is((select v from r where k = 'audit.grade_off'),   'tenant_user|update|active>inactive', 'grade level deactivation is audited');
select is((select v from r where k = 'audit.stage_off'),   'active>inactive,inactive>active', 'stage deactivation and reactivation are audited');
select is((select v from r where k = 'audit.rejected'),    '0|0|0', 'rejected writes leave no audit row');

-- structure
select is((select string_agg(c.relname || ':' || substring(pg_get_triggerdef(t.oid) from 'TRIGGER \S+ (.*?) ON ') || ':' || t.tgfoid::regproc::text, ', ' order by c.relname)
             from pg_trigger t join pg_class c on c.oid = t.tgrelid where t.tgname = 'guard' and c.relname in ('sections', 'grade_levels', 'stages')),
          'grade_levels:BEFORE INSERT OR UPDATE:app.tg_grade_level_guard, sections:BEFORE INSERT OR UPDATE:app.tg_section_guard, stages:BEFORE UPDATE:app.tg_stage_guard',
          'T12: three row-level BEFORE guards');
select is((select count(*)::int from pg_proc p where p.pronamespace = 'app'::regnamespace and p.proname in ('tg_section_guard', 'tg_grade_level_guard', 'tg_stage_guard')
            and p.prosecdef and pg_get_userbyid(p.proowner) = 'app_owner'
            and not has_function_privilege('authenticated', p.oid, 'EXECUTE') and not has_function_privilege('anon', p.oid, 'EXECUTE')), 3,
          'the guard functions are owned by app_owner, SECURITY DEFINER, and not callable by API roles');
select is((select string_agg(column_name, ',' order by column_name) from information_schema.column_privileges
            where table_schema = 'public' and table_name = 'sections' and grantee = 'authenticated' and privilege_type = 'UPDATE'),
          'capacity,gender_policy,name,status', 'column register: a section''s school, year and grade level are not client-writable after creation');
select is((select string_agg(column_name, ',' order by column_name) from information_schema.column_privileges
            where table_schema = 'public' and table_name = 'grade_levels' and grantee = 'authenticated' and privilege_type = 'UPDATE'),
          'name,sequence_no,stage_id,status', 'column register: a grade level''s school is fixed');
select is((select string_agg(column_name, ',' order by column_name) from information_schema.column_privileges
            where table_schema = 'public' and table_name = 'stages' and grantee = 'authenticated' and privilege_type = 'UPDATE'),
          'name,sequence_no,status', 'column register: a stage''s school is fixed');
select is((select count(*)::int from public.permissions where code !~ '^subject\.'), 73, 'no new permission key from this migration (73 frozen; subject.* is B10, M38)');

select * from finish();
rollback;
