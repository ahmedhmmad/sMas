-- M37 — copy_sections (Phase 2A، القرار 8 + Q5): نسخ بنية الشعب من سنة إلى سنة planned في المدرسة نفسها،
-- ذرياً، بالمفتاح الطبيعي (school, year, grade_level, name): المطابق «منسوخ سابقاً» لا يُمس، وغير المطابق يُفشل
-- العملية كلها. لا تسجيلات ولا فصول ولا تعديل للموجود؛ الإدراج يمر بحارس M35.
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
  insert into r values (p_key || '#ctx', coalesce(current_setting('app.audit_action', true), '') || '|' || coalesce(current_setting('app.audit_reason', true), ''))
    on conflict (k) do update set v = excluded.v;
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

-- SA: yC (تُغلق)، yS المصدر (نشطة)، yT/yT2/yT3/yT4/yT5 أهداف planned؛ SB: yB planned؛ SX: yX planned
insert into public.academic_years (id, school_id, name, start_date, end_date) values
  ('c0000000-0000-0000-0000-000000000001', '5a000000-0000-0000-0000-000000000001', '2025', '2025-09-01', '2026-06-30'),
  ('a5000000-0000-0000-0000-000000000002', '5a000000-0000-0000-0000-000000000001', '2026', '2026-09-01', '2027-06-30'),
  ('a7000000-0000-0000-0000-000000000003', '5a000000-0000-0000-0000-000000000001', '2027', '2027-09-01', '2028-06-30'),
  ('a8000000-0000-0000-0000-000000000004', '5a000000-0000-0000-0000-000000000001', '2028', '2028-09-01', '2029-06-30'),
  ('a9000000-0000-0000-0000-000000000005', '5a000000-0000-0000-0000-000000000001', '2029', '2029-09-01', '2030-06-30'),
  ('aa000000-0000-0000-0000-000000000006', '5a000000-0000-0000-0000-000000000001', '2030', '2030-09-01', '2031-06-30'),
  ('ab000000-0000-0000-0000-000000000007', '5a000000-0000-0000-0000-000000000001', '2031', '2031-09-01', '2032-06-30'),
  ('bb000000-0000-0000-0000-000000000008', '5b000000-0000-0000-0000-000000000002', '2027', '2027-09-01', '2028-06-30'),
  ('cc000000-0000-0000-0000-000000000009', '5c000000-0000-0000-0000-000000000003', '2027', '2027-09-01', '2028-06-30');
insert into public.stages (id, school_id, name, sequence_no) values
  ('51000000-0000-0000-0000-000000000001', '5a000000-0000-0000-0000-000000000001', 'P', 1),
  ('5b100000-0000-0000-0000-000000000001', '5b000000-0000-0000-0000-000000000002', 'P', 1);
insert into public.grade_levels (id, school_id, stage_id, name, sequence_no) values
  ('61000000-0000-0000-0000-000000000001', '5a000000-0000-0000-0000-000000000001', '51000000-0000-0000-0000-000000000001', 'G1', 1),
  ('61000000-0000-0000-0000-000000000002', '5a000000-0000-0000-0000-000000000001', '51000000-0000-0000-0000-000000000001', 'G2', 2),
  ('61000000-0000-0000-0000-000000000004', '5a000000-0000-0000-0000-000000000001', '51000000-0000-0000-0000-000000000001', 'GH', 4),
  ('6b100000-0000-0000-0000-000000000001', '5b000000-0000-0000-0000-000000000002', '5b100000-0000-0000-0000-000000000001', 'G1', 1);
-- المصدر yS: G1/A (30، إناث)، G1/B (معطّلة)، G2/A (بلا سعة، مختلط)؛ yC: G1/A و GH/A (يُعطَّل GH بعد إغلاق yC)
insert into public.sections (id, school_id, academic_year_id, grade_level_id, name, capacity, gender_policy, status) values
  ('71000000-0000-0000-0000-000000000001', '5a000000-0000-0000-0000-000000000001', 'a5000000-0000-0000-0000-000000000002', '61000000-0000-0000-0000-000000000001', 'A', 30,   'female_only', 'active'),
  ('71000000-0000-0000-0000-000000000002', '5a000000-0000-0000-0000-000000000001', 'a5000000-0000-0000-0000-000000000002', '61000000-0000-0000-0000-000000000001', 'B', null, 'mixed',       'inactive'),
  ('71000000-0000-0000-0000-000000000003', '5a000000-0000-0000-0000-000000000001', 'a5000000-0000-0000-0000-000000000002', '61000000-0000-0000-0000-000000000002', 'A', null, 'mixed',       'active'),
  ('7c000000-0000-0000-0000-000000000001', '5a000000-0000-0000-0000-000000000001', 'c0000000-0000-0000-0000-000000000001', '61000000-0000-0000-0000-000000000001', 'A', 28,   'mixed',       'active'),
  ('7c000000-0000-0000-0000-000000000002', '5a000000-0000-0000-0000-000000000001', 'c0000000-0000-0000-0000-000000000001', '61000000-0000-0000-0000-000000000004', 'A', null, 'mixed',       'active');
