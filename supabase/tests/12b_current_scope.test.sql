-- M12b — H2: Historical Enrollment ≠ Current Operational Access
--   Student  → أحدث Enrollment (أياً كانت حالته)   Guardian → ارتباط نشط + الطالب في النطاق الحالي   Staff → تكليف نشط
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

create function pg_temp.as_(p_sub uuid) returns void
language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p_sub, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', coalesce(p_sub::text, ''), true);
end $$;

create temp table ids (label text primary key, auth uuid, profile uuid) on commit drop;
create temp table ent (kind text, label text, id uuid, primary key (kind, label)) on commit drop;
grant all on ids, ent to public;

create function pg_temp.person(p_label text) returns uuid
language plpgsql as $$
declare v_auth uuid := gen_random_uuid(); v_profile uuid;
begin
  insert into auth.users (id, email) values (v_auth, p_label || '@m12b.invalid');
  insert into public.auth_identities values (v_auth, 'tenant');
  insert into public.profiles (platform_tenant_id, auth_user_id, display_name)
    values ('10000000-0000-0000-0000-000000000001', v_auth, p_label) returning id into v_profile;
  insert into ids values (p_label, v_auth, v_profile);
  return v_profile;
end $$;
create function pg_temp.pid(p_label text) returns uuid language sql as $$ select profile from ids where label = p_label $$;
create function pg_temp.eid(p_kind text, p_label text) returns uuid language sql as $$ select id from ent where kind = p_kind and label = p_label $$;

-- ============ Fixture ============
-- T1: group GA (SA1, SA2)
insert into public.platform_tenants (id, tenant_code, name) values ('10000000-0000-0000-0000-000000000001', 'T1', 'T1');
insert into public.groups (id, platform_tenant_id, group_code, name) values
  ('a1000000-0000-0000-0000-00000000000a', '10000000-0000-0000-0000-000000000001', 'GA', 'GA');
insert into public.schools (id, platform_tenant_id, group_id, school_code, name, slug) values
  ('5a100000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', 'a1000000-0000-0000-0000-00000000000a', 'SA1', 'SA1', 'sa1'),
  ('5a200000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001', 'a1000000-0000-0000-0000-00000000000a', 'SA2', 'SA2', 'sa2');

create temp table ctx (school uuid primary key, year uuid, stage uuid, g1 uuid, sec uuid) on commit drop;
insert into ctx select s.id, gen_random_uuid(), gen_random_uuid(), gen_random_uuid(), gen_random_uuid() from public.schools s;
insert into public.academic_years (id, school_id, name, start_date, end_date, status) select year, school, '2026/2027', '2026-09-01', '2027-06-30', 'active' from ctx;
insert into public.stages (id, school_id, name, sequence_no) select stage, school, 'Primary', 1 from ctx;
insert into public.grade_levels (id, school_id, stage_id, name, sequence_no) select g1, school, stage, 'G1', 1 from ctx;
insert into public.sections (id, school_id, academic_year_id, grade_level_id, name) select sec, school, year, g1, 'A' from ctx;

-- الفاعلون: مديرا المدرستين
select pg_temp.person(l) from unnest(array['sa1','sa2']) l;

-- الطلاب (نطاق GA):
--   stm  انتقل: SA1 transferred [09-01, 12-01) ← SA2 active من 12-01
--   stc  نهاية سنة: SA1 completed فقط — لم يُسجَّل بعد للسنة التالية
--   stw  انسحاب (ولو بالخطأ): SA1 withdrawn فقط
--   stbk ذهب وعاد: SA1 ← SA2 ← SA1 نشط؛ أُدرجت التسجيلات بغير ترتيبها الزمني
insert into ent select 'student', l, gen_random_uuid() from unnest(array['stm','stc','stw','stbk']) l;
insert into public.students (id, platform_tenant_id, identity_scope_id, student_profile_id, official_id, official_id_type, first_name, family_name)
  select e.id, '10000000-0000-0000-0000-000000000001',
         (select id from public.identity_scopes where group_id = 'a1000000-0000-0000-0000-00000000000a'),
         pg_temp.person(e.label), 'N-' || e.label, 'national_id', e.label, e.label
  from ent e where e.kind = 'student';

create function pg_temp.enroll(p_student text, p_school uuid, p_status text, p_from date, p_to date) returns void
language sql as $$
  insert into public.enrollments (school_id, student_id, platform_tenant_id, academic_year_id, grade_level_id, section_id,
                                  identity_scope_id, scope_owner_id, status, effective_from, effective_to)
  select c.school, s.id, s.platform_tenant_id, c.year, c.g1, c.sec, s.identity_scope_id, sc.scope_owner_id, p_status, p_from, p_to
  from ctx c, public.students s, public.schools sc
  where c.school = p_school and sc.id = p_school and s.id = pg_temp.eid('student', p_student);
