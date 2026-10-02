-- M33 — academic_year_guard (Phase 2A، ف4): T10 يفرض ما يُعدَّل في السنة حسب حالتها، أياً كان المسار.
-- planned: الاسم والتواريخ · active: الاسم فقط · closed: لا شيء · الانتقالات planned → active → closed فقط.
-- المسارات: العميل تحت RLS (school_admin المبذور)، دوال M21، والمسار المميّز (postgres) — الحارس يسري على الثلاثة.
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

create function pg_temp.run(p_key text, p_sub uuid, p_sql text) returns void
language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p_sub, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', p_sub::text, true);
  execute 'set local role authenticated';
  perform pg_temp.rec(p_key, p_sql);
  execute 'reset role';
end $$;

-- ============ Fixture: T1 بمجموعة GA (SA، SB)، و T2 بمدرسة ============
insert into public.platform_tenants (id, tenant_code, host_label, name) values
  ('10000000-0000-0000-0000-000000000001', 'T1', 't1', 'T1'), ('20000000-0000-0000-0000-000000000002', 'T2', 't2', 'T2');
insert into public.groups (id, platform_tenant_id, group_code, name) values ('a1000000-0000-0000-0000-00000000000a', '10000000-0000-0000-0000-000000000001', 'GA', 'GA');
insert into public.schools (id, platform_tenant_id, group_id, school_code, name, slug) values
  ('5a000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', 'a1000000-0000-0000-0000-00000000000a', 'SA', 'SA', 'sa'),
  ('5b000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001', 'a1000000-0000-0000-0000-00000000000a', 'SB', 'SB', 'sb'),
  ('5c000000-0000-0000-0000-000000000003', '20000000-0000-0000-0000-000000000002', null,                                   'SX', 'SX', 'sx');

-- SA: سنة مغلقة، سنة نشطة، سنة مخططة (بفصلين)، سنة مخططة ثانية للانتقالات؛ SB: سنة مخططة
insert into public.academic_years (id, school_id, name, start_date, end_date, status) values
  ('c0000000-0000-0000-0000-000000000001', '5a000000-0000-0000-0000-000000000001', '2025/2026', '2025-09-01', '2026-06-30', 'closed'),
  ('ac000000-0000-0000-0000-000000000002', '5a000000-0000-0000-0000-000000000001', '2026/2027', '2026-09-01', '2027-06-30', 'active'),
  ('b0000000-0000-0000-0000-000000000003', '5a000000-0000-0000-0000-000000000001', '2027/2028', '2027-09-01', '2028-06-30', 'planned'),
  ('b1000000-0000-0000-0000-000000000004', '5a000000-0000-0000-0000-000000000001', '2028/2029', '2028-09-01', '2029-06-30', 'planned'),
  ('bb000000-0000-0000-0000-000000000005', '5b000000-0000-0000-0000-000000000002', '2026/2027', '2026-09-01', '2027-06-30', 'planned');
insert into public.terms (academic_year_id, school_id, year_start_date, year_end_date, name, sequence_no, start_date, end_date) values
  ('b0000000-0000-0000-0000-000000000003', '5a000000-0000-0000-0000-000000000001', '2027-09-01', '2028-06-30', 'T1', 1, '2027-09-01', '2027-12-20'),
  ('b0000000-0000-0000-0000-000000000003', '5a000000-0000-0000-0000-000000000001', '2027-09-01', '2028-06-30', 'T2', 2, '2028-01-10', '2028-06-20'),
  ('c0000000-0000-0000-0000-000000000001', '5a000000-0000-0000-0000-000000000001', '2025-09-01', '2026-06-30', 'T1', 1, '2025-09-01', '2026-06-20');

-- الفاعلون: school_admin المبذور (M23) — adminSA على SA، adminSB على SB، adminX في T2
create function pg_temp.member(p_id uuid, p_tenant uuid, p_school uuid) returns void
language plpgsql as $$
declare v_p uuid; v_m uuid;
begin
  insert into auth.users (id, email) values (p_id, p_id::text || '@m33.invalid');
  insert into public.auth_identities (auth_user_id, kind) values (p_id, 'tenant');
  insert into public.profiles (platform_tenant_id, auth_user_id, display_name) values (p_tenant, p_id, 'x') returning id into v_p;
  insert into public.memberships (platform_tenant_id, profile_id) values (p_tenant, v_p) returning id into v_m;
  insert into public.membership_roles (membership_id, role_id, platform_tenant_id, role_owner_key)
    values (v_m, (select id from public.roles where code = 'school_admin' and platform_tenant_id is null), p_tenant, '00000000-0000-0000-0000-000000000000');
  insert into public.membership_scopes (membership_id, platform_tenant_id, scope_type, school_id) values (v_m, p_tenant, 'school', p_school);
