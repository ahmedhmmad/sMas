-- M12 — authz_helpers: دوال العلاقة (RLS_MODEL §8.1–§8.3، §10.4) و can_see/can_manage_membership (§10.0)
-- كل دالة تُقيَّم على كل الكيانات لكل فاعل، والنتيجة قائمة كاملة: تثبت ما يُقبل وما يُرفض معاً.
-- التوقعات بدلالة H2 النهائية (M12b): أحدث تسجيل، ارتباط ولي أمر نشط، تكليف نشط. حالات H2 المفصلة في 12b_current_scope.
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

-- الأشخاص: label → (auth, profile)؛ الكيانات: (kind, label) → id
create temp table ids (label text primary key, auth uuid, profile uuid) on commit drop;
create temp table ent (kind text, label text, id uuid, primary key (kind, label)) on commit drop;
grant all on ids, ent to public;

create function pg_temp.person(p_tenant uuid, p_label text) returns uuid
language plpgsql as $$
declare v_auth uuid := gen_random_uuid(); v_profile uuid;
begin
  insert into auth.users (id, email) values (v_auth, p_label || '@m12.invalid');
  insert into public.auth_identities values (v_auth, 'tenant');
  insert into public.profiles (platform_tenant_id, auth_user_id, display_name) values (p_tenant, v_auth, p_label) returning id into v_profile;
  insert into ids values (p_label, v_auth, v_profile);
  return v_profile;
end $$;
create function pg_temp.pid(p_label text) returns uuid language sql as $$ select profile from ids where label = p_label $$;
create function pg_temp.eid(p_kind text, p_label text) returns uuid language sql as $$ select id from ent where kind = p_kind and label = p_label $$;

-- ============ Fixture ============
-- T1: group GA (SA1, SA2)، group GB (SB1)، مستقلة SS — T2: مستقلة S2
insert into public.platform_tenants (id, tenant_code, name) values
  ('10000000-0000-0000-0000-000000000001', 'T1', 'T1'), ('20000000-0000-0000-0000-000000000002', 'T2', 'T2');
insert into public.groups (id, platform_tenant_id, group_code, name) values
  ('a1000000-0000-0000-0000-00000000000a', '10000000-0000-0000-0000-000000000001', 'GA', 'GA'),
  ('a2000000-0000-0000-0000-00000000000b', '10000000-0000-0000-0000-000000000001', 'GB', 'GB');
insert into public.schools (id, platform_tenant_id, group_id, school_code, name, slug) values
  ('5a100000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', 'a1000000-0000-0000-0000-00000000000a', 'SA1', 'SA1', 'sa1'),
  ('5a200000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001', 'a1000000-0000-0000-0000-00000000000a', 'SA2', 'SA2', 'sa2'),
  ('5b100000-0000-0000-0000-000000000003', '10000000-0000-0000-0000-000000000001', 'a2000000-0000-0000-0000-00000000000b', 'SB1', 'SB1', 'sb1'),
  ('55000000-0000-0000-0000-000000000004', '10000000-0000-0000-0000-000000000001', null, 'SS', 'SS', 'ss'),
  ('52000000-0000-0000-0000-000000000005', '20000000-0000-0000-0000-000000000002', null, 'S2', 'S2', 's2');

insert into ent select 'scope', 'iga', id from public.identity_scopes where group_id  = 'a1000000-0000-0000-0000-00000000000a';
insert into ent select 'scope', 'igb', id from public.identity_scopes where group_id  = 'a2000000-0000-0000-0000-00000000000b';
insert into ent select 'scope', 'iss', id from public.identity_scopes where school_id = '55000000-0000-0000-0000-000000000004';
insert into ent select 'scope', 'is2', id from public.identity_scopes where school_id = '52000000-0000-0000-0000-000000000005';

-- البنية الأكاديمية لمدارس التسجيل
create temp table ctx (school uuid primary key, year uuid, stage uuid, g1 uuid, sec uuid) on commit drop;
insert into ctx select s.id, gen_random_uuid(), gen_random_uuid(), gen_random_uuid(), gen_random_uuid() from public.schools s;
insert into public.academic_years (id, school_id, name, start_date, end_date, status) select year, school, '2026/2027', '2026-09-01', '2027-06-30', 'active' from ctx;
insert into public.stages (id, school_id, name, sequence_no) select stage, school, 'Primary', 1 from ctx;
insert into public.grade_levels (id, school_id, stage_id, name, sequence_no) select g1, school, stage, 'G1', 1 from ctx;
insert into public.sections (id, school_id, academic_year_id, grade_level_id, name) select sec, school, year, g1, 'A' from ctx;

