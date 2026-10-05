-- M44 — copy_bell_schedules (Phase 2B / 2B-3، B13): الجداول والحصص وإسناد الصفوف ذرياً بعقد M37/M40/M42.
begin;

create temp table r (k text primary key, v text) on commit drop;
grant all on r to public;
create temp table actors (label text primary key, auth uuid) on commit drop;
grant select on actors to public;

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
  ('5c000000-0000-0000-0000-000000000003', '20000000-0000-0000-0000-000000000002', null, 'SX', 'SX', 'sx');
-- SA: yC مغلقة، yS المصدر (نشطة)، أهداف planned: yT نظيف، yT2 جدول معطَّل، yT3 حصة مختلفة، yT4 بلا الخميس، yT5 إسناد مختلف، yT6 مطابق + إضافي، yT7 الذرية
insert into public.academic_years (id, school_id, name, start_date, end_date) values
  ('c0000000-0000-0000-0000-000000000001', '5a000000-0000-0000-0000-000000000001', 'yC',  '2025-09-01', '2026-06-30'),
  ('a5000000-0000-0000-0000-000000000002', '5a000000-0000-0000-0000-000000000001', 'yS',  '2026-09-01', '2027-06-30'),
  ('a7000000-0000-0000-0000-000000000003', '5a000000-0000-0000-0000-000000000001', 'yT',  '2027-09-01', '2028-06-30'),
  ('a8000000-0000-0000-0000-000000000004', '5a000000-0000-0000-0000-000000000001', 'yT2', '2028-09-01', '2029-06-30'),
  ('a9000000-0000-0000-0000-000000000005', '5a000000-0000-0000-0000-000000000001', 'yT3', '2029-09-01', '2030-06-30'),
  ('aa000000-0000-0000-0000-000000000006', '5a000000-0000-0000-0000-000000000001', 'yT4', '2030-09-01', '2031-06-30'),
  ('ab000000-0000-0000-0000-000000000007', '5a000000-0000-0000-0000-000000000001', 'yT5', '2031-09-01', '2032-06-30'),
  ('ac000000-0000-0000-0000-000000000008', '5a000000-0000-0000-0000-000000000001', 'yT6', '2032-09-01', '2033-06-30'),
  ('ad000000-0000-0000-0000-000000000009', '5a000000-0000-0000-0000-000000000001', 'yT7', '2033-09-01', '2034-06-30'),
  ('ae000000-0000-0000-0000-00000000000c', '5a000000-0000-0000-0000-000000000001', 'yT8', '2034-09-01', '2035-06-30'),
  ('bb000000-0000-0000-0000-00000000000a', '5b000000-0000-0000-0000-000000000002', 'yB',  '2027-09-01', '2028-06-30'),
  ('cc000000-0000-0000-0000-00000000000b', '5c000000-0000-0000-0000-000000000003', 'yX',  '2027-09-01', '2028-06-30');
insert into public.stages (id, school_id, name, sequence_no) values ('51000000-0000-0000-0000-000000000001', '5a000000-0000-0000-0000-000000000001', 'P', 1);
insert into public.grade_levels (id, school_id, stage_id, name, sequence_no) values
  ('61000000-0000-0000-0000-000000000001', '5a000000-0000-0000-0000-000000000001', '51000000-0000-0000-0000-000000000001', 'G1', 1),
  ('61000000-0000-0000-0000-000000000002', '5a000000-0000-0000-0000-000000000001', '51000000-0000-0000-0000-000000000001', 'G2', 2),
  ('61000000-0000-0000-0000-000000000003', '5a000000-0000-0000-0000-000000000001', '51000000-0000-0000-0000-000000000001', 'GH', 3);
insert into public.calendar_weekdays (school_id, academic_year_id, weekday)
select y.school_id, y.id, d from public.academic_years y, generate_series(0, 4) d
 where y.school_id = '5a000000-0000-0000-0000-000000000001' and not (y.name = 'yT4' and d = 4);

create function pg_temp.sch(p_id text, p_year text, p_name text) returns void language sql as $$
  insert into public.bell_schedules (id, school_id, academic_year_id, name) select p_id::uuid, y.school_id, y.id, p_name from public.academic_years y where y.id = p_year::uuid
