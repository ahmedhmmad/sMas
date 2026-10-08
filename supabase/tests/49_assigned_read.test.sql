-- M50 + M51 — assigned_read (Phase 3A / 3-4، إغلاق D1/R5): القراءة «بالتكليف» = المفتاح + العلاقة (P5)، لا اسم الدور.
-- مصفوفة فاعل × جدول، كل شرط في P5 بحالته، دور مخصص يحمل المفاتيح الأربعة وحدها، T8 بعد M51 (N4)، سحب profile.read (N8)،
-- والفروع القائمة في السياسات الخمس حرفياً كما كانت.
begin;

create temp table r (k text primary key, v text) on commit drop;
grant all on r to public;
create temp table actors (label text primary key, auth uuid) on commit drop;
grant select on actors to public;
create temp table lbl (id uuid primary key, label text) on commit drop;      -- أسماء مرئية للجميع: لا join على جدول محمي يخفي صفاً
grant select on lbl to public;

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
-- SA: yZ (تُغلق لاحقاً)، yP (planned — الأساس)؛ SB: yB؛ SX: yX
insert into public.academic_years (id, school_id, name, start_date, end_date) values
  ('c0000000-0000-0000-0000-000000000001', '5a000000-0000-0000-0000-000000000001', '2025', '2025-09-01', '2026-06-30'),
  ('b0000000-0000-0000-0000-000000000003', '5a000000-0000-0000-0000-000000000001', '2027', '2027-09-01', '2028-06-30'),
  ('bb000000-0000-0000-0000-000000000004', '5b000000-0000-0000-0000-000000000002', '2027', '2027-09-01', '2028-06-30'),
  ('cc000000-0000-0000-0000-000000000005', '5c000000-0000-0000-0000-000000000003', '2027', '2027-09-01', '2028-06-30');
insert into public.stages (id, school_id, name, sequence_no) values
  ('51000000-0000-0000-0000-000000000001', '5a000000-0000-0000-0000-000000000001', 'P', 1),
  ('52000000-0000-0000-0000-000000000002', '5b000000-0000-0000-0000-000000000002', 'P', 1),
  ('53000000-0000-0000-0000-000000000003', '5c000000-0000-0000-0000-000000000003', 'P', 1);
insert into public.grade_levels (id, school_id, stage_id, name, sequence_no) values
  ('61000000-0000-0000-0000-000000000001', '5a000000-0000-0000-0000-000000000001', '51000000-0000-0000-0000-000000000001', 'G7', 1),
  ('62000000-0000-0000-0000-000000000001', '5b000000-0000-0000-0000-000000000002', '52000000-0000-0000-0000-000000000002', 'G7', 1),
  ('63000000-0000-0000-0000-000000000001', '5c000000-0000-0000-0000-000000000003', '53000000-0000-0000-0000-000000000003', 'G7', 1);
insert into public.sections (id, school_id, academic_year_id, grade_level_id, name) values
  ('5ec00000-0000-0000-0000-00000000007a', '5a000000-0000-0000-0000-000000000001', 'b0000000-0000-0000-0000-000000000003', '61000000-0000-0000-0000-000000000001', '7A'),
  ('5ec00000-0000-0000-0000-00000000007b', '5a000000-0000-0000-0000-000000000001', 'b0000000-0000-0000-0000-000000000003', '61000000-0000-0000-0000-000000000001', '7B'),
  ('5ec00000-0000-0000-0000-00000000007c', '5a000000-0000-0000-0000-000000000001', 'b0000000-0000-0000-0000-000000000003', '61000000-0000-0000-0000-000000000001', '7C'),
  ('5ec00000-0000-0000-0000-00000000007d', '5a000000-0000-0000-0000-000000000001', 'c0000000-0000-0000-0000-000000000001', '61000000-0000-0000-0000-000000000001', '7Z'),
  ('5ec00000-0000-0000-0000-0000000000b1', '5b000000-0000-0000-0000-000000000002', 'bb000000-0000-0000-0000-000000000004', '62000000-0000-0000-0000-000000000001', 'B1'),
  ('5ec00000-0000-0000-0000-0000000000c1', '5c000000-0000-0000-0000-000000000003', 'cc000000-0000-0000-0000-000000000005', '63000000-0000-0000-0000-000000000001', 'X1');
insert into lbl select id, name from public.sections;
insert into public.subjects (id, school_id, subject_code, name) values
  ('5e000000-0000-0000-0000-000000000001', '5a000000-0000-0000-0000-000000000001', 'MA', 'Math'),
  ('5e000000-0000-0000-0000-000000000002', '5a000000-0000-0000-0000-000000000001', 'AR', 'Arabic'),
  ('5e000000-0000-0000-0000-000000000003', '5a000000-0000-0000-0000-000000000001', 'SC', 'Science'),
  ('5e000000-0000-0000-0000-000000000004', '5a000000-0000-0000-0000-000000000001', 'EN', 'English'),
  ('5e000000-0000-0000-0000-0000000000b1', '5b000000-0000-0000-0000-000000000002', 'MA', 'Math'),
  ('5e000000-0000-0000-0000-0000000000c1', '5c000000-0000-0000-0000-000000000003', 'MA', 'Math');
insert into public.grade_subjects (school_id, academic_year_id, grade_level_id, subject_id, weekly_periods)
  select s.school_id, y.id, g.id, s.id, 4
    from public.subjects s join public.academic_years y on y.school_id = s.school_id join public.grade_levels g on g.school_id = s.school_id;