-- الفاعلون: ta (نطاق tenant)، gm (GA)، sa1، sa2، sb (SB1)، t2 (tenant في T2)، plat (سياق منصة، بلا profile)
select pg_temp.person('10000000-0000-0000-0000-000000000001', l) from unnest(array['ta','gm','sa1','sa2','sb','multi','fa1','fold','fnone','gp','garch','sta','stb','sto','sts','stx']) l;
select pg_temp.person('20000000-0000-0000-0000-000000000002', l) from unnest(array['t2','st2']) l;
insert into auth.users (id, email) values ('c7000000-0000-0000-0000-000000000007', 'plat@m12.invalid');
insert into public.auth_identities values ('c7000000-0000-0000-0000-000000000007', 'platform');
insert into ids values ('plat', 'c7000000-0000-0000-0000-000000000007', null);

-- الأسر
insert into ent values ('family', 'fama', gen_random_uuid()), ('family', 'famx', gen_random_uuid());
insert into public.families (id, platform_tenant_id, family_name)
  select id, '10000000-0000-0000-0000-000000000001', label from ent where kind = 'family';

-- الطلاب: sta (GA، SA1 نشط، أسرة fama)، stb (GA، SA2 نشط)، sto (GA، SA1 مكتمل — تاريخ)،
--         sts (SS نشط)، stx (GA، بلا تسجيل، أسرة famx)، st2 (T2، S2)
insert into ent select 'student', l, gen_random_uuid() from unnest(array['sta','stb','sto','sts','stx','st2']) l;
insert into public.students (id, platform_tenant_id, identity_scope_id, student_profile_id, family_id, official_id, official_id_type, first_name, family_name)
  select e.id, p.platform_tenant_id,
         case e.label when 'sts' then pg_temp.eid('scope','iss') when 'st2' then pg_temp.eid('scope','is2') else pg_temp.eid('scope','iga') end,
         p.id,
         case e.label when 'sta' then pg_temp.eid('family','fama') when 'stx' then pg_temp.eid('family','famx') end,
         'N-' || e.label, 'national_id', e.label, e.label
  from ent e join public.profiles p on p.id = pg_temp.pid(e.label)
  where e.kind = 'student';

create function pg_temp.enroll(p_student text, p_school uuid, p_status text, p_to date) returns void
language sql as $$
  insert into public.enrollments (school_id, student_id, platform_tenant_id, academic_year_id, grade_level_id, section_id,
                                  identity_scope_id, scope_owner_id, status, effective_from, effective_to)
  select c.school, s.id, s.platform_tenant_id, c.year, c.g1, c.sec, s.identity_scope_id, sc.scope_owner_id, p_status, '2026-09-01', p_to
  from ctx c, public.students s, public.schools sc
  where c.school = p_school and sc.id = p_school and s.id = pg_temp.eid('student', p_student);
$$;
select pg_temp.enroll('sta', '5a100000-0000-0000-0000-000000000001', 'active',    null);
select pg_temp.enroll('stb', '5a200000-0000-0000-0000-000000000002', 'active',    null);
select pg_temp.enroll('sto', '5a100000-0000-0000-0000-000000000001', 'completed', '2026-12-01');
select pg_temp.enroll('sts', '55000000-0000-0000-0000-000000000004', 'active',    null);
select pg_temp.enroll('st2', '52000000-0000-0000-0000-000000000005', 'active',    null);

-- أولياء الأمور: gp (نشط → sta ارتباط نشط، stb ارتباط منتهٍ)، garch (مؤرشف → sts نشط)، gnone (بلا ارتباط ولا profile)
insert into ent select 'guardian', l, gen_random_uuid() from unnest(array['gp','garch','gnone']) l;
insert into public.guardians (id, platform_tenant_id, profile_id, first_name, family_name, phone_e164, status, archived_at)
  select id, '10000000-0000-0000-0000-000000000001', pg_temp.pid(label), label, label,
         case label when 'gp' then '+201000000001' when 'garch' then '+201000000002' else '+201000000003' end,
         case label when 'garch' then 'archived' else 'active' end,
         case label when 'garch' then now() end
  from ent where kind = 'guardian';
