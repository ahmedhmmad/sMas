-- M41 — التقويم (Phase 2B / 2B-2): الجدولان، T14 (B8 بقرارات C1–C5)، set_calendar_weekdays، is_school_day، school_today.
-- كل التواريخ نسبية إلى «اليوم» بتوقيت المدرسة (T = app.school_today(SA)) — الاختبار صالح في أي يوم.
begin;

create temp table r (k text primary key, v text) on commit drop;
grant all on r to public;
create temp table actors (label text primary key, auth uuid) on commit drop;
grant select on actors to public;

-- p_reason: يوضع في سياق التدقيق قبل الجملة (كما يفعل الـAPI — C3) ويُفرَّغ بعدها
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
insert into public.schools (id, platform_tenant_id, group_id, school_code, name, slug, timezone) values
  ('5a000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', 'a1000000-0000-0000-0000-00000000000a', 'SA', 'SA', 'sa', 'Africa/Cairo'),
  ('5b000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001', 'a1000000-0000-0000-0000-00000000000a', 'SB', 'SB', 'sb', 'Africa/Cairo'),
  ('5c000000-0000-0000-0000-000000000003', '20000000-0000-0000-0000-000000000002', null, 'SX', 'SX', 'sx', 'Africa/Cairo'),
  ('5d000000-0000-0000-0000-000000000004', '10000000-0000-0000-0000-000000000001', null, 'SK', 'SK', 'sk', 'Pacific/Kiritimati'),   -- UTC+14
  ('5e000000-0000-0000-0000-000000000005', '10000000-0000-0000-0000-000000000001', null, 'SP', 'SP', 'sp', 'Pacific/Pago_Pago');    -- UTC-11

create temp table t (today date, sun1 date, sun2 date, sun3 date, sun4 date, fri1 date, fri2 date, sunc date) on commit drop;
grant select on t to public;
create function pg_temp.nd(p_base date, p_dow int) returns date language sql immutable as $$
  select p_base + ((p_dow - extract(dow from p_base)::int + 7) % 7)
$$;
insert into t select x, pg_temp.nd(x + 50, 0), pg_temp.nd(x + 70, 0), pg_temp.nd(x + 100, 0), pg_temp.nd(x + 120, 0),
                     pg_temp.nd(x + 80, 5), pg_temp.nd(x + 130, 5), pg_temp.nd(x - 400, 0)
  from (select app.school_today('5a000000-0000-0000-0000-000000000001') as x) s;
create function pg_temp.d(p_offset int) returns date language sql stable as $$ select today + p_offset from t $$;

-- السنوات: SA — yC مغلقة، yA نشطة (تحتوي اليوم)، yP و yQ planned؛ SB yB نشطة بلا أيام دوام (C2)؛ SX yX؛ SK yK؛ SP ySP
insert into public.academic_years (id, school_id, name, start_date, end_date) values
  ('c0000000-0000-0000-0000-000000000001', '5a000000-0000-0000-0000-000000000001', 'yC',  pg_temp.d(-500), pg_temp.d(-200)),
  ('a0000000-0000-0000-0000-000000000002', '5a000000-0000-0000-0000-000000000001', 'yA',  pg_temp.d(-100), pg_temp.d(200)),
  ('b0000000-0000-0000-0000-000000000003', '5a000000-0000-0000-0000-000000000001', 'yP',  pg_temp.d(300),  pg_temp.d(600)),
  ('b1000000-0000-0000-0000-000000000004', '5a000000-0000-0000-0000-000000000001', 'yQ',  pg_temp.d(700),  pg_temp.d(900)),
  ('bb000000-0000-0000-0000-000000000005', '5b000000-0000-0000-0000-000000000002', 'yB',  pg_temp.d(-100), pg_temp.d(200)),
  ('cc000000-0000-0000-0000-000000000006', '5c000000-0000-0000-0000-000000000003', 'yX',  pg_temp.d(-100), pg_temp.d(200)),
  ('dd000000-0000-0000-0000-000000000007', '5d000000-0000-0000-0000-000000000004', 'yK',  pg_temp.d(-100), pg_temp.d(200)),
  ('ee000000-0000-0000-0000-000000000008', '5e000000-0000-0000-0000-000000000005', 'ySP', pg_temp.d(-100), pg_temp.d(200));

insert into public.calendar_weekdays (school_id, academic_year_id, weekday)
select '5a000000-0000-0000-0000-000000000001'::uuid, y, d from unnest(array['a0000000-0000-0000-0000-000000000002', 'c0000000-0000-0000-0000-000000000001']::uuid[]) y, generate_series(0, 4) d
union all select '5c000000-0000-0000-0000-000000000003'::uuid, 'cc000000-0000-0000-0000-000000000006'::uuid, d from generate_series(0, 4) d;