-- عضوية بدور ونطاق مدرسة (أو نطاق Tenant)
create function pg_temp.account(p_label text, p_role text, p_tenant uuid, p_school uuid, p_auth uuid default gen_random_uuid()) returns uuid
language plpgsql as $$
declare v_p uuid; v_m uuid;
begin
  insert into auth.users (id, email) values (p_auth, p_label || '@m50.invalid');
  insert into public.auth_identities (auth_user_id, kind) values (p_auth, 'tenant');
  insert into public.profiles (platform_tenant_id, auth_user_id, display_name) values (p_tenant, p_auth, p_label) returning id into v_p;
  insert into public.memberships (platform_tenant_id, profile_id) values (p_tenant, v_p) returning id into v_m;
  if p_role is not null then
    insert into public.membership_roles (membership_id, role_id, platform_tenant_id, role_owner_key)
      select v_m, ro.id, p_tenant, ro.owner_key from public.roles ro where ro.code = p_role and (ro.platform_tenant_id is null or ro.platform_tenant_id = p_tenant);
  end if;
  if p_school is not null then
    insert into public.membership_scopes (membership_id, platform_tenant_id, scope_type, school_id) values (v_m, p_tenant, 'school', p_school);
  end if;
  insert into actors values (p_label, p_auth);
  return v_p;
end $$;

-- دور مخصص يحمل المفاتيح الأربعة **وحدها** — لا شيء من اسم الدور
insert into public.roles (id, platform_tenant_id, code, name) values ('7c000000-0000-0000-0000-0000000000c1', '10000000-0000-0000-0000-000000000001', 'zt_assigned_only', 'Assigned only');
insert into public.role_permissions (role_id, permission_id)
  select '7c000000-0000-0000-0000-0000000000c1', id from public.permissions where code like '%.read_assigned';

-- موظف بحساب: الدور، مدرسة التكليف، ثم تكليفاته بصيغة 'T:شعبة:مادة' أو 'C:شعبة'
create function pg_temp.teacher(p_label text, p_role text, p_school_code text, p_assign text[]) returns void
language plpgsql as $$
declare v_id uuid := gen_random_uuid(); v_p uuid; v_school public.schools%rowtype; a text; v_sec public.sections%rowtype; v_subj uuid;
begin
  select * into v_school from public.schools where school_code = p_school_code;
  v_p := pg_temp.account(p_label, p_role, v_school.platform_tenant_id, v_school.id, v_id);
  insert into public.staff (id, platform_tenant_id, profile_id, employee_code, first_name, family_name) values (v_id, v_school.platform_tenant_id, v_p, p_label, 'S', p_label);
  insert into public.staff_school_assignments (staff_id, school_id, platform_tenant_id, job_title, effective_from) values (v_id, v_school.id, v_school.platform_tenant_id, 'T', '2025-09-01');
  insert into lbl values (v_id, p_label);
  foreach a in array p_assign loop
    select s.* into v_sec from public.sections s where s.school_id = v_school.id and s.name = split_part(a, ':', 2);
    if split_part(a, ':', 1) = 'C' then
      insert into public.class_teacher_assignments (platform_tenant_id, school_id, academic_year_id, grade_level_id, section_id, staff_id, effective_from)
        values (v_school.platform_tenant_id, v_school.id, v_sec.academic_year_id, v_sec.grade_level_id, v_sec.id, v_id, '2025-09-01');
    else
      select id into v_subj from public.subjects where school_id = v_school.id and subject_code = split_part(a, ':', 3);
      insert into public.teaching_assignments (platform_tenant_id, school_id, academic_year_id, grade_level_id, section_id, subject_id, staff_id, effective_from)
        values (v_school.platform_tenant_id, v_school.id, v_sec.academic_year_id, v_sec.grade_level_id, v_sec.id, v_subj, v_id, '2025-09-01');
    end if;
  end loop;
end $$;
select pg_temp.teacher('tA',     'teacher',          'SA', array['T:7A:MA']);          -- معلم 7أ/رياضيات
select pg_temp.teacher('tB',     'teacher',          'SA', array['C:7B']);             -- مربي 7ب لا يدرّسها
select pg_temp.teacher('tN',     'teacher',          'SA', array[]::text[]);           -- المفتاح بلا العلاقة
select pg_temp.teacher('tCT',    'teacher',          'SA', array['C:7A']);             -- مربي 7أ
select pg_temp.teacher('tL',     'teacher',          'SA', array['T:7A:AR']);          -- ربط مادته سيُعطَّل
select pg_temp.teacher('tS',     'teacher',          'SA', array['T:7C:MA']);          -- شعبته ستُعطَّل
select pg_temp.teacher('tLeave', 'teacher',          'SA', array['T:7B:MA']);          -- on_leave
select pg_temp.teacher('tEnd',   'teacher',          'SA', array['T:7B:AR']);          -- ended (وصف نشط متبقٍّ)
select pg_temp.teacher('tSsa',   'teacher',          'SA', array['T:7B:SC']);          -- تكليف المدرسة ينتهي (وصف نشط متبقٍّ)
select pg_temp.teacher('tZ',     'teacher',          'SA', array['T:7Z:MA']);          -- السنة ستُغلق
select pg_temp.teacher('tFin',   'teacher',          'SA', array['T:7C:AR', 'C:7C']);  -- سيُنهى تكليفاه بالدالتين
select pg_temp.teacher('custom', 'zt_assigned_only', 'SA', array['T:7A:SC']);          -- دور مخصص: المفاتيح الأربعة وحدها
select pg_temp.teacher('nokey',  'bus_supervisor',   'SA', array['T:7A:EN']);          -- العلاقة بلا المفتاح
select pg_temp.teacher('tSB',    'teacher',          'SB', array['T:B1:MA']);
select pg_temp.teacher('tX',     'teacher',          'SX', array['T:X1:MA']);
-- معلم في مدرستين: تدريس 7B/EN في SA، ومربي B1 في SB بتكليف مدرسة هناك — **بلا نطاق عضوية** على SB (العلاقة هي تكليف المدرسة)
select pg_temp.teacher('tTwo', 'teacher', 'SA', array['T:7B:EN']);
insert into public.staff_school_assignments (staff_id, school_id, platform_tenant_id, job_title, effective_from)
  select l.id, '5b000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001', 'T', '2025-09-01' from lbl l where l.label = 'tTwo';
insert into public.class_teacher_assignments (platform_tenant_id, school_id, academic_year_id, grade_level_id, section_id, staff_id, effective_from)
  select '10000000-0000-0000-0000-000000000001', s.school_id, s.academic_year_id, s.grade_level_id, s.id, l.id, '2025-09-01'
    from public.sections s, lbl l where s.id = '5ec00000-0000-0000-0000-0000000000b1' and l.label = 'tTwo';