$$;
select pg_temp.enroll('stm',  '5a100000-0000-0000-0000-000000000001', 'transferred', '2026-09-01', '2026-12-01');
select pg_temp.enroll('stm',  '5a200000-0000-0000-0000-000000000002', 'active',      '2026-12-01', null);
select pg_temp.enroll('stc',  '5a100000-0000-0000-0000-000000000001', 'completed',   '2026-09-01', '2027-06-30');
select pg_temp.enroll('stw',  '5a100000-0000-0000-0000-000000000001', 'withdrawn',   '2026-09-01', '2026-10-01');
select pg_temp.enroll('stbk', '5a100000-0000-0000-0000-000000000001', 'active',      '2026-11-01', null);           -- الأحدث أولاً
select pg_temp.enroll('stbk', '5a100000-0000-0000-0000-000000000001', 'transferred', '2026-09-01', '2026-10-01');
select pg_temp.enroll('stbk', '5a200000-0000-0000-0000-000000000002', 'transferred', '2026-10-01', '2026-11-01');

-- أولياء الأمور:
--   gmv   ولي أمر stm فقط (ارتباط نشط) — يتبع الطالب إلى SA2
--   gtwo  ارتباطان نشطان: stm (في SA2 الآن) و stc (ما زال في SA1)
--   gend  ارتباط منتهٍ بـstc
insert into ent select 'guardian', l, gen_random_uuid() from unnest(array['gmv','gtwo','gend']) l;
insert into public.guardians (id, platform_tenant_id, profile_id, first_name, family_name, phone_e164)
  select id, '10000000-0000-0000-0000-000000000001', pg_temp.person(label), label, label,
         case label when 'gmv' then '+201000000011' when 'gtwo' then '+201000000012' else '+201000000013' end
  from ent where kind = 'guardian';
insert into public.student_guardians (student_id, guardian_id, platform_tenant_id, relationship_type, status, effective_from, effective_to) values
  (pg_temp.eid('student','stm'), pg_temp.eid('guardian','gmv'),  '10000000-0000-0000-0000-000000000001', 'father', 'active', '2026-01-01', null),
  (pg_temp.eid('student','stm'), pg_temp.eid('guardian','gtwo'), '10000000-0000-0000-0000-000000000001', 'mother', 'active', '2026-01-01', null),
  (pg_temp.eid('student','stc'), pg_temp.eid('guardian','gtwo'), '10000000-0000-0000-0000-000000000001', 'mother', 'active', '2026-01-01', null),
  (pg_temp.eid('student','stc'), pg_temp.eid('guardian','gend'), '10000000-0000-0000-0000-000000000001', 'father', 'ended',  '2026-01-01', '2026-06-01');

-- الموظفون:
--   fmv   انتقل: SA1 منتهٍ ← SA2 نشط
--   fend  SA1 منتهٍ فقط
insert into ent select 'staff', l, gen_random_uuid() from unnest(array['fmv','fend']) l;
insert into public.staff (id, platform_tenant_id, profile_id, employee_code, first_name, family_name)
  select id, '10000000-0000-0000-0000-000000000001', pg_temp.person(label), upper(label), label, label from ent where kind = 'staff';
insert into public.staff_school_assignments (staff_id, school_id, platform_tenant_id, job_title, status, effective_from, effective_to) values
  (pg_temp.eid('staff','fmv'),  '5a100000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', 'Teacher', 'ended',  '2025-09-01', '2026-06-30'),
  (pg_temp.eid('staff','fmv'),  '5a200000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001', 'Teacher', 'active', '2026-09-01', null),
  (pg_temp.eid('staff','fend'), '5a100000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', 'Teacher', 'ended',  '2025-09-01', '2026-06-30');

-- العضويات: المديران (نطاق مدرستيهما)، fmv (نطاق SA2 — مدرسته الحالية)، الطلاب وأولياء الأمور بلا نطاقات
insert into ent select 'membership', l, gen_random_uuid() from unnest(array['sa1','sa2','fmv','stm','stc','gmv','gtwo','gend']) l;
insert into public.memberships (id, platform_tenant_id, profile_id)
  select id, '10000000-0000-0000-0000-000000000001', pg_temp.pid(label) from ent where kind = 'membership';
insert into public.membership_scopes (membership_id, platform_tenant_id, scope_type, school_id) values
  (pg_temp.eid('membership','sa1'), '10000000-0000-0000-0000-000000000001', 'school', '5a100000-0000-0000-0000-000000000001'),
  (pg_temp.eid('membership','sa2'), '10000000-0000-0000-0000-000000000001', 'school', '5a200000-0000-0000-0000-000000000002'),
  (pg_temp.eid('membership','fmv'), '10000000-0000-0000-0000-000000000001', 'school', '5a200000-0000-0000-0000-000000000002');

