-- M16 — policies_academic: الجداول الأكاديمية الخمسة (School-level)
-- لكل فاعل قائمة كاملة بالمدارس المرئية في كل جدول؛ فصل الصلاحيات لكل مورد؛ الكتابة بضوابط إيجابية.
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

create temp table ids (label text primary key, auth uuid) on commit drop;
grant all on ids to public;

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

-- ============ Fixture ============
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
create temp table sch on commit drop as select id, school_code as code from public.schools;
grant select on sch to public;

-- لكل مدرسة: سنة، فصل، مرحلة، صف، شعبة
create temp table ctx (school uuid primary key, year uuid, stage uuid, grade uuid, sec uuid) on commit drop;
insert into ctx select id, gen_random_uuid(), gen_random_uuid(), gen_random_uuid(), gen_random_uuid() from public.schools;
grant select on ctx to public;
insert into public.academic_years (id, school_id, name, start_date, end_date, status) select year, school, '2026/2027', '2026-09-01', '2027-06-30', 'active' from ctx;
insert into public.terms (academic_year_id, school_id, year_start_date, year_end_date, name, sequence_no, start_date, end_date)
  select year, school, '2026-09-01', '2027-06-30', 'T1', 1, '2026-09-01', '2026-12-15' from ctx;
insert into public.stages (id, school_id, name, sequence_no) select stage, school, 'Primary', 1 from ctx;
insert into public.grade_levels (id, school_id, stage_id, name, sequence_no) select grade, school, stage, 'G1', 1 from ctx;
insert into public.sections (id, school_id, academic_year_id, grade_level_id, name) select sec, school, year, grade, 'A' from ctx;

-- الصلاحيات (البذر الحقيقي في M23) والأدوار
insert into public.permissions (code, resource, operation, description)
  select c, split_part(c, '.', 1), split_part(c, '.', 2), 'test' from unnest(array[
    'academic_year.read','academic_year.create','academic_year.update',
    'term.read','term.manage','stage.read','stage.manage','grade_level.read','grade_level.manage','section.read','section.manage']) c;
insert into public.roles (id, platform_tenant_id, code, name, is_system) values
  ('71000000-0000-0000-0000-000000000001', null, 'acad_admin', 'Admin',   true),
  ('72000000-0000-0000-0000-000000000002', null, 'reader',     'Reader',  true),
  ('73000000-0000-0000-0000-000000000003', null, 'yr_creator', 'YrC',     true),
  ('74000000-0000-0000-0000-000000000004', null, 'sec_only',   'SecOnly', true);
insert into public.role_permissions (role_id, permission_id)
  select '71000000-0000-0000-0000-000000000001'::uuid, id from public.permissions
  union all select '72000000-0000-0000-0000-000000000002'::uuid, id from public.permissions where operation = 'read'
  union all select '73000000-0000-0000-0000-000000000003'::uuid, id from public.permissions where code in ('academic_year.read','academic_year.create')
  union all select '74000000-0000-0000-0000-000000000004'::uuid, id from public.permissions where code = 'section.read';

create function pg_temp.member(p_label text, p_tenant uuid, p_role uuid, p_scopes text[]) returns void
language plpgsql as $$
declare v_auth uuid := gen_random_uuid(); v_profile uuid; v_m uuid; s text;
begin
  insert into auth.users (id, email) values (v_auth, p_label || '@m16.invalid');
  insert into public.auth_identities values (v_auth, 'tenant');
  insert into public.profiles (platform_tenant_id, auth_user_id, display_name) values (p_tenant, v_auth, p_label) returning id into v_profile;
  insert into public.memberships (platform_tenant_id, profile_id) values (p_tenant, v_profile) returning id into v_m;
  if p_role is not null then
    insert into public.membership_roles (membership_id, role_id, platform_tenant_id, role_owner_key)
      values (v_m, p_role, p_tenant, '00000000-0000-0000-0000-000000000000');
  end if;
  foreach s in array coalesce(p_scopes, '{}') loop
    if s = 'tenant' then
      insert into public.membership_scopes (membership_id, platform_tenant_id, scope_type) values (v_m, p_tenant, 'tenant');
    elsif s like 'G%' then
      insert into public.membership_scopes (membership_id, platform_tenant_id, scope_type, group_id)
        values (v_m, p_tenant, 'group', (select id from public.groups where group_code = s));
    else
      insert into public.membership_scopes (membership_id, platform_tenant_id, scope_type, school_id)
        values (v_m, p_tenant, 'school', (select id from public.schools where school_code = s));
    end if;
  end loop;
  insert into ids values (p_label, v_auth);