create function pg_temp.exc(p_id text, p_year uuid, p_kind text, p_name text, p_s date, p_e date) returns void language sql as $$
  insert into public.calendar_exceptions (id, school_id, academic_year_id, year_start_date, year_end_date, kind, name, start_date, end_date)
  select p_id::uuid, y.school_id, y.id, y.start_date, y.end_date, p_kind, p_name, p_s, p_e from public.academic_years y where y.id = p_year
$$;
-- yA (تُنشأ وهي planned): جارية R، ماضية Past، مستقبلية Future، Mid تغطي sun1 ويوم استثنائي فيها، CH تُلغى
select pg_temp.exc('e0000000-0000-0000-0000-000000000001', 'a0000000-0000-0000-0000-000000000002', 'holiday',   'R',      pg_temp.d(-3),  pg_temp.d(3));
select pg_temp.exc('e0000000-0000-0000-0000-000000000002', 'a0000000-0000-0000-0000-000000000002', 'holiday',   'Past',   pg_temp.d(-20), pg_temp.d(-15));
select pg_temp.exc('e0000000-0000-0000-0000-000000000003', 'a0000000-0000-0000-0000-000000000002', 'holiday',   'Future', pg_temp.d(30),  pg_temp.d(35));
select pg_temp.exc('e0000000-0000-0000-0000-000000000004', 'a0000000-0000-0000-0000-000000000002', 'holiday',   'Mid',    (select sun1 - 1 from t), (select sun1 + 1 from t));
select pg_temp.exc('e0000000-0000-0000-0000-000000000005', 'a0000000-0000-0000-0000-000000000002', 'study_day', 'Makeup', (select sun1 from t), (select sun1 from t));
select pg_temp.exc('e0000000-0000-0000-0000-000000000006', 'a0000000-0000-0000-0000-000000000002', 'holiday',   'CH',     (select sun2 from t), (select sun2 from t));
update public.calendar_exceptions set status = 'cancelled' where id = 'e0000000-0000-0000-0000-000000000006';
select pg_temp.exc('e0000000-0000-0000-0000-000000000007', 'c0000000-0000-0000-0000-000000000001', 'holiday',   'Old',    pg_temp.d(-300), pg_temp.d(-299));
select pg_temp.exc('e0000000-0000-0000-0000-000000000008', 'b1000000-0000-0000-0000-000000000004', 'holiday',   'Q1',     pg_temp.d(750), pg_temp.d(760));
select pg_temp.exc('e0000000-0000-0000-0000-000000000009', 'b1000000-0000-0000-0000-000000000004', 'holiday',   'Q2',     pg_temp.d(770), pg_temp.d(771));
update public.calendar_exceptions set status = 'cancelled' where id = 'e0000000-0000-0000-0000-000000000009';
select pg_temp.exc('e0000000-0000-0000-0000-00000000000b', 'bb000000-0000-0000-0000-000000000005', 'holiday',   'B',      pg_temp.d(40), pg_temp.d(41));
select pg_temp.exc('e0000000-0000-0000-0000-00000000000c', 'cc000000-0000-0000-0000-000000000006', 'holiday',   'X',      pg_temp.d(40), pg_temp.d(41));

update public.academic_years set status = 'active' where id = 'c0000000-0000-0000-0000-000000000001';
update public.academic_years set status = 'closed' where id = 'c0000000-0000-0000-0000-000000000001';
update public.academic_years set status = 'active'
 where id in ('a0000000-0000-0000-0000-000000000002', 'bb000000-0000-0000-0000-000000000005', 'cc000000-0000-0000-0000-000000000006',
              'dd000000-0000-0000-0000-000000000007', 'ee000000-0000-0000-0000-000000000008');

create function pg_temp.member(p_label text, p_role text, p_tenant uuid, p_school uuid) returns void
language plpgsql as $$
declare v_a uuid := gen_random_uuid(); v_p uuid; v_m uuid;
begin
  insert into auth.users (id, email) values (v_a, p_label || '@m41.invalid');
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

-- إدراج استثناء بقيم حرفية (المدرسة وحدود السنة من صف السنة، كما يفعل الـAPI)
create function pg_temp.ins(p_year uuid, p_kind text, p_name text, p_s date, p_e date) returns text language sql as $$
  select format($f$insert into public.calendar_exceptions (school_id, academic_year_id, year_start_date, year_end_date, kind, name, start_date, end_date)
                   values (%L, %L, %L, %L, %L, %L, %L, %L) returning 'ok'$f$, y.school_id, y.id, y.start_date, y.end_date, p_kind, p_name, p_s, p_e)
    from public.academic_years y where y.id = p_year
$$;
create function pg_temp.upd(p_id text, p_set text) returns text language sql as $$
  select format($f$update public.calendar_exceptions set %s where id = %L returning 'ok'$f$, p_set, p_id)
$$;
create function pg_temp.wd(p_year text, p_days text, p_reason text default 'r') returns text language sql as $$
  select format($f$select app.set_calendar_weekdays(%L, %L::smallint[], %L)::text$f$, p_year, p_days, p_reason)
$$;