$$;
create function pg_temp.per(p_sched text, p_day int, p_kind text, p_s text, p_e text, p_name text default null) returns void language sql as $$
  insert into public.bell_periods (school_id, academic_year_id, bell_schedule_id, weekday, kind, name, start_time, end_time)
  select s.school_id, s.academic_year_id, s.id, p_day, p_kind, p_name, p_s::time, p_e::time from public.bell_schedules s where s.id = p_sched::uuid
$$;
create function pg_temp.asg(p_year text, p_grade text, p_sched text) returns void language sql as $$
  insert into public.grade_level_bell_schedules (school_id, academic_year_id, grade_level_id, bell_schedule_id)
  values ('5a000000-0000-0000-0000-000000000001', p_year::uuid, p_grade::uuid, p_sched::uuid)
$$;
-- المصدر yS: Morning (الأحد حصة + استراحة، الخميس حصة، الاثنين حصة معطّلة)، Evening (الأحد)، Old معطَّل؛ G1 ← Morning، G2 ← Evening، GH (يُعطَّل) ← Morning
select pg_temp.sch('d1000000-0000-0000-0000-000000000001', 'a5000000-0000-0000-0000-000000000002', 'Morning');
select pg_temp.sch('d1000000-0000-0000-0000-000000000002', 'a5000000-0000-0000-0000-000000000002', 'Evening');
select pg_temp.sch('d1000000-0000-0000-0000-000000000003', 'a5000000-0000-0000-0000-000000000002', 'Old');
select pg_temp.per('d1000000-0000-0000-0000-000000000001', 0, 'lesson', '08:00', '08:45');
select pg_temp.per('d1000000-0000-0000-0000-000000000001', 0, 'break',  '08:45', '09:00', 'R');
select pg_temp.per('d1000000-0000-0000-0000-000000000001', 4, 'lesson', '08:00', '08:40');
select pg_temp.per('d1000000-0000-0000-0000-000000000001', 1, 'lesson', '08:00', '08:45');
update public.bell_periods set status = 'inactive' where bell_schedule_id = 'd1000000-0000-0000-0000-000000000001' and weekday = 1;
select pg_temp.per('d1000000-0000-0000-0000-000000000002', 0, 'lesson', '13:00', '13:45');
update public.bell_schedules set status = 'inactive' where id = 'd1000000-0000-0000-0000-000000000003';
select pg_temp.asg('a5000000-0000-0000-0000-000000000002', '61000000-0000-0000-0000-000000000001', 'd1000000-0000-0000-0000-000000000001');
select pg_temp.asg('a5000000-0000-0000-0000-000000000002', '61000000-0000-0000-0000-000000000002', 'd1000000-0000-0000-0000-000000000002');
select pg_temp.asg('a5000000-0000-0000-0000-000000000002', '61000000-0000-0000-0000-000000000003', 'd1000000-0000-0000-0000-000000000001');
update public.grade_levels set status = 'inactive' where id = '61000000-0000-0000-0000-000000000003';
-- الأهداف المتعارضة والمطابقة
select pg_temp.sch('d2000000-0000-0000-0000-000000000001', 'a8000000-0000-0000-0000-000000000004', 'Morning');
update public.bell_schedules set status = 'inactive' where id = 'd2000000-0000-0000-0000-000000000001';
select pg_temp.sch('d3000000-0000-0000-0000-000000000001', 'a9000000-0000-0000-0000-000000000005', 'Morning');
select pg_temp.per('d3000000-0000-0000-0000-000000000001', 0, 'lesson', '08:00', '08:50');
select pg_temp.sch('d5000000-0000-0000-0000-000000000001', 'ab000000-0000-0000-0000-000000000007', 'Other');
select pg_temp.asg('ab000000-0000-0000-0000-000000000007', '61000000-0000-0000-0000-000000000001', 'd5000000-0000-0000-0000-000000000001');
select pg_temp.sch('d6000000-0000-0000-0000-000000000001', 'ac000000-0000-0000-0000-000000000008', 'Morning');
select pg_temp.per('d6000000-0000-0000-0000-000000000001', 0, 'lesson', '08:00', '08:45');
select pg_temp.per('d6000000-0000-0000-0000-000000000001', 0, 'lesson', '10:00', '10:45');
select pg_temp.asg('ac000000-0000-0000-0000-000000000008', '61000000-0000-0000-0000-000000000001', 'd6000000-0000-0000-0000-000000000001');
-- yT8: الاستراحة نفسها وقتاً ونوعاً، باسم مختلف
select pg_temp.sch('d8000000-0000-0000-0000-000000000001', 'ae000000-0000-0000-0000-00000000000c', 'Morning');
select pg_temp.per('d8000000-0000-0000-0000-000000000001', 0, 'break', '08:45', '09:00', 'Prayer');
update public.academic_years set status = 'active' where id = 'c0000000-0000-0000-0000-000000000001';
update public.academic_years set status = 'closed' where id = 'c0000000-0000-0000-0000-000000000001';
update public.academic_years set status = 'active' where id = 'a5000000-0000-0000-0000-000000000002';