end $$;
select pg_temp.member('ta',      '10000000-0000-0000-0000-000000000001', '71000000-0000-0000-0000-000000000001', array['tenant']);
select pg_temp.member('gm',      '10000000-0000-0000-0000-000000000001', '71000000-0000-0000-0000-000000000001', array['GA']);
select pg_temp.member('sa1',     '10000000-0000-0000-0000-000000000001', '71000000-0000-0000-0000-000000000001', array['SA1']);
select pg_temp.member('multi',   '10000000-0000-0000-0000-000000000001', '71000000-0000-0000-0000-000000000001', array['SA2','SS']);
select pg_temp.member('tch',     '10000000-0000-0000-0000-000000000001', '72000000-0000-0000-0000-000000000002', array['SA1']);
select pg_temp.member('yc',      '10000000-0000-0000-0000-000000000001', '73000000-0000-0000-0000-000000000003', array['SA1']);
select pg_temp.member('so',      '10000000-0000-0000-0000-000000000001', '74000000-0000-0000-0000-000000000004', array['SA1']);
select pg_temp.member('noperm',  '10000000-0000-0000-0000-000000000001', null,                                   array['SA1']);
select pg_temp.member('noscope', '10000000-0000-0000-0000-000000000001', '71000000-0000-0000-0000-000000000001', null);
select pg_temp.member('t2a',     '20000000-0000-0000-0000-000000000002', '71000000-0000-0000-0000-000000000001', array['tenant']);

-- Platform Admin بكل الصلاحيات الأكاديمية في سياق المنصة
insert into public.platform_admin_roles (id, code, name) values ('81000000-0000-0000-0000-000000000001', 'pa_all', 'All');
insert into public.platform_admin_role_permissions select '81000000-0000-0000-0000-000000000001', id from public.permissions;
insert into auth.users (id, email) values ('c7000000-0000-0000-0000-000000000007', 'pa@m16.invalid');
insert into public.auth_identities values ('c7000000-0000-0000-0000-000000000007', 'platform');
insert into public.system_users (id, auth_user_id, display_name) values ('d7000000-0000-0000-0000-000000000007', 'c7000000-0000-0000-0000-000000000007', 'pa');
insert into public.platform_admin_assignments (system_user_id, platform_admin_role_id) values ('d7000000-0000-0000-0000-000000000007', '81000000-0000-0000-0000-000000000001');
insert into ids values ('pa', 'c7000000-0000-0000-0000-000000000007');

-- ============ القراءة: المدارس المرئية في كل جدول ============
create function pg_temp.vis() returns text language sql as $$
  select format('ay=%s|te=%s|st=%s|gl=%s|se=%s',
    (select coalesce(string_agg(s.code, ',' order by s.code collate "C"), '') from public.academic_years x join sch s on s.id = x.school_id),
    (select coalesce(string_agg(s.code, ',' order by s.code collate "C"), '') from public.terms          x join sch s on s.id = x.school_id),
    (select coalesce(string_agg(s.code, ',' order by s.code collate "C"), '') from public.stages         x join sch s on s.id = x.school_id),
    (select coalesce(string_agg(s.code, ',' order by s.code collate "C"), '') from public.grade_levels   x join sch s on s.id = x.school_id),
    (select coalesce(string_agg(s.code, ',' order by s.code collate "C"), '') from public.sections       x join sch s on s.id = x.school_id)) $$;
select pg_temp.run('vis.' || l, l, 'select pg_temp.vis()')
  from unnest(array['ta','gm','sa1','multi','tch','yc','so','noperm','noscope','t2a','pa','anon']) l;