-- ============ القراءة ============
select pg_temp.rec('read.expected', $q$select count(*)::text from public.calendar_exceptions where school_id = '5a000000-0000-0000-0000-000000000001'$q$);
select pg_temp.run('read.sa',  'sa',  $q$select count(*) || '|' || count(distinct school_id) || '|' || (select count(*) from public.calendar_weekdays) from public.calendar_exceptions$q$);
select pg_temp.run('read.sec', 'sec', $q$select count(*) || '|' || count(distinct school_id) || '|' || (select count(*) from public.calendar_weekdays) from public.calendar_exceptions$q$);
select pg_temp.run('read.bus', 'bus', $q$select count(*) || '|' || (select count(*) from public.calendar_weekdays) from public.calendar_exceptions$q$);
select pg_temp.run('read.sb',  'sb',  $q$select string_agg(distinct school_id::text, ',') from public.calendar_exceptions$q$);
select pg_temp.run('read.x',   'x',   $q$select string_agg(distinct school_id::text, ',') from public.calendar_exceptions$q$);

-- ============ الكتابة (RLS والمنح) ============
select pg_temp.run('w.sec_insert', 'sec', pg_temp.ins('b0000000-0000-0000-0000-000000000003', 'holiday', 'h', pg_temp.d(400), pg_temp.d(401)));
select pg_temp.run('w.sec_update', 'sec', $q$with u as (update public.calendar_exceptions set name = 'h' where id = 'e0000000-0000-0000-0000-000000000008' returning 1) select count(*)::text from u$q$);
select pg_temp.run('w.sb_insert',  'sb',  pg_temp.ins('b0000000-0000-0000-0000-000000000003', 'holiday', 'h', pg_temp.d(400), pg_temp.d(401)));
select pg_temp.run('w.weekday_direct', 'sa', $q$insert into public.calendar_weekdays (school_id, academic_year_id, weekday) values ('5a000000-0000-0000-0000-000000000001', 'b0000000-0000-0000-0000-000000000003', 5) returning 'ok'$q$);
select pg_temp.rec('blind.before', $q$select md5(string_agg(to_jsonb(e)::text, ';' order by e.id)) from public.calendar_exceptions e where e.school_id = '5a000000-0000-0000-0000-000000000001'$q$);
select pg_temp.run('blind.sb', 'sb', $q$with u as (update public.calendar_exceptions set name = 'hijack') select 'done'$q$, 'r');
select pg_temp.rec('blind.after',  $q$select md5(string_agg(to_jsonb(e)::text, ';' order by e.id)) from public.calendar_exceptions e where e.school_id = '5a000000-0000-0000-0000-000000000001'$q$);

-- ============ سنة planned: حرة ============
select pg_temp.run('p.ins',     'sa', pg_temp.ins('b0000000-0000-0000-0000-000000000003', 'holiday', 'P1', pg_temp.d(310), pg_temp.d(315)));
select pg_temp.run('p.overlap', 'sa', pg_temp.ins('b0000000-0000-0000-0000-000000000003', 'holiday', 'P2', pg_temp.d(312), pg_temp.d(320)));
select pg_temp.run('p.cancel',  'sa', $q$update public.calendar_exceptions set status = 'cancelled' where name = 'P1' returning status$q$);
select pg_temp.run('p.overlap_after_cancel', 'sa', pg_temp.ins('b0000000-0000-0000-0000-000000000003', 'holiday', 'P2', pg_temp.d(312), pg_temp.d(320)));
select pg_temp.run('p.final',   'sa', $q$update public.calendar_exceptions set name = 'again' where name = 'P1' returning 'ok'$q$);
select pg_temp.run('p.outside', 'sa', pg_temp.ins('b0000000-0000-0000-0000-000000000003', 'holiday', 'P3', pg_temp.d(600), pg_temp.d(601)));
select pg_temp.run('p.sd_range','sa', pg_temp.ins('b0000000-0000-0000-0000-000000000003', 'study_day', 'S', pg_temp.d(330), pg_temp.d(331)));
select pg_temp.run('p.sd_one',  'sa', pg_temp.ins('b0000000-0000-0000-0000-000000000003', 'study_day', 'S1', pg_temp.d(330), pg_temp.d(330)));
select pg_temp.run('p.sd_dup',  'sa', pg_temp.ins('b0000000-0000-0000-0000-000000000003', 'study_day', 'S2', pg_temp.d(330), pg_temp.d(330)));
select pg_temp.run('p.move',    'sa', $q$update public.calendar_exceptions set start_date = start_date - 9, end_date = end_date - 9 where name = 'P2' returning 'ok'$q$);

