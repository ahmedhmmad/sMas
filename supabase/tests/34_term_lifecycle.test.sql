-- M34 — term_lifecycle (Phase 2A، ف5): planned → active → closed بدالتين (term.manage)، فصل active واحد لكل سنة
-- وداخل سنة active فقط، T11 يحرس كل مسار، وإغلاق السنة يُرفض مع فصل active.
-- الصلاحية والنطاق تحكمهما RLS والدوال — لا الحارس.
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
  -- سياق التدقيق بعد الاستدعاء: يجب أن يكون فارغاً
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

-- SA / yC: سنة تُغلق عبر مسارها المشروع، بفصل مغلق (tC1) وفصل بقي planned (tC2)
insert into public.academic_years (id, school_id, name, start_date, end_date) values
  ('c0000000-0000-0000-0000-000000000001', '5a000000-0000-0000-0000-000000000001', '2025/2026', '2025-09-01', '2026-06-30');
insert into public.terms (id, academic_year_id, school_id, year_start_date, year_end_date, name, sequence_no, start_date, end_date) values
  ('7c000000-0000-0000-0000-000000000001', 'c0000000-0000-0000-0000-000000000001', '5a000000-0000-0000-0000-000000000001', '2025-09-01', '2026-06-30', 'C1', 1, '2025-09-01', '2025-12-31'),
  ('7c000000-0000-0000-0000-000000000002', 'c0000000-0000-0000-0000-000000000001', '5a000000-0000-0000-0000-000000000001', '2025-09-01', '2026-06-30', 'C2', 2, '2026-01-05', '2026-06-20');
update public.academic_years set status = 'active' where id = 'c0000000-0000-0000-0000-000000000001';
update public.terms set status = 'active' where id = '7c000000-0000-0000-0000-000000000001';
update public.terms set status = 'closed' where id = '7c000000-0000-0000-0000-000000000001';
update public.academic_years set status = 'closed' where id = 'c0000000-0000-0000-0000-000000000001';

-- SA / yA نشطة بثلاثة فصول planned؛ SA / yP مخططة بفصل؛ SB / yB نشطة بفصل؛ SX / yX نشطة بفصل
insert into public.academic_years (id, school_id, name, start_date, end_date) values
  ('ac000000-0000-0000-0000-000000000002', '5a000000-0000-0000-0000-000000000001', '2026/2027', '2026-09-01', '2027-06-30'),
  ('b0000000-0000-0000-0000-000000000003', '5a000000-0000-0000-0000-000000000001', '2027/2028', '2027-09-01', '2028-06-30'),
  ('bb000000-0000-0000-0000-000000000004', '5b000000-0000-0000-0000-000000000002', '2026/2027', '2026-09-01', '2027-06-30'),
  ('cc000000-0000-0000-0000-000000000005', '5c000000-0000-0000-0000-000000000003', '2026/2027', '2026-09-01', '2027-06-30');
insert into public.terms (id, academic_year_id, school_id, year_start_date, year_end_date, name, sequence_no, start_date, end_date) values
  ('7a000000-0000-0000-0000-000000000001', 'ac000000-0000-0000-0000-000000000002', '5a000000-0000-0000-0000-000000000001', '2026-09-01', '2027-06-30', 'A1', 1, '2026-09-01', '2026-11-30'),
  ('7a000000-0000-0000-0000-000000000002', 'ac000000-0000-0000-0000-000000000002', '5a000000-0000-0000-0000-000000000001', '2026-09-01', '2027-06-30', 'A2', 2, '2026-12-01', '2027-02-28'),
  ('7a000000-0000-0000-0000-000000000003', 'ac000000-0000-0000-0000-000000000002', '5a000000-0000-0000-0000-000000000001', '2026-09-01', '2027-06-30', 'A3', 3, '2027-03-01', '2027-04-30'),
  ('7b000000-0000-0000-0000-000000000001', 'b0000000-0000-0000-0000-000000000003', '5a000000-0000-0000-0000-000000000001', '2027-09-01', '2028-06-30', 'P1', 1, '2027-09-01', '2027-12-20'),
  ('7d000000-0000-0000-0000-000000000001', 'bb000000-0000-0000-0000-000000000004', '5b000000-0000-0000-0000-000000000002', '2026-09-01', '2027-06-30', 'B1', 1, '2026-09-01', '2026-12-20'),
  ('7e000000-0000-0000-0000-000000000001', 'cc000000-0000-0000-0000-000000000005', '5c000000-0000-0000-0000-000000000003', '2026-09-01', '2027-06-30', 'X1', 1, '2026-09-01', '2026-12-20');