-- ============ الكتابة ============
create function pg_temp.c(p_school text, p_col text) returns uuid language sql as $$
  select case p_col when 'year' then c.year when 'stage' then c.stage when 'grade' then c.grade end
  from ctx c join sch s on s.id = c.school where s.code = p_school $$;

select pg_temp.run('w.sa1_stage_SA1',  'sa1', $q$insert into public.stages (school_id, name, sequence_no) values ('5a100000-0000-0000-0000-000000000001','P9',9) returning 'ok'$q$);
select pg_temp.run('w.sa1_stage_SA2',  'sa1', $q$insert into public.stages (school_id, name, sequence_no) values ('5a200000-0000-0000-0000-000000000002','P9',9) returning 'ok'$q$);
select pg_temp.run('w.tch_stage_SA1',  'tch', $q$insert into public.stages (school_id, name, sequence_no) values ('5a100000-0000-0000-0000-000000000001','P8',8) returning 'ok'$q$);
select pg_temp.run('w.noscope_stage',  'noscope', $q$insert into public.stages (school_id, name, sequence_no) values ('5a100000-0000-0000-0000-000000000001','P7',7) returning 'ok'$q$);
select pg_temp.run('w.pa_stage',       'pa',  $q$insert into public.stages (school_id, name, sequence_no) values ('5a100000-0000-0000-0000-000000000001','P6',6) returning 'ok'$q$);
select pg_temp.run('w.anon_stage',     'anon',$q$insert into public.stages (school_id, name, sequence_no) values ('5a100000-0000-0000-0000-000000000001','P5',5) returning 'ok'$q$);
select pg_temp.run('w.sa1_stage_move_SA2', 'sa1', $q$update public.stages set school_id = '5a200000-0000-0000-0000-000000000002' where name = 'P9' and school_id = '5a100000-0000-0000-0000-000000000001' returning 'ok'$q$);
select pg_temp.run('w.ta_stage_move_T2',   'ta',  $q$update public.stages set school_id = '52000000-0000-0000-0000-000000000005' where name = 'P9' and school_id = '5a100000-0000-0000-0000-000000000001' returning 'ok'$q$);

select pg_temp.run('w.sa1_year',       'sa1', $q$insert into public.academic_years (school_id, name, start_date, end_date) values ('5a100000-0000-0000-0000-000000000001','2027/2028','2027-09-01','2028-06-30') returning 'ok'$q$);
select pg_temp.run('w.yc_year',        'yc',  $q$insert into public.academic_years (school_id, name, start_date, end_date) values ('5a100000-0000-0000-0000-000000000001','2028/2029','2028-09-01','2029-06-30') returning 'ok'$q$);
select pg_temp.run('w.yc_year_update', 'yc',  $q$with u as (update public.academic_years set name = name where school_id = '5a100000-0000-0000-0000-000000000001' returning 1) select count(*)::text from u$q$);
select pg_temp.run('w.sa1_year_update','sa1', $q$with u as (update public.academic_years set name = name where school_id = '5a100000-0000-0000-0000-000000000001' and name = '2026/2027' returning 1) select count(*)::text from u$q$);
select pg_temp.run('w.so_year',        'so',  $q$insert into public.academic_years (school_id, name, start_date, end_date) values ('5a100000-0000-0000-0000-000000000001','2029/2030','2029-09-01','2030-06-30') returning 'ok'$q$);

select pg_temp.run('w.sa1_section_SA2', 'sa1', $q$with u as (update public.sections set name = 'B' where school_id = '5a200000-0000-0000-0000-000000000002' returning 1) select count(*)::text from u$q$);
select pg_temp.run('w.sa1_section_SA1', 'sa1', $q$with u as (update public.sections set name = 'B' where school_id = '5a100000-0000-0000-0000-000000000001' returning 1) select count(*)::text from u$q$);
select pg_temp.run('w.so_section_SA1',  'so',  $q$with u as (update public.sections set name = 'C' where school_id = '5a100000-0000-0000-0000-000000000001' returning 1) select count(*)::text from u$q$);
select pg_temp.run('w.t2a_section_SA1', 't2a', $q$with u as (update public.sections set name = 'C' where school_id = '5a100000-0000-0000-0000-000000000001' returning 1) select count(*)::text from u$q$);
select pg_temp.run('w.gm_section_SB1',  'gm',  format($q$insert into public.sections (school_id, academic_year_id, grade_level_id, name) values ('5b100000-0000-0000-0000-000000000003', %L, %L, 'Z') returning 'ok'$q$,
                                                      pg_temp.c('SB1','year'), pg_temp.c('SB1','grade')));