end $$;
select pg_temp.member('e1000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', '5a000000-0000-0000-0000-000000000001');
select pg_temp.member('e2000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001', '5b000000-0000-0000-0000-000000000002');
select pg_temp.member('e3000000-0000-0000-0000-000000000003', '20000000-0000-0000-0000-000000000002', '5c000000-0000-0000-0000-000000000003');

-- ============ planned: الاسم والتواريخ (العميل) ============
select pg_temp.run('p.name',   'e1000000-0000-0000-0000-000000000001', $q$update public.academic_years set name = '2027-28' where id = 'b0000000-0000-0000-0000-000000000003' returning name$q$);
select pg_temp.run('p.extend', 'e1000000-0000-0000-0000-000000000001', $q$update public.academic_years set end_date = '2028-07-15' where id = 'b0000000-0000-0000-0000-000000000003' returning end_date::text$q$);
select pg_temp.rec('p.cascade', $q$select string_agg(distinct year_end_date::text, ',') from public.terms where academic_year_id = 'b0000000-0000-0000-0000-000000000003'$q$);
-- لا تعديل صامت لحدود الفصول: تقليص السنة تحت فصل قائم يُرفض بقيد الفصل
select pg_temp.run('p.shrink', 'e1000000-0000-0000-0000-000000000001', $q$update public.academic_years set end_date = '2028-03-01' where id = 'b0000000-0000-0000-0000-000000000003' returning 'ok'$q$);

-- ============ active: الاسم فقط ============
select pg_temp.run('a.name',   'e1000000-0000-0000-0000-000000000001', $q$update public.academic_years set name = '2026-27' where id = 'ac000000-0000-0000-0000-000000000002' returning name$q$);
select pg_temp.run('a.end',    'e1000000-0000-0000-0000-000000000001', $q$update public.academic_years set end_date = '2027-07-15' where id = 'ac000000-0000-0000-0000-000000000002' returning 'ok'$q$);
select pg_temp.run('a.start',  'e1000000-0000-0000-0000-000000000001', $q$update public.academic_years set start_date = '2026-08-25' where id = 'ac000000-0000-0000-0000-000000000002' returning 'ok'$q$);
select pg_temp.run('a.both',   'e1000000-0000-0000-0000-000000000001', $q$update public.academic_years set name = 'x', end_date = '2027-07-15' where id = 'ac000000-0000-0000-0000-000000000002' returning 'ok'$q$);

-- ============ closed: لا شيء ============
select pg_temp.run('c.name',   'e1000000-0000-0000-0000-000000000001', $q$update public.academic_years set name = 'renamed' where id = 'c0000000-0000-0000-0000-000000000001' returning 'ok'$q$);
select pg_temp.run('c.dates',  'e1000000-0000-0000-0000-000000000001', $q$update public.academic_years set end_date = '2026-07-15' where id = 'c0000000-0000-0000-0000-000000000001' returning 'ok'$q$);
select pg_temp.run('c.noop',   'e1000000-0000-0000-0000-000000000001', $q$update public.academic_years set name = name where id = 'c0000000-0000-0000-0000-000000000001' returning 'ok'$q$);
select pg_temp.run('c.read',   'e1000000-0000-0000-0000-000000000001', $q$select name || '|' || end_date from public.academic_years where id = 'c0000000-0000-0000-0000-000000000001'$q$);
select pg_temp.rec('c.terms',  $q$select string_agg(distinct year_end_date::text, ',') from public.terms where academic_year_id = 'c0000000-0000-0000-0000-000000000001'$q$);

-- ============ الانتقالات — العميل لا يكتب status (M20)، والدوال تمر بالحارس ============
select pg_temp.run('s.client',    'e1000000-0000-0000-0000-000000000001', $q$update public.academic_years set status = 'active' where id = 'b0000000-0000-0000-0000-000000000003' returning 'ok'$q$);
select pg_temp.run('s.reopen_fn', 'e1000000-0000-0000-0000-000000000001', $q$select app.activate_academic_year('c0000000-0000-0000-0000-000000000001', 'r')$q$);
select pg_temp.run('s.close',     'e1000000-0000-0000-0000-000000000001', $q$select app.close_academic_year('ac000000-0000-0000-0000-000000000002', 'year end')$q$);
select pg_temp.rec('s.closed',    $q$select status from public.academic_years where id = 'ac000000-0000-0000-0000-000000000002'$q$);
select pg_temp.run('s.activate',  'e1000000-0000-0000-0000-000000000001', $q$select app.activate_academic_year('b0000000-0000-0000-0000-000000000003', 'new year')$q$);
select pg_temp.rec('s.active',    $q$select status from public.academic_years where id = 'b0000000-0000-0000-0000-000000000003'$q$);
-- بعد الانتقال تسري قواعد الحالة الجديدة
select pg_temp.run('s.after_close',    'e1000000-0000-0000-0000-000000000001', $q$update public.academic_years set name = 'again' where id = 'ac000000-0000-0000-0000-000000000002' returning 'ok'$q$);
select pg_temp.run('s.after_activate', 'e1000000-0000-0000-0000-000000000001', $q$update public.academic_years set end_date = '2028-07-20' where id = 'b0000000-0000-0000-0000-000000000003' returning 'ok'$q$);

