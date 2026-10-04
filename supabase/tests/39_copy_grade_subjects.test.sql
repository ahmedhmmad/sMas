-- M40 — copy_grade_subjects (Phase 2B / 2B-1، B13): عقد M37 على ربط المواد بالصفوف. المفتاح الطبيعي
-- (السنة الهدف، الصف، المادة): المطابق «منسوخ سابقاً» لا يُمس، المتعارض يُفشل الكل؛ ذري؛ لا تعديل للموجود.
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
insert into public.stages (id, school_id, name, sequence_no) values ('51000000-0000-0000-0000-000000000001', '5a000000-0000-0000-0000-000000000001', 'P', 1);
insert into public.grade_levels (id, school_id, stage_id, name, sequence_no) values
  ('61000000-0000-0000-0000-000000000001', '5a000000-0000-0000-0000-000000000001', '51000000-0000-0000-0000-000000000001', 'G1', 1),
  ('61000000-0000-0000-0000-000000000002', '5a000000-0000-0000-0000-000000000001', '51000000-0000-0000-0000-000000000001', 'G2', 2),
  ('61000000-0000-0000-0000-000000000004', '5a000000-0000-0000-0000-000000000001', '51000000-0000-0000-0000-000000000001', 'GH', 4);
insert into public.subjects (id, school_id, subject_code, name) values
  ('5e000000-0000-0000-0000-000000000001', '5a000000-0000-0000-0000-000000000001', 'AR',  'Arabic'),
  ('5e000000-0000-0000-0000-000000000002', '5a000000-0000-0000-0000-000000000001', 'MA',  'Math'),
  ('5e000000-0000-0000-0000-000000000003', '5a000000-0000-0000-0000-000000000001', 'OLD', 'Old');
-- المصدر yS: G1/AR (5، في المجموع)، G1/MA (4، خارج المجموع)، G2/AR (معطّل)؛ yC: G1/AR (3)، GH/AR، G2/OLD
insert into public.grade_subjects (school_id, academic_year_id, grade_level_id, subject_id, weekly_periods, counts_toward_total, status) values
  ('5a000000-0000-0000-0000-000000000001', 'a5000000-0000-0000-0000-000000000002', '61000000-0000-0000-0000-000000000001', '5e000000-0000-0000-0000-000000000001', 5, true,  'active'),
  ('5a000000-0000-0000-0000-000000000001', 'a5000000-0000-0000-0000-000000000002', '61000000-0000-0000-0000-000000000001', '5e000000-0000-0000-0000-000000000002', 4, false, 'active'),
  ('5a000000-0000-0000-0000-000000000001', 'a5000000-0000-0000-0000-000000000002', '61000000-0000-0000-0000-000000000002', '5e000000-0000-0000-0000-000000000001', 6, true,  'inactive'),
  ('5a000000-0000-0000-0000-000000000001', 'c0000000-0000-0000-0000-000000000001', '61000000-0000-0000-0000-000000000001', '5e000000-0000-0000-0000-000000000001', 3, true,  'active'),
  ('5a000000-0000-0000-0000-000000000001', 'c0000000-0000-0000-0000-000000000001', '61000000-0000-0000-0000-000000000004', '5e000000-0000-0000-0000-000000000001', 2, true,  'active'),
  ('5a000000-0000-0000-0000-000000000001', 'c0000000-0000-0000-0000-000000000001', '61000000-0000-0000-0000-000000000002', '5e000000-0000-0000-0000-000000000003', 1, true,  'active'),
  -- yT3: G1/AR موجود بحصص مختلفة (متعارض)؛ yT4: G1/AR مطابق + G2/MA إضافي
  ('5a000000-0000-0000-0000-000000000001', 'a9000000-0000-0000-0000-000000000005', '61000000-0000-0000-0000-000000000001', '5e000000-0000-0000-0000-000000000001', 3, true,  'active'),
  ('5a000000-0000-0000-0000-000000000001', 'aa000000-0000-0000-0000-000000000006', '61000000-0000-0000-0000-000000000001', '5e000000-0000-0000-0000-000000000001', 5, true,  'active'),
  ('5a000000-0000-0000-0000-000000000001', 'aa000000-0000-0000-0000-000000000006', '61000000-0000-0000-0000-000000000002', '5e000000-0000-0000-0000-000000000002', 7, true,  'active');