insert into public.student_guardians (student_id, guardian_id, platform_tenant_id, relationship_type, status, effective_from, effective_to) values
  (pg_temp.eid('student','sta'), pg_temp.eid('guardian','gp'),    '10000000-0000-0000-0000-000000000001', 'father', 'active', '2026-01-01', null),
  (pg_temp.eid('student','stb'), pg_temp.eid('guardian','gp'),    '10000000-0000-0000-0000-000000000001', 'father', 'ended',  '2026-01-01', '2026-06-01'),
  (pg_temp.eid('student','sts'), pg_temp.eid('guardian','garch'), '10000000-0000-0000-0000-000000000001', 'mother', 'active', '2026-01-01', null);

-- الموظفون: fa1 (تكليف SA1 نشط)، fold (تكليف SB1 منتهٍ)، fnone (بلا تكليف)
insert into ent select 'staff', l, gen_random_uuid() from unnest(array['fa1','fold','fnone']) l;
insert into public.staff (id, platform_tenant_id, profile_id, employee_code, first_name, family_name)
  select id, '10000000-0000-0000-0000-000000000001', pg_temp.pid(label), upper(label), label, label from ent where kind = 'staff';
insert into public.staff_school_assignments (staff_id, school_id, platform_tenant_id, job_title, status, effective_from, effective_to) values
  (pg_temp.eid('staff','fa1'),  '5a100000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', 'Teacher', 'active', '2026-09-01', null),
  (pg_temp.eid('staff','fold'), '5b100000-0000-0000-0000-000000000003', '10000000-0000-0000-0000-000000000001', 'Teacher', 'ended',  '2025-09-01', '2026-06-30');

-- العضويات: عضوية لكل profile عدا fnone و garch و stb و sts و st2 (لا يحتاجها الاختبار)
insert into ent select 'membership', l, gen_random_uuid()
  from unnest(array['ta','gm','sa1','sa2','sb','multi','fa1','fold','gp','sta','sto','stx','t2']) l;
insert into public.memberships (id, platform_tenant_id, profile_id)
  select e.id, p.platform_tenant_id, p.id from ent e join public.profiles p on p.id = pg_temp.pid(e.label) where e.kind = 'membership';
insert into public.membership_scopes (membership_id, platform_tenant_id, scope_type, group_id, school_id) values
  (pg_temp.eid('membership','ta'),    '10000000-0000-0000-0000-000000000001', 'tenant', null, null),
  (pg_temp.eid('membership','gm'),    '10000000-0000-0000-0000-000000000001', 'group',  'a1000000-0000-0000-0000-00000000000a', null),
  (pg_temp.eid('membership','sa1'),   '10000000-0000-0000-0000-000000000001', 'school', null, '5a100000-0000-0000-0000-000000000001'),
  (pg_temp.eid('membership','sa2'),   '10000000-0000-0000-0000-000000000001', 'school', null, '5a200000-0000-0000-0000-000000000002'),
  (pg_temp.eid('membership','sb'),    '10000000-0000-0000-0000-000000000001', 'school', null, '5b100000-0000-0000-0000-000000000003'),
  (pg_temp.eid('membership','multi'), '10000000-0000-0000-0000-000000000001', 'school', null, '5a100000-0000-0000-0000-000000000001'),
  (pg_temp.eid('membership','multi'), '10000000-0000-0000-0000-000000000001', 'school', null, '5b100000-0000-0000-0000-000000000003'),
  (pg_temp.eid('membership','fa1'),   '10000000-0000-0000-0000-000000000001', 'school', null, '5a100000-0000-0000-0000-000000000001'),
  (pg_temp.eid('membership','t2'),    '20000000-0000-0000-0000-000000000002', 'tenant', null, null);
-- fold، gp، sta، sto، stx: بلا نطاقات (موظف سابق، ولي أمر، طلاب)

-- ============ التقييم ============
-- القائمة الكاملة للكيانات من نوع p_kind التي تُرجع لها الدالة true، بهوية الفاعل p_actor (NULL = service)
create function pg_temp.lst(p_fn text, p_kind text, p_actor text) returns void
language plpgsql as $$
begin
  perform pg_temp.as_((select auth from ids where label = p_actor));
  perform pg_temp.rec(p_fn || '.' || coalesce(p_actor, 'service'),
    format('select string_agg(label, '','' order by label collate "C") from ent where kind = %L and app.%I(id)', p_kind, p_fn));
end $$;

select pg_temp.lst('student_in_scope', 'student', a)
  from unnest(array['ta','gm','sa1','sa2','sb','t2','plat','gp',null]) a;