create function pg_temp.member(p_label text, p_role text, p_tenant uuid, p_scope text, p_target uuid) returns void
language plpgsql as $$
declare v_a uuid := gen_random_uuid(); v_p uuid; v_m uuid;
begin
  insert into auth.users (id, email) values (v_a, p_label || '@m44.invalid');
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
select pg_temp.member('sec', 'secretary',    '10000000-0000-0000-0000-000000000001', 'school', '5a000000-0000-0000-0000-000000000001');
select pg_temp.member('ta',  'tenant_admin', '10000000-0000-0000-0000-000000000001', 'tenant', null);
select pg_temp.member('x',   'school_admin', '20000000-0000-0000-0000-000000000002', 'school', '5c000000-0000-0000-0000-000000000003');

-- وصف السنة: الجداول (الحالة)، الحصص النشطة، الإسناد — بالأسماء
create function pg_temp.desc_(p_year text) returns text language sql as $$
  select coalesce((select string_agg(name || ':' || status, ',' order by name) from public.bell_schedules where academic_year_id = p_year::uuid), '') || ' | ' ||
         coalesce((select string_agg(s.name || '/' || p.weekday || '/' || p.kind || '/' || to_char(p.start_time, 'HH24:MI') || '-' || to_char(p.end_time, 'HH24:MI') || coalesce('/' || p.name, ''),
                                     ',' order by s.name, p.weekday, p.start_time)
                     from public.bell_periods p join public.bell_schedules s on s.id = p.bell_schedule_id
                    where p.academic_year_id = p_year::uuid and p.status = 'active'), '') || ' | ' ||
         coalesce((select string_agg(g.name || '>' || s.name, ',' order by g.name)
                     from public.grade_level_bell_schedules a join public.grade_levels g on g.id = a.grade_level_id join public.bell_schedules s on s.id = a.bell_schedule_id
                    where a.academic_year_id = p_year::uuid), '')
$$;
create function pg_temp.snap(p_year text) returns text language sql as $$
  select md5(coalesce((select string_agg(to_jsonb(s)::text, ';' order by s.id) from public.bell_schedules s where s.academic_year_id = p_year::uuid), '') ||
             coalesce((select string_agg(to_jsonb(p)::text, ';' order by p.id) from public.bell_periods p where p.academic_year_id = p_year::uuid), '') ||
             coalesce((select string_agg(to_jsonb(a)::text, ';' order by a.id) from public.grade_level_bell_schedules a where a.academic_year_id = p_year::uuid), ''))
$$;
create function pg_temp.copy(p_src text, p_tgt text, p_reason text default 'r') returns text language sql as $$
  select format($f$select app.copy_bell_schedules(%L, %L, %L)::text$f$, p_src, p_tgt, p_reason)
$$;

-- ============ الرفض ============
select pg_temp.run('f.sec',        'sec', pg_temp.copy('a5000000-0000-0000-0000-000000000002', 'a7000000-0000-0000-0000-000000000003'));
select pg_temp.run('f.sibling',    'sb',  pg_temp.copy('a5000000-0000-0000-0000-000000000002', 'a7000000-0000-0000-0000-000000000003'));
select pg_temp.run('f.to_sibling', 'sa',  pg_temp.copy('a5000000-0000-0000-0000-000000000002', 'bb000000-0000-0000-0000-00000000000a'));
select pg_temp.run('f.cross_ta',   'ta',  pg_temp.copy('a5000000-0000-0000-0000-000000000002', 'bb000000-0000-0000-0000-00000000000a'));
select pg_temp.run('f.tenant',     'x',   pg_temp.copy('a5000000-0000-0000-0000-000000000002', 'cc000000-0000-0000-0000-00000000000b'));
select pg_temp.run('f.noreason',   'sa',  pg_temp.copy('a5000000-0000-0000-0000-000000000002', 'a7000000-0000-0000-0000-000000000003', ''));
select pg_temp.run('f.same',       'sa',  pg_temp.copy('a7000000-0000-0000-0000-000000000003', 'a7000000-0000-0000-0000-000000000003'));
select pg_temp.run('f.to_active',  'sa',  pg_temp.copy('a7000000-0000-0000-0000-000000000003', 'a5000000-0000-0000-0000-000000000002'));
select pg_temp.run('f.to_closed',  'sa',  pg_temp.copy('a5000000-0000-0000-0000-000000000002', 'c0000000-0000-0000-0000-000000000001'));
select pg_temp.rec('f.untouched',  $q$select pg_temp.desc_('a7000000-0000-0000-0000-000000000003') || '#' || pg_temp.desc_('bb000000-0000-0000-0000-00000000000a')$q$);