-- yT3: G1/A موجودة بسعة مختلفة (غير مطابقة)؛ yT4: G1/A مطابقة + G2/Z إضافية لا مقابل لها
insert into public.sections (id, school_id, academic_year_id, grade_level_id, name, capacity, gender_policy, status) values
  ('73000000-0000-0000-0000-000000000001', '5a000000-0000-0000-0000-000000000001', 'a9000000-0000-0000-0000-000000000005', '61000000-0000-0000-0000-000000000001', 'A', 25, 'female_only', 'active'),
  ('74000000-0000-0000-0000-000000000001', '5a000000-0000-0000-0000-000000000001', 'aa000000-0000-0000-0000-000000000006', '61000000-0000-0000-0000-000000000001', 'A', 30, 'female_only', 'active'),
  ('74000000-0000-0000-0000-000000000002', '5a000000-0000-0000-0000-000000000001', 'aa000000-0000-0000-0000-000000000006', '61000000-0000-0000-0000-000000000002', 'Z', 40, 'mixed',       'active');
update public.academic_years set status = 'active' where id = 'c0000000-0000-0000-0000-000000000001';
update public.academic_years set status = 'closed' where id = 'c0000000-0000-0000-0000-000000000001';
update public.academic_years set status = 'active' where id = 'a5000000-0000-0000-0000-000000000002';
update public.grade_levels set status = 'inactive' where id = '61000000-0000-0000-0000-000000000004';   -- شعبته الوحيدة في yC المغلقة

-- تسجيل نشط في المصدر G1/A — لا يُنسخ
do $$
declare v_a uuid := 'e9000000-0000-0000-0000-000000000009'; v_p uuid; v_scope uuid;
begin
  insert into auth.users (id, email) values (v_a, 'st@m37.invalid');
  insert into public.auth_identities (auth_user_id, kind) values (v_a, 'tenant');
  insert into public.profiles (platform_tenant_id, auth_user_id, display_name) values ('10000000-0000-0000-0000-000000000001', v_a, 'st') returning id into v_p;
  select i.id into v_scope from public.identity_scopes i where i.owner_id = 'a1000000-0000-0000-0000-00000000000a';
  insert into public.students (id, platform_tenant_id, identity_scope_id, student_profile_id, official_id, official_id_type, first_name, family_name)
    values (v_a, '10000000-0000-0000-0000-000000000001', v_scope, v_p, 'N1', 'national_id', 'S', 'T');
  insert into public.enrollments (school_id, student_id, platform_tenant_id, academic_year_id, grade_level_id, section_id, identity_scope_id, scope_owner_id, effective_from)
    values ('5a000000-0000-0000-0000-000000000001', v_a, '10000000-0000-0000-0000-000000000001', 'a5000000-0000-0000-0000-000000000002',
            '61000000-0000-0000-0000-000000000001', '71000000-0000-0000-0000-000000000001', v_scope, 'a1000000-0000-0000-0000-00000000000a', '2026-09-01');
end $$;

create function pg_temp.member(p_label text, p_role text, p_tenant uuid, p_scope text, p_target uuid) returns void
language plpgsql as $$
declare v_a uuid := gen_random_uuid(); v_p uuid; v_m uuid;
begin
  insert into auth.users (id, email) values (v_a, p_label || '@m37.invalid');
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
select pg_temp.member('sec', 'secretary',    '10000000-0000-0000-0000-000000000001', 'school', '5a000000-0000-0000-0000-000000000001');   -- section.read بلا section.manage
select pg_temp.member('ta',  'tenant_admin', '10000000-0000-0000-0000-000000000001', 'tenant', null);
select pg_temp.member('x',   'school_admin', '20000000-0000-0000-0000-000000000002', 'school', '5c000000-0000-0000-0000-000000000003');