select pg_temp.lst('student_linked_to_guardian', 'student', a) from unnest(array['gp','garch','sa1']) a;
select pg_temp.lst('student_is_self',            'student', a) from unnest(array['sta','gp','sa1']) a;
select pg_temp.lst('staff_in_scope',    'staff',    a) from unnest(array['ta','gm','sa1','sa2','sb','t2']) a;
select pg_temp.lst('guardian_in_scope', 'guardian', a) from unnest(array['ta','gm','sa1','sa2','sb']) a;
select pg_temp.lst('family_in_scope',   'family',   a) from unnest(array['ta','sa1','sa2']) a;
select pg_temp.lst('can_access_identity_scope', 'scope', a) from unnest(array['ta','gm','sa1','t2','plat']) a;
select pg_temp.lst('can_see_membership',    'membership', a) from unnest(array['ta','gm','sa1','sa2','sb','t2','plat','gp',null]) a;
select pg_temp.lst('can_manage_membership', 'membership', a) from unnest(array['ta','gm','sa1','sa2','sb','t2','plat','gp',null]) a;

select pg_temp.as_((select auth from ids where label = 'sa1'));
select pg_temp.rec('sa1.school_SA1', $q$select app.can_access_school('5a100000-0000-0000-0000-000000000001')::text$q$);

select pg_temp.as_((select auth from ids where label = 'gp'));
select pg_temp.rec('cg.gp',    $q$select (app.current_guardian_id() = pg_temp.eid('guardian','gp'))::text$q$);
select pg_temp.as_((select auth from ids where label = 'garch'));
select pg_temp.rec('cg.garch', $q$select app.current_guardian_id()::text$q$);
select pg_temp.as_((select auth from ids where label = 'sa1'));
select pg_temp.rec('cg.sa1',   $q$select app.current_guardian_id()::text$q$);
select pg_temp.as_(null);

-- الدوال والصلاحيات — تُقرأ قبل منح EXECUTE المؤقت أدناه
create temp table fns on commit drop as
  select unnest(array[
    'app.student_in_scope(uuid)', 'app.student_linked_to_guardian(uuid)', 'app.student_is_self(uuid)',
    'app.staff_in_scope(uuid)', 'app.guardian_in_scope(uuid)', 'app.family_in_scope(uuid)',
    'app.can_access_identity_scope(uuid)', 'app.current_guardian_id()',
    'app.can_see_membership(uuid)', 'app.can_manage_membership(uuid)'])::regprocedure as oid;
select pg_temp.rec('meta.definer', $q$select (count(*) = 10 and bool_and(pg_get_userbyid(p.proowner) = 'app_owner' and p.prosecdef
                                                 and array_to_string(p.proconfig, ',') like 'search_path=%'))::text
                                      from pg_proc p join fns f on f.oid = p.oid$q$);
select pg_temp.rec('meta.execute', $q$select coalesce(string_agg(g || ':' || f.oid::regprocedure::text, ','), 'none') from fns f, unnest(array['anon','authenticated','public']) g
                                      where has_function_privilege(g, f.oid, 'EXECUTE')$q$);

-- تحت FORCE RLS: authenticated لا يرى أي صف مباشرة (لا سياسات بعد)، والدالة ترى العلاقة.
-- EXECUTE يُمنح هنا مؤقتاً فقط (يُلغى بالـrollback) — المنح الفعلي في M20.
grant execute on function app.student_in_scope(uuid), app.can_see_membership(uuid) to authenticated;
select pg_temp.as_((select auth from ids where label = 'sa1'));
set local role authenticated;
select pg_temp.rec('rls.direct',  'select count(*)::text from public.enrollments');
select pg_temp.rec('rls.student', $q$select app.student_in_scope((select id from ent where kind = 'student' and label = 'sta'))::text$q$);
select pg_temp.rec('rls.member',  $q$select app.can_see_membership((select id from ent where kind = 'membership' and label = 'fa1'))::text$q$);
reset role;
select pg_temp.as_(null);

select plan(61);