update public.academic_years set status = 'active' where id in
  ('ac000000-0000-0000-0000-000000000002', 'bb000000-0000-0000-0000-000000000004', 'cc000000-0000-0000-0000-000000000005');

-- الفاعلون بالأدوار المبذورة (M23)
create function pg_temp.member(p_label text, p_role text, p_tenant uuid, p_school uuid) returns void
language plpgsql as $$
declare v_a uuid := gen_random_uuid(); v_p uuid; v_m uuid;
begin
  insert into auth.users (id, email) values (v_a, p_label || '@m34.invalid');
  insert into public.auth_identities (auth_user_id, kind) values (v_a, 'tenant');
  insert into public.profiles (platform_tenant_id, auth_user_id, display_name) values (p_tenant, v_a, p_label) returning id into v_p;
  insert into public.memberships (platform_tenant_id, profile_id) values (p_tenant, v_p) returning id into v_m;
  insert into public.membership_roles (membership_id, role_id, platform_tenant_id, role_owner_key)
    values (v_m, (select id from public.roles where code = p_role and platform_tenant_id is null), p_tenant, '00000000-0000-0000-0000-000000000000');
  if p_school is null then
    insert into public.membership_scopes (membership_id, platform_tenant_id, scope_type) values (v_m, p_tenant, 'tenant');
  else
    insert into public.membership_scopes (membership_id, platform_tenant_id, scope_type, school_id) values (v_m, p_tenant, 'school', p_school);
  end if;
  insert into actors values (p_label, v_a);
end $$;
select pg_temp.member('sa',  'school_admin', '10000000-0000-0000-0000-000000000001', '5a000000-0000-0000-0000-000000000001');
select pg_temp.member('sb',  'school_admin', '10000000-0000-0000-0000-000000000001', '5b000000-0000-0000-0000-000000000002');
select pg_temp.member('sec', 'secretary',    '10000000-0000-0000-0000-000000000001', '5a000000-0000-0000-0000-000000000001');   -- term.read بلا term.manage
select pg_temp.member('ta',  'tenant_admin', '10000000-0000-0000-0000-000000000001', null);
select pg_temp.member('x',   'school_admin', '20000000-0000-0000-0000-000000000002', '5c000000-0000-0000-0000-000000000003');

-- دور مخصص يملك term.manage وحده (بلا academic_year.read): لا يرى صف السنة تحت RLS — يثبت أن الحارس SECURITY DEFINER
insert into public.roles (id, platform_tenant_id, code, name) values ('7f000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', 'zt_term_only', 'term only');
insert into public.role_permissions (role_id, permission_id) select '7f000000-0000-0000-0000-000000000001', id from public.permissions where code = 'term.manage';
do $$
declare v_a uuid := gen_random_uuid(); v_p uuid; v_m uuid;
begin
  insert into auth.users (id, email) values (v_a, 'termonly@m34.invalid');
  insert into public.auth_identities (auth_user_id, kind) values (v_a, 'tenant');
  insert into public.profiles (platform_tenant_id, auth_user_id, display_name) values ('10000000-0000-0000-0000-000000000001', v_a, 'to') returning id into v_p;
  insert into public.memberships (platform_tenant_id, profile_id) values ('10000000-0000-0000-0000-000000000001', v_p) returning id into v_m;
  insert into public.membership_roles (membership_id, role_id, platform_tenant_id, role_owner_key)
    values (v_m, '7f000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001');
  insert into public.membership_scopes (membership_id, platform_tenant_id, scope_type, school_id)
    values (v_m, '10000000-0000-0000-0000-000000000001', 'school', '5a000000-0000-0000-0000-000000000001');
  insert into actors values ('to', v_a);
end $$;

create function pg_temp.st(p_id uuid) returns text language sql as $$ select status from public.terms where id = p_id $$;