-- ============ المسار المميّز (postgres، بلا RLS ولا منح أعمدة): الحارس وحده يمنع ============
select pg_temp.rec('x.reopen',       $q$update public.academic_years set status = 'active'  where id = 'c0000000-0000-0000-0000-000000000001' returning 'ok'$q$);
select pg_temp.rec('x.closed_plan',  $q$update public.academic_years set status = 'planned' where id = 'c0000000-0000-0000-0000-000000000001' returning 'ok'$q$);
select pg_temp.rec('x.skip',         $q$update public.academic_years set status = 'closed'  where id = 'b1000000-0000-0000-0000-000000000004' returning 'ok'$q$);
select pg_temp.rec('x.back',         $q$update public.academic_years set status = 'planned' where id = 'b0000000-0000-0000-0000-000000000003' returning 'ok'$q$);
select pg_temp.rec('x.move_school',  $q$update public.academic_years set school_id = '5b000000-0000-0000-0000-000000000002' where id = 'b1000000-0000-0000-0000-000000000004' returning 'ok'$q$);
select pg_temp.rec('x.active_dates', $q$update public.academic_years set end_date = '2028-08-01' where id = 'b0000000-0000-0000-0000-000000000003' returning 'ok'$q$);
select pg_temp.rec('x.planned_ok',   $q$update public.academic_years set name = '2028-29', start_date = '2028-09-05' where id = 'b1000000-0000-0000-0000-000000000004' returning start_date::text$q$);
-- I33 باقٍ: الانتقال المشروع يمر بالحارس ثم يرفضه الفهرس الفريد
select pg_temp.rec('x.second_active', $q$update public.academic_years set status = 'active' where id = 'b1000000-0000-0000-0000-000000000004' returning 'ok'$q$);

-- ============ العزل: مدرسة شقيقة و Tenant آخر (الحارس لا يوسّع ما تمنعه RLS) ============
select pg_temp.run('i.sibling', 'e2000000-0000-0000-0000-000000000002', $q$with u as (update public.academic_years set name = 'hijack' where id = 'b1000000-0000-0000-0000-000000000004' returning 1) select count(*)::text from u$q$);
select pg_temp.run('i.tenant',  'e3000000-0000-0000-0000-000000000003', $q$with u as (update public.academic_years set name = 'hijack' where id = 'b1000000-0000-0000-0000-000000000004' returning 1) select count(*)::text from u$q$);
select pg_temp.run('i.own',     'e2000000-0000-0000-0000-000000000002', $q$update public.academic_years set name = 'SB 26-27', start_date = '2026-09-02' where id = 'bb000000-0000-0000-0000-000000000005' returning name$q$);

-- ============ التدقيق ============
select pg_temp.rec('audit.rename', $q$select actor_type || '|' || action || '|' || (old_values ->> 'name') || '>' || (new_values ->> 'name') || '|' || (school_id = '5a000000-0000-0000-0000-000000000001')::text
  from public.audit_log where entity_type = 'academic_years' and entity_id = 'ac000000-0000-0000-0000-000000000002' and action = 'update' and new_values ->> 'name' = '2026-27'$q$);
select pg_temp.rec('audit.rejected', $q$select count(*)::text from public.audit_log where entity_type = 'academic_years' and entity_id = 'c0000000-0000-0000-0000-000000000001' and action <> 'insert'$q$);

-- =====================================================================
select plan(5 + 4 + 5 + 8 + 8 + 3 + 2 + 2);

-- planned
select is((select v from r where k = 'p.name'),    '2027-28',    'planned: the name can change');
select is((select v from r where k = 'p.extend'),  '2028-07-15', 'planned: the dates can change');
select is((select v from r where k = 'p.cascade'), '2028-07-15', 'planned: the new bounds reach the year''s terms (I35 cascade)');
select ok((select v from r where k = 'p.shrink') like 'ERR 23514%terms_within_year_chk%', 'planned: shrinking the year below an existing term is rejected — no silent change of term bounds');
select is((select end_date::text from public.academic_years where id = 'b1000000-0000-0000-0000-000000000004'), '2029-06-30', 'control: an untouched planned year keeps its dates');