-- ============ student_in_scope — أي تسجيل في مدرسة ضمن النطاق ============
select is((select v from r where k = 'student_in_scope.ta'),      'sta,stb,sto,sts', 'student_in_scope: tenant scope → every enrolled T1 student; not the unenrolled stx, not T2');
select is((select v from r where k = 'student_in_scope.gm'),      'sta,stb,sto',     'student_in_scope: group scope → students enrolled in GA schools only (not SS)');
select is((select v from r where k = 'student_in_scope.sa1'),     'sta,sto',         'student_in_scope: school scope → its students, including one whose latest enrollment is completed (H2)');
select is((select v from r where k = 'student_in_scope.sa2'),     'stb',             'student_in_scope: SA2 does not see SA1 students in the same group (§1.1 rule 5)');
select is((select v from r where k = 'student_in_scope.sb'),      '<null>',          'student_in_scope: another group sees nothing');
select is((select v from r where k = 'student_in_scope.t2'),      'st2',             'student_in_scope: T2 tenant scope sees only T2');
select is((select v from r where k = 'student_in_scope.plat'),    '<null>',          'student_in_scope: platform context has no tenant scope (C3/G10)');
select is((select v from r where k = 'student_in_scope.gp'),      '<null>',          'student_in_scope: a guardian has no scope path');
select is((select v from r where k = 'student_in_scope.service'), '<null>',          'student_in_scope: service context');

-- ============ student_linked_to_guardian / student_is_self ============
select is((select v from r where k = 'student_linked_to_guardian.gp'),    'sta',    'linked_to_guardian: active link only — the ended link to stb grants nothing');
select is((select v from r where k = 'student_linked_to_guardian.garch'), '<null>', 'linked_to_guardian: an archived guardian with an active link sees nothing');
select is((select v from r where k = 'student_linked_to_guardian.sa1'),   '<null>', 'linked_to_guardian: staff are not guardians');
select is((select v from r where k = 'student_is_self.sta'), 'sta',    'student_is_self: the student sees exactly itself');
select is((select v from r where k = 'student_is_self.gp'),  '<null>', 'student_is_self: a guardian is not the student');
select is((select v from r where k = 'student_is_self.sa1'), '<null>', 'student_is_self: staff are not the student');

-- ============ staff / guardian / family ============
select is((select v from r where k = 'staff_in_scope.ta'),  'fa1',      'staff_in_scope: tenant scope → active assignments only; not fold (ended), not fnone (H2)');
select is((select v from r where k = 'staff_in_scope.gm'),  'fa1',      'staff_in_scope: group scope → GA assignments only');
select is((select v from r where k = 'staff_in_scope.sa1'), 'fa1',      'staff_in_scope: school scope → its staff');
select is((select v from r where k = 'staff_in_scope.sa2'), '<null>',   'staff_in_scope: SA2 does not see SA1 staff');
select is((select v from r where k = 'staff_in_scope.sb'),  '<null>',   'staff_in_scope: an ended assignment grants its former school nothing (H2)');
select is((select v from r where k = 'staff_in_scope.t2'),  '<null>',   'staff_in_scope: never across tenants');

select is((select v from r where k = 'guardian_in_scope.ta'),  'garch,gp', 'guardian_in_scope: tenant scope → every linked guardian; gnone has no link');
select is((select v from r where k = 'guardian_in_scope.gm'),  'gp',       'guardian_in_scope: group scope → guardians of GA students');
select is((select v from r where k = 'guardian_in_scope.sa1'), 'gp',       'guardian_in_scope: school scope via an active link');
select is((select v from r where k = 'guardian_in_scope.sa2'), '<null>',   'guardian_in_scope: an ended link grants nothing, although stb is current in SA2 (H2)');
select is((select v from r where k = 'guardian_in_scope.sb'),  '<null>',   'guardian_in_scope: another group sees nothing');

select is((select v from r where k = 'family_in_scope.ta'),  'fama',   'family_in_scope: a family with an enrolled student; famx (unenrolled) never');
select is((select v from r where k = 'family_in_scope.sa1'), 'fama',   'family_in_scope: school scope');
select is((select v from r where k = 'family_in_scope.sa2'), '<null>', 'family_in_scope: a family with no student in scope');

-- ============ can_access_identity_scope — نص RLS_MODEL §8.4/§10.4 حرفياً ============
select is((select v from r where k = 'can_access_identity_scope.ta'),   'iga,igb,iss', 'identity scope: tenant scope → every T1 scope');
select is((select v from r where k = 'can_access_identity_scope.gm'),   'iga',         'identity scope: group scope → its group scope only');
select is((select v from r where k = 'can_access_identity_scope.sa1'),  '<null>',      'identity scope: a school-scoped member of a grouped school has NO access to its group scope (as specified — see report)');
select is((select v from r where k = 'sa1.school_SA1'),                 'true',        '…while the same member does access its school');
select is((select v from r where k = 'can_access_identity_scope.t2'),   'is2',         'identity scope: T2 only');
select is((select v from r where k = 'can_access_identity_scope.plat'), '<null>',      'identity scope: platform context has none');