-- ============ أ. قبل أي تفعيل: الصلاحية والنطاق (الدوال و RLS) ============
select pg_temp.run('fn.sec',      'sec', $q$select app.activate_term('7a000000-0000-0000-0000-000000000001', 'r')$q$);
select pg_temp.run('fn.sibling',  'sb',  $q$select app.activate_term('7a000000-0000-0000-0000-000000000001', 'r')$q$);
select pg_temp.run('fn.tenant',   'x',   $q$select app.activate_term('7a000000-0000-0000-0000-000000000001', 'r')$q$);
select pg_temp.run('fn.close_sibling', 'sb', $q$select app.close_term('7a000000-0000-0000-0000-000000000001', 'r')$q$);
select pg_temp.run('fn.noreason', 'sa',  $q$select app.activate_term('7a000000-0000-0000-0000-000000000001', '  ')$q$);
select pg_temp.run('fn.close_planned', 'sa', $q$select app.close_term('7a000000-0000-0000-0000-000000000001', 'r')$q$);
select pg_temp.run('fn.planned_year',  'sa', $q$select app.activate_term('7b000000-0000-0000-0000-000000000001', 'r')$q$);
select pg_temp.run('fn.closed_year',   'sa', $q$select app.activate_term('7c000000-0000-0000-0000-000000000002', 'r')$q$);
select pg_temp.rec('fn.untouched', $q$select string_agg(status, ',' order by id) from public.terms where academic_year_id = 'ac000000-0000-0000-0000-000000000002'$q$);

-- RLS تحكم الكتابة المباشرة: بلا term.manage، مدرسة شقيقة، Tenant آخر
select pg_temp.run('rls.sec',      'sec', $q$with u as (update public.terms set name = 'h' where id = '7a000000-0000-0000-0000-000000000003' returning 1) select count(*)::text from u$q$);
select pg_temp.run('rls.sibling',  'sb',  $q$with u as (update public.terms set name = 'h' where id = '7a000000-0000-0000-0000-000000000003' returning 1) select count(*)::text from u$q$);
select pg_temp.run('rls.tenant',   'x',   $q$with u as (update public.terms set name = 'h' where id = '7a000000-0000-0000-0000-000000000003' returning 1) select count(*)::text from u$q$);
select pg_temp.run('rls.sibling_ins', 'sb', $q$insert into public.terms (academic_year_id, school_id, year_start_date, year_end_date, name, sequence_no, start_date, end_date)
  values ('ac000000-0000-0000-0000-000000000002', '5a000000-0000-0000-0000-000000000001', '2026-09-01', '2027-06-30', 'hijack', 9, '2027-05-01', '2027-06-15') returning 'ok'$q$);
select pg_temp.run('rls.sec_read', 'sec', $q$select count(*)::text from public.terms where academic_year_id = 'ac000000-0000-0000-0000-000000000002'$q$);

-- العميل لا يكتب status ولا هوية الفصل (منح الأعمدة)
select pg_temp.run('col.status',     'sa', $q$update public.terms set status = 'active' where id = '7a000000-0000-0000-0000-000000000001' returning 'ok'$q$);
select pg_temp.run('col.ins_status', 'sa', $q$insert into public.terms (academic_year_id, school_id, year_start_date, year_end_date, name, sequence_no, start_date, end_date, status)
  values ('ac000000-0000-0000-0000-000000000002', '5a000000-0000-0000-0000-000000000001', '2026-09-01', '2027-06-30', 'A4', 4, '2027-05-01', '2027-06-15', 'active') returning 'ok'$q$);
select pg_temp.run('col.year',       'sa', $q$update public.terms set academic_year_id = 'b0000000-0000-0000-0000-000000000003' where id = '7a000000-0000-0000-0000-000000000003' returning 'ok'$q$);

-- CRUD المشروع: فصل planned يُعدَّل كله؛ فصل جديد يولد planned؛ لا فصل جديد في سنة مغلقة
select pg_temp.run('crud.planned', 'sa', $q$update public.terms set name = 'A3b', sequence_no = 5, start_date = '2027-03-05', end_date = '2027-04-25' where id = '7a000000-0000-0000-0000-000000000003'
  returning name || '|' || sequence_no || '|' || start_date || '|' || end_date$q$);
select pg_temp.run('crud.insert',  'sa', $q$insert into public.terms (academic_year_id, school_id, year_start_date, year_end_date, name, sequence_no, start_date, end_date)
  values ('ac000000-0000-0000-0000-000000000002', '5a000000-0000-0000-0000-000000000001', '2026-09-01', '2027-06-30', 'A4', 4, '2027-05-01', '2027-06-15') returning status$q$);