-- ترحيل حدود سنة planned (ON UPDATE CASCADE) — ومنه الاستثناء الملغى
select pg_temp.rec('casc.ok', format($q$update public.academic_years set end_date = %L where id = 'b1000000-0000-0000-0000-000000000004' returning 'ok'$q$, pg_temp.d(800)));
select pg_temp.rec('casc.rows', $q$select string_agg(name || ':' || year_end_date::text, ',' order by name) from public.calendar_exceptions where academic_year_id = 'b1000000-0000-0000-0000-000000000004'$q$);
select pg_temp.rec('casc.out', format($q$update public.academic_years set end_date = %L where id = 'b1000000-0000-0000-0000-000000000004' returning 'ok'$q$, pg_temp.d(755)));

-- ============ سنة active (C1، C3، C4) ============
select pg_temp.run('a.noreason',   'sa', pg_temp.ins('a0000000-0000-0000-0000-000000000002', 'holiday', 'N', pg_temp.d(12), pg_temp.d(13)));
select pg_temp.run('a.yesterday',  'sa', pg_temp.ins('a0000000-0000-0000-0000-000000000002', 'study_day', 'Y', pg_temp.d(-1), pg_temp.d(-1)), 'r');
select pg_temp.run('a.today',      'sa', pg_temp.ins('a0000000-0000-0000-0000-000000000002', 'study_day', 'Today', pg_temp.d(0), pg_temp.d(0)), 'emergency');
select pg_temp.run('a.future',     'sa', pg_temp.ins('a0000000-0000-0000-0000-000000000002', 'holiday', 'Fut2', pg_temp.d(12), pg_temp.d(13)), 'r-future');
select pg_temp.run('f.move_ok',    'sa', pg_temp.upd('e0000000-0000-0000-0000-000000000003', format('start_date = %L', pg_temp.d(31))), 'r');
select pg_temp.run('f.move_past',  'sa', pg_temp.upd('e0000000-0000-0000-0000-000000000003', format('start_date = %L', pg_temp.d(-1))), 'r');
select pg_temp.run('f.noreason',   'sa', pg_temp.upd('e0000000-0000-0000-0000-000000000003', $s$name = 'F2'$s$));
select pg_temp.run('f.cancel',     'sa', pg_temp.upd('e0000000-0000-0000-0000-000000000003', $s$status = 'cancelled'$s$), 'r');
select pg_temp.run('f.final',      'sa', pg_temp.upd('e0000000-0000-0000-0000-000000000003', $s$name = 'F3'$s$), 'r');
select pg_temp.run('r.extend',     'sa', pg_temp.upd('e0000000-0000-0000-0000-000000000001', format('end_date = %L', pg_temp.d(10))), 'extended');
select pg_temp.run('r.shorten',    'sa', pg_temp.upd('e0000000-0000-0000-0000-000000000001', format('end_date = %L', pg_temp.d(0))), 'r');
select pg_temp.run('r.past_end',   'sa', pg_temp.upd('e0000000-0000-0000-0000-000000000001', format('end_date = %L', pg_temp.d(-1))), 'r');
select pg_temp.run('r.rename',     'sa', pg_temp.upd('e0000000-0000-0000-0000-000000000001', $s$name = 'R2'$s$), 'r');
select pg_temp.run('r.move_start', 'sa', pg_temp.upd('e0000000-0000-0000-0000-000000000001', format('start_date = %L', pg_temp.d(-2))), 'r');
select pg_temp.run('r.cancel',     'sa', pg_temp.upd('e0000000-0000-0000-0000-000000000001', $s$status = 'cancelled'$s$), 'r');
select pg_temp.run('past.extend',  'sa', pg_temp.upd('e0000000-0000-0000-0000-000000000002', format('end_date = %L', pg_temp.d(1))), 'r');
select pg_temp.rec('r.state', $q$select start_date - (select today from t) || '|' || end_date - (select today from t) || '|' || name || '|' || status
  from public.calendar_exceptions where id = 'e0000000-0000-0000-0000-000000000001'$q$);

-- كل مسار: المسار المميّز (postgres) يمر بالحارس نفسه
select pg_temp.rec('su.past',     (select replace(pg_temp.ins('a0000000-0000-0000-0000-000000000002', 'holiday', 'SU', pg_temp.d(-10), pg_temp.d(-9)), $s$returning 'ok'$s$, $s$returning 'ok'$s$)), 'r');
select pg_temp.rec('su.noreason', pg_temp.ins('a0000000-0000-0000-0000-000000000002', 'holiday', 'SU2', pg_temp.d(40), pg_temp.d(41)));
select pg_temp.rec('su.kind',     pg_temp.upd('e0000000-0000-0000-0000-000000000001', $s$kind = 'study_day'$s$), 'r');
select pg_temp.run('col.kind',    'sa', pg_temp.upd('e0000000-0000-0000-0000-000000000001', $s$kind = 'study_day'$s$), 'r');

-- C5
select pg_temp.run('c5.sunday', 'sa', pg_temp.ins('a0000000-0000-0000-0000-000000000002', 'study_day', 'Sun', (select sun3 from t), (select sun3 from t)), 'r');
select pg_temp.run('c5.friday', 'sa', pg_temp.ins('a0000000-0000-0000-0000-000000000002', 'study_day', 'Fri', (select fri1 from t), (select fri1 from t)), 'r');