select pg_temp.run('w.gm_section_SA2',  'gm',  format($q$insert into public.sections (school_id, academic_year_id, grade_level_id, name) values ('5a200000-0000-0000-0000-000000000002', %L, %L, 'Z') returning 'ok'$q$,
                                                      pg_temp.c('SA2','year'), pg_temp.c('SA2','grade')));
select pg_temp.run('w.multi_term_SS',   'multi', format($q$insert into public.terms (academic_year_id, school_id, year_start_date, year_end_date, name, sequence_no, start_date, end_date)
                                                        values (%L, '55000000-0000-0000-0000-000000000004', '2026-09-01', '2027-06-30', 'T2', 2, '2027-01-05', '2027-03-31') returning 'ok'$q$, pg_temp.c('SS','year')));
select pg_temp.run('w.multi_grade_SA1', 'multi', format($q$insert into public.grade_levels (school_id, stage_id, name, sequence_no) values ('5a100000-0000-0000-0000-000000000001', %L, 'G9', 9) returning 'ok'$q$, pg_temp.c('SA1','stage')));

-- DELETE: لا سياسة (§5.2) — حتى بكل الصلاحيات ونطاق tenant
select pg_temp.run('d.all', 'ta', $q$
  with a as (delete from public.sections returning 1), b as (delete from public.terms returning 1),
       c as (delete from public.grade_levels returning 1), d as (delete from public.stages returning 1),
       e as (delete from public.academic_years returning 1)
  select ((select count(*) from a) + (select count(*) from b) + (select count(*) from c) + (select count(*) from d) + (select count(*) from e))::text$q$);

select plan(40);

-- ---------- القراءة ----------
select is((select v from r where k = 'vis.ta'),      'ay=SA1,SA2,SB1,SS|te=SA1,SA2,SB1,SS|st=SA1,SA2,SB1,SS|gl=SA1,SA2,SB1,SS|se=SA1,SA2,SB1,SS', 'tenant scope → every T1 school in all five tables, none of T2');
select is((select v from r where k = 'vis.gm'),      'ay=SA1,SA2|te=SA1,SA2|st=SA1,SA2|gl=SA1,SA2|se=SA1,SA2', 'group scope → GA schools only; not GB, not the standalone school');
select is((select v from r where k = 'vis.sa1'),     'ay=SA1|te=SA1|st=SA1|gl=SA1|se=SA1', 'school scope → its school only, not the sibling SA2 (§1.1 rule 5)');
select is((select v from r where k = 'vis.multi'),   'ay=SA2,SS|te=SA2,SS|st=SA2,SS|gl=SA2,SS|se=SA2,SS', 'several school scopes work together');
select is((select v from r where k = 'vis.tch'),     'ay=SA1|te=SA1|st=SA1|gl=SA1|se=SA1', 'read-only role reads its school (K2: .read keys)');
select is((select v from r where k = 'vis.yc'),      'ay=SA1|te=|st=|gl=|se=', 'per-resource permission: academic_year.read reads years only');
select is((select v from r where k = 'vis.so'),      'ay=|te=|st=|gl=|se=SA1', 'per-resource permission: section.read reads sections only');
select is((select v from r where k = 'vis.noperm'),  'ay=|te=|st=|gl=|se=', 'scope without permission → nothing (P2)');
select is((select v from r where k = 'vis.noscope'), 'ay=|te=|st=|gl=|se=', 'permission without scope → nothing (P1)');
select is((select v from r where k = 'vis.t2a'),     'ay=S2|te=S2|st=S2|gl=S2|se=S2', 'T2 → T2 only (I1)');
select is((select v from r where k = 'vis.pa'),      'ay=|te=|st=|gl=|se=', 'platform admin with every academic permission sees nothing — no platform policy on school data');
select is((select v from r where k = 'vis.anon'),    'ay=|te=|st=|gl=|se=', 'anon sees nothing');