select pg_temp.run('crud.insert_planned_year', 'sa', $q$insert into public.terms (academic_year_id, school_id, year_start_date, year_end_date, name, sequence_no, start_date, end_date)
  values ('b0000000-0000-0000-0000-000000000003', '5a000000-0000-0000-0000-000000000001', '2027-09-01', '2028-06-30', 'P2', 2, '2028-01-10', '2028-06-20') returning status$q$);
select pg_temp.run('crud.insert_closed_year', 'sa', $q$insert into public.terms (academic_year_id, school_id, year_start_date, year_end_date, name, sequence_no, start_date, end_date)
  values ('c0000000-0000-0000-0000-000000000001', '5a000000-0000-0000-0000-000000000001', '2025-09-01', '2026-06-30', 'C3', 3, '2026-06-21', '2026-06-30') returning 'ok'$q$);
select pg_temp.run('crud.closed_year_planned_term', 'sa', $q$update public.terms set name = 'C2b' where id = '7c000000-0000-0000-0000-000000000002' returning 'ok'$q$);
select pg_temp.run('crud.blind_year', 'to', $q$select count(*)::text from public.academic_years$q$);
select pg_temp.run('crud.blind_closed_year', 'to', $q$insert into public.terms (academic_year_id, school_id, year_start_date, year_end_date, name, sequence_no, start_date, end_date)
  values ('c0000000-0000-0000-0000-000000000001', '5a000000-0000-0000-0000-000000000001', '2025-09-01', '2026-06-30', 'C9', 9, '2026-06-21', '2026-06-30') returning 'ok'$q$);
-- تعديل تواريخ سنة planned ما زال يصل إلى نسخ حدودها في فصولها (الحارس لا يعترض الـcascade)
select pg_temp.run('crud.cascade', 'sa', $q$update public.academic_years set end_date = '2028-07-10' where id = 'b0000000-0000-0000-0000-000000000003' returning 'ok'$q$);
select pg_temp.rec('crud.cascade_terms', $q$select string_agg(distinct year_end_date::text, ',') from public.terms where academic_year_id = 'b0000000-0000-0000-0000-000000000003'$q$);

-- ============ ب. planned → active ============
select pg_temp.run('act.a1', 'sa', $q$select app.activate_term('7a000000-0000-0000-0000-000000000001', 'term starts')$q$);
select pg_temp.rec('act.a1_status', $q$select pg_temp.st('7a000000-0000-0000-0000-000000000001')$q$);
select pg_temp.run('act.again',  'sa', $q$select app.activate_term('7a000000-0000-0000-0000-000000000001', 'r')$q$);
select pg_temp.run('act.second', 'sa', $q$select app.activate_term('7a000000-0000-0000-0000-000000000002', 'r')$q$);
select pg_temp.rec('x.second',   $q$update public.terms set status = 'active' where id = '7a000000-0000-0000-0000-000000000002' returning 'ok'$q$);
select pg_temp.rec('act.one_active', $q$select count(*)::text from public.terms where academic_year_id = 'ac000000-0000-0000-0000-000000000002' and status = 'active'$q$);
-- فصل نشط في مدرسة أخرى لا يتأثر: الواحد «لكل سنة»
select pg_temp.run('act.sb', 'sb', $q$select app.activate_term('7d000000-0000-0000-0000-000000000001', 'sb term')$q$);
select pg_temp.rec('act.sb_status', $q$select pg_temp.st('7d000000-0000-0000-0000-000000000001')$q$);

-- active: الاسم فقط
select pg_temp.run('active.name',  'sa', $q$update public.terms set name = 'A1b' where id = '7a000000-0000-0000-0000-000000000001' returning name$q$);
select pg_temp.run('active.dates', 'sa', $q$update public.terms set end_date = '2026-11-25' where id = '7a000000-0000-0000-0000-000000000001' returning 'ok'$q$);
select pg_temp.run('active.seq',   'sa', $q$update public.terms set sequence_no = 9 where id = '7a000000-0000-0000-0000-000000000001' returning 'ok'$q$);