-- سنة closed
select pg_temp.run('cl.insert', 'sa', pg_temp.ins('c0000000-0000-0000-0000-000000000001', 'holiday', 'C', pg_temp.d(-250), pg_temp.d(-250)), 'r');
select pg_temp.run('cl.update', 'sa', pg_temp.upd('e0000000-0000-0000-0000-000000000007', $s$name = 'Old2'$s$), 'r');

-- ============ أيام الدوام ============
select pg_temp.run('w.sec',      'sec', pg_temp.wd('b0000000-0000-0000-0000-000000000003', '{0,1}'));
select pg_temp.run('w.sb_sa',    'sb',  pg_temp.wd('b0000000-0000-0000-0000-000000000003', '{0,1}'));
select pg_temp.run('w.noreason', 'sa',  pg_temp.wd('b0000000-0000-0000-0000-000000000003', '{0,1}', ''));
select pg_temp.run('w.empty',    'sa',  pg_temp.wd('b0000000-0000-0000-0000-000000000003', '{}'));
select pg_temp.run('w.range',    'sa',  pg_temp.wd('b0000000-0000-0000-0000-000000000003', '{0,7}'));
select pg_temp.run('w.p1',       'sa',  pg_temp.wd('b0000000-0000-0000-0000-000000000003', '{0,1,2,3,4}', 'set week'));
select pg_temp.run('w.p2',       'sa',  pg_temp.wd('b0000000-0000-0000-0000-000000000003', '{6,0,1,2,3,3}', 'change week'));
select pg_temp.rec('w.p_state',  $q$select string_agg(weekday || ':' || status, ',' order by weekday) from public.calendar_weekdays where academic_year_id = 'b0000000-0000-0000-0000-000000000003'$q$);
select pg_temp.run('w.active_fixed', 'sa', pg_temp.wd('a0000000-0000-0000-0000-000000000002', '{0,1}'));
select pg_temp.run('w.c2_first', 'sb', pg_temp.wd('bb000000-0000-0000-0000-000000000005', '{0,1,2,3,4}', 'first definition'));
select pg_temp.run('w.c2_again', 'sb', pg_temp.wd('bb000000-0000-0000-0000-000000000005', '{0}'));
select pg_temp.run('w.closed',   'sa', pg_temp.wd('c0000000-0000-0000-0000-000000000001', '{0}'));
select pg_temp.rec('w.guard_closed', $q$update public.calendar_weekdays set status = 'inactive' where academic_year_id = 'c0000000-0000-0000-0000-000000000001' and weekday = 0 returning 'ok'$q$);
select pg_temp.rec('w.guard_identity', $q$update public.calendar_weekdays set weekday = 5 where academic_year_id = 'b0000000-0000-0000-0000-000000000003' and weekday = 4 returning 'ok'$q$);

-- ============ is_school_day (العقد للمرحلة 5) ============
select pg_temp.rec('isd', $q$select string_agg(k || '=' || app.is_school_day(s, d), ',' order by k) from (values
  ('a_none',     '5a000000-0000-0000-0000-000000000001'::uuid, (select today + 1000 from t)),
  ('b_weekday',  '5a000000-0000-0000-0000-000000000001'::uuid, (select sun4 from t)),
  ('c_rest',     '5a000000-0000-0000-0000-000000000001'::uuid, (select fri2 from t)),
  ('d_holiday',  '5a000000-0000-0000-0000-000000000001'::uuid, (select sun1 + 1 from t)),
  ('e_study_in_holiday', '5a000000-0000-0000-0000-000000000001'::uuid, (select sun1 from t)),
  ('f_cancelled','5a000000-0000-0000-0000-000000000001'::uuid, (select sun2 from t)),
  ('g_study_rest','5a000000-0000-0000-0000-000000000001'::uuid, (select fri1 from t)),
  ('h_closed',   '5a000000-0000-0000-0000-000000000001'::uuid, (select sunc from t)),
  ('i_today',    '5a000000-0000-0000-0000-000000000001'::uuid, (select today from t)),
  ('j_other_school', '5b000000-0000-0000-0000-000000000002'::uuid, (select fri2 from t)),
  ('k_inactive_day', '5a000000-0000-0000-0000-000000000001'::uuid, (select today + 450 + ((4 - extract(dow from today + 450)::int + 7) % 7) from t))
) v(k, s, d)$q$);