-- ---------- الكتابة ----------
select is((select v from r where k = 'w.sa1_stage_SA1'), 'ok', 'insert: stage.manage in own school');
select ok((select v from r where k = 'w.sa1_stage_SA2')  like 'ERR 42501%row-level security%stages%', 'insert: never in a sibling school');
select ok((select v from r where k = 'w.tch_stage_SA1')  like 'ERR 42501%row-level security%stages%', 'insert: stage.read does not grant stage.manage');
select ok((select v from r where k = 'w.noscope_stage')  like 'ERR 42501%row-level security%stages%', 'insert: permission without scope (P1)');
select ok((select v from r where k = 'w.pa_stage')       like 'ERR 42501%row-level security%stages%', 'insert: platform admin has no path');
select ok((select v from r where k = 'w.anon_stage')     like 'ERR 42501%row-level security%stages%', 'insert: anon');
select ok((select v from r where k = 'w.sa1_stage_move_SA2') like 'ERR 42501%row-level security%stages%', 'update: cannot move a row to a school outside the scope (WITH CHECK on the new school_id)');
select ok((select v from r where k = 'w.ta_stage_move_T2')   like 'ERR 42501%row-level security%stages%', 'update: cannot move a row to another tenant''s school');

select is((select v from r where k = 'w.sa1_year'),        'ok', 'academic_years insert: academic_year.create');
select is((select v from r where k = 'w.yc_year'),         'ok', 'academic_years insert: create without update is enough to create');
select is((select v from r where k = 'w.yc_year_update'),  '0',  'academic_years update: create does not grant update (catalog keys, not .manage)');
select is((select v from r where k = 'w.sa1_year_update'), '1',  'academic_years update: academic_year.update');
select ok((select v from r where k = 'w.so_year') like 'ERR 42501%row-level security%academic_years%', 'academic_years insert: section.read grants nothing here');

select is((select v from r where k = 'w.sa1_section_SA2'), '0', 'sections update: a sibling school is invisible to USING');
select is((select v from r where k = 'w.sa1_section_SA1'), '1', 'sections update: own school (control)');
select is((select v from r where k = 'w.so_section_SA1'),  '0', 'sections update: section.read does not grant section.manage');
select is((select v from r where k = 'w.t2a_section_SA1'), '0', 'sections update: never another tenant');
select ok((select v from r where k = 'w.gm_section_SB1') like 'ERR 42501%row-level security%sections%', 'sections insert: group manager outside its group');
select is((select v from r where k = 'w.gm_section_SA2'), 'ok', 'sections insert: group manager inside its group (control)');
select is((select v from r where k = 'w.multi_term_SS'),  'ok', 'terms insert: a second school scope works for writes');
select ok((select v from r where k = 'w.multi_grade_SA1') like 'ERR 42501%row-level security%grade_levels%', 'grade_levels insert: a school outside the actor''s scopes');

select is((select v from r where k = 'd.all'), '0', 'DELETE on the five academic tables removes nothing, even for a tenant-scoped admin (§5.2)');

-- ---------- السياسات ----------
select policies_are('public', 'academic_years', array['academic_years_select','academic_years_insert','academic_years_update'], 'academic_years: exactly the M16 policies');
select policies_are('public', 'terms',          array['terms_select','terms_insert','terms_update'], 'terms: exactly the M16 policies');
select policies_are('public', 'stages',         array['stages_select','stages_insert','stages_update'], 'stages: exactly the M16 policies');
select policies_are('public', 'grade_levels',   array['grade_levels_select','grade_levels_insert','grade_levels_update'], 'grade_levels: exactly the M16 policies');
select policies_are('public', 'sections',       array['sections_select','sections_insert','sections_update'], 'sections: exactly the M16 policies');
select is((select count(*)::int from pg_policies where schemaname = 'public'
            and tablename in ('academic_years','terms','stages','grade_levels','sections')
            and not ('authenticated' = any(roles) and cardinality(roles) = 1)), 0, 'every M16 policy is TO authenticated only');

select * from finish();
rollback;