-- إغلاق السنة مع فصل active
select pg_temp.run('year.close_busy', 'sa', $q$select app.close_academic_year('ac000000-0000-0000-0000-000000000002', 'year end')$q$);
select pg_temp.rec('year.still_active', $q$select status from public.academic_years where id = 'ac000000-0000-0000-0000-000000000002'$q$);

-- المسار المميّز: الحارس وحده
select pg_temp.rec('x.back',         $q$update public.terms set status = 'planned' where id = '7a000000-0000-0000-0000-000000000001' returning 'ok'$q$);
select pg_temp.rec('x.skip',         $q$update public.terms set status = 'closed'  where id = '7a000000-0000-0000-0000-000000000002' returning 'ok'$q$);
select pg_temp.rec('x.planned_year', $q$update public.terms set status = 'active'  where id = '7b000000-0000-0000-0000-000000000001' returning 'ok'$q$);
select pg_temp.rec('x.closed_year',  $q$update public.terms set status = 'active'  where id = '7c000000-0000-0000-0000-000000000002' returning 'ok'$q$);
select pg_temp.rec('x.closed_term',  $q$update public.terms set status = 'active'  where id = '7c000000-0000-0000-0000-000000000001' returning 'ok'$q$);
select pg_temp.rec('x.move',         $q$update public.terms set academic_year_id = 'b0000000-0000-0000-0000-000000000003', year_start_date = '2027-09-01', year_end_date = '2028-07-10',
  start_date = '2028-01-01', end_date = '2028-01-05' where id = '7a000000-0000-0000-0000-000000000002' returning 'ok'$q$);
select pg_temp.rec('x.born_active',  $q$insert into public.terms (academic_year_id, school_id, year_start_date, year_end_date, name, sequence_no, start_date, end_date, status)
  values ('bb000000-0000-0000-0000-000000000004', '5b000000-0000-0000-0000-000000000002', '2026-09-01', '2027-06-30', 'B2', 2, '2027-01-05', '2027-03-31', 'closed') returning 'ok'$q$);
select pg_temp.rec('x.active_dates', $q$update public.terms set start_date = '2026-09-02' where id = '7a000000-0000-0000-0000-000000000001' returning 'ok'$q$);

-- ============ ج. active → closed ============
select pg_temp.run('close.a1', 'ta', $q$select app.close_term('7a000000-0000-0000-0000-000000000001', 'term ends')$q$);
select pg_temp.rec('close.a1_status', $q$select pg_temp.st('7a000000-0000-0000-0000-000000000001')$q$);
select pg_temp.run('close.again',   'sa', $q$select app.close_term('7a000000-0000-0000-0000-000000000001', 'r')$q$);
select pg_temp.run('close.reopen',  'sa', $q$select app.activate_term('7a000000-0000-0000-0000-000000000001', 'r')$q$);
select pg_temp.run('closed.name',   'sa', $q$update public.terms set name = 'A1c' where id = '7a000000-0000-0000-0000-000000000001' returning 'ok'$q$);
select pg_temp.run('closed.noop',   'sa', $q$update public.terms set name = name where id = '7a000000-0000-0000-0000-000000000001' returning 'ok'$q$);
select pg_temp.rec('x.reopen',      $q$update public.terms set status = 'active' where id = '7a000000-0000-0000-0000-000000000001' returning 'ok'$q$);
-- الفصل التالي يُفعَّل بعد إغلاق السابق، ثم يُغلق
select pg_temp.run('next.act',   'sa', $q$select app.activate_term('7a000000-0000-0000-0000-000000000002', 'second term')$q$);
select pg_temp.run('next.close', 'sa', $q$select app.close_term('7a000000-0000-0000-0000-000000000002', 'second term ends')$q$);
select pg_temp.rec('next.status', $q$select pg_temp.st('7a000000-0000-0000-0000-000000000002')$q$);

-- ============ د. إغلاق السنة بلا فصل active، ثم تجمّد فصولها ============
select pg_temp.run('year.close', 'sa', $q$select app.close_academic_year('ac000000-0000-0000-0000-000000000002', 'year end')$q$);
select pg_temp.rec('year.closed', $q$select status from public.academic_years where id = 'ac000000-0000-0000-0000-000000000002'$q$);
select pg_temp.run('frozen.edit',     'sa', $q$update public.terms set name = 'late' where id = '7a000000-0000-0000-0000-000000000003' returning 'ok'$q$);
select pg_temp.run('frozen.activate', 'sa', $q$select app.activate_term('7a000000-0000-0000-0000-000000000003', 'r')$q$);