-- ============ التعارضات: كلها تُفشل الكل والهدف لا يتغير ============
create function pg_temp.conflict(p_key text, p_tgt text) returns void language plpgsql as $$
begin
  perform pg_temp.rec(p_key || '.before', format('select pg_temp.snap(%L)', p_tgt));
  perform pg_temp.run(p_key, 'sa', pg_temp.copy('a5000000-0000-0000-0000-000000000002', p_tgt));
  perform pg_temp.rec(p_key || '.after', format('select pg_temp.snap(%L)', p_tgt));
end $$;
select pg_temp.conflict('c.inactive', 'a8000000-0000-0000-0000-000000000004');
select pg_temp.conflict('c.period',   'a9000000-0000-0000-0000-000000000005');
select pg_temp.conflict('c.weekday',  'aa000000-0000-0000-0000-000000000006');
select pg_temp.conflict('c.assign',   'ab000000-0000-0000-0000-000000000007');
select pg_temp.conflict('c.name',     'ae000000-0000-0000-0000-00000000000c');

-- الذرية: فشل مُحقن على الإسناد (آخر الأجزاء) لا يترك جدولاً ولا حصة
create function public.zz_fail_asg() returns trigger language plpgsql as $$
begin
  if new.academic_year_id = 'ad000000-0000-0000-0000-000000000009' then raise exception 'injected failure'; end if;
  return new;
end $$;
create trigger zz_fail after insert on public.grade_level_bell_schedules for each row execute function public.zz_fail_asg();
select pg_temp.run('atomic', 'sa', pg_temp.copy('a5000000-0000-0000-0000-000000000002', 'ad000000-0000-0000-0000-000000000009'));
drop trigger zz_fail on public.grade_level_bell_schedules;
drop function public.zz_fail_asg();
select pg_temp.rec('atomic.after', $q$select pg_temp.desc_('ad000000-0000-0000-0000-000000000009') || '#' ||
  (select count(*) from public.audit_log where action = 'copy_bell_schedules' and entity_id = 'ad000000-0000-0000-0000-000000000009')$q$);

-- ============ النجاح ============
select pg_temp.run('ok.first',  'sa', pg_temp.copy('a5000000-0000-0000-0000-000000000002', 'a7000000-0000-0000-0000-000000000003', 'new year'));
select pg_temp.rec('ok.desc',   $q$select pg_temp.desc_('a7000000-0000-0000-0000-000000000003')$q$);
select pg_temp.rec('ok.source', $q$select pg_temp.desc_('a5000000-0000-0000-0000-000000000002')$q$);
select pg_temp.rec('ok.snap1',  $q$select pg_temp.snap('a7000000-0000-0000-0000-000000000003')$q$);
select pg_temp.run('ok.second', 'sa', pg_temp.copy('a5000000-0000-0000-0000-000000000002', 'a7000000-0000-0000-0000-000000000003', 'again'));
select pg_temp.rec('ok.snap2',  $q$select pg_temp.snap('a7000000-0000-0000-0000-000000000003')$q$);
select pg_temp.rec('pre.before', $q$select md5(string_agg(to_jsonb(p)::text, ';' order by p.id)) from public.bell_periods p where p.academic_year_id = 'ac000000-0000-0000-0000-000000000008'$q$);
select pg_temp.run('pre.copy',  'ta', pg_temp.copy('a5000000-0000-0000-0000-000000000002', 'ac000000-0000-0000-0000-000000000008', 'top up'));
select pg_temp.rec('pre.desc',  $q$select pg_temp.desc_('ac000000-0000-0000-0000-000000000008')$q$);
select pg_temp.rec('pre.kept',  $q$select (md5(string_agg(to_jsonb(p)::text, ';' order by p.id)) = (select v from r where k = 'pre.before'))::text
  from public.bell_periods p where p.academic_year_id = 'ac000000-0000-0000-0000-000000000008' and p.bell_schedule_id = 'd6000000-0000-0000-0000-000000000001' and p.weekday = 0 and p.kind = 'lesson'$q$);