-- ============ C1: «اليوم» بتوقيت المدرسة ============
select pg_temp.rec('tz.cairo', $q$select (app.school_today('5a000000-0000-0000-0000-000000000001') = (now() at time zone 'Africa/Cairo')::date)::text$q$);
select pg_temp.rec('tz.diff',  $q$select (app.school_today('5d000000-0000-0000-0000-000000000004') - app.school_today('5e000000-0000-0000-0000-000000000005'))::text$q$);
select pg_temp.rec('tz.k_yesterday', (select pg_temp.ins('dd000000-0000-0000-0000-000000000007', 'holiday', 'K0', app.school_today('5d000000-0000-0000-0000-000000000004') - 1, app.school_today('5d000000-0000-0000-0000-000000000004') - 1)), 'r');
select pg_temp.rec('tz.k_today',     (select pg_temp.ins('dd000000-0000-0000-0000-000000000007', 'holiday', 'K1', app.school_today('5d000000-0000-0000-0000-000000000004'), app.school_today('5d000000-0000-0000-0000-000000000004'))), 'r');
select pg_temp.rec('tz.p_today',     (select pg_temp.ins('ee000000-0000-0000-0000-000000000008', 'holiday', 'P0', app.school_today('5e000000-0000-0000-0000-000000000005'), app.school_today('5e000000-0000-0000-0000-000000000005'))), 'r');
select pg_temp.rec('tz.p_yesterday', (select pg_temp.ins('ee000000-0000-0000-0000-000000000008', 'holiday', 'P-1', app.school_today('5e000000-0000-0000-0000-000000000005') - 1, app.school_today('5e000000-0000-0000-0000-000000000005') - 1)), 'r');

-- ============ التدقيق ============
select pg_temp.rec('audit.exc', $q$select action || '|' || reason || '|' || actor_type from public.audit_log
  where entity_type = 'calendar_exceptions' and new_values ->> 'name' = 'Fut2' and action = 'insert'$q$);
select pg_temp.rec('audit.extend', $q$select action || '|' || reason || '|' || (old_values ->> 'end_date') || '>' || (new_values ->> 'end_date') from public.audit_log
  where entity_type = 'calendar_exceptions' and entity_id = 'e0000000-0000-0000-0000-000000000001' and reason = 'extended'$q$);
select pg_temp.rec('audit.weekdays', $q$select string_agg(action || ':' || reason, ',' order by id) from public.audit_log
  where entity_type = 'calendar_weekdays' and new_values ->> 'academic_year_id' = 'b0000000-0000-0000-0000-000000000003' and reason = 'change week'$q$);
select pg_temp.rec('audit.domain', $q$select string_agg(reason || ':' || (new_values ->> 'weekdays') || ':' || (new_values ->> 'changed'), ',' order by id) from public.audit_log
  where action = 'set_calendar_weekdays' and entity_id = 'b0000000-0000-0000-0000-000000000003'$q$);
select pg_temp.rec('audit.ctx', $q$select coalesce(string_agg(k, ',' order by k), 'none') from r where k like '%#ctx' and v <> '|'$q$);

-- =====================================================================
select plan(79);

-- القراءة
select is((select v from r where k = 'read.sa'),  (select v from r where k = 'read.expected') || '|1|10', 'school_admin reads all of its school''s calendar and only it');
select is((select v from r where k = 'read.sec'), (select v from r where k = 'read.expected') || '|1|10', 'secretary: academic_year.read is enough to read (B15)');
select is((select v from r where k = 'read.bus'), '0|0', 'bus_supervisor: no academic_year.read → nothing');
select is((select v from r where k = 'read.sb'),  '5b000000-0000-0000-0000-000000000002', 'a sibling school''s admin sees only its own exceptions (§1.1 rule 5)');
select is((select v from r where k = 'read.x'),   '5c000000-0000-0000-0000-000000000003', 'another tenant sees only its own (I1)');
select ok((select v from r where k = 'read.expected')::int > 0, 'the fixture holds exceptions to read');

-- الكتابة
select ok((select v from r where k = 'w.sec_insert') like 'ERR 42501%row-level security%calendar_exceptions%', 'academic_year.read does not grant writing (insert)');
select is((select v from r where k = 'w.sec_update'), '0', 'academic_year.read does not grant writing (update)');
select ok((select v from r where k = 'w.sb_insert') like 'ERR 42501%row-level security%calendar_exceptions%', 'a sibling school''s admin cannot add to SA''s calendar');
select ok((select v from r where k = 'w.weekday_direct') like 'ERR 42501%permission denied%calendar_weekdays%', 'weekdays have no client write path — the function only');
select ok((select v from r where k = 'blind.sb') = 'done' and (select v from r where k = 'blind.after') = (select v from r where k = 'blind.before'),
          'a blind UPDATE (no WHERE, no RETURNING) by a sibling school''s admin touches nothing in SA — the UPDATE policy carries the scope');

-- planned
select is((select v from r where k = 'p.ins'), 'ok', 'planned: free — add without a reason');
select ok((select v from r where k = 'p.overlap') like 'ERR 23P01%calendar_exceptions_no_overlap%', 'two active holidays cannot overlap (EXCLUDE)');
select is((select v from r where k = 'p.cancel'), 'cancelled', 'planned: cancel without a reason');
select is((select v from r where k = 'p.overlap_after_cancel'), 'ok', 'a cancelled holiday no longer blocks an overlapping one');
select ok((select v from r where k = 'p.final') like 'ERR 23514%cancelled calendar exception is final%', 'cancelling is final (planned too)');
select ok((select v from r where k = 'p.outside') like 'ERR 23514%calendar_exceptions_within_year_chk%', 'an exception stays inside its year');