-- ============ التدقيق ============
select pg_temp.rec('audit.activate', $q$select actor_type || '|' || action || '|' || reason || '|' || (old_values ->> 'status') || '>' || (new_values ->> 'status') || '|' || (school_id = '5a000000-0000-0000-0000-000000000001')::text || '|' ||
    (actor_id = (select p.id from public.profiles p join actors a on a.auth = p.auth_user_id where a.label = 'sa'))::text
  from public.audit_log where entity_type = 'terms' and entity_id = '7a000000-0000-0000-0000-000000000001' and action = 'activate'$q$);
select pg_temp.rec('audit.close', $q$select actor_type || '|' || action || '|' || reason || '|' || (old_values ->> 'status') || '>' || (new_values ->> 'status') || '|' ||
    (actor_id = (select p.id from public.profiles p join actors a on a.auth = p.auth_user_id where a.label = 'ta'))::text
  from public.audit_log where entity_type = 'terms' and entity_id = '7a000000-0000-0000-0000-000000000001' and action = 'close'$q$);
select pg_temp.rec('audit.rejected', $q$select count(*)::text from public.audit_log where entity_type = 'terms' and entity_id = '7b000000-0000-0000-0000-000000000001' and action <> 'insert'
   and (new_values ->> 'status') <> 'planned'$q$);
select pg_temp.rec('audit.ctx', $q$select coalesce(string_agg(k, ',' order by k), 'none') from r where k like '%#ctx' and v <> '|'$q$);

-- =====================================================================
select plan(9 + 5 + 3 + 9 + 8 + 3 + 2 + 8 + 9 + 4 + 4 + 6);

-- 8. الصلاحية والنطاق: الدوال
select ok((select v from r where k = 'fn.sec')     like 'ERR 42501%forbidden%', 'activate_term: term.read without term.manage → forbidden');
select ok((select v from r where k = 'fn.sibling') like 'ERR P0002%not found%', 'activate_term: a sibling school''s admin → not found (no disclosure)');
select ok((select v from r where k = 'fn.tenant')  like 'ERR P0002%not found%', 'activate_term: another tenant → not found');
select ok((select v from r where k = 'fn.close_sibling') like 'ERR P0002%not found%', 'close_term: a sibling school''s admin → not found');
select ok((select v from r where k = 'fn.noreason')      like 'ERR 22023%reason required%', 'activate_term: a reason is required');
select ok((select v from r where k = 'fn.close_planned') like 'ERR 22023%invalid transition planned -> closed%', 'close_term: planned → closed is not a declared transition');
select ok((select v from r where k = 'fn.planned_year')  like 'ERR 23514%academic year is not active%', 'activate_term: a term of a planned year cannot be activated');
select ok((select v from r where k = 'fn.closed_year')   like 'ERR 23514%academic year is not active%', 'activate_term: a term of a closed year cannot be activated');
select is((select v from r where k = 'fn.untouched'), 'planned,planned,planned', 'every refused call left the terms untouched');

-- 8. الصلاحية والنطاق: RLS على الكتابة المباشرة
select is((select v from r where k = 'rls.sec'),     '0', 'direct UPDATE without term.manage changes nothing (RLS)');
select is((select v from r where k = 'rls.sibling'), '0', 'direct UPDATE from a sibling school changes nothing (RLS, §1.1 rule 5)');
select is((select v from r where k = 'rls.tenant'),  '0', 'direct UPDATE from another tenant changes nothing (I1)');
select ok((select v from r where k = 'rls.sibling_ins') like 'ERR 42501%row-level security%terms%', 'a valid planned term in another school is rejected by RLS — the guard (SECURITY DEFINER) grants nothing');
select is((select v from r where k = 'rls.sec_read'), '3', 'term.read still reads the terms');

-- 7. منح الأعمدة
select ok((select v from r where k = 'col.status')     like 'ERR 42501%permission denied%', 'the client cannot UPDATE status');
select ok((select v from r where k = 'col.ins_status') like 'ERR 42501%permission denied%', 'the client cannot INSERT a status');
select ok((select v from r where k = 'col.year')       like 'ERR 42501%permission denied%', 'the client cannot move a term to another year');