create function pg_temp.secs(p_year uuid) returns text language sql as $$
  select coalesce(string_agg(g.name || '/' || s.name || ':' || coalesce(s.capacity::text, '-') || ':' || s.gender_policy || ':' || s.status || ':' || (s.school_id = y.school_id)::text,
                             ',' order by g.name, s.name), '')
    from public.sections s join public.grade_levels g on g.id = s.grade_level_id join public.academic_years y on y.id = s.academic_year_id
   where s.academic_year_id = p_year
$$;
create function pg_temp.snap(p_year uuid) returns text language sql as $$
  select md5(coalesce(string_agg(to_jsonb(s)::text, ';' order by s.id), '')) from public.sections s where s.academic_year_id = p_year
$$;

-- ============ الرفض ============
select pg_temp.run('f.sec',        'sec', $q$select app.copy_sections('a5000000-0000-0000-0000-000000000002', 'a7000000-0000-0000-0000-000000000003', 'r')::text$q$);
select pg_temp.run('f.sibling',    'sb',  $q$select app.copy_sections('a5000000-0000-0000-0000-000000000002', 'a7000000-0000-0000-0000-000000000003', 'r')::text$q$);
select pg_temp.run('f.to_sibling', 'sa',  $q$select app.copy_sections('a5000000-0000-0000-0000-000000000002', 'bb000000-0000-0000-0000-000000000008', 'r')::text$q$);
select pg_temp.run('f.cross_school_ta', 'ta', $q$select app.copy_sections('a5000000-0000-0000-0000-000000000002', 'bb000000-0000-0000-0000-000000000008', 'r')::text$q$);
select pg_temp.run('f.tenant',     'x',   $q$select app.copy_sections('a5000000-0000-0000-0000-000000000002', 'cc000000-0000-0000-0000-000000000009', 'r')::text$q$);
select pg_temp.run('f.to_tenant',  'ta',  $q$select app.copy_sections('a5000000-0000-0000-0000-000000000002', 'cc000000-0000-0000-0000-000000000009', 'r')::text$q$);
select pg_temp.run('f.noreason',   'sa',  $q$select app.copy_sections('a5000000-0000-0000-0000-000000000002', 'a7000000-0000-0000-0000-000000000003', '')::text$q$);
select pg_temp.run('f.same',       'sa',  $q$select app.copy_sections('a7000000-0000-0000-0000-000000000003', 'a7000000-0000-0000-0000-000000000003', 'r')::text$q$);
select pg_temp.run('f.to_active',  'sa',  $q$select app.copy_sections('a7000000-0000-0000-0000-000000000003', 'a5000000-0000-0000-0000-000000000002', 'r')::text$q$);
select pg_temp.run('f.to_closed',  'sa',  $q$select app.copy_sections('a5000000-0000-0000-0000-000000000002', 'c0000000-0000-0000-0000-000000000001', 'r')::text$q$);
select pg_temp.rec('f.untouched',  $q$select pg_temp.secs('a7000000-0000-0000-0000-000000000003') || '|' || pg_temp.secs('bb000000-0000-0000-0000-000000000008') || '|' || pg_temp.secs('cc000000-0000-0000-0000-000000000009')$q$);

-- الهدف غير المطابق: العملية كلها تُرفض ولا يُنشأ شيء
select pg_temp.rec('conflict.before', $q$select pg_temp.snap('a9000000-0000-0000-0000-000000000005')$q$);
select pg_temp.run('conflict', 'sa', $q$select app.copy_sections('a5000000-0000-0000-0000-000000000002', 'a9000000-0000-0000-0000-000000000005', 'r')::text$q$);
select pg_temp.rec('conflict.after', $q$select pg_temp.snap('a9000000-0000-0000-0000-000000000005')$q$);
select pg_temp.rec('conflict.secs',  $q$select pg_temp.secs('a9000000-0000-0000-0000-000000000005')$q$);
-- شعبة معطّلة بالمفتاح نفسه غير مطابقة أيضاً (المدرسة عطّلتها عمداً)
update public.sections set capacity = 30 where id = '73000000-0000-0000-0000-000000000001';
update public.sections set status = 'inactive' where id = '73000000-0000-0000-0000-000000000001';
select pg_temp.run('conflict.inactive', 'sa', $q$select app.copy_sections('a5000000-0000-0000-0000-000000000002', 'a9000000-0000-0000-0000-000000000005', 'r')::text$q$);

