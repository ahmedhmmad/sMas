-- M42 — copy_calendar_weekdays (Phase 2B / 2B-2، B13): عقد M37/M40 على أيام الدوام. المفتاح (السنة الهدف، اليوم):
-- الموجود active «منسوخ سابقاً» لا يُمس، الموجود inactive يُفشل الكل؛ ذري؛ الاستثناءات المؤرخة لا تُنسخ.
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
  ('5c000000-0000-0000-0000-000000000003', '20000000-0000-0000-0000-000000000002', null,                                   'SX', 'SX', 'sx');
-- SA: yC (تُغلق)، yS المصدر (نشطة)، أهداف planned: yT، yT2، yT3 (متعارض)، yT4 (مطابق + إضافي)، yT5 (الذرية)؛ SB: yB؛ SX: yX
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
-- المصدر yS: الأحد–الخميس نشطة، الجمعة inactive؛ yC: السبت–الأربعاء؛ yT3: الأحد inactive (متعارض)؛ yT4: الأحد active (مطابق) + السبت (إضافي)
insert into public.calendar_weekdays (school_id, academic_year_id, weekday, status)
select '5a000000-0000-0000-0000-000000000001'::uuid, 'a5000000-0000-0000-0000-000000000002'::uuid, d, case when d = 5 then 'inactive' else 'active' end from generate_series(0, 5) d
union all select '5a000000-0000-0000-0000-000000000001', 'c0000000-0000-0000-0000-000000000001', d, 'active' from unnest(array[6, 0, 1, 2, 3]) d
union all select '5a000000-0000-0000-0000-000000000001', 'a9000000-0000-0000-0000-000000000005', 0, 'inactive'
union all select '5a000000-0000-0000-0000-000000000001', 'aa000000-0000-0000-0000-000000000006', d, 'active' from unnest(array[0, 6]) d;
-- استثناء مؤرخ في المصدر — لا يُنسخ (B13)
insert into public.calendar_exceptions (school_id, academic_year_id, year_start_date, year_end_date, kind, name, start_date, end_date)
values ('5a000000-0000-0000-0000-000000000001', 'a5000000-0000-0000-0000-000000000002', '2026-09-01', '2027-06-30', 'holiday', 'H', '2027-03-01', '2027-03-02');
update public.academic_years set status = 'active' where id = 'c0000000-0000-0000-0000-000000000001';
update public.academic_years set status = 'closed' where id = 'c0000000-0000-0000-0000-000000000001';
update public.academic_years set status = 'active' where id = 'a5000000-0000-0000-0000-000000000002';

create function pg_temp.member(p_label text, p_role text, p_tenant uuid, p_scope text, p_target uuid) returns void
language plpgsql as $$
declare v_a uuid := gen_random_uuid(); v_p uuid; v_m uuid;
begin
  insert into auth.users (id, email) values (v_a, p_label || '@m42.invalid');
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

create function pg_temp.days(p_year uuid) returns text language sql as $$
  select coalesce(string_agg(weekday || ':' || status, ',' order by weekday), '') from public.calendar_weekdays where academic_year_id = p_year
$$;
create function pg_temp.snap(p_year uuid) returns text language sql as $$
  select md5(coalesce(string_agg(to_jsonb(w)::text, ';' order by w.id), '')) from public.calendar_weekdays w where w.academic_year_id = p_year
$$;
create function pg_temp.copy(p_src text, p_tgt text, p_reason text default 'r') returns text language sql as $$
  select format($f$select app.copy_calendar_weekdays(%L, %L, %L)::text$f$, p_src, p_tgt, p_reason)
$$;

-- ============ الرفض ============
select pg_temp.run('f.sec',        'sec', pg_temp.copy('a5000000-0000-0000-0000-000000000002', 'a7000000-0000-0000-0000-000000000003'));
select pg_temp.run('f.sibling',    'sb',  pg_temp.copy('a5000000-0000-0000-0000-000000000002', 'a7000000-0000-0000-0000-000000000003'));
select pg_temp.run('f.to_sibling', 'sa',  pg_temp.copy('a5000000-0000-0000-0000-000000000002', 'bb000000-0000-0000-0000-000000000008'));
select pg_temp.run('f.cross_ta',   'ta',  pg_temp.copy('a5000000-0000-0000-0000-000000000002', 'bb000000-0000-0000-0000-000000000008'));
select pg_temp.run('f.tenant',     'x',   pg_temp.copy('a5000000-0000-0000-0000-000000000002', 'cc000000-0000-0000-0000-000000000009'));
select pg_temp.run('f.noreason',   'sa',  pg_temp.copy('a5000000-0000-0000-0000-000000000002', 'a7000000-0000-0000-0000-000000000003', ''));
select pg_temp.run('f.same',       'sa',  pg_temp.copy('a7000000-0000-0000-0000-000000000003', 'a7000000-0000-0000-0000-000000000003'));
select pg_temp.run('f.to_active',  'sa',  pg_temp.copy('a7000000-0000-0000-0000-000000000003', 'a5000000-0000-0000-0000-000000000002'));
select pg_temp.run('f.to_closed',  'sa',  pg_temp.copy('a5000000-0000-0000-0000-000000000002', 'c0000000-0000-0000-0000-000000000001'));
select pg_temp.rec('f.untouched',  $q$select pg_temp.days('a7000000-0000-0000-0000-000000000003') || '|' || pg_temp.days('bb000000-0000-0000-0000-000000000008')$q$);