-- ============ التقييم ============
create function pg_temp.lst(p_fn text, p_kind text, p_actor text) returns void
language plpgsql as $$
begin
  perform pg_temp.as_((select auth from ids where label = p_actor));
  perform pg_temp.rec(p_fn || '.' || p_actor,
    format('select string_agg(label, '','' order by label collate "C") from ent where kind = %L and app.%I(id)', p_kind, p_fn));
end $$;

select pg_temp.lst(f, k, a)
  from (values ('student_in_scope', 'student'), ('guardian_in_scope', 'guardian'), ('staff_in_scope', 'staff'),
               ('can_see_membership', 'membership'), ('can_manage_membership', 'membership')) fk(f, k),
       unnest(array['sa1','sa2']) a;

select pg_temp.as_((select auth from ids where label = 'sa1'));
select pg_temp.rec('sa1.manage_stm', $q$select app.can_manage_membership(pg_temp.eid('membership','stm'))::text$q$);
select pg_temp.rec('sa1.manage_gmv', $q$select app.can_manage_membership(pg_temp.eid('membership','gmv'))::text$q$);
select pg_temp.as_(null);

select pg_temp.rec('meta.definer', $q$select (count(*) = 3 and bool_and(pg_get_userbyid(p.proowner) = 'app_owner' and p.prosecdef
                                                 and array_to_string(p.proconfig, ',') like 'search_path=%'))::text
                                      from pg_proc p
                                      where p.oid in ('app.student_in_scope(uuid)'::regprocedure, 'app.staff_in_scope(uuid)'::regprocedure,
                                                      'app.guardian_in_scope(uuid)'::regprocedure)$q$);
select pg_temp.rec('meta.execute', $q$select count(*)::text
                                      from unnest(array['app.student_in_scope(uuid)'::regprocedure, 'app.staff_in_scope(uuid)'::regprocedure,
                                                        'app.guardian_in_scope(uuid)'::regprocedure]) f,
                                           unnest(array['anon','authenticated','public']) g
                                      where has_function_privilege(g, f, 'EXECUTE')$q$);

select plan(14);

-- الطالب: أحدث تسجيل
select is((select v from r where k = 'student_in_scope.sa1'), 'stbk,stc,stw',
          'H2 student: SA1 keeps stc (completed, year end), stw (withdrawn) and stbk (came back) — but NOT stm, who moved to SA2');
select is((select v from r where k = 'student_in_scope.sa2'), 'stm',
          'H2 student: SA2 has stm (latest enrollment) — but NOT stbk, whose SA2 enrollment is superseded, although inserted later');

-- ولي الأمر: ارتباط نشط + الطالب في النطاق الحالي
select is((select v from r where k = 'guardian_in_scope.sa1'), 'gtwo',
          'H2 guardian: SA1 reaches gtwo only through the child still current in SA1; not gmv (child moved), not gend (ended link)');
select is((select v from r where k = 'guardian_in_scope.sa2'), 'gmv,gtwo',
          'H2 guardian: the guardians follow the moved student to SA2');

-- الموظف: تكليف نشط
select is((select v from r where k = 'staff_in_scope.sa1'), '<null>',
          'H2 staff: SA1 reaches neither fmv (moved to SA2) nor fend through ended assignments');
select is((select v from r where k = 'staff_in_scope.sa2'), 'fmv',
          'H2 staff: SA2 reaches fmv through the active assignment');

-- العضويات: الرؤية والإدارة تتبعان العلاقة الحالية
select is((select v from r where k = 'can_see_membership.sa1'), 'gtwo,sa1,stc',
          'H2 memberships: SA1 sees only current relationships — not stm, gmv, gend, fmv');
select is((select v from r where k = 'can_see_membership.sa2'), 'fmv,gmv,gtwo,sa2,stm',
          'H2 memberships: SA2 sees the moved student, their guardians and the moved staff member');
select is((select v from r where k = 'can_manage_membership.sa1'), 'gtwo,stc',
          'H2 manage: SA1 manages only accounts of current relationships (gtwo through stc)');
select is((select v from r where k = 'can_manage_membership.sa2'), 'fmv,gmv,gtwo,stm',
          'H2 manage: SA2 manages the moved student, their guardians and the moved staff member');
select is((select v from r where k = 'sa1.manage_stm'), 'false', 'H2: the former school cannot manage the moved student''s account');
select is((select v from r where k = 'sa1.manage_gmv'), 'false', 'H2: the former school cannot manage the moved student''s guardian account');

-- الدوال المستبدلة
select is((select v from r where k = 'meta.definer'), 'true', 'replaced helpers keep SECURITY DEFINER, owner app_owner, pinned search_path');
select is((select v from r where k = 'meta.execute'), '0',    'replaced helpers: still no EXECUTE for anon, authenticated or PUBLIC');

select * from finish();
rollback;