-- ============ التدقيق ============
select pg_temp.rec('audit.domain', $q$select actor_type || '|' || reason || '|' || (new_values ->> 'schedules') || '/' || (new_values ->> 'periods') || '/' || (new_values ->> 'assignments')
  from public.audit_log where action = 'copy_bell_schedules' and entity_id = 'a7000000-0000-0000-0000-000000000003' and reason = 'new year'$q$);
select pg_temp.rec('audit.second', $q$select (new_values ->> 'schedules') || '/' || (new_values ->> 'periods') || '/' || (new_values ->> 'assignments') from public.audit_log
  where action = 'copy_bell_schedules' and entity_id = 'a7000000-0000-0000-0000-000000000003' and reason = 'again'$q$);
select pg_temp.rec('audit.rows', $q$select count(*) || ':' || string_agg(distinct action || '/' || reason, ',') from public.audit_log
  where entity_type in ('bell_schedules', 'bell_periods', 'grade_level_bell_schedules') and new_values ->> 'academic_year_id' = 'a7000000-0000-0000-0000-000000000003'$q$);
select pg_temp.rec('audit.refused', $q$select count(*)::text from public.audit_log where action = 'copy_bell_schedules' and entity_id in
  ('a8000000-0000-0000-0000-000000000004', 'a9000000-0000-0000-0000-000000000005', 'aa000000-0000-0000-0000-000000000006', 'ab000000-0000-0000-0000-000000000007', 'bb000000-0000-0000-0000-00000000000a')$q$);
select pg_temp.rec('audit.ctx', $q$select coalesce(string_agg(k, ',' order by k), 'none') from r where k like '%#ctx' and v <> '|'$q$);

-- =====================================================================
select plan(10 + 12 + 2 + 9 + 2 + 5);

select ok((select v from r where k = 'f.sec')        like 'ERR 42501%forbidden%', 'academic_year.read without academic_year.update → forbidden');
select ok((select v from r where k = 'f.sibling')    like 'ERR P0002%not found%', 'a sibling school''s admin cannot copy SA''s years');
select ok((select v from r where k = 'f.to_sibling') like 'ERR P0002%not found%', 'SA''s admin cannot target another school''s year');
select ok((select v from r where k = 'f.cross_ta')   like 'ERR 22023%different schools%', 'no copy across schools, even with scope on both');
select ok((select v from r where k = 'f.tenant')     like 'ERR P0002%not found%', 'another tenant cannot copy T1''s years');
select ok((select v from r where k = 'f.noreason')   like 'ERR 22023%reason required%', 'a reason is required');
select ok((select v from r where k = 'f.same')       like 'ERR 22023%same academic year%', 'source and target must differ');
select ok((select v from r where k = 'f.to_active')  like 'ERR 22023%must be planned (is active)%', 'no copy into an active year');
select ok((select v from r where k = 'f.to_closed')  like 'ERR 22023%must be planned (is closed)%', 'no copy into a closed year');
select is((select v from r where k = 'f.untouched'), ' |  | # |  | ', 'refused calls created nothing');