select pg_temp.account('sa',  'school_admin', '10000000-0000-0000-0000-000000000001', '5a000000-0000-0000-0000-000000000001');
select pg_temp.account('sec', 'secretary',    '10000000-0000-0000-0000-000000000001', '5a000000-0000-0000-0000-000000000001');
select pg_temp.account('acc', 'accountant',   '10000000-0000-0000-0000-000000000001', '5a000000-0000-0000-0000-000000000001');
select pg_temp.account('cou', 'counselor',    '10000000-0000-0000-0000-000000000001', '5a000000-0000-0000-0000-000000000001');

-- الأسر والطلاب (كل طالب بتسجيلاته: 'شعبة:حالة:من[:إلى]') وأولياء الأمور
insert into public.families (id, platform_tenant_id, family_name) values
  ('fa000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', 'F1'),      -- s7a1 + s7b1 (شقيقان في شعبتين)
  ('fa000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001', 'F2'),      -- s7b2 وحده
  ('fa000000-0000-0000-0000-000000000003', '20000000-0000-0000-0000-000000000002', 'FX');
insert into lbl select id, family_name from public.families;

create function pg_temp.student(p_label text, p_school_code text, p_enroll text[], p_family uuid default null) returns uuid
language plpgsql as $$
declare v_school public.schools%rowtype; v_a uuid := gen_random_uuid(); v_p uuid; v_st uuid; e text; v_sec public.sections%rowtype; v_iscope uuid;
begin
  select * into v_school from public.schools where school_code = p_school_code;
  select i.id into v_iscope from public.identity_scopes i where i.owner_id = v_school.scope_owner_id;
  insert into auth.users (id, email) values (v_a, p_label || '@st.m50.invalid');
  insert into public.auth_identities values (v_a, 'tenant');
  insert into public.profiles (platform_tenant_id, auth_user_id, display_name) values (v_school.platform_tenant_id, v_a, 'profile-' || p_label) returning id into v_p;
  insert into public.students (platform_tenant_id, identity_scope_id, student_profile_id, family_id, official_id, official_id_type, first_name, family_name)
    values (v_school.platform_tenant_id, v_iscope, v_p, p_family, 'N-' || p_label, 'national_id', p_label, 'S') returning id into v_st;
  insert into lbl values (v_st, p_label);
  foreach e in array p_enroll loop
    select s.* into v_sec from public.sections s where s.school_id = v_school.id and s.name = split_part(e, ':', 1);
    insert into public.enrollments (school_id, student_id, platform_tenant_id, academic_year_id, grade_level_id, section_id, identity_scope_id, scope_owner_id, status, effective_from, effective_to)
      values (v_school.id, v_st, v_school.platform_tenant_id, v_sec.academic_year_id, v_sec.grade_level_id, v_sec.id, v_iscope, v_school.scope_owner_id,
              split_part(e, ':', 2), split_part(e, ':', 3)::date, nullif(split_part(e, ':', 4), '')::date);
  end loop;
  return v_st;
end $$;
select pg_temp.student('s7a1',   'SA', array['7A:active:2027-09-01'], 'fa000000-0000-0000-0000-000000000001');
select pg_temp.student('s7a2',   'SA', array['7A:active:2027-09-01']);
select pg_temp.student('s7b1',   'SA', array['7B:active:2027-09-01'], 'fa000000-0000-0000-0000-000000000001');
select pg_temp.student('s7b2',   'SA', array['7B:active:2027-09-01'], 'fa000000-0000-0000-0000-000000000002');
select pg_temp.student('s7c1',   'SA', array['7C:active:2027-09-01']);
select pg_temp.student('sMoved', 'SA', array['7A:transferred:2027-09-01:2027-10-01', '7B:active:2027-10-01']);   -- تسجيله الأحدث في 7B
select pg_temp.student('sWith',  'SA', array['7A:withdrawn:2027-09-01:2027-11-01']);                              -- الأحدث withdrawn
select pg_temp.student('sOld',   'SA', array['7Z:active:2025-09-01']);                                            -- في السنة التي ستُغلق
select pg_temp.student('sB1',    'SB', array['B1:active:2027-09-01']);
select pg_temp.student('sX1',    'SX', array['X1:active:2027-09-01'], 'fa000000-0000-0000-0000-000000000003');

create function pg_temp.guardian(p_label text, p_student text, p_status text default 'active') returns void
language plpgsql as $$
declare v_g uuid; v_st public.students%rowtype;
begin
  select s.* into v_st from public.students s join lbl on lbl.id = s.id where lbl.label = p_student;
  select id into v_g from lbl where label = p_label;
  if v_g is null then
    insert into public.guardians (platform_tenant_id, first_name, family_name, phone_e164)
      values (v_st.platform_tenant_id, p_label, 'G', '+2010' || lpad((select count(*)::text from public.guardians), 8, '0')) returning id into v_g;
    insert into lbl values (v_g, p_label);
  end if;
  insert into public.student_guardians (student_id, guardian_id, platform_tenant_id, relationship_type, status, effective_from, effective_to)
    values (v_st.id, v_g, v_st.platform_tenant_id, 'father', p_status, '2027-09-01', case when p_status = 'ended' then '2027-10-01'::date end);
end $$;
select pg_temp.guardian('gA',    's7a1');
select pg_temp.guardian('gAold', 's7a1', 'ended');      -- ارتباط منتهٍ بطالب 7أ
select pg_temp.guardian('gB',    's7b1');
select pg_temp.guardian('gBoth', 's7a2');               -- ولي أمر لطالبين في شعبتين
select pg_temp.guardian('gBoth', 's7b2');
select pg_temp.guardian('gX',    'sX1');
-- حساب ولي أمر (gB) وحساب طالب (s7b2) بدوري النظام — لا يتغير ما يريانه
update public.guardians g set profile_id = pg_temp.account('gAcc', 'guardian', '10000000-0000-0000-0000-000000000001', null) from lbl l where l.id = g.id and l.label = 'gB';
insert into actors select 'stAcc', p.auth_user_id from public.students st join lbl l on l.id = st.id join public.profiles p on p.id = st.student_profile_id where l.label = 's7b2';
with m as (insert into public.memberships (platform_tenant_id, profile_id)
             select st.platform_tenant_id, st.student_profile_id from public.students st join lbl l on l.id = st.id where l.label = 's7b2' returning id, platform_tenant_id)