-- CRUD المشروع
select is((select v from r where k = 'crud.planned'), 'A3b|5|2027-03-05|2027-04-25', 'planned term: name, sequence and dates are editable');
select is((select v from r where k = 'crud.insert'),  'planned', 'a new term in an active year is born planned');
select is((select v from r where k = 'crud.insert_planned_year'), 'planned', 'terms of a planned year can be prepared in advance');
select ok((select v from r where k = 'crud.insert_closed_year') like 'ERR 23514%academic year is closed — no new terms%', 'no new term in a closed year');
select ok((select v from r where k = 'crud.closed_year_planned_term') like 'ERR 23514%academic year is closed — its terms cannot be modified%', 'a planned term of a closed year is frozen with it');
select is((select v from r where k = 'crud.blind_year'), '0', 'control: an actor with term.manage only cannot read academic years');
select ok((select v from r where k = 'crud.blind_closed_year') like 'ERR 23514%academic year is closed — no new terms%', '… yet the guard still sees the closed year for that actor (SECURITY DEFINER: the invariant does not depend on what RLS shows the caller)');
select is((select v from r where k = 'crud.cascade'), 'ok', 'a planned year''s dates still change');
select is((select v from r where k = 'crud.cascade_terms'), '2028-07-10', '… and the bounds reach its terms through the guard (I35 cascade)');

-- 1، 3، 4. planned → active
select is((select v from r where k = 'act.a1'),        '', 'activate_term: planned → active');
select is((select v from r where k = 'act.a1_status'), 'active', 'the term is active');
select ok((select v from r where k = 'act.again')  like 'ERR 22023%invalid transition active -> active%', 'activate_term on an active term is not a transition');
select ok((select v from r where k = 'act.second') like 'ERR 23514%already has an active term%', 'a second active term in the same year is refused by the function');
select ok((select v from r where k = 'x.second')   like 'ERR 23505%terms_active_uq%', 'privileged path: a second active term is refused by the unique index');
select is((select v from r where k = 'act.one_active'), '1', 'exactly one active term in the year');
select is((select v from r where k = 'act.sb'),        '', 'another school activates its own term independently');
select is((select v from r where k = 'act.sb_status'), 'active', 'one active term per year, not per tenant');

-- active: الاسم فقط
select is((select v from r where k = 'active.name'), 'A1b', 'active term: the name can change');
select ok((select v from r where k = 'active.dates') like 'ERR 23514%only the name of an active term%', 'active term: dates are fixed');
select ok((select v from r where k = 'active.seq')   like 'ERR 23514%only the name of an active term%', 'active term: sequence is fixed');

-- 6. إغلاق السنة
select ok((select v from r where k = 'year.close_busy') like 'ERR 23514%the year has an active term%', 'close_academic_year: refused while a term is active');
select is((select v from r where k = 'year.still_active'), 'active', '… and the year stays active');

-- 3، 5، 7. المسار المميّز: الحارس نفسه
select ok((select v from r where k = 'x.back')         like 'ERR 23514%term transition active -> planned is not allowed%', 'guard: active → planned');
select ok((select v from r where k = 'x.skip')         like 'ERR 23514%term transition planned -> closed is not allowed%', 'guard: planned → closed (skipping active)');
select ok((select v from r where k = 'x.planned_year') like 'ERR 23514%active only in an active academic year%', 'guard: no active term in a planned year');
select ok((select v from r where k = 'x.closed_year')  like 'ERR 23514%academic year is closed — its terms cannot be modified%', 'guard: no active term in a closed year');
select ok((select v from r where k = 'x.closed_term')  like 'ERR 23514%academic year is closed — its terms cannot be modified%', 'guard: a closed term of a closed year stays closed');
select ok((select v from r where k = 'x.move')         like 'ERR 23514%cannot move to another year or school%', 'guard: a term cannot move to another year');
select ok((select v from r where k = 'x.born_active')  like 'ERR 23514%a term is created planned%', 'guard: a term cannot be born in another state');
select ok((select v from r where k = 'x.active_dates') like 'ERR 23514%only the name of an active term%', 'guard: active dates are fixed for every role');