update public.academic_years set status = 'active' where id = 'c0000000-0000-0000-0000-000000000001';
update public.academic_years set status = 'closed' where id = 'c0000000-0000-0000-0000-000000000001';
update public.academic_years set status = 'active' where id = 'a5000000-0000-0000-0000-000000000002';
update public.grade_levels set status = 'inactive' where id = '61000000-0000-0000-0000-000000000004';   -- روابطه في yC المغلقة فقط
update public.subjects     set status = 'inactive' where id = '5e000000-0000-0000-0000-000000000003';   -- OLD: ربطها في yC المغلقة فقط

create function pg_temp.member(p_label text, p_role text, p_tenant uuid, p_scope text, p_target uuid) returns void
language plpgsql as $$
declare v_a uuid := gen_random_uuid(); v_p uuid; v_m uuid;
begin
  insert into auth.users (id, email) values (v_a, p_label || '@m40.invalid');
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
select pg_temp.member('sec', 'secretary',    '10000000-0000-0000-0000-000000000001', 'school', '5a000000-0000-0000-0000-000000000001');   -- subject.read بلا subject.manage
select pg_temp.member('ta',  'tenant_admin', '10000000-0000-0000-0000-000000000001', 'tenant', null);
select pg_temp.member('x',   'school_admin', '20000000-0000-0000-0000-000000000002', 'school', '5c000000-0000-0000-0000-000000000003');

create function pg_temp.links(p_year uuid) returns text language sql as $$
  select coalesce(string_agg(g.name || '/' || s.subject_code || ':' || gs.weekly_periods || ':' || gs.counts_toward_total || ':' || gs.status, ',' order by g.name, s.subject_code), '')
    from public.grade_subjects gs join public.grade_levels g on g.id = gs.grade_level_id join public.subjects s on s.id = gs.subject_id
   where gs.academic_year_id = p_year
$$;
create function pg_temp.snap(p_year uuid) returns text language sql as $$
  select md5(coalesce(string_agg(to_jsonb(gs)::text, ';' order by gs.id), '')) from public.grade_subjects gs where gs.academic_year_id = p_year
$$;
create function pg_temp.copy(p_src text, p_tgt text, p_reason text default 'r') returns text language sql as $$
  select format($f$select app.copy_grade_subjects(%L, %L, %L)::text$f$, p_src, p_tgt, p_reason)
$$;

-- ============ الرفض ============
select pg_temp.run('f.sec',        'sec', pg_temp.copy('a5000000-0000-0000-0000-000000000002', 'a7000000-0000-0000-0000-000000000003'));
select pg_temp.run('f.sibling',    'sb',  pg_temp.copy('a5000000-0000-0000-0000-000000000002', 'a7000000-0000-0000-0000-000000000003'));
select pg_temp.run('f.to_sibling', 'sa',  pg_temp.copy('a5000000-0000-0000-0000-000000000002', 'bb000000-0000-0000-0000-000000000008'));
select pg_temp.run('f.cross_ta',   'ta',  pg_temp.copy('a5000000-0000-0000-0000-000000000002', 'bb000000-0000-0000-0000-000000000008'));
select pg_temp.run('f.tenant',     'x',   pg_temp.copy('a5000000-0000-0000-0000-000000000002', 'cc000000-0000-0000-0000-000000000009'));
select pg_temp.run('f.to_tenant',  'ta',  pg_temp.copy('a5000000-0000-0000-0000-000000000002', 'cc000000-0000-0000-0000-000000000009'));
select pg_temp.run('f.noreason',   'sa',  pg_temp.copy('a5000000-0000-0000-0000-000000000002', 'a7000000-0000-0000-0000-000000000003', ''));
select pg_temp.run('f.same',       'sa',  pg_temp.copy('a7000000-0000-0000-0000-000000000003', 'a7000000-0000-0000-0000-000000000003'));
select pg_temp.run('f.to_active',  'sa',  pg_temp.copy('a7000000-0000-0000-0000-000000000003', 'a5000000-0000-0000-0000-000000000002'));
select pg_temp.run('f.to_closed',  'sa',  pg_temp.copy('a5000000-0000-0000-0000-000000000002', 'c0000000-0000-0000-0000-000000000001'));
select pg_temp.rec('f.untouched',  $q$select pg_temp.links('a7000000-0000-0000-0000-000000000003') || '|' || pg_temp.links('bb000000-0000-0000-0000-000000000008')$q$);