-- active
select is((select v from r where k = 'a.name'), '2026-27', 'active: the name can change');
select ok((select v from r where k = 'a.end')   like 'ERR 23514%dates of an active academic year%', 'active: end_date cannot change');
select ok((select v from r where k = 'a.start') like 'ERR 23514%dates of an active academic year%', 'active: start_date cannot change');
select ok((select v from r where k = 'a.both')  like 'ERR 23514%dates of an active academic year%', 'active: a name change does not smuggle a date change');

-- closed
select ok((select v from r where k = 'c.name')  like 'ERR 23514%is closed and cannot be modified%', 'closed: the name cannot change');
select ok((select v from r where k = 'c.dates') like 'ERR 23514%is closed and cannot be modified%', 'closed: the dates cannot change');
select ok((select v from r where k = 'c.noop')  like 'ERR 23514%is closed and cannot be modified%', 'closed: even a no-op UPDATE is rejected (immutable)');
select is((select v from r where k = 'c.read'),  '2025/2026|2026-06-30', 'closed: still readable, unchanged');
select is((select v from r where k = 'c.terms'), '2026-06-30', 'closed: its terms keep the year bounds');

-- transitions
select ok((select v from r where k = 's.client')    like 'ERR 42501%permission denied%', 'the client cannot write status directly (M20 column grants)');
select ok((select v from r where k = 's.reopen_fn') like 'ERR 22023%invalid transition closed -> active%', 'activate_academic_year refuses a closed year (no reopening)');
select is((select v from r where k = 's.close'),    '', 'close_academic_year still works through the guard');
select is((select v from r where k = 's.closed'),   'closed', 'active → closed');
select is((select v from r where k = 's.activate'), '', 'activate_academic_year still works through the guard');
select is((select v from r where k = 's.active'),   'active', 'planned → active');
select ok((select v from r where k = 's.after_close')    like 'ERR 23514%is closed and cannot be modified%', 'a year just closed is immutable at once');
select ok((select v from r where k = 's.after_activate') like 'ERR 23514%dates of an active academic year%', 'a year just activated has fixed dates at once');

-- privileged path
select ok((select v from r where k = 'x.reopen')       like 'ERR 23514%is closed and cannot be modified%', 'privileged path: closed → active is rejected by the guard itself');
select ok((select v from r where k = 'x.closed_plan')  like 'ERR 23514%is closed and cannot be modified%', 'privileged path: closed → planned is rejected');
select ok((select v from r where k = 'x.skip')         like 'ERR 23514%transition planned -> closed is not allowed%', 'privileged path: planned → closed (skipping active) is rejected');
select ok((select v from r where k = 'x.back')         like 'ERR 23514%transition active -> planned is not allowed%', 'privileged path: active → planned is rejected');
select ok((select v from r where k = 'x.move_school')  like 'ERR 23514%cannot move to another school%', 'privileged path: a year cannot move to another school');
select ok((select v from r where k = 'x.active_dates') like 'ERR 23514%dates of an active academic year%', 'privileged path: active dates are fixed for every role');
select is((select v from r where k = 'x.planned_ok'),  '2028-09-05', 'privileged path: a planned year is still editable');
select ok((select v from r where k = 'x.second_active') like 'ERR 23505%academic_years_active_uq%', 'I33 unchanged: a legal transition passes the guard and the unique index rejects a second active year');

-- isolation
select is((select v from r where k = 'i.sibling'), '0', 'a sibling school''s admin updates nothing (RLS, §1.1 rule 5)');
select is((select v from r where k = 'i.tenant'),  '0', 'another tenant''s admin updates nothing (I1)');
select is((select v from r where k = 'i.own'),     'SB 26-27', 'control: the same admin edits a planned year of its own school');

-- audit
select is((select v from r where k = 'audit.rename'),   'tenant_user|update|2026/2027>2026-27|true', 'an allowed edit is audited with actor, old and new values, and school');
select is((select v from r where k = 'audit.rejected'), '0', 'a rejected edit leaves no audit row and no change');

-- structure
select is((select pg_get_triggerdef(t.oid) from pg_trigger t where t.tgrelid = 'public.academic_years'::regclass and t.tgname = 'guard'),
          'CREATE TRIGGER guard BEFORE UPDATE ON public.academic_years FOR EACH ROW EXECUTE FUNCTION app.tg_academic_year_guard()',
          'T10 is a row-level BEFORE UPDATE trigger on academic_years');
select is((select count(*)::int from pg_proc p where p.oid = 'app.tg_academic_year_guard()'::regprocedure and not p.prosecdef
            and pg_get_userbyid(p.proowner) = 'app_owner'
            and not has_function_privilege('authenticated', p.oid, 'EXECUTE') and not has_function_privilege('anon', p.oid, 'EXECUTE')), 1,
          'the guard function is owned by app_owner, SECURITY INVOKER, and not callable by API roles');

select * from finish();
rollback;
