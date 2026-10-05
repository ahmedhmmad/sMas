-- M43 — الدوام والحصص (Phase 2B / 2B-3): الجداول الثلاثة، منع التداخل (D6)، T15 (D3، D4)، امتداد T14 (D4)، copy_bell_day.
begin;

create temp table r (k text primary key, v text) on commit drop;
grant all on r to public;
create temp table actors (label text primary key, auth uuid) on commit drop;
grant select on actors to public;

create function pg_temp.rec(p_key text, p_sql text, p_reason text default null) returns void
language plpgsql as $$
declare x text;
begin
  perform set_config('app.audit_reason', coalesce(p_reason, ''), true);
  begin
    execute p_sql into x;
    x := coalesce(x, '<null>');
  exception when others then
    x := 'ERR ' || sqlstate || ': ' || sqlerrm;
  end;
  perform set_config('app.audit_reason', '', true);
  insert into r values (p_key, x) on conflict (k) do update set v = excluded.v;
end $$;

create function pg_temp.run(p_key text, p_label text, p_sql text, p_reason text default null) returns void
language plpgsql as $$
declare v_sub uuid := (select auth from actors where label = p_label);
begin
  perform set_config('request.jwt.claims', json_build_object('sub', v_sub, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', v_sub::text, true);
  execute 'set local role authenticated';
  perform pg_temp.rec(p_key, p_sql, p_reason);
  execute 'reset role';
  insert into r values (p_key || '#ctx', coalesce(current_setting('app.audit_action', true), '') || '|' || coalesce(current_setting('app.audit_reason', true), ''))
    on conflict (k) do update set v = excluded.v;
end $$;

-- ============ Fixture ============
insert into public.platform_tenants (id, tenant_code, host_label, name) values
  ('10000000-0000-0000-0000-000000000001', 'T1', 't1', 'T1'), ('20000000-0000-0000-0000-000000000002', 'T2', 't2', 'T2');
insert into public.groups (id, platform_tenant_id, group_code, name) values ('a1000000-0000-0000-0000-00000000000a', '10000000-0000-0000-0000-000000000001', 'GA', 'GA');
insert into public.schools (id, platform_tenant_id, group_id, school_code, name, slug) values
  ('5a000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', 'a1000000-0000-0000-0000-00000000000a', 'SA', 'SA', 'sa'),
  ('5b000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001', 'a1000000-0000-0000-0000-00000000000a', 'SB', 'SB', 'sb'),
  ('5c000000-0000-0000-0000-000000000003', '20000000-0000-0000-0000-000000000002', null, 'SX', 'SX', 'sx');
insert into public.academic_years (id, school_id, name, start_date, end_date) values
  ('c0000000-0000-0000-0000-000000000001', '5a000000-0000-0000-0000-000000000001', 'yC', '2025-09-01', '2026-06-30'),
  ('a0000000-0000-0000-0000-000000000002', '5a000000-0000-0000-0000-000000000001', 'yA', '2026-09-01', '2027-06-30'),
  ('b0000000-0000-0000-0000-000000000003', '5a000000-0000-0000-0000-000000000001', 'yP', '2027-09-01', '2028-06-30'),
  ('bb000000-0000-0000-0000-000000000004', '5b000000-0000-0000-0000-000000000002', 'yB', '2026-09-01', '2027-06-30'),
  ('cc000000-0000-0000-0000-000000000005', '5c000000-0000-0000-0000-000000000003', 'yX', '2026-09-01', '2027-06-30');
insert into public.stages (id, school_id, name, sequence_no) values ('51000000-0000-0000-0000-000000000001', '5a000000-0000-0000-0000-000000000001', 'P', 1);
insert into public.grade_levels (id, school_id, stage_id, name, sequence_no) values
  ('61000000-0000-0000-0000-000000000001', '5a000000-0000-0000-0000-000000000001', '51000000-0000-0000-0000-000000000001', 'G1', 1),
  ('61000000-0000-0000-0000-000000000002', '5a000000-0000-0000-0000-000000000001', '51000000-0000-0000-0000-000000000001', 'G2', 2),
  ('61000000-0000-0000-0000-000000000003', '5a000000-0000-0000-0000-000000000001', '51000000-0000-0000-0000-000000000001', 'GH', 3);
update public.grade_levels set status = 'inactive' where id = '61000000-0000-0000-0000-000000000003';
insert into public.calendar_weekdays (school_id, academic_year_id, weekday)
select y.school_id, y.id, d from public.academic_years y, generate_series(0, 4) d
 where y.id in ('c0000000-0000-0000-0000-000000000001', 'a0000000-0000-0000-0000-000000000002', 'b0000000-0000-0000-0000-000000000003',
                'bb000000-0000-0000-0000-000000000004', 'cc000000-0000-0000-0000-000000000005');
insert into public.bell_schedules (id, school_id, academic_year_id, name) values
  ('d0000000-0000-0000-0000-000000000001', '5a000000-0000-0000-0000-000000000001', 'c0000000-0000-0000-0000-000000000001', 'Old'),
  ('d1000000-0000-0000-0000-000000000002', '5a000000-0000-0000-0000-000000000001', 'a0000000-0000-0000-0000-000000000002', 'Morning'),
  ('d2000000-0000-0000-0000-000000000003', '5a000000-0000-0000-0000-000000000001', 'b0000000-0000-0000-0000-000000000003', 'Morning'),
  ('d3000000-0000-0000-0000-000000000004', '5a000000-0000-0000-0000-000000000001', 'b0000000-0000-0000-0000-000000000003', 'Evening'),
  ('d4000000-0000-0000-0000-000000000005', '5b000000-0000-0000-0000-000000000002', 'bb000000-0000-0000-0000-000000000004', 'B'),
  ('d5000000-0000-0000-0000-000000000006', '5c000000-0000-0000-0000-000000000003', 'cc000000-0000-0000-0000-000000000005', 'X');
-- yA Morning: الأحد حصتان واستراحة؛ الخميس حصة أقصر (D1)
insert into public.bell_periods (id, school_id, academic_year_id, bell_schedule_id, weekday, kind, name, start_time, end_time) values
  ('e1000000-0000-0000-0000-000000000001', '5a000000-0000-0000-0000-000000000001', 'a0000000-0000-0000-0000-000000000002', 'd1000000-0000-0000-0000-000000000002', 0, 'lesson', null,     '08:00', '08:45'),
  ('e1000000-0000-0000-0000-000000000002', '5a000000-0000-0000-0000-000000000001', 'a0000000-0000-0000-0000-000000000002', 'd1000000-0000-0000-0000-000000000002', 0, 'break',  'Recess', '08:45', '09:00'),
  ('e1000000-0000-0000-0000-000000000003', '5a000000-0000-0000-0000-000000000001', 'a0000000-0000-0000-0000-000000000002', 'd1000000-0000-0000-0000-000000000002', 0, 'lesson', null,     '09:00', '09:45'),
  ('e1000000-0000-0000-0000-000000000004', '5a000000-0000-0000-0000-000000000001', 'a0000000-0000-0000-0000-000000000002', 'd1000000-0000-0000-0000-000000000002', 4, 'lesson', null,     '08:00', '08:40'),
  ('e0000000-0000-0000-0000-000000000005', '5a000000-0000-0000-0000-000000000001', 'c0000000-0000-0000-0000-000000000001', 'd0000000-0000-0000-0000-000000000001', 0, 'lesson', null,     '08:00', '08:45'),
  ('e4000000-0000-0000-0000-000000000006', '5b000000-0000-0000-0000-000000000002', 'bb000000-0000-0000-0000-000000000004', 'd4000000-0000-0000-0000-000000000005', 0, 'lesson', null,     '08:00', '08:45'),
  ('e5000000-0000-0000-0000-000000000007', '5c000000-0000-0000-0000-000000000003', 'cc000000-0000-0000-0000-000000000005', 'd5000000-0000-0000-0000-000000000006', 0, 'lesson', null,     '08:00', '08:45');
insert into public.grade_level_bell_schedules (school_id, academic_year_id, grade_level_id, bell_schedule_id) values
  ('5a000000-0000-0000-0000-000000000001', 'a0000000-0000-0000-0000-000000000002', '61000000-0000-0000-0000-000000000001', 'd1000000-0000-0000-0000-000000000002');
update public.academic_years set status = 'active' where id = 'c0000000-0000-0000-0000-000000000001';
update public.academic_years set status = 'closed' where id = 'c0000000-0000-0000-0000-000000000001';
update public.academic_years set status = 'active'
 where id in ('a0000000-0000-0000-0000-000000000002', 'bb000000-0000-0000-0000-000000000004', 'cc000000-0000-0000-0000-000000000005');

create function pg_temp.member(p_label text, p_role text, p_tenant uuid, p_school uuid) returns void
language plpgsql as $$
declare v_a uuid := gen_random_uuid(); v_p uuid; v_m uuid;
begin
  insert into auth.users (id, email) values (v_a, p_label || '@m43.invalid');
  insert into public.auth_identities (auth_user_id, kind) values (v_a, 'tenant');
  insert into public.profiles (platform_tenant_id, auth_user_id, display_name) values (p_tenant, v_a, p_label) returning id into v_p;
  insert into public.memberships (platform_tenant_id, profile_id) values (p_tenant, v_p) returning id into v_m;
  insert into public.membership_roles (membership_id, role_id, platform_tenant_id, role_owner_key)
    values (v_m, (select id from public.roles where code = p_role and platform_tenant_id is null), p_tenant, '00000000-0000-0000-0000-000000000000');
  insert into public.membership_scopes (membership_id, platform_tenant_id, scope_type, school_id) values (v_m, p_tenant, 'school', p_school);
  insert into actors values (p_label, v_a);
end $$;
select pg_temp.member('sa',  'school_admin',   '10000000-0000-0000-0000-000000000001', '5a000000-0000-0000-0000-000000000001');
select pg_temp.member('sb',  'school_admin',   '10000000-0000-0000-0000-000000000001', '5b000000-0000-0000-0000-000000000002');
select pg_temp.member('sec', 'secretary',      '10000000-0000-0000-0000-000000000001', '5a000000-0000-0000-0000-000000000001');
select pg_temp.member('bus', 'bus_supervisor', '10000000-0000-0000-0000-000000000001', '5a000000-0000-0000-0000-000000000001');
select pg_temp.member('x',   'school_admin',   '20000000-0000-0000-0000-000000000002', '5c000000-0000-0000-0000-000000000003');

-- حصة في جدول بقيم حرفية (المدرسة والسنة من صف الجدول، كما يفعل الـAPI)
create function pg_temp.per(p_sched text, p_day int, p_kind text, p_s text, p_e text, p_name text default null) returns text language sql as $$
  select format($f$insert into public.bell_periods (school_id, academic_year_id, bell_schedule_id, weekday, kind, name, start_time, end_time)
                   values (%L, %L, %L, %s, %L, %L, %L, %L) returning 'ok'$f$, s.school_id, s.academic_year_id, s.id, p_day, p_kind, p_name, p_s, p_e)
    from public.bell_schedules s where s.id = p_sched::uuid
$$;
create function pg_temp.day(p_sched text, p_day int) returns text language sql as $$
  select coalesce(string_agg(kind || ':' || to_char(start_time, 'HH24:MI') || '-' || to_char(end_time, 'HH24:MI'), ',' order by start_time), '')
    from public.bell_periods where bell_schedule_id = p_sched::uuid and weekday = p_day and status = 'active'
$$;

-- ============ القراءة والكتابة (RLS) ============
select pg_temp.run('read.sa',  'sa',  $q$select (select count(*) from public.bell_schedules) || '|' || (select count(*) from public.bell_periods) || '|' || (select count(*) from public.grade_level_bell_schedules)$q$);
select pg_temp.run('read.sec', 'sec', $q$select (select count(*) from public.bell_schedules) || '|' || (select count(*) from public.bell_periods) || '|' || (select count(*) from public.grade_level_bell_schedules)$q$);
select pg_temp.run('read.bus', 'bus', $q$select (select count(*) from public.bell_schedules) || '|' || (select count(*) from public.bell_periods) || '|' || (select count(*) from public.grade_level_bell_schedules)$q$);
select pg_temp.run('read.sb',  'sb',  $q$select string_agg(distinct school_id::text, ',') from public.bell_periods$q$);
select pg_temp.run('read.x',   'x',   $q$select string_agg(distinct school_id::text, ',') from public.bell_periods$q$);
select pg_temp.run('w.sec',    'sec', $q$insert into public.bell_schedules (school_id, academic_year_id, name) values ('5a000000-0000-0000-0000-000000000001', 'b0000000-0000-0000-0000-000000000003', 'S') returning 'ok'$q$);
select pg_temp.run('w.sb',     'sb',  pg_temp.per('d2000000-0000-0000-0000-000000000003', 1, 'lesson', '08:00', '08:45'));
select pg_temp.run('w.sec_per','sec', pg_temp.per('d2000000-0000-0000-0000-000000000003', 1, 'lesson', '08:00', '08:45'));
select pg_temp.run('w.sec_upd','sec', $q$with u as (update public.bell_periods set end_time = '08:50' where id = 'e1000000-0000-0000-0000-000000000001' returning 1) select count(*)::text from u$q$, 'r');
select pg_temp.rec('blind.before', $q$select md5(coalesce((select string_agg(to_jsonb(p)::text, ';' order by p.id) from public.bell_periods p where p.school_id = '5a000000-0000-0000-0000-000000000001'), '') || coalesce((select string_agg(to_jsonb(g)::text, ';' order by g.id) from public.grade_level_bell_schedules g where g.school_id = '5a000000-0000-0000-0000-000000000001'), ''))$q$);
select pg_temp.run('blind.sb', 'sb', $q$with u as (update public.bell_periods set name = 'hijack') select 'done'$q$, 'r');
select pg_temp.run('blind.sb2','sb', $q$with u as (update public.grade_level_bell_schedules set bell_schedule_id = 'd1000000-0000-0000-0000-000000000002') select 'done'$q$, 'r');
select pg_temp.rec('blind.after',  $q$select md5(coalesce((select string_agg(to_jsonb(p)::text, ';' order by p.id) from public.bell_periods p where p.school_id = '5a000000-0000-0000-0000-000000000001'), '') || coalesce((select string_agg(to_jsonb(g)::text, ';' order by g.id) from public.grade_level_bell_schedules g where g.school_id = '5a000000-0000-0000-0000-000000000001'), ''))$q$);

-- ============ D6: منع التداخل (سنة planned — بلا سبب) ============
select pg_temp.run('o.first',    'sa', pg_temp.per('d2000000-0000-0000-0000-000000000003', 0, 'lesson', '09:00', '10:00'));
select pg_temp.run('o.overlap',  'sa', pg_temp.per('d2000000-0000-0000-0000-000000000003', 0, 'lesson', '09:30', '10:30'));
select pg_temp.run('o.adjacent', 'sa', pg_temp.per('d2000000-0000-0000-0000-000000000003', 0, 'lesson', '10:00', '11:00'));
select pg_temp.run('o.inside',   'sa', pg_temp.per('d2000000-0000-0000-0000-000000000003', 0, 'break',  '09:10', '09:20', 'b'));
select pg_temp.run('o.other_day','sa', pg_temp.per('d2000000-0000-0000-0000-000000000003', 1, 'lesson', '09:30', '10:30'));
select pg_temp.run('o.shift',    'sa', pg_temp.per('d3000000-0000-0000-0000-000000000004', 0, 'lesson', '09:30', '10:30'));
select pg_temp.rec('o.su',       pg_temp.per('d2000000-0000-0000-0000-000000000003', 0, 'lesson', '09:45', '10:15'));
select pg_temp.run('o.off',      'sa', $q$update public.bell_periods set status = 'inactive' where bell_schedule_id = 'd2000000-0000-0000-0000-000000000003' and weekday = 0 and start_time = '10:00' returning status$q$);
select pg_temp.run('o.after_off','sa', pg_temp.per('d2000000-0000-0000-0000-000000000003', 0, 'lesson', '10:15', '10:45'));
select pg_temp.run('o.move_into','sa', $q$update public.bell_periods set start_time = '09:50' where bell_schedule_id = 'd2000000-0000-0000-0000-000000000003' and weekday = 0 and start_time = '10:15' returning 'ok'$q$);
select pg_temp.run('o.times',    'sa', pg_temp.per('d2000000-0000-0000-0000-000000000003', 2, 'lesson', '10:00', '09:00'));
select pg_temp.run('o.midnight', 'sa', pg_temp.per('d2000000-0000-0000-0000-000000000003', 2, 'lesson', '23:30', '00:15'));
select pg_temp.run('o.break_noname', 'sa', pg_temp.per('d2000000-0000-0000-0000-000000000003', 2, 'break', '08:00', '08:15'));
select pg_temp.run('o.kind',     'sa', pg_temp.per('d2000000-0000-0000-0000-000000000003', 2, 'assembly', '07:30', '07:45', 'a'));

-- ============ D4: من الجهتين ============
select pg_temp.run('d4.friday',  'sa', pg_temp.per('d2000000-0000-0000-0000-000000000003', 5, 'lesson', '08:00', '08:45'));
select pg_temp.run('d4.move',    'sa', $q$update public.bell_periods set weekday = 5 where bell_schedule_id = 'd2000000-0000-0000-0000-000000000003' and weekday = 1 returning 'ok'$q$);
select pg_temp.rec('d4.su',      pg_temp.per('d2000000-0000-0000-0000-000000000003', 6, 'lesson', '08:00', '08:45'));
select pg_temp.run('d4.remove_day',  'sa', $q$select app.set_calendar_weekdays('b0000000-0000-0000-0000-000000000003', '{1,2,3,4}', 'drop sunday')::text$q$);
select pg_temp.run('d4.remove_free', 'sa', $q$select app.set_calendar_weekdays('b0000000-0000-0000-0000-000000000003', '{0,1,2,3}', 'drop thursday')::text$q$);
select pg_temp.rec('d4.su_day',  $q$update public.calendar_weekdays set status = 'inactive' where academic_year_id = 'b0000000-0000-0000-0000-000000000003' and weekday = 1 returning 'ok'$q$);

-- ============ الجدول النشط والإسناد ============
select pg_temp.run('s.off_with_periods', 'sa', $q$update public.bell_schedules set status = 'inactive' where id = 'd2000000-0000-0000-0000-000000000003' returning 'ok'$q$);
select pg_temp.run('s.spare',     'sa', $q$insert into public.bell_schedules (school_id, academic_year_id, name) values ('5a000000-0000-0000-0000-000000000001', 'b0000000-0000-0000-0000-000000000003', 'Spare') returning 'ok'$q$);
select pg_temp.run('s.spare_off', 'sa', $q$update public.bell_schedules set status = 'inactive' where name = 'Spare' returning status$q$);
select pg_temp.run('s.under_inactive', 'sa', (select pg_temp.per(id::text, 2, 'lesson', '08:00', '08:45') from public.bell_schedules where name = 'Spare'));
select pg_temp.run('s.dup_name',  'sa', $q$insert into public.bell_schedules (school_id, academic_year_id, name) values ('5a000000-0000-0000-0000-000000000001', 'b0000000-0000-0000-0000-000000000003', 'Morning') returning 'ok'$q$);
select pg_temp.run('g.assign',    'sa', $q$insert into public.grade_level_bell_schedules (school_id, academic_year_id, grade_level_id, bell_schedule_id) values ('5a000000-0000-0000-0000-000000000001', 'b0000000-0000-0000-0000-000000000003', '61000000-0000-0000-0000-000000000001', 'd2000000-0000-0000-0000-000000000003') returning 'ok'$q$);
select pg_temp.run('g.dup',       'sa', $q$insert into public.grade_level_bell_schedules (school_id, academic_year_id, grade_level_id, bell_schedule_id) values ('5a000000-0000-0000-0000-000000000001', 'b0000000-0000-0000-0000-000000000003', '61000000-0000-0000-0000-000000000001', 'd3000000-0000-0000-0000-000000000004') returning 'ok'$q$);
select pg_temp.run('g.reassign',  'sa', $q$update public.grade_level_bell_schedules set bell_schedule_id = 'd3000000-0000-0000-0000-000000000004' where academic_year_id = 'b0000000-0000-0000-0000-000000000003' and grade_level_id = '61000000-0000-0000-0000-000000000001' returning 'ok'$q$);
select pg_temp.run('g.inactive_grade', 'sa', $q$insert into public.grade_level_bell_schedules (school_id, academic_year_id, grade_level_id, bell_schedule_id) values ('5a000000-0000-0000-0000-000000000001', 'b0000000-0000-0000-0000-000000000003', '61000000-0000-0000-0000-000000000003', 'd2000000-0000-0000-0000-000000000003') returning 'ok'$q$);
select pg_temp.run('g.inactive_sched', 'sa', (select format($f$insert into public.grade_level_bell_schedules (school_id, academic_year_id, grade_level_id, bell_schedule_id) values ('5a000000-0000-0000-0000-000000000001', 'b0000000-0000-0000-0000-000000000003', '61000000-0000-0000-0000-000000000002', %L) returning 'ok'$f$, id) from public.bell_schedules where name = 'Spare'));
select pg_temp.run('g.other_year', 'sa', $q$insert into public.grade_level_bell_schedules (school_id, academic_year_id, grade_level_id, bell_schedule_id) values ('5a000000-0000-0000-0000-000000000001', 'b0000000-0000-0000-0000-000000000003', '61000000-0000-0000-0000-000000000002', 'd1000000-0000-0000-0000-000000000002') returning 'ok'$q$);
select pg_temp.run('s.free_evening', 'sa', $q$with p as (update public.bell_periods set status = 'inactive' where bell_schedule_id = 'd3000000-0000-0000-0000-000000000004' returning 1) select count(*)::text from p$q$);
select pg_temp.run('s.off_assigned', 'sa', $q$update public.bell_schedules set status = 'inactive' where id = 'd3000000-0000-0000-0000-000000000004' returning 'ok'$q$);

-- ============ D3: active بسبب، closed مجمَّدة، كل مسار ============
select pg_temp.run('a.noreason', 'sa', pg_temp.per('d1000000-0000-0000-0000-000000000002', 1, 'lesson', '08:00', '08:45'));
select pg_temp.run('a.reason',   'sa', pg_temp.per('d1000000-0000-0000-0000-000000000002', 1, 'lesson', '08:00', '08:45'), 'winter timing');
select pg_temp.run('a.edit',     'sa', $q$update public.bell_periods set end_time = '09:50' where id = 'e1000000-0000-0000-0000-000000000003' returning id::text$q$, 'longer lesson');
select pg_temp.run('a.assign_noreason', 'sa', $q$insert into public.grade_level_bell_schedules (school_id, academic_year_id, grade_level_id, bell_schedule_id) values ('5a000000-0000-0000-0000-000000000001', 'a0000000-0000-0000-0000-000000000002', '61000000-0000-0000-0000-000000000002', 'd1000000-0000-0000-0000-000000000002') returning 'ok'$q$);
select pg_temp.rec('a.su_noreason', pg_temp.per('d1000000-0000-0000-0000-000000000002', 2, 'lesson', '08:00', '08:45'));
select pg_temp.run('c.period',   'sa', pg_temp.per('d0000000-0000-0000-0000-000000000001', 1, 'lesson', '08:00', '08:45'), 'r');
select pg_temp.run('c.schedule', 'sa', $q$update public.bell_schedules set name = 'Old2' where id = 'd0000000-0000-0000-0000-000000000001' returning 'ok'$q$, 'r');
select pg_temp.rec('c.su',       $q$update public.bell_periods set end_time = '08:50' where id = 'e0000000-0000-0000-0000-000000000005' returning 'ok'$q$, 'r');
select pg_temp.rec('id.schedule', $q$update public.bell_periods set bell_schedule_id = 'd3000000-0000-0000-0000-000000000004' where id = 'e1000000-0000-0000-0000-000000000004' returning 'ok'$q$, 'r');
select pg_temp.rec('id.sched_year', $q$update public.bell_schedules set academic_year_id = 'a0000000-0000-0000-0000-000000000002' where name = 'Spare' returning 'ok'$q$, 'r');
select pg_temp.rec('id.assign_grade', $q$update public.grade_level_bell_schedules set grade_level_id = '61000000-0000-0000-0000-000000000002' where academic_year_id = 'a0000000-0000-0000-0000-000000000002' and grade_level_id = '61000000-0000-0000-0000-000000000001' returning 'ok'$q$, 'r');
select pg_temp.run('id.grant',    'sa', $q$update public.bell_periods set bell_schedule_id = 'd3000000-0000-0000-0000-000000000004' where id = 'e1000000-0000-0000-0000-000000000004' returning 'ok'$q$, 'r');

-- ============ D1، D5 ============
select pg_temp.rec('d1.days', $q$select pg_temp.day('d1000000-0000-0000-0000-000000000002', 0) || ' / ' || pg_temp.day('d1000000-0000-0000-0000-000000000002', 4)$q$);
select pg_temp.rec('d5.numbers', $q$select string_agg(n::text || '@' || to_char(start_time, 'HH24:MI'), ',' order by start_time) from (
  select start_time, row_number() over (order by start_time) n from public.bell_periods
   where bell_schedule_id = 'd1000000-0000-0000-0000-000000000002' and weekday = 0 and kind = 'lesson' and status = 'active') q$q$);

-- ============ copy_bell_day ============
create function pg_temp.cd(p_sched text, p_from int, p_to text, p_reason text default 'r') returns text language sql as $$
  select format($f$select app.copy_bell_day(%L, %s::smallint, %L::smallint[], %L)::text$f$, p_sched, p_from, p_to, p_reason)
$$;
select pg_temp.run('cd.sec',     'sec', pg_temp.cd('d2000000-0000-0000-0000-000000000003', 0, '{2}'));
select pg_temp.run('cd.sb',      'sb',  pg_temp.cd('d2000000-0000-0000-0000-000000000003', 0, '{2}'));
select pg_temp.run('cd.noreason','sa',  pg_temp.cd('d2000000-0000-0000-0000-000000000003', 0, '{2}', ''));
select pg_temp.run('cd.self',    'sa',  pg_temp.cd('d2000000-0000-0000-0000-000000000003', 0, '{0,2}'));
select pg_temp.run('cd.empty',   'sa',  pg_temp.cd('d2000000-0000-0000-0000-000000000003', 3, '{2}'));
select pg_temp.run('cd.busy',    'sa',  pg_temp.cd('d2000000-0000-0000-0000-000000000003', 0, '{1,2}'));
select pg_temp.run('cd.ok',      'sa',  pg_temp.cd('d2000000-0000-0000-0000-000000000003', 0, '{2,3}', 'same as sunday'));
select pg_temp.rec('cd.days',    $q$select (pg_temp.day('d2000000-0000-0000-0000-000000000003', 2) = pg_temp.day('d2000000-0000-0000-0000-000000000003', 0)
                                       and pg_temp.day('d2000000-0000-0000-0000-000000000003', 3) = pg_temp.day('d2000000-0000-0000-0000-000000000003', 0))::text$q$);
select pg_temp.run('cd.not_weekday', 'sa', pg_temp.cd('d1000000-0000-0000-0000-000000000002', 0, '{5}'));

-- ============ التدقيق ============
select pg_temp.rec('audit.period', $q$select action || '|' || reason from public.audit_log where entity_type = 'bell_periods' and action = 'insert' and reason = 'winter timing'$q$);
select pg_temp.rec('audit.edit',   $q$select action || '|' || reason || '|' || (old_values ->> 'end_time') || '>' || (new_values ->> 'end_time') from public.audit_log
  where entity_type = 'bell_periods' and entity_id = 'e1000000-0000-0000-0000-000000000003' and action = 'update'$q$);
select pg_temp.rec('audit.cd',     $q$select reason || '|' || (new_values ->> 'from_weekday') || '>' || (new_values ->> 'to_weekdays') || '|' || (new_values ->> 'created') from public.audit_log
  where action = 'copy_bell_day' and entity_id = 'd2000000-0000-0000-0000-000000000003'$q$);
select pg_temp.rec('audit.ctx',    $q$select coalesce(string_agg(k, ',' order by k), 'none') from r where k like '%#ctx' and v <> '|'$q$);

-- =====================================================================
select plan(76);

-- القراءة والكتابة
select is((select v from r where k = 'read.sa'),  '4|5|1', 'school_admin reads its school''s schedules, periods, assignments (all years)');
select is((select v from r where k = 'read.sec'), '4|5|1', 'secretary: academic_year.read is enough to read (B15)');
select is((select v from r where k = 'read.bus'), '0|0|0', 'bus_supervisor: no academic_year.read → nothing');
select is((select v from r where k = 'read.sb'),  '5b000000-0000-0000-0000-000000000002', 'a sibling school''s admin sees only its own periods');
select is((select v from r where k = 'read.x'),   '5c000000-0000-0000-0000-000000000003', 'another tenant sees only its own (I1)');
select ok((select v from r where k = 'w.sec') like 'ERR 42501%row-level security%bell_schedules%', 'academic_year.read does not grant writing');
select ok((select v from r where k = 'w.sb') like 'ERR 42501%row-level security%bell_periods%', 'a sibling school''s admin cannot add a period in SA');
select is((select v from r where k = 'w.sec_upd'), '0', 'secretary cannot update a period');
select ok((select v from r where k = 'w.sec_per') like 'ERR 42501%row-level security%bell_periods%', 'academic_year.read does not grant adding a period');
select ok((select v from r where k = 'blind.sb') = 'done' and (select v from r where k = 'blind.sb2') = 'done'
          and (select v from r where k = 'blind.after') = (select v from r where k = 'blind.before'),
          'blind UPDATEs (no WHERE, no RETURNING) by a sibling school''s admin touch no SA period or assignment — the UPDATE policies carry the scope');

-- D6
select is((select v from r where k = 'o.first'), 'ok', 'D6: 09:00–10:00');
select ok((select v from r where k = 'o.overlap') like 'ERR 23P01%bell_periods_no_overlap%', 'D6: 09:30–10:30 overlaps 09:00–10:00 — refused by the database');
select is((select v from r where k = 'o.adjacent'), 'ok', 'D6: 10:00–11:00 touches 09:00–10:00 — allowed ([) range)');
select ok((select v from r where k = 'o.inside') like 'ERR 23P01%bell_periods_no_overlap%', 'D6: a break inside a lesson overlaps too');
select is((select v from r where k = 'o.other_day'), 'ok', 'D6: the same time on another day is fine');
select is((select v from r where k = 'o.shift'), 'ok', 'D6: another schedule (shift) may overlap on the same day');
select ok((select v from r where k = 'o.su') like 'ERR 23P01%bell_periods_no_overlap%', 'D6: every path — the privileged role is refused too');
select is((select v from r where k = 'o.off'), 'inactive', 'a period is removed by turning it inactive');
select is((select v from r where k = 'o.after_off'), 'ok', 'an inactive period no longer blocks the slot');
select ok((select v from r where k = 'o.move_into') like 'ERR 23P01%bell_periods_no_overlap%', 'D6: moving a period into an overlap is refused (UPDATE too)');
select ok((select v from r where k = 'o.times') like 'ERR 23514%bell_periods_times_chk%', 'start before end');
select ok((select v from r where k = 'o.midnight') like 'ERR 23514%bell_periods_times_chk%', 'no period crosses midnight');
select ok((select v from r where k = 'o.break_noname') like 'ERR 23514%bell_periods_name_chk%', 'D7: a break needs a name');
select ok((select v from r where k = 'o.kind') like 'ERR 23514%bell_periods_kind_chk%', 'D7: lesson and break only');

-- D4
select ok((select v from r where k = 'd4.friday') like 'ERR 23514%active only on an active school weekday%', 'D4: no period on a day that is not a school day');
select ok((select v from r where k = 'd4.move') like 'ERR 23514%active only on an active school weekday%', 'D4: nor moved onto one');
select ok((select v from r where k = 'd4.su') like 'ERR 23514%active only on an active school weekday%', 'D4: every path');
select ok((select v from r where k = 'd4.remove_day') like 'ERR 23514%school weekday has active bell periods%', 'D4 (other direction): a school day with active periods cannot be removed — through set_calendar_weekdays');
select is((select v from r where k = 'd4.remove_free'), '1', 'D4: a school day without periods can still be removed');
select ok((select v from r where k = 'd4.su_day') like 'ERR 23514%school weekday has active bell periods%', 'D4 (other direction): every path');

-- الجدول والإسناد
select ok((select v from r where k = 's.off_with_periods') like 'ERR 23514%has active periods%', 'a schedule with active periods cannot be deactivated');
select is((select v from r where k = 's.spare') || '|' || (select v from r where k = 's.spare_off'), 'ok|inactive', 'an empty, unassigned schedule can be deactivated');
select ok((select v from r where k = 's.under_inactive') like 'ERR 23514%active only under an active bell schedule%', 'no active period under an inactive schedule');
select ok((select v from r where k = 's.dup_name') like 'ERR 23505%bell_schedules_name_uq%', 'one schedule name per year');
select is((select v from r where k = 'g.assign'), 'ok', 'D2: a grade level is assigned a schedule');
select ok((select v from r where k = 'g.dup') like 'ERR 23505%grade_level_bell_schedules_key_uq%', 'D2: one schedule per grade level per year');
select is((select v from r where k = 'g.reassign'), 'ok', 'D2: reassignment is an update of the schedule');
select ok((select v from r where k = 'g.inactive_grade') like 'ERR 23514%only an active grade level%', 'only an active grade level is assigned');
select ok((select v from r where k = 'g.inactive_sched') like 'ERR 23514%only to an active bell schedule%', 'only to an active schedule');
select ok((select v from r where k = 'g.other_year') like 'ERR 23503%grade_level_bell_schedules_schedule_fk%', 'the schedule must belong to the assignment''s year (FK)');
select ok((select v from r where k = 's.free_evening') = '1' and (select v from r where k = 's.off_assigned') like 'ERR 23514%assigned to a grade level%',
          'an assigned schedule cannot be deactivated (even with no active periods)');

-- D3
select ok((select v from r where k = 'a.noreason') like 'ERR 22023%reason required%', 'D3: an active year''s schedule changes need a reason');
select is((select v from r where k = 'a.reason'), 'ok', 'D3: … and are allowed with one');
select is((select v from r where k = 'a.edit'), 'e1000000-0000-0000-0000-000000000003', 'D5: editing the times keeps the period id (the stable slot identity)');
select ok((select v from r where k = 'a.assign_noreason') like 'ERR 22023%reason required%', 'D3: assignments too');
select ok((select v from r where k = 'a.su_noreason') like 'ERR 22023%reason required%', 'D3: every path');
select ok((select v from r where k = 'c.period') like 'ERR 23514%academic year is closed%', 'closed: no new period');
select ok((select v from r where k = 'c.schedule') like 'ERR 23514%academic year is closed%', 'closed: no schedule change');
select ok((select v from r where k = 'c.su') like 'ERR 23514%academic year is closed%', 'closed: every path');
select ok((select v from r where k = 'id.schedule') like 'ERR 23514%cannot move to another school, year or schedule%', 'a period keeps its schedule (guard)');
select ok((select v from r where k = 'id.sched_year') like 'ERR 23514%cannot move to another school or year%', 'a schedule keeps its year (guard, every path)');
select ok((select v from r where k = 'id.assign_grade') like 'ERR 23514%cannot move to another school, year or grade level%', 'an assignment keeps its grade level (guard, every path)');
select ok((select v from r where k = 'id.grant') like 'ERR 42501%permission denied%bell_periods%', '… and the column is outside the grant');

-- D1، D5
select is((select v from r where k = 'd1.days'), 'lesson:08:00-08:45,break:08:45-09:00,lesson:09:00-09:50 / lesson:08:00-08:40',
          'D1: each weekday has its own list — Thursday shorter, different times');
select is((select v from r where k = 'd5.numbers'), '1@08:00,2@09:00', 'D5: lesson numbers derive from start_time (breaks are not numbered)');
select ok(not exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'bell_periods' and column_name ~ 'seq|number|lesson_no'),
          'D5: no stored sequence column');

-- copy_bell_day
select ok((select v from r where k = 'cd.sec') like 'ERR 42501%forbidden%', 'copy day: academic_year.update required');
select ok((select v from r where k = 'cd.sb') like 'ERR P0002%not found%', 'copy day: another school''s schedule is not found');
select ok((select v from r where k = 'cd.noreason') like 'ERR 22023%reason required%', 'copy day: a reason is required');
select ok((select v from r where k = 'cd.self') like 'ERR 22023%other weekdays%', 'copy day: not onto itself');
select ok((select v from r where k = 'cd.empty') like 'ERR 22023%no active periods%', 'copy day: the source day must have periods');
select ok((select v from r where k = 'cd.busy') like 'ERR 23514%already have active periods: 1%', 'copy day: no silent merge into a day that has periods');
select is((select v from r where k = 'cd.ok'), '4', 'copy day: Sunday''s two active periods onto two days');
select is((select v from r where k = 'cd.days'), 'true', '… identical to Sunday');
select ok((select v from r where k = 'cd.not_weekday') like 'ERR 23514%active only on an active school weekday%', 'copy day: D4 holds — not onto a non-school day');
select is((select pg_get_function_identity_arguments('app.copy_bell_day(uuid,smallint,smallint[],text)'::regprocedure)),
          'p_schedule_id uuid, p_from_weekday smallint, p_to_weekdays smallint[], p_reason text', 'copy day: no client school_id');
select ok(has_function_privilege('authenticated', 'app.copy_bell_day(uuid,smallint,smallint[],text)', 'EXECUTE')
      and not has_function_privilege('anon', 'app.copy_bell_day(uuid,smallint,smallint[],text)', 'EXECUTE'), 'copy day: EXECUTE for authenticated only');
select ok(not has_function_privilege('authenticated', 'app.require_year_setup_writable(uuid,text)', 'EXECUTE'), 'the year-state helper is internal');

-- التدقيق والبنية
select is((select v from r where k = 'audit.period'), 'insert|winter timing', 'T7: an active-year period carries the reason from the request (C3)');
select is((select v from r where k = 'audit.edit'), 'update|longer lesson|09:45:00>09:50:00', 'T7: the time change with old/new and the reason');
select is((select v from r where k = 'audit.cd'), 'same as sunday|0>[2, 3]|4', 'one domain audit row for copy day');
select is((select v from r where k = 'audit.ctx'), 'none', 'the audit context is empty after every call');
select ok(not has_table_privilege('authenticated', 'public.bell_schedules', 'DELETE') and not has_table_privilege('authenticated', 'public.bell_periods', 'DELETE')
      and not has_table_privilege('authenticated', 'public.grade_level_bell_schedules', 'DELETE'), 'no DELETE on the three tables');
select ok(exists (select 1 from pg_constraint where conname = 'bell_periods_no_overlap' and contype = 'x'), 'D6 is a database exclusion constraint');
select is((select count(*)::int from pg_trigger where tgname = 'guard' and tgrelid in ('public.bell_schedules'::regclass, 'public.bell_periods'::regclass, 'public.grade_level_bell_schedules'::regclass)), 3,
          'T15 guards all three tables');
select is((select count(*)::int from public.bell_periods where academic_year_id = 'a0000000-0000-0000-0000-000000000002' and status = 'active'), 5,
          'refused writes left nothing behind in the active year');

select * from finish();
rollback;