-- المتعارض: الكل يُرفض والهدف لا يتغير
select pg_temp.rec('conflict.before', $q$select pg_temp.snap('a9000000-0000-0000-0000-000000000005')$q$);
select pg_temp.run('conflict', 'sa', pg_temp.copy('a5000000-0000-0000-0000-000000000002', 'a9000000-0000-0000-0000-000000000005'));
select pg_temp.rec('conflict.after', $q$select pg_temp.snap('a9000000-0000-0000-0000-000000000005')$q$);
update public.grade_subjects set weekly_periods = 5, counts_toward_total = false where academic_year_id = 'a9000000-0000-0000-0000-000000000005';
select pg_temp.run('conflict.total', 'sa', pg_temp.copy('a5000000-0000-0000-0000-000000000002', 'a9000000-0000-0000-0000-000000000005'));
update public.grade_subjects set counts_toward_total = true, status = 'inactive' where academic_year_id = 'a9000000-0000-0000-0000-000000000005';
select pg_temp.run('conflict.inactive', 'sa', pg_temp.copy('a5000000-0000-0000-0000-000000000002', 'a9000000-0000-0000-0000-000000000005'));

-- الذرية: فشل مُحقن على ربط MA لا يترك ربط AR ولا صف تدقيق
create function public.zz_fail_ma() returns trigger language plpgsql as $$
begin
  if new.academic_year_id = 'ab000000-0000-0000-0000-000000000007' and new.subject_id = '5e000000-0000-0000-0000-000000000002' then
    raise exception 'injected failure';
  end if;
  return new;
end $$;
create trigger zz_fail after insert on public.grade_subjects for each row execute function public.zz_fail_ma();
select pg_temp.run('atomic', 'sa', pg_temp.copy('a5000000-0000-0000-0000-000000000002', 'ab000000-0000-0000-0000-000000000007'));
drop trigger zz_fail on public.grade_subjects;
drop function public.zz_fail_ma();
select pg_temp.rec('atomic.after', $q$select (select count(*) from public.grade_subjects where academic_year_id = 'ab000000-0000-0000-0000-000000000007') || '|' ||
  (select count(*) from public.audit_log where action = 'copy_grade_subjects' and entity_id = 'ab000000-0000-0000-0000-000000000007')$q$);

-- ============ النجاح ============
select pg_temp.run('ok.first',  'sa', pg_temp.copy('a5000000-0000-0000-0000-000000000002', 'a7000000-0000-0000-0000-000000000003', 'new year'));
select pg_temp.rec('ok.links',  $q$select pg_temp.links('a7000000-0000-0000-0000-000000000003')$q$);
select pg_temp.rec('ok.source', $q$select pg_temp.links('a5000000-0000-0000-0000-000000000002')$q$);
select pg_temp.rec('ok.snap1',  $q$select pg_temp.snap('a7000000-0000-0000-0000-000000000003')$q$);
select pg_temp.run('ok.second', 'sa', pg_temp.copy('a5000000-0000-0000-0000-000000000002', 'a7000000-0000-0000-0000-000000000003', 'again'));
select pg_temp.rec('ok.snap2',  $q$select pg_temp.snap('a7000000-0000-0000-0000-000000000003')$q$);
select pg_temp.rec('pre.before', $q$select string_agg(to_jsonb(gs)::text, ';' order by gs.id) from public.grade_subjects gs where gs.academic_year_id = 'aa000000-0000-0000-0000-000000000006'$q$);
select pg_temp.run('pre.copy',  'ta', pg_temp.copy('a5000000-0000-0000-0000-000000000002', 'aa000000-0000-0000-0000-000000000006', 'top up'));
select pg_temp.rec('pre.links', $q$select pg_temp.links('aa000000-0000-0000-0000-000000000006')$q$);
select pg_temp.rec('pre.kept',  $q$select (string_agg(to_jsonb(gs)::text, ';' order by gs.id) = (select v from r where k = 'pre.before'))::text from public.grade_subjects gs
  where gs.academic_year_id = 'aa000000-0000-0000-0000-000000000006'
    and not (gs.grade_level_id = '61000000-0000-0000-0000-000000000001' and gs.subject_id = '5e000000-0000-0000-0000-000000000002')$q$);
