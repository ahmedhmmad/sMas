-- M48 — teaching_assignments / class_teacher_assignments (Phase 3A / 3-3): القيود الإعلانية بأسمائها، T17 قاعدةً قاعدة،
-- RLS (staff.read / staff.assign + نطاق المدرسة)، لا UPDATE ولا DELETE للعميل، الإنهاء بالدالتين، والاستبدال (إنهاء ثم إدراج).
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

-- p_reason: ما يضعه الـAPI في app.audit_reason داخل معاملة الكتابة (C3)؛ NULL = بلا سبب
create function pg_temp.run(p_key text, p_label text, p_sql text, p_reason text default null) returns void
language plpgsql as $$
declare v_sub uuid := (select auth from actors where label = p_label);
begin
  perform set_config('request.jwt.claims', json_build_object('sub', v_sub, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', v_sub::text, true);
  perform set_config('app.audit_reason', coalesce(p_reason, ''), true);
  execute 'set local role authenticated';
  perform pg_temp.rec(p_key, p_sql);
  insert into r values (p_key || '#ctx', coalesce(current_setting('app.audit_action', true), '') || '|' || coalesce(current_setting('app.audit_reason', true), ''))
    on conflict (k) do update set v = excluded.v;
  execute 'reset role';
  perform set_config('app.audit_reason', '', true);
end $$;

-- ============ Fixture ============
insert into public.platform_tenants (id, tenant_code, host_label, name) values
  ('10000000-0000-0000-0000-000000000001', 'T1', 't1', 'T1'), ('20000000-0000-0000-0000-000000000002', 'T2', 't2', 'T2');
insert into public.groups (id, platform_tenant_id, group_code, name) values ('a1000000-0000-0000-0000-00000000000a', '10000000-0000-0000-0000-000000000001', 'GA', 'GA');
insert into public.schools (id, platform_tenant_id, group_id, school_code, name, slug) values
  ('5a000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', 'a1000000-0000-0000-0000-00000000000a', 'SA', 'SA', 'sa'),
  ('5b000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001', 'a1000000-0000-0000-0000-00000000000a', 'SB', 'SB', 'sb'),
  ('5c000000-0000-0000-0000-000000000003', '20000000-0000-0000-0000-000000000002', null,                                   'SX', 'SX', 'sx');
-- SA: yC (تُغلق)، yA (نشطة)، yP (planned)؛ SB: yB؛ SX: yX
insert into public.academic_years (id, school_id, name, start_date, end_date) values
  ('c0000000-0000-0000-0000-000000000001', '5a000000-0000-0000-0000-000000000001', '2025', '2025-09-01', '2026-06-30'),
  ('a0000000-0000-0000-0000-000000000002', '5a000000-0000-0000-0000-000000000001', '2026', '2026-09-01', '2027-06-30'),
  ('b0000000-0000-0000-0000-000000000003', '5a000000-0000-0000-0000-000000000001', '2027', '2027-09-01', '2028-06-30'),
  ('bb000000-0000-0000-0000-000000000004', '5b000000-0000-0000-0000-000000000002', '2027', '2027-09-01', '2028-06-30'),
  ('cc000000-0000-0000-0000-000000000005', '5c000000-0000-0000-0000-000000000003', '2027', '2027-09-01', '2028-06-30');
insert into public.stages (id, school_id, name, sequence_no) values
  ('51000000-0000-0000-0000-000000000001', '5a000000-0000-0000-0000-000000000001', 'P', 1),
  ('52000000-0000-0000-0000-000000000002', '5b000000-0000-0000-0000-000000000002', 'P', 1),
  ('53000000-0000-0000-0000-000000000003', '5c000000-0000-0000-0000-000000000003', 'P', 1);
insert into public.grade_levels (id, school_id, stage_id, name, sequence_no) values
  ('61000000-0000-0000-0000-000000000001', '5a000000-0000-0000-0000-000000000001', '51000000-0000-0000-0000-000000000001', 'G1', 1),
  ('61000000-0000-0000-0000-000000000002', '5a000000-0000-0000-0000-000000000001', '51000000-0000-0000-0000-000000000001', 'G2', 2),
  ('62000000-0000-0000-0000-000000000001', '5b000000-0000-0000-0000-000000000002', '52000000-0000-0000-0000-000000000002', 'G1', 1),
  ('63000000-0000-0000-0000-000000000001', '5c000000-0000-0000-0000-000000000003', '53000000-0000-0000-0000-000000000003', 'G1', 1);
-- الشعب: secP1/secP2/secOff (yP، G1)، secP_G2 (yP، G2)، secA (yA)، secC (yC)، secB (SB)، secX (SX)
insert into public.sections (id, school_id, academic_year_id, grade_level_id, name) values
  ('5ec00000-0000-0000-0000-0000000000a1', '5a000000-0000-0000-0000-000000000001', 'b0000000-0000-0000-0000-000000000003', '61000000-0000-0000-0000-000000000001', 'P1'),
  ('5ec00000-0000-0000-0000-0000000000a2', '5a000000-0000-0000-0000-000000000001', 'b0000000-0000-0000-0000-000000000003', '61000000-0000-0000-0000-000000000001', 'P2'),
  ('5ec00000-0000-0000-0000-0000000000a3', '5a000000-0000-0000-0000-000000000001', 'b0000000-0000-0000-0000-000000000003', '61000000-0000-0000-0000-000000000001', 'Off'),
  ('5ec00000-0000-0000-0000-0000000000a4', '5a000000-0000-0000-0000-000000000001', 'b0000000-0000-0000-0000-000000000003', '61000000-0000-0000-0000-000000000002', 'G2'),
  ('5ec00000-0000-0000-0000-0000000000a5', '5a000000-0000-0000-0000-000000000001', 'a0000000-0000-0000-0000-000000000002', '61000000-0000-0000-0000-000000000001', 'A'),
  ('5ec00000-0000-0000-0000-0000000000a6', '5a000000-0000-0000-0000-000000000001', 'c0000000-0000-0000-0000-000000000001', '61000000-0000-0000-0000-000000000001', 'C'),
  ('5ec00000-0000-0000-0000-0000000000b1', '5b000000-0000-0000-0000-000000000002', 'bb000000-0000-0000-0000-000000000004', '62000000-0000-0000-0000-000000000001', 'B'),
  ('5ec00000-0000-0000-0000-0000000000c1', '5c000000-0000-0000-0000-000000000003', 'cc000000-0000-0000-0000-000000000005', '63000000-0000-0000-0000-000000000001', 'X');
-- المواد: AR، MA، OLD (تُعطَّل)، GEO (ربطها معطَّل)، UNL (غير مربوطة بالصف)؛ SB: ARb؛ SX: ARx
insert into public.subjects (id, school_id, subject_code, name) values
  ('5e000000-0000-0000-0000-000000000001', '5a000000-0000-0000-0000-000000000001', 'AR',  'Arabic'),
  ('5e000000-0000-0000-0000-000000000002', '5a000000-0000-0000-0000-000000000001', 'MA',  'Math'),
  ('5e000000-0000-0000-0000-000000000003', '5a000000-0000-0000-0000-000000000001', 'OLD', 'Old'),
  ('5e000000-0000-0000-0000-000000000004', '5a000000-0000-0000-0000-000000000001', 'GEO', 'Geo'),
  ('5e000000-0000-0000-0000-000000000005', '5a000000-0000-0000-0000-000000000001', 'UNL', 'Unlinked'),
  ('5e000000-0000-0000-0000-0000000000b1', '5b000000-0000-0000-0000-000000000002', 'AR',  'Arabic'),
  ('5e000000-0000-0000-0000-0000000000c1', '5c000000-0000-0000-0000-000000000003', 'AR',  'Arabic');
insert into public.grade_subjects (school_id, academic_year_id, grade_level_id, subject_id, weekly_periods) values
  ('5a000000-0000-0000-0000-000000000001', 'b0000000-0000-0000-0000-000000000003', '61000000-0000-0000-0000-000000000001', '5e000000-0000-0000-0000-000000000001', 5),
  ('5a000000-0000-0000-0000-000000000001', 'b0000000-0000-0000-0000-000000000003', '61000000-0000-0000-0000-000000000001', '5e000000-0000-0000-0000-000000000002', 4),
  ('5a000000-0000-0000-0000-000000000001', 'b0000000-0000-0000-0000-000000000003', '61000000-0000-0000-0000-000000000001', '5e000000-0000-0000-0000-000000000004', 2),
  ('5a000000-0000-0000-0000-000000000001', 'a0000000-0000-0000-0000-000000000002', '61000000-0000-0000-0000-000000000001', '5e000000-0000-0000-0000-000000000001', 5),
  ('5a000000-0000-0000-0000-000000000001', 'c0000000-0000-0000-0000-000000000001', '61000000-0000-0000-0000-000000000001', '5e000000-0000-0000-0000-000000000001', 5),
  ('5a000000-0000-0000-0000-000000000001', 'c0000000-0000-0000-0000-000000000001', '61000000-0000-0000-0000-000000000001', '5e000000-0000-0000-0000-000000000003', 1),
  ('5b000000-0000-0000-0000-000000000002', 'bb000000-0000-0000-0000-000000000004', '62000000-0000-0000-0000-000000000001', '5e000000-0000-0000-0000-0000000000b1', 5),
  ('5c000000-0000-0000-0000-000000000003', 'cc000000-0000-0000-0000-000000000005', '63000000-0000-0000-0000-000000000001', '5e000000-0000-0000-0000-0000000000c1', 5);
-- OLD: مربوطة في yP أيضاً ثم يُعطَّل ربطها والمادة (الربط في yC المغلقة يبقى)
insert into public.grade_subjects (school_id, academic_year_id, grade_level_id, subject_id, weekly_periods, status) values
  ('5a000000-0000-0000-0000-000000000001', 'b0000000-0000-0000-0000-000000000003', '61000000-0000-0000-0000-000000000001', '5e000000-0000-0000-0000-000000000003', 1, 'inactive');
update public.grade_subjects set status = 'inactive'
 where academic_year_id = 'b0000000-0000-0000-0000-000000000003' and subject_id = '5e000000-0000-0000-0000-000000000004';   -- GEO: المادة نشطة والربط معطَّل
update public.sections set status = 'inactive' where id = '5ec00000-0000-0000-0000-0000000000a3';

-- الموظفون: e1، e2 (SA نشطان)، eL (SA، on_leave)، eE (ended)، eB (SB وحدها)، eX (T2)، eOld (تكليف SA منتهٍ)
insert into public.staff (id, platform_tenant_id, employee_code, first_name, family_name, status) values
  ('e1000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', 'E1',   'E', 'One',   'active'),
  ('e2000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001', 'E2',   'E', 'Two',   'active'),
  ('e3000000-0000-0000-0000-000000000003', '10000000-0000-0000-0000-000000000001', 'EL',   'E', 'Leave', 'on_leave'),
  ('e4000000-0000-0000-0000-000000000004', '10000000-0000-0000-0000-000000000001', 'EE',   'E', 'Ended', 'ended'),
  ('e5000000-0000-0000-0000-000000000005', '10000000-0000-0000-0000-000000000001', 'EB',   'E', 'B',     'active'),
  ('e6000000-0000-0000-0000-000000000006', '20000000-0000-0000-0000-000000000002', 'EX',   'E', 'X',     'active'),
  ('e7000000-0000-0000-0000-000000000007', '10000000-0000-0000-0000-000000000001', 'EOLD', 'E', 'Old',   'active');
insert into public.staff_school_assignments (staff_id, school_id, platform_tenant_id, job_title, effective_from) values
  ('e1000000-0000-0000-0000-000000000001', '5a000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', 'T', '2025-09-01'),
  ('e2000000-0000-0000-0000-000000000002', '5a000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', 'T', '2025-09-01'),
  ('e3000000-0000-0000-0000-000000000003', '5a000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', 'T', '2025-09-01'),
  ('e5000000-0000-0000-0000-000000000005', '5b000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001', 'T', '2025-09-01'),
  ('e6000000-0000-0000-0000-000000000006', '5c000000-0000-0000-0000-000000000003', '20000000-0000-0000-0000-000000000002', 'T', '2025-09-01');
insert into public.staff_school_assignments (staff_id, school_id, platform_tenant_id, job_title, effective_from, status, effective_to) values
  ('e4000000-0000-0000-0000-000000000004', '5a000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', 'T', '2024-09-01', 'ended', '2025-06-30'),
  ('e7000000-0000-0000-0000-000000000007', '5a000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', 'T', '2024-09-01', 'ended', '2025-06-30');

-- السنة المغلقة: تكليف وُضع قبل إغلاقها (يبقى active تاريخاً — T7)؛ ثم yA نشطة
insert into public.teaching_assignments (id, platform_tenant_id, school_id, academic_year_id, grade_level_id, section_id, subject_id, staff_id, effective_from) values
  ('7c000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', '5a000000-0000-0000-0000-000000000001', 'c0000000-0000-0000-0000-000000000001',
   '61000000-0000-0000-0000-000000000001', '5ec00000-0000-0000-0000-0000000000a6', '5e000000-0000-0000-0000-000000000001', 'e1000000-0000-0000-0000-000000000001', '2025-09-01');
update public.academic_years set status = 'active' where id = 'c0000000-0000-0000-0000-000000000001';
update public.academic_years set status = 'closed' where id = 'c0000000-0000-0000-0000-000000000001';
update public.academic_years set status = 'active' where id = 'a0000000-0000-0000-0000-000000000002';
update public.subjects set status = 'inactive' where id = '5e000000-0000-0000-0000-000000000003';   -- OLD
-- SB و SX: صف لكل منهما (للعزل)
insert into public.teaching_assignments (id, platform_tenant_id, school_id, academic_year_id, grade_level_id, section_id, subject_id, staff_id, effective_from) values
  ('7b000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', '5b000000-0000-0000-0000-000000000002', 'bb000000-0000-0000-0000-000000000004',
   '62000000-0000-0000-0000-000000000001', '5ec00000-0000-0000-0000-0000000000b1', '5e000000-0000-0000-0000-0000000000b1', 'e5000000-0000-0000-0000-000000000005', '2027-09-01'),
  ('7d000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000002', '5c000000-0000-0000-0000-000000000003', 'cc000000-0000-0000-0000-000000000005',
   '63000000-0000-0000-0000-000000000001', '5ec00000-0000-0000-0000-0000000000c1', '5e000000-0000-0000-0000-0000000000c1', 'e6000000-0000-0000-0000-000000000006', '2027-09-01');
insert into public.class_teacher_assignments (id, platform_tenant_id, school_id, academic_year_id, grade_level_id, section_id, staff_id, effective_from) values
  ('8b000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', '5b000000-0000-0000-0000-000000000002', 'bb000000-0000-0000-0000-000000000004',
   '62000000-0000-0000-0000-000000000001', '5ec00000-0000-0000-0000-0000000000b1', 'e5000000-0000-0000-0000-000000000005', '2027-09-01');

create function pg_temp.member(p_label text, p_role text, p_tenant uuid, p_scope text, p_target uuid) returns void
language plpgsql as $$
declare v_a uuid := gen_random_uuid(); v_p uuid; v_m uuid;
begin
  insert into auth.users (id, email) values (v_a, p_label || '@m48.invalid');
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
select pg_temp.member('tch', 'teacher',      '10000000-0000-0000-0000-000000000001', 'school', '5a000000-0000-0000-0000-000000000001');   -- staff.read بلا staff.assign
select pg_temp.member('sec', 'secretary',    '10000000-0000-0000-0000-000000000001', 'school', '5a000000-0000-0000-0000-000000000001');   -- بلا staff.read
select pg_temp.member('x',   'school_admin', '20000000-0000-0000-0000-000000000002', 'school', '5c000000-0000-0000-0000-000000000003');

-- إدراج بالقيم (كما يبنيه الـAPI من صف الشعبة): الشعبة تحدد المدرسة والسنة والصف
create function pg_temp.teach(p_section text, p_subject text, p_staff text, p_from text default '2027-09-01') returns text language sql as $$
  select format($f$insert into public.teaching_assignments (platform_tenant_id, school_id, academic_year_id, grade_level_id, section_id, subject_id, staff_id, effective_from)
                   select sc.platform_tenant_id, s.school_id, s.academic_year_id, s.grade_level_id, s.id, %L, %L, %L
                     from public.sections s join public.schools sc on sc.id = s.school_id where s.id = %L returning 'ok'$f$,
                p_subject, p_staff, p_from, p_section)
$$;
create function pg_temp.class(p_section text, p_staff text, p_from text default '2027-09-01') returns text language sql as $$
  select format($f$insert into public.class_teacher_assignments (platform_tenant_id, school_id, academic_year_id, grade_level_id, section_id, staff_id, effective_from)
                   select sc.platform_tenant_id, s.school_id, s.academic_year_id, s.grade_level_id, s.id, %L, %L
                     from public.sections s join public.schools sc on sc.id = s.school_id where s.id = %L returning 'ok'$f$,
                p_staff, p_from, p_section)
$$;

-- ============ القراءة ============
-- أسماء المدارس من جدول مؤقت مرئي للجميع: join على public.schools يُسقط صفوف المدرسة غير المرئية فيخفي سياسة بلا نطاق
create temp table sch on commit drop as select id, school_code as code from public.schools;
grant select on sch to public;
create function pg_temp.reads(p_label text) returns void language plpgsql as $$
begin
  perform pg_temp.run('read.t.' || p_label, p_label, $q$select coalesce(string_agg(sc.code, ',' order by sc.code, t.id), '') from public.teaching_assignments t join sch sc on sc.id = t.school_id$q$);
  perform pg_temp.run('read.c.' || p_label, p_label, $q$select count(*)::text from public.class_teacher_assignments$q$);
end $$;
select pg_temp.reads(l) from unnest(array['sa','sb','tch','sec','x']) l;

-- ============ الإنشاء المسموح ============
select pg_temp.run('ok.teach_p1_ar',  'sa', pg_temp.teach('5ec00000-0000-0000-0000-0000000000a1', '5e000000-0000-0000-0000-000000000001', 'e1000000-0000-0000-0000-000000000001'));
select pg_temp.run('ok.teach_p1_ma',  'sa', pg_temp.teach('5ec00000-0000-0000-0000-0000000000a1', '5e000000-0000-0000-0000-000000000002', 'e1000000-0000-0000-0000-000000000001'));
select pg_temp.run('ok.teach_p2_ar',  'sa', pg_temp.teach('5ec00000-0000-0000-0000-0000000000a2', '5e000000-0000-0000-0000-000000000001', 'e1000000-0000-0000-0000-000000000001'));
select pg_temp.run('ok.class_p1',     'sa', pg_temp.class('5ec00000-0000-0000-0000-0000000000a1', 'e2000000-0000-0000-0000-000000000002'));   -- المربي لا يدرّس الشعبة
select pg_temp.run('ok.class_p2',     'sa', pg_temp.class('5ec00000-0000-0000-0000-0000000000a2', 'e2000000-0000-0000-0000-000000000002'));   -- مربٍّ لشعبتين
select pg_temp.run('ok.active_year',  'sa', pg_temp.teach('5ec00000-0000-0000-0000-0000000000a5', '5e000000-0000-0000-0000-000000000001', 'e1000000-0000-0000-0000-000000000001', '2026-09-01'), 'mid-year staffing');

select pg_temp.run('read2.c.sec', 'sec', $q$select count(*)::text from public.class_teacher_assignments$q$);
select pg_temp.run('read2.c.sa',  'sa',  $q$select coalesce(string_agg(distinct sc.code, ','), '') from public.class_teacher_assignments t join sch sc on sc.id = t.school_id$q$);
select pg_temp.run('read2.c.sb',  'sb',  $q$select coalesce(string_agg(distinct sc.code, ','), '') from public.class_teacher_assignments t join sch sc on sc.id = t.school_id$q$);

-- ============ «نشط واحد» (T3) ============
select pg_temp.run('uq.teach', 'sa', pg_temp.teach('5ec00000-0000-0000-0000-0000000000a1', '5e000000-0000-0000-0000-000000000001', 'e2000000-0000-0000-0000-000000000002'));
select pg_temp.run('uq.class', 'sa', pg_temp.class('5ec00000-0000-0000-0000-0000000000a1', 'e1000000-0000-0000-0000-000000000001'));

-- ============ T17 عند الإنشاء ============
select pg_temp.run('g.active_no_reason', 'sa', pg_temp.teach('5ec00000-0000-0000-0000-0000000000a5', '5e000000-0000-0000-0000-000000000001', 'e2000000-0000-0000-0000-000000000002', '2026-09-01'));
select pg_temp.run('g.closed_year',      'sa', pg_temp.class('5ec00000-0000-0000-0000-0000000000a6', 'e1000000-0000-0000-0000-000000000001', '2025-09-01'), 'r');
select pg_temp.run('g.section_inactive', 'sa', pg_temp.teach('5ec00000-0000-0000-0000-0000000000a3', '5e000000-0000-0000-0000-000000000001', 'e1000000-0000-0000-0000-000000000001'));
select pg_temp.run('g.subject_inactive', 'sa', pg_temp.teach('5ec00000-0000-0000-0000-0000000000a1', '5e000000-0000-0000-0000-000000000003', 'e1000000-0000-0000-0000-000000000001'));
select pg_temp.run('g.link_inactive',    'sa', pg_temp.teach('5ec00000-0000-0000-0000-0000000000a1', '5e000000-0000-0000-0000-000000000004', 'e1000000-0000-0000-0000-000000000001'));
select pg_temp.run('g.staff_on_leave',   'sa', pg_temp.teach('5ec00000-0000-0000-0000-0000000000a2', '5e000000-0000-0000-0000-000000000002', 'e3000000-0000-0000-0000-000000000003'));
select pg_temp.run('g.class_on_leave',   'sa', pg_temp.class('5ec00000-0000-0000-0000-0000000000a4', 'e3000000-0000-0000-0000-000000000003'));
select pg_temp.run('g.staff_ended',      'sa', pg_temp.teach('5ec00000-0000-0000-0000-0000000000a2', '5e000000-0000-0000-0000-000000000002', 'e4000000-0000-0000-0000-000000000004'));
select pg_temp.run('g.assignment_ended', 'sa', pg_temp.teach('5ec00000-0000-0000-0000-0000000000a2', '5e000000-0000-0000-0000-000000000002', 'e7000000-0000-0000-0000-000000000007'));
select pg_temp.run('g.other_school_staff','sa', pg_temp.teach('5ec00000-0000-0000-0000-0000000000a2', '5e000000-0000-0000-0000-000000000002', 'e5000000-0000-0000-0000-000000000005'));
-- المسار المميّز يخضع للحارس كذلك
select pg_temp.rec('g.owner_closed', pg_temp.teach('5ec00000-0000-0000-0000-0000000000a6', '5e000000-0000-0000-0000-000000000001', 'e2000000-0000-0000-0000-000000000002', '2025-09-01'));
select pg_temp.rec('g.owner_no_reason', pg_temp.teach('5ec00000-0000-0000-0000-0000000000a5', '5e000000-0000-0000-0000-000000000001', 'e2000000-0000-0000-0000-000000000002', '2026-09-01'));
select pg_temp.rec('g.owner_born_ended', $q$insert into public.class_teacher_assignments (platform_tenant_id, school_id, academic_year_id, grade_level_id, section_id, staff_id, effective_from, status, effective_to)
  values ('10000000-0000-0000-0000-000000000001', '5a000000-0000-0000-0000-000000000001', 'b0000000-0000-0000-0000-000000000003', '61000000-0000-0000-0000-000000000001',
          '5ec00000-0000-0000-0000-0000000000a4', 'e1000000-0000-0000-0000-000000000001', '2027-09-01', 'ended', '2027-10-01') returning 'ok'$q$);

-- ============ القيود الإعلانية بأسمائها (المسار المميّز) ============
-- ترتيب الفحص: الحارس (BEFORE) ← الفهرس الفريد ← الـFK في نهاية الجملة. كل حالة مبنية ليكون الـFK المقصود هو الخرق الوحيد.
select set_config('app.audit_reason', 'fixture', true);
-- شعبة G2 من yP تُقدَّم بسياق (yA، G1): الحارس يمر (الربط yA/G1/AR نشط، e2 مكلَّف في SA) والـFK وحده يرفض
select pg_temp.rec('c.section_other_year', $q$insert into public.teaching_assignments (platform_tenant_id, school_id, academic_year_id, grade_level_id, section_id, subject_id, staff_id, effective_from)
  values ('10000000-0000-0000-0000-000000000001', '5a000000-0000-0000-0000-000000000001', 'a0000000-0000-0000-0000-000000000002', '61000000-0000-0000-0000-000000000001',
          '5ec00000-0000-0000-0000-0000000000a4', '5e000000-0000-0000-0000-000000000001', 'e2000000-0000-0000-0000-000000000002', '2026-09-01') returning 'ok'$q$);
select set_config('app.audit_reason', '', true);
-- شعبة SA تُقدَّم بسياق مدرسة SB وموظف SB
select pg_temp.rec('c.section_other_school', $q$insert into public.class_teacher_assignments (platform_tenant_id, school_id, academic_year_id, grade_level_id, section_id, staff_id, effective_from)
  values ('10000000-0000-0000-0000-000000000001', '5b000000-0000-0000-0000-000000000002', 'bb000000-0000-0000-0000-000000000004', '62000000-0000-0000-0000-000000000001',
          '5ec00000-0000-0000-0000-0000000000a4', 'e5000000-0000-0000-0000-000000000005', '2027-09-01') returning 'ok'$q$);
select pg_temp.rec('c.subject_unlinked',    pg_temp.teach('5ec00000-0000-0000-0000-0000000000a2', '5e000000-0000-0000-0000-000000000005', 'e2000000-0000-0000-0000-000000000002'));
select pg_temp.rec('c.subject_other_grade', pg_temp.teach('5ec00000-0000-0000-0000-0000000000a4', '5e000000-0000-0000-0000-000000000001', 'e2000000-0000-0000-0000-000000000002'));
-- FK الـTenant يقع خلف الحارس (موظف Tenant آخر لا يملك تكليفاً في المدرسة): يُختبر بتعطيل الحارس داخل المعاملة —
-- المحرك يفرضه حتى بلا الحارس
alter table public.teaching_assignments      disable trigger guard;
alter table public.class_teacher_assignments disable trigger guard;
select pg_temp.rec('c.staff_other_tenant', pg_temp.teach('5ec00000-0000-0000-0000-0000000000a2', '5e000000-0000-0000-0000-000000000002', 'e6000000-0000-0000-0000-000000000006'));
select pg_temp.rec('c.school_other_tenant', $q$insert into public.class_teacher_assignments (platform_tenant_id, school_id, academic_year_id, grade_level_id, section_id, staff_id, effective_from)
  values ('20000000-0000-0000-0000-000000000002', '5a000000-0000-0000-0000-000000000001', 'b0000000-0000-0000-0000-000000000003', '61000000-0000-0000-0000-000000000002',
          '5ec00000-0000-0000-0000-0000000000a4', 'e6000000-0000-0000-0000-000000000006', '2027-09-01') returning 'ok'$q$);
select pg_temp.rec('c.class_staff_other_tenant', pg_temp.class('5ec00000-0000-0000-0000-0000000000a4', 'e6000000-0000-0000-0000-000000000006'));
alter table public.teaching_assignments      enable trigger guard;
alter table public.class_teacher_assignments enable trigger guard;

-- ============ RLS والامتيازات ============
select pg_temp.run('p.tch_insert',   'tch', pg_temp.teach('5ec00000-0000-0000-0000-0000000000a2', '5e000000-0000-0000-0000-000000000002', 'e2000000-0000-0000-0000-000000000002'));
select pg_temp.run('p.sec_insert',   'sec', pg_temp.class('5ec00000-0000-0000-0000-0000000000a4', 'e2000000-0000-0000-0000-000000000002'));
select pg_temp.run('p.tch_class',    'tch', pg_temp.class('5ec00000-0000-0000-0000-0000000000a4', 'e2000000-0000-0000-0000-000000000002'));
-- مدير SB يدرج في SA بالقيم (لا يرى شعبة SA، فيكتب القيم مباشرة)
select pg_temp.run('p.sb_into_sa', 'sb', $q$insert into public.teaching_assignments (platform_tenant_id, school_id, academic_year_id, grade_level_id, section_id, subject_id, staff_id, effective_from)
  values ('10000000-0000-0000-0000-000000000001', '5a000000-0000-0000-0000-000000000001', 'b0000000-0000-0000-0000-000000000003', '61000000-0000-0000-0000-000000000001',
          '5ec00000-0000-0000-0000-0000000000a2', '5e000000-0000-0000-0000-000000000002', 'e2000000-0000-0000-0000-000000000002', '2027-09-01') returning 'ok'$q$);
select pg_temp.run('p.x_into_t1', 'x', $q$insert into public.class_teacher_assignments (platform_tenant_id, school_id, academic_year_id, grade_level_id, section_id, staff_id, effective_from)
  values ('10000000-0000-0000-0000-000000000001', '5a000000-0000-0000-0000-000000000001', 'b0000000-0000-0000-0000-000000000003', '61000000-0000-0000-0000-000000000002',
          '5ec00000-0000-0000-0000-0000000000a4', 'e2000000-0000-0000-0000-000000000002', '2027-09-01') returning 'ok'$q$);
select pg_temp.run('p.status_insert', 'sa', $q$insert into public.class_teacher_assignments (platform_tenant_id, school_id, academic_year_id, grade_level_id, section_id, staff_id, effective_from, status)
  values ('10000000-0000-0000-0000-000000000001', '5a000000-0000-0000-0000-000000000001', 'b0000000-0000-0000-0000-000000000003', '61000000-0000-0000-0000-000000000002',
          '5ec00000-0000-0000-0000-0000000000a4', 'e2000000-0000-0000-0000-000000000002', '2027-09-01', 'active') returning 'ok'$q$);
select pg_temp.run('p.update_status', 'sa', $q$update public.teaching_assignments set status = 'ended', effective_to = '2027-12-31' returning 'ok'$q$);
select pg_temp.run('p.update_staff',  'sa', $q$update public.teaching_assignments set staff_id = 'e2000000-0000-0000-0000-000000000002' returning 'ok'$q$);
select pg_temp.run('p.update_class',  'sa', $q$update public.class_teacher_assignments set effective_from = '2027-01-01' returning 'ok'$q$);
select pg_temp.run('p.delete_teach',  'sa', $q$delete from public.teaching_assignments returning 'ok'$q$);
select pg_temp.run('p.delete_class',  'sa', $q$delete from public.class_teacher_assignments returning 'ok'$q$);

-- ============ T17 عند التعديل (المسار المميّز) ============
select pg_temp.rec('u.identity',   $q$update public.teaching_assignments set staff_id = 'e2000000-0000-0000-0000-000000000002' where section_id = '5ec00000-0000-0000-0000-0000000000a2' returning 'ok'$q$);
select pg_temp.rec('u.from',       $q$update public.class_teacher_assignments set effective_from = '2027-01-01' where section_id = '5ec00000-0000-0000-0000-0000000000a2' returning 'ok'$q$);
select pg_temp.rec('u.noop',       $q$update public.teaching_assignments set status = 'active' where section_id = '5ec00000-0000-0000-0000-0000000000a2' returning 'ok'$q$);
select pg_temp.rec('u.closed_end', $q$update public.teaching_assignments set status = 'ended', effective_to = '2026-06-30' where id = '7c000000-0000-0000-0000-000000000001' returning 'ok'$q$);
select pg_temp.rec('u.chk_active', $q$update public.teaching_assignments set status = 'ended' where section_id = '5ec00000-0000-0000-0000-0000000000a2' returning 'ok'$q$);
select pg_temp.rec('u.chk_dates',  $q$update public.teaching_assignments set status = 'ended', effective_to = '2027-08-01' where section_id = '5ec00000-0000-0000-0000-0000000000a2' returning 'ok'$q$);

select pg_temp.rec('u.class_chk_active', $q$update public.class_teacher_assignments set status = 'ended' where section_id = '5ec00000-0000-0000-0000-0000000000a2' returning 'ok'$q$);
select pg_temp.rec('u.class_chk_dates',  $q$update public.class_teacher_assignments set status = 'ended', effective_to = '2027-08-01' where section_id = '5ec00000-0000-0000-0000-0000000000a2' returning 'ok'$q$);

-- ============ الإنهاء بالدالتين ============
create function pg_temp.end_t(p_where text, p_to text, p_reason text) returns text language sql as $$
  select format($f$select app.end_teaching_assignment((select id from public.teaching_assignments where %s and status = 'active'), %L, %L)::text$f$, p_where, p_to, p_reason)
$$;
select pg_temp.run('e.tch',         'tch', pg_temp.end_t($w$section_id = '5ec00000-0000-0000-0000-0000000000a2'$w$, '2027-12-31', 'r'));
select pg_temp.run('e.sb',          'sb',  format($f$select app.end_teaching_assignment(%L, '2027-12-31', 'r')::text$f$, (select id from public.teaching_assignments where section_id = '5ec00000-0000-0000-0000-0000000000a2' and status = 'active')));
select pg_temp.run('e.no_reason',   'sa',  pg_temp.end_t($w$section_id = '5ec00000-0000-0000-0000-0000000000a2'$w$, '2027-12-31', ' '));
select pg_temp.run('e.before_from', 'sa',  pg_temp.end_t($w$section_id = '5ec00000-0000-0000-0000-0000000000a2'$w$, '2027-08-31', 'r'));
select pg_temp.run('e.missing',     'sa',  $q$select app.end_teaching_assignment(gen_random_uuid(), '2027-12-31', 'r')::text$q$);
select pg_temp.run('e.closed',      'sa',  $q$select app.end_teaching_assignment('7c000000-0000-0000-0000-000000000001', '2026-06-30', 'r')::text$q$);
-- الإنهاء في السنة النشطة: السبب من الدالة نفسها يستوفي C3
select pg_temp.run('e.active_year', 'sa',  pg_temp.end_t($w$section_id = '5ec00000-0000-0000-0000-0000000000a5'$w$, '2026-12-31', 'teacher left'));
-- الاستبدال (T5): إنهاء في اليوم نفسه ثم إدراج الجديد
select pg_temp.run('e.replace_end', 'sa',  pg_temp.end_t($w$section_id = '5ec00000-0000-0000-0000-0000000000a1' and subject_id = '5e000000-0000-0000-0000-000000000001'$w$, '2027-09-01', 'replaced'));
select pg_temp.run('e.replace_new', 'sa',  pg_temp.teach('5ec00000-0000-0000-0000-0000000000a1', '5e000000-0000-0000-0000-000000000001', 'e2000000-0000-0000-0000-000000000002'));
select pg_temp.run('e.twice',       'sa',  $q$select app.end_teaching_assignment((select id from public.teaching_assignments where section_id = '5ec00000-0000-0000-0000-0000000000a1' and subject_id = '5e000000-0000-0000-0000-000000000001' and status = 'ended'), '2027-12-31', 'r')::text$q$);
select pg_temp.rec('u.ended_final', $q$update public.teaching_assignments set effective_to = '2027-12-31' where status = 'ended' and section_id = '5ec00000-0000-0000-0000-0000000000a1' returning 'ok'$q$);
select pg_temp.run('e.class',       'sa',  $q$select app.end_class_teacher_assignment((select id from public.class_teacher_assignments where section_id = '5ec00000-0000-0000-0000-0000000000a1' and status = 'active'), '2027-10-01', 'new class teacher')::text$q$);
select pg_temp.run('e.class_new',   'sa',  pg_temp.class('5ec00000-0000-0000-0000-0000000000a1', 'e1000000-0000-0000-0000-000000000001', '2027-10-01'));
select pg_temp.run('e.class_tch',   'tch', $q$select app.end_class_teacher_assignment((select id from public.class_teacher_assignments where section_id = '5ec00000-0000-0000-0000-0000000000a2' and status = 'active'), '2027-10-01', 'r')::text$q$);

-- T8: لا حارس عكسي — تعطيل الشعبة أو الربط بعد التكليف ممكن والتكليف يبقى (معلَّقاً مشتقاً)
select pg_temp.rec('t8.section_off', $q$update public.sections set status = 'inactive' where id = '5ec00000-0000-0000-0000-0000000000a2' returning status$q$);
select pg_temp.rec('t8.link_off',    $q$update public.grade_subjects set status = 'inactive' where academic_year_id = 'b0000000-0000-0000-0000-000000000003' and subject_id = '5e000000-0000-0000-0000-000000000002' returning status$q$);

select plan(4 + 9 + 6 + 2 + 13 + 7 + 11 + 8 + 15 + 3 + 4);

-- البنية
select ok((select bool_and(relrowsecurity and relforcerowsecurity) from pg_class where oid in ('public.teaching_assignments'::regclass, 'public.class_teacher_assignments'::regclass)),
          'RLS enabled and forced on both tables');
select is((select string_agg(tablename || '.' || cmd, ',' order by tablename, cmd) from pg_policies where schemaname = 'public' and tablename in ('teaching_assignments', 'class_teacher_assignments')),
          'class_teacher_assignments.INSERT,class_teacher_assignments.SELECT,teaching_assignments.INSERT,teaching_assignments.SELECT',
          'SELECT and INSERT policies only — no UPDATE, no DELETE (T4)');
select is((select string_agg(indexrelid::regclass::text || ':' || pg_get_expr(indpred, indrelid), ' | ' order by indexrelid::regclass::text)
             from pg_index where indisunique and indpred is not null and indrelid in ('public.teaching_assignments'::regclass, 'public.class_teacher_assignments'::regclass)),
          'class_teacher_assignments_active_uq:(status = ''active''::text) | teaching_assignments_active_uq:(status = ''active''::text)',
          'one-active partial unique indexes (T3)');
select is((select count(*)::int from public.permissions where code !~ '\.read_assigned$'), 75, 'no permission key added (P8; *.read_assigned is P3/M50)');

-- القراءة
select is((select v from r where k = 'read.t.sa'),  'SA',  'school admin SA reads SA teaching assignments only (the closed-year row is its own record)');
select is((select v from r where k = 'read.t.sb'),  'SB',  'school admin SB (same tenant) reads SB only');
select is((select v from r where k = 'read.t.tch'), 'SA',  'teacher (staff.read) reads its school''s assignments');
select is((select v from r where k = 'read.t.sec'), '',    'secretary without staff.read reads none');
select is((select v from r where k = 'read.t.x'),   'SX',  'T2 admin reads T2 only');
select is((select v from r where k = 'read.c.sb') || '/' || (select v from r where k = 'read.c.sa') || '/' || (select v from r where k = 'read.c.x'), '1/0/0',
          'class-teacher rows follow the same isolation');
select is((select v from r where k = 'read.c.sec'), '0', 'secretary reads no class-teacher row');
select is((select v from r where k = 'read2.c.sec'), '0', 'secretary (scope, no staff.read) still reads none once SA has class-teacher rows');
select is((select v from r where k = 'read2.c.sa') || '/' || (select v from r where k = 'read2.c.sb'), 'SA/SB', 'each school admin reads its own school''s class-teacher rows only');

-- الإنشاء المسموح
select is((select v from r where k = 'ok.teach_p1_ar'), 'ok', 'school admin assigns a teacher to a subject in a section');
select is((select v from r where k = 'ok.teach_p1_ma'), 'ok', 'the same teacher takes another subject in the same section');
select is((select v from r where k = 'ok.teach_p2_ar'), 'ok', 'the same teacher and subject in another section');
select is((select v from r where k = 'ok.class_p1'),    'ok', 'a class teacher who teaches nothing in that section (P7)');
select is((select v from r where k = 'ok.class_p2'),    'ok', 'the same class teacher for a second section — no limit (P7)');
select is((select v from r where k = 'ok.active_year'), 'ok', 'an assignment in the active year is accepted with a reason (C3)');

-- نشط واحد
select ok((select v from r where k = 'uq.teach') like 'ERR 23505%teaching_assignments_active_uq%',      'a second active teacher for the same (section, subject) → teaching_assignments_active_uq');
select ok((select v from r where k = 'uq.class') like 'ERR 23505%class_teacher_assignments_active_uq%', 'a second active class teacher for the section → class_teacher_assignments_active_uq');

-- T17 عند الإنشاء
select ok((select v from r where k = 'g.active_no_reason') like 'ERR 22023%reason required%',                 'T17: active year without a reason is refused');
select ok((select v from r where k = 'g.closed_year')      like 'ERR 23514%academic year is closed%',         'T17: no assignment in a closed year');
select ok((select v from r where k = 'g.section_inactive') like 'ERR 23514%section is not active%',           'T17: inactive section');
select ok((select v from r where k = 'g.subject_inactive') like 'ERR 23514%subject is not active',            'T17: inactive subject');
select ok((select v from r where k = 'g.link_inactive')    like 'ERR 23514%not active for this grade level%', 'T17: inactive grade-subject link (subject itself active)');
select ok((select v from r where k = 'g.staff_on_leave')   like 'ERR 23514%staff member is not active%',      'T17: no new teaching assignment for staff on leave (Q4)');
select ok((select v from r where k = 'g.class_on_leave')   like 'ERR 23514%staff member is not active%',      'T17: no new class-teacher assignment for staff on leave');
select ok((select v from r where k = 'g.staff_ended')      like 'ERR 23514%staff member is not active%',      'T17: ended staff');
select ok((select v from r where k = 'g.assignment_ended') like 'ERR 23514%no active assignment in this school%', 'T17: active staff whose school assignment ended');
select ok((select v from r where k = 'g.other_school_staff') like 'ERR 23514%no active assignment in this school%', 'T17: staff assigned to another school of the same tenant');
select ok((select v from r where k = 'g.owner_closed')     like 'ERR 23514%academic year is closed%',         'T17 binds the privileged path: closed year');
select ok((select v from r where k = 'g.owner_no_reason')  like 'ERR 22023%reason required%',                 'T17 binds the privileged path: reason in an active year');
select ok((select v from r where k = 'g.owner_born_ended') like 'ERR 23514%created active%',                  'T17: an assignment is never born ended');

-- القيود الإعلانية
select ok((select v from r where k = 'c.section_other_year')   like 'ERR 23503%teaching_assignments_section_fk%',       'section of another year → teaching_assignments_section_fk');
select ok((select v from r where k = 'c.section_other_school') like 'ERR 23503%class_teacher_assignments_section_fk%',  'section of another school → class_teacher_assignments_section_fk');
select ok((select v from r where k = 'c.subject_unlinked')     like 'ERR 23503%teaching_assignments_grade_subject_fk%', 'subject not linked to the grade in that year → teaching_assignments_grade_subject_fk');
select ok((select v from r where k = 'c.subject_other_grade')  like 'ERR 23503%teaching_assignments_grade_subject_fk%', 'subject linked to another grade only → teaching_assignments_grade_subject_fk');
select ok((select v from r where k = 'c.staff_other_tenant')   like 'ERR 23503%teaching_assignments_staff_fk%',         'staff of another tenant → teaching_assignments_staff_fk');
select ok((select v from r where k = 'c.school_other_tenant')  like 'ERR 23503%class_teacher_assignments_school_fk%',   'tenant not owning the school → class_teacher_assignments_school_fk');
select ok((select v from r where k = 'c.class_staff_other_tenant') like 'ERR 23503%class_teacher_assignments_staff_fk%', 'class teacher of another tenant → class_teacher_assignments_staff_fk');

-- RLS والامتيازات
select ok((select v from r where k = 'p.tch_insert')    like 'ERR 42501%row-level security%teaching_assignments%',      'teacher (staff.read, no staff.assign) cannot assign');
select ok((select v from r where k = 'p.sec_insert')    like 'ERR 42501%row-level security%class_teacher_assignments%', 'secretary (no staff.assign) cannot assign');
select ok((select v from r where k = 'p.tch_class')     like 'ERR 42501%row-level security%class_teacher_assignments%', 'teacher (staff.read, no staff.assign) cannot name a class teacher');
select ok((select v from r where k = 'p.sb_into_sa')    like 'ERR 42501%row-level security%teaching_assignments%',      'school admin SB cannot assign in SA (same tenant)');
select ok((select v from r where k = 'p.x_into_t1')     like 'ERR 42501%row-level security%class_teacher_assignments%', 'another tenant cannot assign');
select ok((select v from r where k = 'p.status_insert') like 'ERR 42501%permission denied%class_teacher_assignments%', 'status is not client-insertable');
select ok((select v from r where k = 'p.update_status') like 'ERR 42501%permission denied%teaching_assignments%',      'no client UPDATE: status');
select ok((select v from r where k = 'p.update_staff')  like 'ERR 42501%permission denied%teaching_assignments%',      'no client UPDATE: staff');
select ok((select v from r where k = 'p.update_class')  like 'ERR 42501%permission denied%class_teacher_assignments%', 'no client UPDATE on class-teacher rows');
select ok((select v from r where k = 'p.delete_teach')  like 'ERR 42501%permission denied%teaching_assignments%',      'no DELETE');
select ok((select v from r where k = 'p.delete_class')  like 'ERR 42501%permission denied%class_teacher_assignments%', 'no DELETE on class-teacher rows');

-- T17 عند التعديل والقيود
select ok((select v from r where k = 'u.identity')   like 'ERR 23514%cannot change its school, year, section, subject, staff or start date%', 'T17: staff is immutable');
select ok((select v from r where k = 'u.from')       like 'ERR 23514%cannot change its school, year, section, subject, staff or start date%', 'T17: the start date is immutable');
select ok((select v from r where k = 'u.noop')       like 'ERR 23514%only transition is active -> ended%',  'T17: a no-op update is refused');
select ok((select v from r where k = 'u.closed_end') like 'ERR 23514%academic year is closed%',             'T17: a closed year''s assignment cannot be ended — frozen history (T7)');
select ok((select v from r where k = 'u.chk_active') like 'ERR 23514%teaching_assignments_active_chk%',     'ended without an end date → teaching_assignments_active_chk');
select ok((select v from r where k = 'u.chk_dates')  like 'ERR 23514%teaching_assignments_dates_chk%',      'end before start → teaching_assignments_dates_chk');
select ok((select v from r where k = 'u.class_chk_active') like 'ERR 23514%class_teacher_assignments_active_chk%', 'class teacher: ended without an end date → class_teacher_assignments_active_chk');
select ok((select v from r where k = 'u.class_chk_dates')  like 'ERR 23514%class_teacher_assignments_dates_chk%',  'class teacher: end before start → class_teacher_assignments_dates_chk');

-- الإنهاء والاستبدال
select ok((select v from r where k = 'e.tch')         like 'ERR 42501%forbidden%',                        'end: staff.assign required');
select ok((select v from r where k = 'e.sb')          like 'ERR P0002%not found%',                        'end: another school''s admin finds nothing');
select ok((select v from r where k = 'e.no_reason')   like 'ERR 22023%reason required%',                  'end: reason required');
select ok((select v from r where k = 'e.before_from') like 'ERR 22023%must not precede effective_from%',  'end: not before the start');
select ok((select v from r where k = 'e.missing')     like 'ERR P0002%not found%',                        'end: unknown id');
select ok((select v from r where k = 'e.closed')      like 'ERR 23514%academic year is closed%',          'end: refused in a closed year');
select is((select v from r where k = 'e.active_year'), '', 'end in the active year succeeds — the function''s reason satisfies C3');
select is((select v from r where k = 'e.active_year#ctx'), '|', 'the audit context is cleared after the end');
select is((select v from r where k = 'e.replace_end') || '/' || (select v from r where k = 'e.replace_new'), '/ok', 'replacement: end the current teacher (same day), then assign the new one');
select is((select string_agg(st.employee_code || ':' || t.status, ',' order by t.status desc, st.employee_code) from public.teaching_assignments t join public.staff st on st.id = t.staff_id
            where t.section_id = '5ec00000-0000-0000-0000-0000000000a1' and t.subject_id = '5e000000-0000-0000-0000-000000000001'), 'E1:ended,E2:active',
          'after replacement: one active teacher, the previous one kept as history');
select ok((select v from r where k = 'e.twice')       like 'ERR 22023%invalid transition ended -> ended%', 'an ended assignment cannot be ended again');
select ok((select v from r where k = 'u.ended_final') like 'ERR 23514%ended assignment is final%',         'T17: an ended row is frozen on every path');
select is((select v from r where k = 'e.class') || '/' || (select v from r where k = 'e.class_new'), '/ok', 'class teacher replaced the same way');
select ok((select v from r where k = 'e.class_tch')   like 'ERR 42501%forbidden%',                        'class-teacher end: staff.assign required');
select is((select reason from public.audit_log where entity_type = 'teaching_assignments' and action = 'end' order by id desc limit 1), 'replaced',
          'T7: the end is audited with the user''s reason');

-- T8 و T7 (السنة المغلقة)
select is((select v from r where k = 't8.section_off') || '/' || (select v from r where k = 't8.link_off'), 'inactive/inactive',
          'T8: no reverse guard — a section or a grade-subject link with an active assignment can still be deactivated (Phase 2 guards untouched)');
select is((select count(*)::int from public.teaching_assignments where status = 'active' and section_id = '5ec00000-0000-0000-0000-0000000000a2'), 1,
          '…and the assignment row stays (derived "suspended")');
select is((select status from public.teaching_assignments where id = '7c000000-0000-0000-0000-000000000001'), 'active',
          'T7: the closed year''s assignment stays as it was');

-- العقد
select is((select string_agg(p.proname || ':' || pg_get_userbyid(p.proowner) || ':' || p.prosecdef, ',' order by p.proname) from pg_proc p
            where p.pronamespace = 'app'::regnamespace and p.proname in ('end_teaching_assignment', 'end_class_teacher_assignment', 'tg_teaching_assignment_guard')),
          'end_class_teacher_assignment:app_owner:true,end_teaching_assignment:app_owner:true,tg_teaching_assignment_guard:app_owner:true', 'functions owned by app_owner, SECURITY DEFINER');
select ok(not has_function_privilege('authenticated', 'app.tg_teaching_assignment_guard()', 'EXECUTE')
          and not has_function_privilege('anon', 'app.end_teaching_assignment(uuid,date,text)', 'EXECUTE'), 'the guard is not executable by API roles; anon cannot end');
select is((select count(*)::int from public.audit_log where entity_type = 'class_teacher_assignments' and action = 'insert' and actor_type = 'tenant_user'), 3,
          'T7: class-teacher inserts audited as the tenant user');
select is((select string_agg(tgname, ',' order by tgname) from pg_trigger where tgrelid = 'public.sections'::regclass and not tgisinternal), 'audit,guard,stamp',
          'Phase 2 triggers on sections are unchanged (no reverse guard added)');

select * from finish();
rollback;