-- planned (تتمة) + الترحيل
select ok((select v from r where k = 'p.sd_range') like 'ERR 23514%calendar_exceptions_study_day_chk%', 'C5: an exceptional study day is a single day');
select is((select v from r where k = 'p.sd_one'), 'ok', 'a single study day on a non-school day is accepted');
select ok((select v from r where k = 'p.sd_dup') like 'ERR 23505%calendar_exceptions_study_day_uq%', 'one active study day per date');
select is((select v from r where k = 'p.move'), 'ok', 'planned: dates move freely');
select is((select v from r where k = 'casc.ok') || '|' || (select v from r where k = 'casc.rows'),
          'ok|Q1:' || pg_temp.d(800) || ',Q2:' || pg_temp.d(800), 'year bounds cascade into the exceptions (the cancelled one too) — a planned year''s dates still move');
select ok((select v from r where k = 'casc.out') like 'ERR 23514%calendar_exceptions_within_year_chk%', '… but not past an exception inside it');

-- active: السبب، اليوم، المستقبل
select ok((select v from r where k = 'a.noreason') like 'ERR 22023%reason required%', 'C3: an active year''s calendar needs a reason — the database enforces it');
select ok((select v from r where k = 'a.yesterday') like 'ERR 23514%start today or later only%', 'C1: yesterday is the past');
select is((select v from r where k = 'a.today'), 'ok', 'C1: today itself is editable (same-day closure / makeup) with a reason');
select is((select v from r where k = 'a.future'), 'ok', 'a future exception with a reason');
select is((select v from r where k = 'f.move_ok'), 'ok', 'a future exception can move within the future');
select ok((select v from r where k = 'f.move_past') like 'ERR 23514%start today or later only%', '… not into the past');
select ok((select v from r where k = 'f.noreason') like 'ERR 22023%reason required%', 'every active-year edit needs a reason');
select is((select v from r where k = 'f.cancel'), 'ok', 'a future exception can be cancelled with a reason');
select ok((select v from r where k = 'f.final') like 'ERR 23514%final%', '… and the cancellation is final');
select is((select v from r where k = 'r.extend'), 'ok', 'C4: a running holiday can be extended');
select is((select v from r where k = 'r.shorten'), 'ok', 'C4: … or shortened to end today');
select ok((select v from r where k = 'r.past_end') like 'ERR 23514%can change only its future end date%', 'C4: … never to end in the past');
select ok((select v from r where k = 'r.rename') like 'ERR 23514%can change only its future end date%', 'C4: its name is fixed');
select ok((select v from r where k = 'r.move_start') like 'ERR 23514%can change only its future end date%', 'C4: its start is fixed');
select ok((select v from r where k = 'r.cancel') like 'ERR 23514%can change only its future end date%', 'C4: it cannot be cancelled (that would rewrite the past)');
select is((select v from r where k = 'r.state'), '-3|0|R|active', 'the running holiday: start untouched, end today, still active');

-- active (تتمة): الماضي، كل مسار، الهوية
select ok((select v from r where k = 'past.extend') like 'ERR 23514%can change only its future end date%', 'an exception wholly in the past cannot change');
select ok((select v from r where k = 'su.past') like 'ERR 23514%start today or later only%', 'every path: the privileged role cannot add to the past either');
select ok((select v from r where k = 'su.noreason') like 'ERR 22023%reason required%', 'every path: nor write an active year without a reason');
select ok((select v from r where k = 'su.kind') like 'ERR 23514%cannot change its school, year or kind%', 'the kind is fixed (guard)');

-- عمود النوع خارج المنح، و C5
select ok((select v from r where k = 'col.kind') like 'ERR 42501%permission denied%calendar_exceptions%', '… and outside the column grant');
select ok((select v from r where k = 'c5.sunday') like 'ERR 23514%not already a school day%', 'C5: no exceptional study day on a regular school day');

-- C5 (تتمة)، closed
select is((select v from r where k = 'c5.friday'), 'ok', 'C5: an exceptional study day on a rest day');
select ok((select v from r where k = 'cl.insert') like 'ERR 23514%academic year is closed%', 'closed: no new exception');