-- الذرية: فشل في منتصف الإدراج (trigger اختباري يرفض شعبة G2) لا يترك أي شعبة ولا صف تدقيق
create function public.zz_fail_g2() returns trigger language plpgsql as $$
begin
  if new.academic_year_id = 'ab000000-0000-0000-0000-000000000007' and new.grade_level_id = '61000000-0000-0000-0000-000000000002' then
    raise exception 'injected failure';
  end if;
  return new;
end $$;
create trigger zz_fail after insert on public.sections for each row execute function public.zz_fail_g2();
select pg_temp.run('atomic', 'sa', $q$select app.copy_sections('a5000000-0000-0000-0000-000000000002', 'ab000000-0000-0000-0000-000000000007', 'r')::text$q$);
drop trigger zz_fail on public.sections;
drop function public.zz_fail_g2();
select pg_temp.rec('atomic.secs',  $q$select count(*)::text from public.sections where academic_year_id = 'ab000000-0000-0000-0000-000000000007'$q$);
select pg_temp.rec('atomic.audit', $q$select count(*)::text from public.audit_log where (entity_type = 'academic_years' and entity_id = 'ab000000-0000-0000-0000-000000000007' and action = 'copy_sections')
  or (entity_type = 'sections' and new_values ->> 'academic_year_id' = 'ab000000-0000-0000-0000-000000000007')$q$);

-- ============ النجاح ============
select pg_temp.rec('ok.enr_before', $q$select count(*)::text from public.enrollments$q$);
select pg_temp.run('ok.first',  'sa', $q$select app.copy_sections('a5000000-0000-0000-0000-000000000002', 'a7000000-0000-0000-0000-000000000003', 'new year')::text$q$);
select pg_temp.rec('ok.secs',   $q$select pg_temp.secs('a7000000-0000-0000-0000-000000000003')$q$);
select pg_temp.rec('ok.ids',    $q$select string_agg(distinct (academic_year_id = 'a7000000-0000-0000-0000-000000000003' and school_id = '5a000000-0000-0000-0000-000000000001')::text, ',') ||
  '|' || (select count(*) from public.sections t where t.academic_year_id = 'a7000000-0000-0000-0000-000000000003'
           and t.grade_level_id not in (select grade_level_id from public.sections where academic_year_id = 'a5000000-0000-0000-0000-000000000002'))
  from public.sections where academic_year_id = 'a7000000-0000-0000-0000-000000000003'$q$);
select pg_temp.rec('ok.snap1',  $q$select pg_temp.snap('a7000000-0000-0000-0000-000000000003')$q$);
select pg_temp.rec('ok.source', $q$select pg_temp.secs('a5000000-0000-0000-0000-000000000002')$q$);
select pg_temp.rec('ok.enr',    $q$select (select count(*) from public.enrollments)::text || '|' ||
  (select count(*) from public.enrollments e join public.sections s on s.id = e.section_id where s.academic_year_id = 'a7000000-0000-0000-0000-000000000003')$q$);
select pg_temp.rec('ok.terms',  $q$select count(*)::text from public.terms where academic_year_id = 'a7000000-0000-0000-0000-000000000003'$q$);
-- التشغيل الثاني: 0 جديدة، والموجود لا يتغير (حتى الختم)
select pg_temp.run('ok.second', 'sa', $q$select app.copy_sections('a5000000-0000-0000-0000-000000000002', 'a7000000-0000-0000-0000-000000000003', 'again')::text$q$);
select pg_temp.rec('ok.snap2',  $q$select pg_temp.snap('a7000000-0000-0000-0000-000000000003')$q$);
select pg_temp.rec('ok.count',  $q$select count(*)::text from public.sections where academic_year_id = 'a7000000-0000-0000-0000-000000000003'$q$);

-- الهدف بشعبة مطابقة وأخرى إضافية: تُنشأ الناقصة وحدها، والموجودتان لا تُمسّان
select pg_temp.rec('pre.before', $q$select string_agg(to_jsonb(s)::text, ';' order by id) from public.sections s where s.academic_year_id = 'aa000000-0000-0000-0000-000000000006'$q$);
select pg_temp.run('pre.copy',   'ta', $q$select app.copy_sections('a5000000-0000-0000-0000-000000000002', 'aa000000-0000-0000-0000-000000000006', 'top up')::text$q$);
select pg_temp.rec('pre.secs',   $q$select pg_temp.secs('aa000000-0000-0000-0000-000000000006')$q$);
select pg_temp.rec('pre.kept',   $q$select (string_agg(to_jsonb(s)::text, ';' order by id) = (select v from r where k = 'pre.before'))::text from public.sections s
  where s.id in ('74000000-0000-0000-0000-000000000001', '74000000-0000-0000-0000-000000000002')$q$);