insert into public.membership_roles (membership_id, role_id, platform_tenant_id, role_owner_key)
  select m.id, ro.id, m.platform_tenant_id, ro.owner_key from m, public.roles ro where ro.code = 'student' and ro.platform_tenant_id is null;

-- ============ القراءة: خمس قوائم لكل فاعل ============
create function pg_temp.reads(p_tag text, p_actor text) returns void language plpgsql as $$
begin
  perform pg_temp.run(p_tag || '.st.' || p_actor, p_actor, $q$select coalesce(string_agg(l.label, ',' order by l.label), '') from public.students s join lbl l on l.id = s.id$q$);
  perform pg_temp.run(p_tag || '.en.' || p_actor, p_actor, $q$select coalesce(string_agg(ls.label || '@' || lc.label || ':' || e.status, ',' order by ls.label, e.effective_from), '')
                                                               from public.enrollments e join lbl ls on ls.id = e.student_id join lbl lc on lc.id = e.section_id$q$);
  perform pg_temp.run(p_tag || '.gu.' || p_actor, p_actor, $q$select coalesce(string_agg(l.label, ',' order by l.label), '') from public.guardians g join lbl l on l.id = g.id$q$);
  perform pg_temp.run(p_tag || '.fa.' || p_actor, p_actor, $q$select coalesce(string_agg(l.label, ',' order by l.label), '') from public.families f join lbl l on l.id = f.id$q$);
  perform pg_temp.run(p_tag || '.li.' || p_actor, p_actor, $q$select coalesce(string_agg(lg.label || '>' || ls.label || ':' || sg.status, ',' order by lg.label, ls.label), '')
                                                               from public.student_guardians sg join lbl lg on lg.id = sg.guardian_id join lbl ls on ls.id = sg.student_id$q$);
end $$;
create function pg_temp.students_of(p_tag text, p_actor text) returns void language sql as $$
  select pg_temp.run(p_tag || '.' || p_actor, p_actor, $q$select coalesce(string_agg(l.label, ',' order by l.label), '') from public.students s join lbl l on l.id = s.id$q$)
$$;

-- السنة 7Z: قبل الإغلاق
update public.academic_years set status = 'active' where id = 'c0000000-0000-0000-0000-000000000001';
select pg_temp.students_of('z.open', 'tZ');

select pg_temp.reads('m', a) from unnest(array['tA','tB','tN','tCT','custom','nokey','tSB','tX','sa','sec','acc','cou','tTwo','gAcc','stAcc']) a;
select pg_temp.students_of('pre', a) from unnest(array['tL','tS','tLeave','tEnd','tSsa','tFin']) a;