-- ============ current_guardian_id ============
select is((select v from r where k = 'cg.gp'),    'true',   'current_guardian_id: the active guardian of the actor');
select is((select v from r where k = 'cg.garch'), '<null>', 'current_guardian_id: an archived guardian is not current');
select is((select v from r where k = 'cg.sa1'),   '<null>', 'current_guardian_id: a staff member has none');

-- ============ can_see_membership — تقاطع ============
select is((select v from r where k = 'can_see_membership.ta'),      'fa1,gm,gp,multi,sa1,sa2,sb,sta,sto,ta',      'can_see: tenant scope → every T1 membership reachable by scope or current relationship; not fold (ended), not stx, not T2');
select is((select v from r where k = 'can_see_membership.gm'),      'fa1,gm,gp,multi,sa1,sa2,sta,sto',            'can_see: group scope → GA members; multi by intersection; not the tenant admin, not SB1');
select is((select v from r where k = 'can_see_membership.sa1'),     'fa1,gp,multi,sa1,sta,sto',                   'can_see: school scope → its staff, guardian, students; not the group manager above it');
select is((select v from r where k = 'can_see_membership.sa2'),     'sa2',                                        'can_see: SA2 does not see the guardian through an ended link (H2), nothing of SA1');
select is((select v from r where k = 'can_see_membership.sb'),      'multi,sb',                                   'can_see: not the former staff member (H2); multi by intersection');
select is((select v from r where k = 'can_see_membership.t2'),      't2',                                         'can_see: never across tenants');
select is((select v from r where k = 'can_see_membership.plat'),    '<null>',                                     'can_see: platform context sees no tenant membership');
select is((select v from r where k = 'can_see_membership.gp'),      '<null>',                                     'can_see: a guardian has no scope path (self is a policy branch, not this helper)');
select is((select v from r where k = 'can_see_membership.service'), '<null>',                                     'can_see: service context');

-- ============ can_manage_membership — احتواء، ولا إدارة ذاتية ============
select is((select v from r where k = 'can_manage_membership.ta'),      'fa1,fold,gm,gp,multi,sa1,sa2,sb,sta,sto,stx', 'can_manage: tenant scope → every T1 membership except itself (F5), including scope-less ones');
select is((select v from r where k = 'can_manage_membership.gm'),      'fa1,gp,sa1,sa2,sta,sto',                     'can_manage: group scope → not multi (SB1 ⊄ GA, F4), not the tenant admin, not itself');
select is((select v from r where k = 'can_manage_membership.sa1'),     'fa1,gp,sta,sto',                             'can_manage: school scope → not multi (F4: SA1 admin cannot act on SB1), not gm, not itself');
select is((select v from r where k = 'can_manage_membership.sa2'),     '<null>',                                     'can_manage: SA2 does not manage the guardian through an ended link (H2)');
select is((select v from r where k = 'can_manage_membership.sb'),      '<null>',                                     'can_manage: SB1 → not multi (SA1 ⊄ SB1), not the scope-less former staff member');
select is((select v from r where k = 'can_manage_membership.t2'),      '<null>',                                     'can_manage: T2 admin manages nothing in T1 and not itself');
select is((select v from r where k = 'can_manage_membership.plat'),    '<null>',                                     'can_manage: platform context manages no tenant membership');
select is((select v from r where k = 'can_manage_membership.gp'),      '<null>',                                     'can_manage: a guardian manages nothing');
select is((select v from r where k = 'can_manage_membership.service'), '<null>',                                     'can_manage: service context');

-- ============ الدوال ============
select is((select v from r where k = 'meta.definer'), 'true', 'the 10 helpers: SECURITY DEFINER, owned by app_owner, search_path pinned');
select is((select v from r where k = 'meta.execute'), 'authenticated:app.can_access_identity_scope(uuid)',
          'EXECUTE only where a policy needs it: authenticated on can_access_identity_scope (M14); nothing for anon or PUBLIC');

-- ============ تحت FORCE RLS ============
select is((select v from r where k = 'rls.direct'),  '0',    'authenticated reads no enrollment directly (FORCE RLS, no policy)');
select is((select v from r where k = 'rls.student'), 'true', 'student_in_scope still resolves the relationship (app_owner BYPASSRLS)');
select is((select v from r where k = 'rls.member'),  'true', 'can_see_membership still resolves scopes and relationships');

select * from finish();
rollback;