-- أيام الدوام
select ok((select v from r where k = 'cl.update') like 'ERR 23514%academic year is closed%', 'closed: no change');
select ok((select v from r where k = 'w.sec') like 'ERR 42501%forbidden%', 'weekdays: academic_year.update required');
select ok((select v from r where k = 'w.sb_sa') like 'ERR P0002%not found%', 'weekdays: another school''s year is not found');
select ok((select v from r where k = 'w.noreason') like 'ERR 22023%reason required%', 'weekdays: a reason is required');
select ok((select v from r where k = 'w.empty') like 'ERR 22023%non-empty set of 0..6%', 'weekdays: an empty week is refused');
select ok((select v from r where k = 'w.range') like 'ERR 22023%non-empty set of 0..6%', 'weekdays: only 0..6');
select is((select v from r where k = 'w.p1'), '5', 'planned: the week is set');
select is((select v from r where k = 'w.p2'), '2', 'planned: the week changes (one off, one on; duplicates collapse)');
select is((select v from r where k = 'w.p_state'), '0:active,1:active,2:active,3:active,4:inactive,6:active', '… no row deleted: a removed day is inactive');
select ok((select v from r where k = 'w.active_fixed') like 'ERR 22023%fixed once defined%', 'active: a defined week is fixed (B8)');
select is((select v from r where k = 'w.c2_first'), '5', 'C2: an active year with no week defines it once');
select ok((select v from r where k = 'w.c2_again') like 'ERR 22023%fixed once defined%', 'C2: … and then it is fixed');
select ok((select v from r where k = 'w.closed') like 'ERR 22023%closed%', 'closed: the week cannot change');
select ok((select v from r where k = 'w.guard_closed') like 'ERR 23514%academic year is closed%', 'every path: the guard keeps a closed year''s week frozen');

select ok((select v from r where k = 'w.guard_identity') like 'ERR 23514%cannot change its school, year or weekday%', 'every path: a weekday row keeps its identity');

-- is_school_day
select is((select v from r where k = 'isd'),
  'a_none=false,b_weekday=true,c_rest=false,d_holiday=false,e_study_in_holiday=true,f_cancelled=true,g_study_rest=true,h_closed=true,i_today=true,j_other_school=false,k_inactive_day=false',
  'is_school_day: no year · school weekday · rest day · holiday · study day in a holiday · cancelled holiday · study day on a rest day · closed year · today (study day in a running holiday) · per school · a weekday turned inactive');
select ok(not has_function_privilege('authenticated', 'app.is_school_day(uuid,date)', 'EXECUTE') and not has_function_privilege('anon', 'app.is_school_day(uuid,date)', 'EXECUTE'),
          'is_school_day: internal — no EXECUTE for API roles');
select ok(not has_function_privilege('authenticated', 'app.school_today(uuid)', 'EXECUTE') and not has_function_privilege('anon', 'app.school_today(uuid)', 'EXECUTE'),
          'school_today: internal — no EXECUTE for API roles');
select is((select v from r where k = 'tz.cairo'), 'true', 'C1: today for a Cairo school is the Cairo date');
select ok((select v from r where k = 'tz.diff') in ('1', '2'), 'C1: today follows the school''s timezone (UTC+14 vs UTC−11 are never the same date)');
select ok((select v from r where k = 'tz.k_yesterday') like 'ERR 23514%start today or later only%', 'C1: the UTC+14 school''s yesterday is past for it');

select is((select v from r where k = 'tz.k_today'), 'ok', 'C1: … and its own today is open');
select is((select v from r where k = 'tz.p_today'), 'ok', 'C1: the UTC−11 school''s today is open even when it is yesterday elsewhere');
select ok((select v from r where k = 'tz.p_yesterday') like 'ERR 23514%start today or later only%', 'C1: … and its yesterday is past');
select is((select pg_get_function_identity_arguments('app.set_calendar_weekdays(uuid,smallint[],text)'::regprocedure)),
          'p_year_id uuid, p_weekdays smallint[], p_reason text', 'set_calendar_weekdays: year, days, reason — no client school_id');
select ok(has_function_privilege('authenticated', 'app.set_calendar_weekdays(uuid,smallint[],text)', 'EXECUTE')
      and not has_function_privilege('anon', 'app.set_calendar_weekdays(uuid,smallint[],text)', 'EXECUTE'), 'set_calendar_weekdays: EXECUTE for authenticated only');

-- التدقيق والبنية
select is((select v from r where k = 'audit.exc'),      'insert|r-future|tenant_user', 'T7: an exception insert carries the reason from the request (C3)');
select is((select v from r where k = 'audit.extend'),   'update|extended|' || pg_temp.d(3) || '>' || pg_temp.d(10), 'T7: the extension is audited with old/new end and the reason');
select is((select v from r where k = 'audit.weekdays'), 'set_calendar_weekdays:change week,insert:change week', 'T7: each weekday change (day 4 off, day 6 on), with the operation and the reason');
select is((select v from r where k = 'audit.domain'),   'set week:[0, 1, 2, 3, 4]:5,change week:[0, 1, 2, 3, 6]:2', 'one domain audit row per weekday operation: reason, the week, rows changed');
select is((select v from r where k = 'audit.ctx'),      'none', 'the audit context is empty after every call');
select ok(not has_table_privilege('authenticated', 'public.calendar_exceptions', 'DELETE') and not has_table_privilege('authenticated', 'public.calendar_weekdays', 'DELETE'),
          'no DELETE: an exception is cancelled, a weekday turned inactive');

select * from finish();
rollback;