select pg_temp.run('closed_src', 'sa', pg_temp.copy('c0000000-0000-0000-0000-000000000001', 'a8000000-0000-0000-0000-000000000004', 'from history'));
select pg_temp.rec('closed_src.links', $q$select pg_temp.links('a8000000-0000-0000-0000-000000000004')$q$);

-- ============ التدقيق ============
select pg_temp.rec('audit.domain', $q$select actor_type || '|' || reason || '|' || (school_id = '5a000000-0000-0000-0000-000000000001')::text || '|' ||
    (new_values ->> 'source_year_id') || '>' || (new_values ->> 'target_year_id') || '|' || (new_values ->> 'created') || '/' || (new_values ->> 'already_copied') || '|' ||
    (actor_id = (select p.id from public.profiles p join actors a on a.auth = p.auth_user_id where a.label = 'sa'))::text
  from public.audit_log where action = 'copy_grade_subjects' and entity_id = 'a7000000-0000-0000-0000-000000000003' and reason = 'new year'$q$);
select pg_temp.rec('audit.second', $q$select (new_values ->> 'created') || '/' || (new_values ->> 'already_copied') from public.audit_log
  where action = 'copy_grade_subjects' and entity_id = 'a7000000-0000-0000-0000-000000000003' and reason = 'again'$q$);
select pg_temp.rec('audit.rows', $q$select string_agg(action || ':' || reason, ',' order by id) from public.audit_log
  where entity_type = 'grade_subjects' and new_values ->> 'academic_year_id' = 'a7000000-0000-0000-0000-000000000003'$q$);
select pg_temp.rec('audit.refused', $q$select count(*)::text from public.audit_log where action = 'copy_grade_subjects'
  and entity_id in ('a9000000-0000-0000-0000-000000000005', 'bb000000-0000-0000-0000-000000000008', 'cc000000-0000-0000-0000-000000000009', 'c0000000-0000-0000-0000-000000000001')$q$);
select pg_temp.rec('audit.ctx', $q$select coalesce(string_agg(k, ',' order by k), 'none') from r where k like '%#ctx' and v <> '|'$q$);

-- =====================================================================
select plan(11 + 6 + 10 + 2 + 5 + 2);

select ok((select v from r where k = 'f.sec')        like 'ERR 42501%forbidden%', 'subject.read without subject.manage → forbidden');
select ok((select v from r where k = 'f.sibling')    like 'ERR P0002%not found%', 'a sibling school''s admin cannot copy SA''s years');
select ok((select v from r where k = 'f.to_sibling') like 'ERR P0002%not found%', 'SA''s admin cannot target another school''s year');
select ok((select v from r where k = 'f.cross_ta')   like 'ERR 22023%different schools%', 'no copy across schools, even with scope on both');
select ok((select v from r where k = 'f.tenant')     like 'ERR P0002%not found%', 'another tenant cannot copy T1''s years');
select ok((select v from r where k = 'f.to_tenant')  like 'ERR P0002%not found%', 'no target in another tenant');
select ok((select v from r where k = 'f.noreason')   like 'ERR 22023%reason required%', 'a reason is required');
select ok((select v from r where k = 'f.same')       like 'ERR 22023%same academic year%', 'source and target must differ');
select ok((select v from r where k = 'f.to_active')  like 'ERR 22023%must be planned (is active)%', 'no copy into an active year');
select ok((select v from r where k = 'f.to_closed')  like 'ERR 22023%must be planned (is closed)%', 'no copy into a closed year');
select is((select v from r where k = 'f.untouched'), '|', 'refused calls created nothing');