-- مصدر سنة مغلقة: الصف المعطّل لا يُنسخ (لا التفاف على M35)، والباقي يُنسخ
select pg_temp.run('closed_src', 'sa', $q$select app.copy_sections('c0000000-0000-0000-0000-000000000001', 'a8000000-0000-0000-0000-000000000004', 'from history')::text$q$);
select pg_temp.rec('closed_src.secs', $q$select pg_temp.secs('a8000000-0000-0000-0000-000000000004')$q$);

-- ============ التدقيق ============
select pg_temp.rec('audit.domain', $q$select actor_type || '|' || action || '|' || reason || '|' || (school_id = '5a000000-0000-0000-0000-000000000001')::text || '|' ||
    (new_values ->> 'source_year_id') || '>' || (new_values ->> 'target_year_id') || '|' || (new_values ->> 'created') || '/' || (new_values ->> 'already_copied') || '|' ||
    (actor_id = (select p.id from public.profiles p join actors a on a.auth = p.auth_user_id where a.label = 'sa'))::text
  from public.audit_log where action = 'copy_sections' and entity_id = 'a7000000-0000-0000-0000-000000000003' and reason = 'new year'$q$);
select pg_temp.rec('audit.second', $q$select (new_values ->> 'created') || '/' || (new_values ->> 'already_copied') from public.audit_log
  where action = 'copy_sections' and entity_id = 'a7000000-0000-0000-0000-000000000003' and reason = 'again'$q$);
select pg_temp.rec('audit.rows', $q$select string_agg(action || ':' || reason, ',' order by id) from public.audit_log
  where entity_type = 'sections' and new_values ->> 'academic_year_id' = 'a7000000-0000-0000-0000-000000000003'$q$);
select pg_temp.rec('audit.refused', $q$select count(*)::text from public.audit_log where action = 'copy_sections'
  and entity_id in ('a9000000-0000-0000-0000-000000000005', 'bb000000-0000-0000-0000-000000000008', 'cc000000-0000-0000-0000-000000000009', 'c0000000-0000-0000-0000-000000000001')$q$);
select pg_temp.rec('audit.ctx', $q$select coalesce(string_agg(k, ',' order by k), 'none') from r where k like '%#ctx' and v <> '|'$q$);

-- =====================================================================
select plan(11 + 6 + 2 + 9 + 3 + 1 + 5 + 4);

-- 12. الصلاحية والنطاق
select ok((select v from r where k = 'f.sec')        like 'ERR 42501%forbidden%', 'section.read without section.manage → forbidden');
select ok((select v from r where k = 'f.sibling')    like 'ERR P0002%not found%', 'a sibling school''s admin cannot copy SA''s years (not found)');
select ok((select v from r where k = 'f.to_sibling') like 'ERR P0002%not found%', 'SA''s admin cannot target a year of another school (not found)');
select ok((select v from r where k = 'f.tenant')     like 'ERR P0002%not found%', 'another tenant cannot copy T1''s years');
select ok((select v from r where k = 'f.to_tenant')  like 'ERR P0002%not found%', 'a tenant admin cannot target another tenant''s year');
-- 1، 9. المدرسة نفسها
select ok((select v from r where k = 'f.cross_school_ta') like 'ERR 22023%different schools%', 'even with scope on both schools: no copy across schools');
-- 2، 11. الهدف planned
select ok((select v from r where k = 'f.to_active') like 'ERR 22023%target academic year must be planned (is active)%', 'no copy into an active year');
select ok((select v from r where k = 'f.to_closed') like 'ERR 22023%target academic year must be planned (is closed)%', 'no copy into a closed year');
select ok((select v from r where k = 'f.same')      like 'ERR 22023%same academic year%', 'source and target must differ');
select ok((select v from r where k = 'f.noreason')  like 'ERR 22023%reason required%', 'a reason is required');
select is((select v from r where k = 'f.untouched'), '||', 'every refused call created nothing anywhere');