select pg_temp.rec('conflict.before', $q$select pg_temp.snap('a9000000-0000-0000-0000-000000000005')$q$);
select pg_temp.run('conflict', 'sa', pg_temp.copy('a5000000-0000-0000-0000-000000000002', 'a9000000-0000-0000-0000-000000000005'));
select pg_temp.rec('conflict.after', $q$select pg_temp.snap('a9000000-0000-0000-0000-000000000005')$q$);

create function public.zz_fail_wd() returns trigger language plpgsql as $$
begin
  if new.academic_year_id = 'ab000000-0000-0000-0000-000000000007' and new.weekday = 3 then raise exception 'injected failure'; end if;
  return new;
end $$;
create trigger zz_fail after insert on public.calendar_weekdays for each row execute function public.zz_fail_wd();
select pg_temp.run('atomic', 'sa', pg_temp.copy('a5000000-0000-0000-0000-000000000002', 'ab000000-0000-0000-0000-000000000007'));
drop trigger zz_fail on public.calendar_weekdays;
drop function public.zz_fail_wd();
select pg_temp.rec('atomic.after', $q$select (select count(*) from public.calendar_weekdays where academic_year_id = 'ab000000-0000-0000-0000-000000000007') || '|' ||
  (select count(*) from public.audit_log where action = 'copy_calendar_weekdays' and entity_id = 'ab000000-0000-0000-0000-000000000007')$q$);

-- ============ النجاح ============
select pg_temp.run('ok.first',  'sa', pg_temp.copy('a5000000-0000-0000-0000-000000000002', 'a7000000-0000-0000-0000-000000000003', 'new year'));
select pg_temp.rec('ok.days',   $q$select pg_temp.days('a7000000-0000-0000-0000-000000000003')$q$);
select pg_temp.rec('ok.source', $q$select pg_temp.days('a5000000-0000-0000-0000-000000000002')$q$);
select pg_temp.rec('ok.exc',    $q$select count(*)::text from public.calendar_exceptions where academic_year_id = 'a7000000-0000-0000-0000-000000000003'$q$);
select pg_temp.rec('ok.snap1',  $q$select pg_temp.snap('a7000000-0000-0000-0000-000000000003')$q$);
select pg_temp.run('ok.second', 'sa', pg_temp.copy('a5000000-0000-0000-0000-000000000002', 'a7000000-0000-0000-0000-000000000003', 'again'));
select pg_temp.rec('ok.snap2',  $q$select pg_temp.snap('a7000000-0000-0000-0000-000000000003')$q$);
select pg_temp.rec('pre.before', $q$select pg_temp.snap('aa000000-0000-0000-0000-000000000006')$q$);
select pg_temp.run('pre.copy',  'ta', pg_temp.copy('a5000000-0000-0000-0000-000000000002', 'aa000000-0000-0000-0000-000000000006', 'top up'));
select pg_temp.rec('pre.days',  $q$select pg_temp.days('aa000000-0000-0000-0000-000000000006')$q$);
select pg_temp.rec('pre.kept',  $q$select (md5(coalesce(string_agg(to_jsonb(w)::text, ';' order by w.id), '')) = (select v from r where k = 'pre.before'))::text
  from public.calendar_weekdays w where w.academic_year_id = 'aa000000-0000-0000-0000-000000000006' and w.weekday in (0, 6)$q$);
select pg_temp.run('closed_src', 'sa', pg_temp.copy('c0000000-0000-0000-0000-000000000001', 'a8000000-0000-0000-0000-000000000004', 'from history'));
select pg_temp.rec('closed_src.days', $q$select pg_temp.days('a8000000-0000-0000-0000-000000000004')$q$);

-- ============ التدقيق ============
select pg_temp.rec('audit.domain', $q$select actor_type || '|' || reason || '|' || (school_id = '5a000000-0000-0000-0000-000000000001')::text || '|' ||
    (new_values ->> 'source_year_id') || '>' || (new_values ->> 'target_year_id') || '|' || (new_values ->> 'created') || '/' || (new_values ->> 'already_copied')
  from public.audit_log where action = 'copy_calendar_weekdays' and entity_id = 'a7000000-0000-0000-0000-000000000003' and reason = 'new year'$q$);
select pg_temp.rec('audit.second', $q$select (new_values ->> 'created') || '/' || (new_values ->> 'already_copied') from public.audit_log
  where action = 'copy_calendar_weekdays' and entity_id = 'a7000000-0000-0000-0000-000000000003' and reason = 'again'$q$);
select pg_temp.rec('audit.rows', $q$select count(*) || ':' || string_agg(distinct action || '/' || reason, ',') from public.audit_log
  where entity_type = 'calendar_weekdays' and new_values ->> 'academic_year_id' = 'a7000000-0000-0000-0000-000000000003'$q$);