select ok((select v from r where k = 'conflict') like 'ERR 23514%differ from the source: 61000000-0000-0000-0000-000000000001/5e000000-0000-0000-0000-000000000001%', 'a target link with the same key and different content fails the whole copy, naming the key');
select is((select v from r where k = 'conflict.after'), (select v from r where k = 'conflict.before'), '… and nothing in the target changed (the missing link was not created either)');
select ok((select v from r where k = 'conflict.total') like 'ERR 23514%differ from the source%', 'the same periods but a different total flag is a conflict');
select ok((select v from r where k = 'conflict.inactive') like 'ERR 23514%differ from the source%', 'a deactivated link with the same key is a conflict, not a silent skip');
select ok((select v from r where k = 'atomic') like 'ERR P0001%injected failure%', 'atomicity: the injected failure surfaces');
select is((select v from r where k = 'atomic.after'), '0|0', 'atomicity: no link and no domain audit row survive');

select is((select v from r where k = 'ok.first'),  '2', 'first run: two links created (the inactive source link is not copied)');
select is((select v from r where k = 'ok.links'),  'G1/AR:5:true:active,G1/MA:4:false:active', 'copied: grade level, subject, weekly periods, total flag; active');
select is((select v from r where k = 'ok.source'), 'G1/AR:5:true:active,G1/MA:4:false:active,G2/AR:6:true:inactive', 'the source year is untouched');
select is((select v from r where k = 'ok.second'), '0', 'second run: 0 new links');
select is((select v from r where k = 'ok.snap2'),  (select v from r where k = 'ok.snap1'), '… the existing copies are byte-identical (no update, no stamp)');
select is((select v from r where k = 'pre.copy'),  '1', 'a target with one matching and one extra link: only the missing link is created');
select is((select v from r where k = 'pre.links'), 'G1/AR:5:true:active,G1/MA:4:false:active,G2/MA:7:true:active', '… the extra link stays');
select is((select v from r where k = 'pre.kept'),  'true', '… and the matching and extra links are byte-identical (no update, no stamp)');
select is((select v from r where k = 'closed_src'), '1', 'from a closed year: only links of active grade levels and active subjects are copied');
select is((select v from r where k = 'closed_src.links'), 'G1/AR:3:true:active', '… no link of the deactivated grade level or subject is revived');

select is((select pg_get_function_identity_arguments('app.copy_grade_subjects(uuid,uuid,text)'::regprocedure)),
          'p_source_year_id uuid, p_target_year_id uuid, p_reason text', 'year ids and a reason only — no client school_id');
select ok(has_function_privilege('authenticated', 'app.copy_grade_subjects(uuid,uuid,text)', 'EXECUTE')
      and not has_function_privilege('anon', 'app.copy_grade_subjects(uuid,uuid,text)', 'EXECUTE'), 'EXECUTE for authenticated only');

select is((select v from r where k = 'audit.domain'), 'tenant_user|new year|true|a5000000-0000-0000-0000-000000000002>a7000000-0000-0000-0000-000000000003|2/0|true',
          'one domain audit row: actor, reason, school, source > target, created/already copied');
select is((select v from r where k = 'audit.second'), '0/2', 'the second run is audited as 0 created / 2 already copied');
select is((select v from r where k = 'audit.rows'),   'insert:new year,insert:new year', 'each created link is audited (T7) with the operation''s reason');
select is((select v from r where k = 'audit.refused'), '0', 'refused copies leave no domain audit row');
select is((select v from r where k = 'audit.ctx'),    'none', 'the audit context is empty after every call');

select ok(not has_table_privilege('authenticated', 'public.grade_subjects', 'DELETE'), 'no DELETE on grade_subjects: a copy is never undone by deleting');
select is((select count(*)::int from pg_proc p where p.pronamespace = 'app'::regnamespace and p.proname = 'copy_grade_subjects'), 1, 'one copy operation, no overloads');

select * from finish();
rollback;