-- is_class_teacher_of (للمرحلة 6): بلا EXECUTE لأدوار الـAPI — تُختبر بهوية الفاعل (claims) دون تبديل الدور
create function pg_temp.as_actor(p_key text, p_label text, p_sql text) returns void
language plpgsql as $$
declare v_sub uuid := (select auth from actors where label = p_label);
begin
  perform set_config('request.jwt.claims', json_build_object('sub', v_sub, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', v_sub::text, true);
  perform pg_temp.rec(p_key, p_sql);
  perform set_config('request.jwt.claims', '', true);
  perform set_config('request.jwt.claim.sub', '', true);
end $$;
select pg_temp.as_actor('ct.tB',  'tB',  $q$select app.is_class_teacher_of('5ec00000-0000-0000-0000-00000000007b')::text || '/' || app.is_class_teacher_of('5ec00000-0000-0000-0000-00000000007a')::text$q$);
select pg_temp.as_actor('ct.tA',  'tA',  $q$select app.is_class_teacher_of('5ec00000-0000-0000-0000-00000000007a')::text$q$);      -- يدرّسها ولا يربّيها
select pg_temp.as_actor('ct.tCT', 'tCT', $q$select app.is_class_teacher_of('5ec00000-0000-0000-0000-00000000007a')::text$q$);
select pg_temp.run('ct.client', 'tB', $q$select app.is_class_teacher_of('5ec00000-0000-0000-0000-00000000007b')::text$q$);

-- الـprofiles (N8): المعلم يرى صفّه وحده؛ المدير كما كان
select pg_temp.run('prof.tA', 'tA', $q$select string_agg(display_name, ',' order by display_name) from public.profiles$q$);
select pg_temp.run('prof.sa', 'sa', $q$select (count(*) > 10)::text || '/' || bool_or(display_name = 'tB')::text from public.profiles$q$);
select pg_temp.run('perm.tA', 'tA', $q$select array_to_string(app.my_permissions(), ',')$q$);

-- لا كتابة عبر الفرع الجديد
select pg_temp.run('w.blind', 'tA', $q$with u as (update public.students set first_name = 'Hacked') select 'done'$q$);

-- ============ كل شرط في P5 ============
set local app.audit_reason = 'p5';
-- السنة تُغلق
update public.academic_years set status = 'closed' where id = 'c0000000-0000-0000-0000-000000000001';
select pg_temp.students_of('z.closed', 'tZ');
-- ربط المادة يُعطَّل: معلم المادة يفقد، مربي الشعبة لا
update public.grade_subjects set status = 'inactive' where academic_year_id = 'b0000000-0000-0000-0000-000000000003' and subject_id = '5e000000-0000-0000-0000-000000000002';
select pg_temp.students_of('link.off', a) from unnest(array['tL','tCT','tA']) a;
update public.grade_subjects set status = 'active' where academic_year_id = 'b0000000-0000-0000-0000-000000000003' and subject_id = '5e000000-0000-0000-0000-000000000002';
select pg_temp.students_of('link.on', 'tL');
-- الشعبة تُعطَّل (لا حارس عكسي — T8). T12 يمنع تعطيل شعبة فيها تسجيل نشط، فالطالب «الحالي في شعبة معطَّلة» غير قابل للوجود؛
-- الشرط يُختبر على الدالة نفسها (تستدعيها سياسة enrollments مباشرة)
select pg_temp.run('sec.fn.before', 'tS', $q$select app.section_assigned_to_me('5ec00000-0000-0000-0000-00000000007c')::text$q$);
update public.enrollments set status = 'withdrawn', effective_to = '2027-12-01' where section_id = '5ec00000-0000-0000-0000-00000000007c';   -- T12: لا تعطيل لشعبة فيها تسجيل نشط
select pg_temp.students_of('sec.pre', 'tS');
update public.sections set status = 'inactive' where id = '5ec00000-0000-0000-0000-00000000007c';
select pg_temp.run('sec.fn.off', 'tS', $q$select app.section_assigned_to_me('5ec00000-0000-0000-0000-00000000007c')::text$q$);
select pg_temp.rec('sec.fn.rows', $q$select count(*)::text from public.teaching_assignments where section_id = '5ec00000-0000-0000-0000-00000000007c' and status = 'active'$q$);
update public.sections set status = 'active' where id = '5ec00000-0000-0000-0000-00000000007c';
select pg_temp.run('sec.fn.back', 'tS', $q$select app.section_assigned_to_me('5ec00000-0000-0000-0000-00000000007c')::text$q$);
update public.enrollments set status = 'active', effective_to = null where section_id = '5ec00000-0000-0000-0000-00000000007c';
select pg_temp.students_of('sec.on', 'tS');
-- on_leave ثم العودة (بلا cascade)
update public.staff set status = 'on_leave' where employee_code = 'tLeave';
select pg_temp.students_of('leave.on', 'tLeave');
update public.staff set status = 'on_leave' where employee_code = 'tB';
select pg_temp.as_actor('ct.leave', 'tB', $q$select app.is_class_teacher_of('5ec00000-0000-0000-0000-00000000007b')::text$q$);
update public.staff set status = 'active' where employee_code in ('tLeave', 'tB');
select pg_temp.students_of('leave.back', 'tLeave');
-- ended بلا cascade: الصف النشط المتبقي لا يمنح رؤية
update public.staff set status = 'ended' where employee_code = 'tEnd';
select pg_temp.students_of('ended', 'tEnd');
select pg_temp.rec('ended.stale', $q$select count(*)::text from public.teaching_assignments t join lbl l on l.id = t.staff_id where l.label = 'tEnd' and t.status = 'active'$q$);
-- انتهاء تكليف المدرسة بلا cascade
update public.staff_school_assignments a set status = 'ended', effective_to = '2027-12-01' from lbl l where l.id = a.staff_id and l.label = 'tSsa';
select pg_temp.students_of('ssa', 'tSsa');
update public.staff_school_assignments a set status = 'ended', effective_to = '2027-12-01' from lbl l
 where l.id = a.staff_id and l.label = 'tTwo' and a.school_id = '5a000000-0000-0000-0000-000000000001';
select pg_temp.students_of('ssa.one_school', 'tTwo');
-- إنهاء التكليف بالدالتين: التدريس ثم المربي
select pg_temp.run('fin.end1', 'sa', $q$select app.end_teaching_assignment((select t.id from public.teaching_assignments t join lbl l on l.id = t.staff_id where l.label = 'tFin'), '2027-12-01', 'x')::text$q$);
select pg_temp.students_of('fin.class_only', 'tFin');
select pg_temp.run('fin.end2', 'sa', $q$select app.end_class_teacher_assignment((select t.id from public.class_teacher_assignments t join lbl l on l.id = t.staff_id where l.label = 'tFin'), '2027-12-01', 'x')::text$q$);
select pg_temp.students_of('fin.none', 'tFin');
-- ارتباط ولي الأمر ينتهي
update public.student_guardians sg set status = 'ended', effective_to = '2027-12-01' from lbl l where l.id = sg.guardian_id and l.label = 'gA';
select pg_temp.run('unlink.gu.tA', 'tA', $q$select coalesce(string_agg(l.label, ',' order by l.label), '') from public.guardians g join lbl l on l.id = g.id$q$);
-- الطالب ينسحب (التسجيل الأحدث يصير withdrawn)
update public.enrollments e set status = 'withdrawn', effective_to = '2027-12-15' from lbl l where l.id = e.student_id and l.label = 's7a2';
select pg_temp.students_of('withdrawn', 'tA');
select pg_temp.students_of('withdrawn', 'sa');
set local app.audit_reason = '';

-- ============ T8 بعد M51 (N4): المدير يسند دور teacher لحساب موظف جديد ============
select pg_temp.teacher('fresh', null, 'SA', array[]::text[]);
delete from public.membership_scopes ms using public.memberships m, public.profiles p where m.id = ms.membership_id and p.id = m.profile_id and p.display_name = 'fresh';
select pg_temp.run('t8.sa_grants_teacher', 'sa', $q$insert into public.membership_roles (membership_id, role_id, platform_tenant_id, role_owner_key)
  select m.id, ro.id, m.platform_tenant_id, ro.owner_key from public.memberships m join public.profiles p on p.id = m.profile_id, public.roles ro
   where p.display_name = 'fresh' and ro.code = 'teacher' and ro.platform_tenant_id is null returning 'ok'$q$);
-- فاعل يملك كل صلاحيات school_admin **عدا** المفاتيح الأربعة: T8 يرفض إسناده دور teacher (ما كان سيحدث للمدير بلا N4)
insert into public.roles (id, platform_tenant_id, code, name) values ('7c000000-0000-0000-0000-0000000000c2', '10000000-0000-0000-0000-000000000001', 'zt_admin_no_assigned', 'Admin without assigned keys');
insert into public.role_permissions (role_id, permission_id)
  select '7c000000-0000-0000-0000-0000000000c2', rp.permission_id
    from public.role_permissions rp join public.roles ro on ro.id = rp.role_id join public.permissions p on p.id = rp.permission_id
   where ro.code = 'school_admin' and ro.platform_tenant_id is null and p.code not like '%.read_assigned';
select pg_temp.account('saOld', 'zt_admin_no_assigned', '10000000-0000-0000-0000-000000000001', '5a000000-0000-0000-0000-000000000001');
select pg_temp.teacher('fresh2', null, 'SA', array[]::text[]);
delete from public.membership_scopes ms using public.memberships m, public.profiles p where m.id = ms.membership_id and p.id = m.profile_id and p.display_name = 'fresh2';
select pg_temp.run('t8.without_keys', 'saOld', $q$insert into public.membership_roles (membership_id, role_id, platform_tenant_id, role_owner_key)
  select m.id, ro.id, m.platform_tenant_id, ro.owner_key from public.memberships m join public.profiles p on p.id = m.profile_id, public.roles ro
   where p.display_name = 'fresh2' and ro.code = 'teacher' and ro.platform_tenant_id is null returning 'ok'$q$);

select plan(58);

-- ---------- المعلم: ما كُلِّف به فقط ----------
select is((select v from r where k = 'm.st.tA'), 's7a1,s7a2', 'teacher of 7A/Math sees 7A''s current students only — not 7B/7C, not the moved student, not the withdrawn one, not SB');
select is((select v from r where k = 'm.en.tA'), 's7a1@7A:active,s7a2@7A:active', '…their current enrollments in that section only (no history of the moved student)');
select is((select v from r where k = 'm.gu.tA'), 'gA,gBoth', '…their guardians through an ACTIVE link (the ended link''s guardian stays hidden)');
select is((select v from r where k = 'm.fa.tA'), 'F1', '…the family of an assigned student (the sibling in 7B is not visible, the family is)');
select is((select v from r where k = 'm.li.tA'), 'gA>s7a1:active,gBoth>s7a2:active', '…active links of assigned students only (gBoth''s link to the 7B child is hidden)');
select is((select v from r where k = 'm.st.tB'), 's7b1,s7b2,sMoved', 'class teacher of 7B who teaches nothing there sees all of 7B, including the student who moved in');
select is((select v from r where k = 'm.en.tB'), 's7b1@7B:active,s7b2@7B:active,sMoved@7B:active', '…and only their 7B enrollments (sMoved''s old 7A row is hidden)');
select is((select v from r where k = 'm.gu.tB') || '|' || (select v from r where k = 'm.fa.tB'), 'gB,gBoth|F1,F2', '…their guardians and families');
select is((select v from r where k = 'm.st.tCT'), 's7a1,s7a2', 'class teacher of 7A sees 7A');
select is((select v from r where k = 'ct.tB') || '|' || (select v from r where k = 'ct.tA') || '|' || (select v from r where k = 'ct.tCT') || '|' || (select v from r where k = 'ct.leave'),
          'true/false|false|true|false', 'is_class_teacher_of (Phase 6): the class teacher of that section only — not its subject teacher, not while on leave');
select ok((select v from r where k = 'ct.client') like 'ERR 42501%', '…and no API role can call it yet');
select is((select v from r where k = 'm.st.tSB') || '|' || (select v from r where k = 'm.st.tX'), 'sB1|sX1', 'another school''s and another tenant''s teachers see their own section only');
select is((select v from r where k = 'm.st.tTwo'), 's7b1,s7b2,sB1,sMoved',
          'a teacher in two schools sees both assigned sections — the relationship is the SCHOOL ASSIGNMENT (P5), not the membership scope (none on SB here)');
select is((select v from r where k = 'm.st.tN') || (select v from r where k = 'm.en.tN') || (select v from r where k = 'm.gu.tN') || (select v from r where k = 'm.fa.tN') || (select v from r where k = 'm.li.tN'), '',
          'R5: a teacher with no assignment sees no student, enrollment, guardian, family or link (the key without the relationship)');
select is((select v from r where k = 'm.st.nokey') || (select v from r where k = 'm.en.nokey') || (select v from r where k = 'm.gu.nokey'), '',
          'the relationship without the key grants nothing (a staff member teaching 7A under a role with no read_assigned key)');

-- ---------- المفتاح + العلاقة، لا اسم الدور ----------
select is((select v from r where k = 'm.st.custom'), (select v from r where k = 'm.st.tA'), 'a CUSTOM role holding only the four keys sees exactly what the teacher of the same section sees');
select is((select v from r where k = 'm.en.custom') || '|' || (select v from r where k = 'm.gu.custom') || '|' || (select v from r where k = 'm.fa.custom') || '|' || (select v from r where k = 'm.li.custom'),
          (select v from r where k = 'm.en.tA') || '|' || (select v from r where k = 'm.gu.tA') || '|' || (select v from r where k = 'm.fa.tA') || '|' || (select v from r where k = 'm.li.tA'),
          '…on all five tables — the decision is the key and the relationship, never the role name');
select is((select count(*)::int from pg_proc p where p.pronamespace = 'app'::regnamespace
            and p.proname in ('current_staff_id', 'section_assigned_to_me', 'student_assigned_to_me', 'guardian_assigned_to_me', 'family_assigned_to_me', 'is_class_teacher_of')
            and p.prosrc ~* '(''teacher''|\mroles\M|role_permissions|membership|has_permission)'), 0, 'no assigned-read helper mentions a role, the roles table or memberships');
-- ---------- الأدوار الأخرى: كما كانت ----------
select is((select v from r where k = 'm.st.sa'),  's7a1,s7a2,s7b1,s7b2,s7c1,sMoved,sOld,sWith', 'school admin: every student of its school, as before (H2 — any status)');
select is((select v from r where k = 'm.st.sec'), (select v from r where k = 'm.st.sa'), 'secretary: unchanged');
select is((select v from r where k = 'm.st.acc') || '|' || (select v from r where k = 'm.st.cou'), (select v from r where k = 'm.st.sa') || '|' || (select v from r where k = 'm.st.sa'), 'accountant and counselor: unchanged');
select is((select v from r where k = 'm.gu.sa'),  'gA,gB,gBoth', 'school admin: guardians by active link, as before');
select is((select v from r where k = 'm.fa.sa') || '|' || (select v from r where k = 'm.fa.sec'), 'F1,F2|F1,F2', 'school admin and secretary: families as before');
select is((select v from r where k = 'm.st.gAcc') || '|' || (select v from r where k = 'm.gu.gAcc') || '|' || (select v from r where k = 'm.fa.gAcc') || '|' || (select v from r where k = 'm.li.gAcc'),
          's7b1|gB|F1|gB>s7b1:active', 'a guardian account: its child, itself, the child''s family and its own link — unchanged');
select is((select v from r where k = 'm.st.stAcc') || '|' || (select v from r where k = 'm.en.stAcc') || '|' || (select v from r where k = 'm.gu.stAcc'),
          's7b2|s7b2@7B:active|', 'a student account: itself and its enrollment — unchanged');
select ok((select v from r where k = 'm.en.sa') like '%sMoved@7A:transferred%sWith@7A:withdrawn%', 'school admin still reads the school''s enrollment history');
select is((select v from r where k = 'm.li.sa'), 'gA>s7a1:active,gAold>s7a1:ended,gB>s7b1:active,gBoth>s7a2:active,gBoth>s7b2:active', 'school admin: links of its students, ended ones included, as before');
-- ---------- N8 و N3: خريطة المعلم ----------
select is((select v from r where k = 'prof.tA'), 'tA', 'N8: the teacher reads its own profile only — no other name in the school');
select is((select v from r where k = 'prof.sa'), 'true/true', 'the school admin still reads the school''s profiles');
select is((select v from r where k = 'perm.tA'),
          'academic_year.read,enrollment.read_assigned,family.read_assigned,grade_level.read,guardian.read_assigned,school.read,section.read,staff.read,student.read_assigned,subject.read,term.read',
          'the teacher holds exactly the approved 11 keys');

-- ---------- لا كتابة ----------
select is((select v from r where k = 'w.blind'), 'done', 'the blind update ran');
select is((select count(*)::int from public.students where first_name = 'Hacked'), 0, 'the assigned branch grants no write: a teacher''s blind UPDATE changes no student');
select is((select count(*)::int from pg_policies where schemaname = 'public' and tablename in ('students', 'enrollments', 'guardians', 'families', 'student_guardians')
            and cmd <> 'SELECT' and coalesce(qual, '') || coalesce(with_check, '') ~ 'assigned'), 0, 'no write policy mentions an assigned key or helper');
-- ---------- العقود ----------
select is((select string_agg(p.proname, ',' order by p.proname) from pg_proc p where p.pronamespace = 'app'::regnamespace and p.proname ~ 'assigned_to_me$|^is_class_teacher_of$|^current_staff_id$'
            and has_function_privilege('authenticated', p.oid, 'EXECUTE')),
          'family_assigned_to_me,guardian_assigned_to_me,section_assigned_to_me,student_assigned_to_me', 'EXECUTE: only the helpers a policy calls');
select is((select count(*)::int from pg_proc p where p.pronamespace = 'app'::regnamespace and p.proname ~ 'assigned_to_me$|^is_class_teacher_of$|^current_staff_id$'
            and (pg_get_userbyid(p.proowner) <> 'app_owner' or not p.prosecdef or has_function_privilege('anon', p.oid, 'EXECUTE'))), 0,
          'all six: owned by app_owner, SECURITY DEFINER, nothing for anon');
select is((select count(*)::int from public.permissions), 79, 'catalog: 79 keys');

-- ---------- كل شرط في P5 ----------
select is((select v from r where k = 'z.open.tZ') || '>' || (select v from r where k = 'z.closed.tZ'), 'sOld>', 'closing the year removes the visibility (T7) — the assignment row itself stays active');
select is((select v from r where k = 'pre.tL') || '>' || (select v from r where k = 'link.off.tL') || '>' || (select v from r where k = 'link.on.tL'), 's7a1,s7a2>>s7a1,s7a2',
          'deactivating the grade-subject link suspends that subject''s teacher; reactivating restores it (T8, derived)');
select is((select v from r where k = 'link.off.tCT') || '|' || (select v from r where k = 'link.off.tA'), 's7a1,s7a2|s7a1,s7a2', '…while the class teacher and the teacher of another subject keep theirs');
select is((select v from r where k = 'sec.fn.before') || '>' || (select v from r where k = 'sec.fn.off') || '/' || (select v from r where k = 'sec.fn.rows') || '>' || (select v from r where k = 'sec.fn.back'), 'true>false/2>true',
          'an inactive section is assigned to nobody although its assignment rows stay active (suspended, T8); reactivating restores it');
select is((select v from r where k = 'pre.tS') || '>' || (select v from r where k = 'sec.pre.tS') || '>' || (select v from r where k = 'sec.on.tS'), 's7c1>>s7c1',
          'a student whose latest enrollment is withdrawn disappears; active again → visible again');
select is((select v from r where k = 'pre.tLeave') || '>' || (select v from r where k = 'leave.on.tLeave') || '>' || (select v from r where k = 'leave.back.tLeave'), 's7b1,s7b2,sMoved>>s7b1,s7b2,sMoved',
          'on_leave removes the visibility and returning restores it — no assignment row was touched (Q4)');
select is((select v from r where k = 'pre.tEnd') || '>' || (select v from r where k = 'ended.tEnd') || '/' || (select v from r where k = 'ended.stale'), 's7b1,s7b2,sMoved>/1',
          'an ended staff member sees nothing even with a leftover ACTIVE assignment row — P5 alone decides, no cascade needed');
select is((select v from r where k = 'pre.tSsa') || '>' || (select v from r where k = 'ssa.tSsa'), 's7b1,s7b2,sMoved>', 'no active school assignment → nothing');
select is((select v from r where k = 'ssa.one_school.tTwo'), 'sB1', '…and the school assignment is per school: ending the SA one leaves only the SB section');
select is((select v from r where k = 'pre.tFin') || '>' || (select v from r where k = 'fin.class_only.tFin') || '>' || (select v from r where k = 'fin.none.tFin'), 's7c1>s7c1>',
          'ending the teaching assignment leaves the class-teacher path; ending that too removes everything');
select is((select v from r where k = 'fin.end1') || (select v from r where k = 'fin.end2'), '', 'both ends went through the controlled functions');
select is((select v from r where k = 'unlink.gu.tA'), 'gBoth', 'ending the guardian link hides that guardian from the teacher');
select is((select v from r where k = 'withdrawn.tA') || '|' || (select v from r where k = 'withdrawn.sa'), 's7a1|s7a1,s7a2,s7b1,s7b2,s7c1,sMoved,sOld,sWith',
          'latest enrollment withdrawn → gone for the teacher, still visible to the school (N5)');
select is((select v from r where k = 'm.st.tA') ~ 'sWith|sMoved', false, 'a historical enrollment in my section is not a current one: neither the withdrawn nor the moved student');
-- N4 / T8
select is((select v from r where k = 't8.sa_grants_teacher'), 'ok', 'N4: after M51 a school admin can still grant the teacher role (T8: it holds the four keys)');
select ok((select v from r where k = 't8.without_keys') like 'ERR %T8: role grants permissions the actor does not hold:%read_assigned%',
          'T8 unchanged: an admin-like actor WITHOUT the four keys cannot grant teacher — which is why N4 gives them to the admin roles');
select is((select string_agg(ro.code, ',' order by ro.code) from public.roles ro where ro.platform_tenant_id is null
            and exists (select 1 from public.role_permissions rp join public.permissions p on p.id = rp.permission_id where rp.role_id = ro.id and p.code = 'student.read_assigned')),
          'group_manager,school_admin,teacher,tenant_admin', 'the assigned keys are held by the teacher and the three admin roles only');

-- ---------- الفروع القائمة حرفياً ----------
select is((select string_agg(old.name, ',' order by old.name) from (values
    ('students_select',
     $q$((platform_tenant_id = ( SELECT app.current_tenant_id() AS current_tenant_id)) AND app.has_permission('student.read'::text) AND (app.student_in_scope(id) OR app.student_linked_to_guardian(id) OR app.student_is_self(id)))$q$,
     $q$((platform_tenant_id = ( SELECT app.current_tenant_id() AS current_tenant_id)) AND app.has_permission('student.read_assigned'::text) AND app.student_assigned_to_me(id))$q$),
    ('enrollments_select',
     $q$(app.has_permission('enrollment.read'::text) AND (app.can_access_school(school_id) OR app.student_linked_to_guardian(student_id) OR app.student_is_self(student_id)))$q$,
     $q$(app.has_permission('enrollment.read_assigned'::text) AND app.student_assigned_to_me(student_id) AND app.section_assigned_to_me(section_id))$q$),
    ('guardians_select',
     $q$((profile_id = ( SELECT app.current_profile_id() AS current_profile_id)) OR ((platform_tenant_id = ( SELECT app.current_tenant_id() AS current_tenant_id)) AND app.has_permission('guardian.read'::text) AND app.guardian_in_scope(id)))$q$,
     $q$((platform_tenant_id = ( SELECT app.current_tenant_id() AS current_tenant_id)) AND app.has_permission('guardian.read_assigned'::text) AND app.guardian_assigned_to_me(id))$q$),
    ('families_select',
     $q$((platform_tenant_id = ( SELECT app.current_tenant_id() AS current_tenant_id)) AND app.has_permission('family.read'::text) AND (app.family_in_scope(id) OR (EXISTS ( SELECT 1 FROM students s WHERE ((s.family_id = families.id) AND app.student_linked_to_guardian(s.id))))))$q$,
     $q$((platform_tenant_id = ( SELECT app.current_tenant_id() AS current_tenant_id)) AND app.has_permission('family.read_assigned'::text) AND app.family_assigned_to_me(id))$q$),
    ('student_guardians_select',
     $q$((guardian_id = ( SELECT app.current_guardian_id() AS current_guardian_id)) OR (app.has_permission('guardian.read'::text) AND app.student_in_scope(student_id)) OR app.student_is_self(student_id))$q$,
     $q$(app.has_permission('guardian.read_assigned'::text) AND (status = 'active'::text) AND app.student_assigned_to_me(student_id))$q$)
  ) old(name, was, added) join pg_policies p on p.policyname = old.name and p.schemaname = 'public'
  -- Postgres يسطّح سلسلة OR: القديم (A OR B) يصير (A OR B OR C)؛ والقديم (X AND Y) يصير ((X AND Y) OR C)
  where regexp_replace(p.qual, '\s+', ' ', 'g') in ('(' || old.was || ' OR ' || old.added || ')',
                                                    left(old.was, -1) || ' OR ' || old.added || ')')),
  'enrollments_select,families_select,guardians_select,student_guardians_select,students_select',
  'each of the five SELECT policies is EXACTLY its Foundation text (M17, verbatim as pg stored it before M50) OR its one assigned branch — nothing else changed');
select is((select count(*)::int from pg_policies where schemaname = 'public' and policyname in ('students_select', 'enrollments_select', 'guardians_select', 'families_select', 'student_guardians_select')
            and qual ~ 'read_assigned' and cmd = 'SELECT'), 5, 'each of the five SELECT policies carries exactly its assigned branch');
select is((select count(*)::int from pg_policies where schemaname = 'public'), 94, 'no policy added or removed (94)');
select is((select md5(string_agg(p.proname || ':' || p.prosrc, '|' order by p.proname)) from pg_proc p where p.pronamespace = 'app'::regnamespace
            and p.proname in ('student_in_scope', 'guardian_in_scope', 'family_in_scope', 'can_see_membership', 'can_manage_membership', 'tg_authz_integrity', 'has_permission')),
          '72cbb02b6ff6771f01620cf026f77f05', 'H2 helpers, can_see/can_manage_membership, has_permission and T8: source text unchanged by 3-4 (pinned hash of the texts as of 3-3)');
select is((select count(*)::int from public.role_permissions rp join public.roles ro on ro.id = rp.role_id where ro.platform_tenant_id is null), 276, 'system-role links: 276');

select * from finish();
rollback;