select ok((select v from r where k = 'c.inactive') like 'ERR 23514%schedule Morning is inactive in the target%', 'conflict: a same-named schedule turned inactive in the target');
select is((select v from r where k = 'c.inactive.after'), (select v from r where k = 'c.inactive.before'), '… nothing in the target changed');
select ok((select v from r where k = 'c.period') like 'ERR 23514%Morning/0 08:00:00 differs from the target%', 'conflict: a target period overlapping a source period without matching it');
select is((select v from r where k = 'c.period.after'), (select v from r where k = 'c.period.before'), '… nothing in the target changed');
select ok((select v from r where k = 'c.weekday') like 'ERR 23514%Morning/4 08:00:00 is not an active school weekday in the target%', 'conflict (D4): a source day that is not a school day in the target — copy the weekdays first (M42)');
select is((select v from r where k = 'c.weekday.after'), (select v from r where k = 'c.weekday.before'), '… nothing in the target changed');
select ok((select v from r where k = 'c.assign') like 'ERR 23514%grade 61000000-0000-0000-0000-000000000001 is assigned to another schedule in the target%', 'conflict: a grade level assigned to a different schedule in the target');
select is((select v from r where k = 'c.assign.after'), (select v from r where k = 'c.assign.before'), '… nothing in the target changed');
select ok((select v from r where k = 'c.name') like 'ERR 23514%Morning/0 08:45:00 differs from the target%', 'conflict: the same break with another name is not a match');
select is((select v from r where k = 'c.name.after'), (select v from r where k = 'c.name.before'), '… nothing in the target changed');
select ok((select v from r where k = 'atomic') like 'ERR P0001%injected failure%', 'atomicity: a failure in the last part surfaces');
select is((select v from r where k = 'atomic.after'), ' |  | #0', 'atomicity: no schedule, period, assignment or domain audit row survives');

select is((select pg_get_function_identity_arguments('app.copy_bell_schedules(uuid,uuid,text)'::regprocedure)),
          'p_source_year_id uuid, p_target_year_id uuid, p_reason text', 'year ids and a reason only — no client school_id');
select ok(has_function_privilege('authenticated', 'app.copy_bell_schedules(uuid,uuid,text)', 'EXECUTE')
      and not has_function_privilege('anon', 'app.copy_bell_schedules(uuid,uuid,text)', 'EXECUTE'), 'EXECUTE for authenticated only');

select is((select v from r where k = 'ok.first'), '8', 'first run: 2 schedules + 4 periods + 2 assignments');
select is((select v from r where k = 'ok.desc'),
  'Evening:active,Morning:active | Evening/0/lesson/13:00-13:45,Morning/0/lesson/08:00-08:45,Morning/0/break/08:45-09:00/R,Morning/4/lesson/08:00-08:40 | G1>Morning,G2>Evening',
  'copied: active schedules, their active periods (per day, D1), active grade assignments — not the inactive schedule, period or grade');
select ok((select v from r where k = 'ok.source') like 'Evening:active,Morning:active,Old:inactive | %', 'the source year is untouched');
select is((select v from r where k = 'ok.second'), '0', 'second run: nothing new');
select is((select v from r where k = 'ok.snap2'), (select v from r where k = 'ok.snap1'), '… and the target is byte-identical (no update, no stamp)');
select is((select v from r where k = 'pre.copy'), '5', 'a target with matching and extra rows: only the missing ones (1 schedule + 3 periods + 1 assignment)');
select is((select v from r where k = 'pre.desc'),
  'Evening:active,Morning:active | Evening/0/lesson/13:00-13:45,Morning/0/lesson/08:00-08:45,Morning/0/break/08:45-09:00/R,Morning/0/lesson/10:00-10:45,Morning/4/lesson/08:00-08:40 | G1>Morning,G2>Evening',
  '… the extra period stays');
select is((select v from r where k = 'pre.kept'), 'true', '… and the matching and extra lessons are byte-identical');
select is((select v from r where k = 'ok.first#ctx') || (select v from r where k = 'ok.second#ctx'), '||', 'the audit context is empty after the calls');

select is((select v from r where k = 'audit.domain'), 'tenant_user|new year|2/4/2', 'one domain audit row: actor, reason, schedules/periods/assignments');
select is((select v from r where k = 'audit.second'), '0/0/0', 'the second run is audited as nothing created');

select is((select v from r where k = 'audit.rows'), '8:insert/new year', 'each created row is audited (T7) with the operation''s reason');
select is((select v from r where k = 'audit.refused'), '0', 'refused copies leave no domain audit row');
select is((select v from r where k = 'audit.ctx'), 'none', 'the audit context is empty after every call');
select ok(not exists (select 1 from public.bell_schedules where academic_year_id = 'a7000000-0000-0000-0000-000000000003' and name = 'Old'), 'an inactive source schedule is not copied');
select ok(not exists (select 1 from public.grade_level_bell_schedules where academic_year_id = 'a7000000-0000-0000-0000-000000000003' and grade_level_id = '61000000-0000-0000-0000-000000000003'),
          'an inactive grade level''s assignment is not copied');

select * from finish();
rollback;