-- 2، 3. active → closed
select is((select v from r where k = 'close.a1'),        '', 'close_term: active → closed (tenant admin, tenant scope)');
select is((select v from r where k = 'close.a1_status'), 'closed', 'the term is closed');
select ok((select v from r where k = 'close.again')  like 'ERR 22023%invalid transition closed -> closed%', 'close_term on a closed term is not a transition');
select ok((select v from r where k = 'close.reopen') like 'ERR 22023%invalid transition closed -> active%', 'a closed term cannot be reopened');
select ok((select v from r where k = 'closed.name')  like 'ERR 23514%is closed and cannot be modified%', 'closed term: the name cannot change');
select ok((select v from r where k = 'closed.noop')  like 'ERR 23514%is closed and cannot be modified%', 'closed term: even a no-op UPDATE is rejected');
select ok((select v from r where k = 'x.reopen')     like 'ERR 23514%is closed and cannot be modified%', 'guard: closed → active is rejected for every role');
select is((select v from r where k = 'next.act') || (select v from r where k = 'next.close'), '', 'the next term is activated after the first closes, then closed');
select is((select v from r where k = 'next.status'), 'closed', 'second term closed');

-- 6 (تتمة). إغلاق السنة وتجمّد فصولها
select is((select v from r where k = 'year.close'),  '', 'close_academic_year succeeds once no term is active');
select is((select v from r where k = 'year.closed'), 'closed', 'the year is closed');
select ok((select v from r where k = 'frozen.edit')     like 'ERR 23514%academic year is closed — its terms cannot be modified%', 'a planned term left in the closed year is frozen');
select ok((select v from r where k = 'frozen.activate') like 'ERR 23514%academic year is not active%', '… and cannot be activated');

-- 9. التدقيق
select is((select v from r where k = 'audit.activate'), 'tenant_user|activate|term starts|planned>active|true|true', 'activate_term is audited: actor, action, reason, old/new state, school');
select is((select v from r where k = 'audit.close'),    'tenant_user|close|term ends|active>closed|true', 'close_term is audited with its own actor and reason');
select is((select v from r where k = 'audit.rejected'), '0', 'a refused transition leaves no audit row');
select is((select v from r where k = 'audit.ctx'),      'none', 'the audit context is empty after every call (allowed or refused)');

-- البنية
select is((select pg_get_triggerdef(t.oid) from pg_trigger t where t.tgrelid = 'public.terms'::regclass and t.tgname = 'guard'),
          'CREATE TRIGGER guard BEFORE INSERT OR UPDATE ON public.terms FOR EACH ROW EXECUTE FUNCTION app.tg_term_guard()', 'T11 is a row-level BEFORE INSERT OR UPDATE trigger on terms');
select is((select pg_get_indexdef('public.terms_active_uq'::regclass)),
          'CREATE UNIQUE INDEX terms_active_uq ON public.terms USING btree (academic_year_id) WHERE (status = ''active''::text)', 'one active term per year is declarative');
select ok(not has_function_privilege('authenticated', 'app.tg_term_guard()', 'EXECUTE') and not has_function_privilege('anon', 'app.tg_term_guard()', 'EXECUTE'),
          'the guard function is not callable by API roles');
select ok(has_function_privilege('authenticated', 'app.activate_term(uuid,text)', 'EXECUTE') and has_function_privilege('authenticated', 'app.close_term(uuid,text)', 'EXECUTE')
      and not has_function_privilege('anon', 'app.activate_term(uuid,text)', 'EXECUTE') and not has_function_privilege('anon', 'app.close_term(uuid,text)', 'EXECUTE'),
          'activate_term / close_term: EXECUTE for authenticated only');
select is((select string_agg(privilege_type || ':' || column_name, ',' order by privilege_type, column_name) from information_schema.column_privileges
            where table_schema = 'public' and table_name = 'terms' and grantee = 'authenticated' and privilege_type in ('INSERT', 'UPDATE')),
          'INSERT:academic_year_id,INSERT:end_date,INSERT:name,INSERT:school_id,INSERT:sequence_no,INSERT:start_date,INSERT:year_end_date,INSERT:year_start_date,UPDATE:end_date,UPDATE:name,UPDATE:sequence_no,UPDATE:start_date',
          'column register: status is not client-writable; a term''s year and school are fixed after creation');
select is((select count(*)::int from public.permissions), 73, 'no new permission key: the catalog is still 73');

select * from finish();
rollback;