select pg_temp.rec('audit.refused', $q$select count(*)::text from public.audit_log where action = 'copy_calendar_weekdays'
  and entity_id in ('a9000000-0000-0000-0000-000000000005', 'bb000000-0000-0000-0000-000000000008', 'cc000000-0000-0000-0000-000000000009', 'c0000000-0000-0000-0000-000000000001')$q$);
select pg_temp.rec('audit.ctx', $q$select coalesce(string_agg(k, ',' order by k), 'none') from r where k like '%#ctx' and v <> '|'$q$);

-- =====================================================================
select plan(10 + 4 + 10 + 2 + 5);

select ok((select v from r where k = 'f.sec')        like 'ERR 42501%forbidden%', 'academic_year.read without academic_year.update → forbidden');
select ok((select v from r where k = 'f.sibling')    like 'ERR P0002%not found%', 'a sibling school''s admin cannot copy SA''s years');
select ok((select v from r where k = 'f.to_sibling') like 'ERR P0002%not found%', 'SA''s admin cannot target another school''s year');
select ok((select v from r where k = 'f.cross_ta')   like 'ERR 22023%different schools%', 'no copy across schools, even with scope on both');
select ok((select v from r where k = 'f.tenant')     like 'ERR P0002%not found%', 'another tenant cannot copy T1''s years');
select ok((select v from r where k = 'f.noreason')   like 'ERR 22023%reason required%', 'a reason is required');
select ok((select v from r where k = 'f.same')       like 'ERR 22023%same academic year%', 'source and target must differ');
select ok((select v from r where k = 'f.to_active')  like 'ERR 22023%must be planned (is active)%', 'no copy into an active year');
select ok((select v from r where k = 'f.to_closed')  like 'ERR 22023%must be planned (is closed)%', 'no copy into a closed year');
select is((select v from r where k = 'f.untouched'), '|', 'refused calls created nothing');

select ok((select v from r where k = 'conflict') like 'ERR 23514%differ from the source: 0%', 'a target weekday turned inactive is a conflict that fails the whole copy, naming the day');
select is((select v from r where k = 'conflict.after'), (select v from r where k = 'conflict.before'), '… and nothing in the target changed (the missing days were not created either)');
select ok((select v from r where k = 'atomic') like 'ERR P0001%injected failure%', 'atomicity: the injected failure surfaces');
select is((select v from r where k = 'atomic.after'), '0|0', 'atomicity: no weekday and no domain audit row survive');

select is((select v from r where k = 'ok.first'),  '5', 'first run: the five active days (the inactive source day is not copied)');
select is((select v from r where k = 'ok.days'),   '0:active,1:active,2:active,3:active,4:active', 'copied: Sunday–Thursday, active');
select is((select v from r where k = 'ok.source'), '0:active,1:active,2:active,3:active,4:active,5:inactive', 'the source year is untouched');
select is((select v from r where k = 'ok.exc'),    '0', 'dated exceptions are not copied (B13)');
select is((select v from r where k = 'ok.second'), '0', 'second run: 0 new days');
select is((select v from r where k = 'ok.snap2'),  (select v from r where k = 'ok.snap1'), '… the existing copies are byte-identical (no update, no stamp)');
select is((select v from r where k = 'pre.copy'),  '4', 'a target with one matching and one extra day: only the missing days are created');
select is((select v from r where k = 'pre.days'),  '0:active,1:active,2:active,3:active,4:active,6:active', '… the extra day stays');
select is((select v from r where k = 'pre.kept'),  'true', '… and the matching and extra days are byte-identical');
select is((select v from r where k = 'closed_src') || '|' || (select v from r where k = 'closed_src.days'),
          '5|0:active,1:active,2:active,3:active,6:active', 'from a closed year: its week is copied as it was');

select is((select pg_get_function_identity_arguments('app.copy_calendar_weekdays(uuid,uuid,text)'::regprocedure)),
          'p_source_year_id uuid, p_target_year_id uuid, p_reason text', 'year ids and a reason only — no client school_id');
select ok(has_function_privilege('authenticated', 'app.copy_calendar_weekdays(uuid,uuid,text)', 'EXECUTE')
      and not has_function_privilege('anon', 'app.copy_calendar_weekdays(uuid,uuid,text)', 'EXECUTE'), 'EXECUTE for authenticated only');

select is((select v from r where k = 'audit.domain'), 'tenant_user|new year|true|a5000000-0000-0000-0000-000000000002>a7000000-0000-0000-0000-000000000003|5/0',
          'one domain audit row: actor, reason, school, source > target, created/already copied');
select is((select v from r where k = 'audit.second'), '0/5', 'the second run is audited as 0 created / 5 already copied');
select is((select v from r where k = 'audit.rows'),   '5:insert/new year', 'each created day is audited (T7) with the operation''s reason');
select is((select v from r where k = 'audit.refused'), '0', 'refused copies leave no domain audit row');
select is((select v from r where k = 'audit.ctx'),    'none', 'the audit context is empty after every call');

select * from finish();
rollback;