-- 8، 14. الهدف غير المطابق والذرية
select ok((select v from r where k = 'conflict') like 'ERR 23514%differ from the source: 61000000-0000-0000-0000-000000000001/A%', 'a target section with the same natural key but different content fails the whole copy, naming the key');
select is((select v from r where k = 'conflict.after'), (select v from r where k = 'conflict.before'), '… and nothing in the target changed — not even the sections that had no counterpart');
select is((select v from r where k = 'conflict.secs'), 'G1/A:25:female_only:active:true', '… the existing section is not "corrected" to match the source');
select ok((select v from r where k = 'conflict.inactive') like 'ERR 23514%differ from the source%', 'a deactivated section with the same key is also a conflict, not a silent skip');
select is((select v from r where k = 'atomic.secs'),  '0', 'atomicity: a failure on one inserted section leaves none of the others');
select is((select v from r where k = 'atomic.audit'), '0', 'atomicity: and no audit row (neither per section nor for the operation)');

-- 6، 4، 3. التشغيل الأول
select is((select v from r where k = 'ok.first'), '2', 'first run: two sections created (the inactive source section is not copied)');
select is((select v from r where k = 'ok.secs'),  'G1/A:30:female_only:active:true,G2/A:-:mixed:active:true', 'copied: grade level, name, capacity and gender policy; active; same school');

-- 4. الهوية الجديدة صحيحة
select is((select v from r where k = 'ok.ids'), 'true|0', 'the new sections belong to the target year and the school, with grade levels taken from the source');
select is((select v from r where k = 'ok.source'), 'G1/A:30:female_only:active:true,G1/B:-:mixed:inactive:true,G2/A:-:mixed:active:true', 'the source year is untouched');
select is((select v from r where k = 'ok.enr'),   (select v from r where k = 'ok.enr_before') || '|0', 'no enrollment copied: the total is unchanged and the target year has none');
select is((select v from r where k = 'ok.terms'), '0', 'no term copied');
-- 7. التشغيل الثاني
select is((select v from r where k = 'ok.second'), '0', 'second run: 0 new sections');
select is((select v from r where k = 'ok.snap2'),  (select v from r where k = 'ok.snap1'), '… and the existing copies are byte-identical (no update, no stamp)');
select is((select v from r where k = 'ok.count'),  '2', '… no duplicates');
select is((select v from r where k = 'pre.copy'),  '1', 'a target holding one matching section and one extra: only the missing section is created');
select is((select v from r where k = 'pre.secs'),  'G1/A:30:female_only:active:true,G2/A:-:mixed:active:true,G2/Z:40:mixed:active:true', '… the extra section stays');

-- 10. لا التفاف على M35
select is((select v from r where k = 'closed_src'), '1', 'copying from a closed year copies only sections whose grade level is still active');
select is((select v from r where k = 'closed_src.secs'), 'G1/A:28:mixed:active:true', '… the section of the deactivated grade level is not revived');
select is((select v from r where k = 'pre.kept'), 'true', 'the pre-existing matching and extra sections are byte-identical after the copy');

-- 12. لا school_id من العميل
select is((select pg_get_function_identity_arguments('app.copy_sections(uuid,uuid,text)'::regprocedure)),
          'p_source_year_id uuid, p_target_year_id uuid, p_reason text', 'the operation takes year ids and a reason only — no client school_id');

-- 13. التدقيق
select is((select v from r where k = 'audit.domain'), 'tenant_user|copy_sections|new year|true|a5000000-0000-0000-0000-000000000002>a7000000-0000-0000-0000-000000000003|2/0|true',
          'one domain audit row: actor, action, reason, school, source > target, created/already copied');
select is((select v from r where k = 'audit.second'), '0/2', 'the second run is audited as 0 created / 2 already copied');
select is((select v from r where k = 'audit.rows'),   'insert:new year,insert:new year', 'each created section is audited (T7) with the operation''s reason');
select is((select v from r where k = 'audit.refused'), '0', 'refused copies leave no domain audit row');
select is((select v from r where k = 'audit.ctx'),    'none', 'the audit context is empty after every call');

-- البنية
select ok(has_function_privilege('authenticated', 'app.copy_sections(uuid,uuid,text)', 'EXECUTE')
      and not has_function_privilege('anon', 'app.copy_sections(uuid,uuid,text)', 'EXECUTE'), 'copy_sections: EXECUTE for authenticated only');
select is((select count(*)::int from public.permissions where code !~ '^subject\.'), 73, 'no new permission key from this migration (73 frozen; subject.* is B10, M38)');
select ok(not has_table_privilege('authenticated', 'public.sections', 'DELETE'), 'no DELETE on sections: a copy can never be undone by deleting');
select is((select count(*)::int from pg_proc p where p.pronamespace = 'app'::regnamespace and p.proname = 'copy_sections'), 1, 'one copy operation, no overloads');

select * from finish();
rollback;
