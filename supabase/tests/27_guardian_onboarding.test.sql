-- M27 — guardian_onboarding (F2/D4): النمط على المدرسة، المدرسة الهدف، A/B/C، D4.1، إصدار C
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

create function pg_temp.svc(p_key text, p_sql text) returns void
language plpgsql as $$
begin
  execute 'set local role service_role';
  perform pg_temp.rec(p_key, p_sql);
  execute 'reset role';
end $$;

-- ============ Fixture ============
-- T1: المجموعة GA (SA، SB — نطاق هوية واحد) + SC مستقلة
insert into public.platform_tenants (id, tenant_code, host_label, name) values ('10000000-0000-0000-0000-000000000001', 'T1', 't1', 'T1');
insert into public.groups (id, platform_tenant_id, group_code, name) values ('a1000000-0000-0000-0000-00000000000a', '10000000-0000-0000-0000-000000000001', 'GA', 'GA');
insert into public.schools (id, platform_tenant_id, group_id, school_code, name, slug) values
  ('5a000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', 'a1000000-0000-0000-0000-00000000000a', 'SA', 'SA', 'sa'),
  ('5b000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001', 'a1000000-0000-0000-0000-00000000000a', 'SB', 'SB', 'sb'),
  ('5c000000-0000-0000-0000-000000000003', '10000000-0000-0000-0000-000000000001', null,                                   'SC', 'SC', 'sc');
create temp table sec (code text primary key, school uuid, year uuid, grade uuid, section uuid) on commit drop;
grant select on sec to public;
do $$
declare s record; v_y uuid; v_st uuid; v_g uuid; v_sec uuid;
begin
  for s in select id, school_code from public.schools where platform_tenant_id = '10000000-0000-0000-0000-000000000001' loop
    insert into public.academic_years (school_id, name, start_date, end_date, status) values (s.id, 'Y', '2026-09-01', '2027-06-30', 'active') returning id into v_y;
    insert into public.stages (school_id, name, sequence_no) values (s.id, 'P', 1) returning id into v_st;
    insert into public.grade_levels (school_id, stage_id, name, sequence_no) values (s.id, v_st, 'G1', 1) returning id into v_g;
    insert into public.sections (school_id, academic_year_id, grade_level_id, name) values (s.id, v_y, v_g, 'A') returning id into v_sec;
    insert into sec values (s.school_code, s.id, v_y, v_g, v_sec);
  end loop;
end $$;

create function pg_temp.account(p_id uuid, p_state text default 'active') returns uuid
language plpgsql as $$
declare v_p uuid;
begin
  insert into auth.users (id, email, updated_at) values (p_id, p_id::text || '@m27.invalid', '2026-09-26 10:00+00');
  insert into public.auth_identities (auth_user_id, kind, credential_state) values (p_id, 'tenant', p_state);
  insert into public.profiles (platform_tenant_id, auth_user_id, display_name) values ('10000000-0000-0000-0000-000000000001', p_id, 'x') returning id into v_p;
  return v_p;
end $$;

-- طالب في مدرسة (تسجيل واحد أو تاريخ: [مدرسة سابقة منتهية] ثم الحالية)
create function pg_temp.student(p_id uuid, p_school text, p_prev text default null) returns void
language plpgsql as $$
declare v_p uuid := pg_temp.account(p_id); v_sc public.schools%rowtype; x record;
begin
  select * into v_sc from public.schools where school_code = p_school and platform_tenant_id = '10000000-0000-0000-0000-000000000001';
  insert into public.students (id, platform_tenant_id, identity_scope_id, student_profile_id, temporary_id, first_name, family_name)
    values (p_id, v_sc.platform_tenant_id, (select id from public.identity_scopes where owner_id = v_sc.scope_owner_id), v_p,
            'TMP-2026-' || lpad((floor(random() * 1e6))::int::text, 6, '0'), 'S', 'T');
  if p_prev is not null then
    select * into x from sec where code = p_prev;
    insert into public.enrollments (school_id, student_id, platform_tenant_id, academic_year_id, grade_level_id, section_id,
                                    identity_scope_id, scope_owner_id, effective_from, effective_to, status)
      select x.school, p_id, v_sc.platform_tenant_id, x.year, x.grade, x.section, st.identity_scope_id, v_sc.scope_owner_id,
             '2026-09-01', '2026-09-15', 'transferred' from public.students st where st.id = p_id;
  end if;
  select * into x from sec where code = p_school;
  insert into public.enrollments (school_id, student_id, platform_tenant_id, academic_year_id, grade_level_id, section_id,
                                  identity_scope_id, scope_owner_id, effective_from)
    select x.school, p_id, v_sc.platform_tenant_id, x.year, x.grade, x.section, st.identity_scope_id, v_sc.scope_owner_id,
           case when p_prev is null then date '2026-09-01' else date '2026-09-15' end from public.students st where st.id = p_id;
end $$;

create function pg_temp.guardian(p_id uuid, p_phone text, p_children uuid[], p_state text default 'pending', p_link text default 'active') returns void
language plpgsql as $$
declare v_p uuid := pg_temp.account(p_id, p_state); c uuid;
begin
  insert into public.guardians (id, platform_tenant_id, first_name, family_name, phone_e164, profile_id)
    values (p_id, '10000000-0000-0000-0000-000000000001', 'G', 'X', p_phone, v_p);
  foreach c in array p_children loop
    insert into public.student_guardians (student_id, guardian_id, platform_tenant_id, relationship_type, is_primary,
                                          receives_whatsapp, can_pickup, status, effective_from, effective_to)
      values (c, p_id, '10000000-0000-0000-0000-000000000001', 'father', false, false, false, p_link, '2026-09-01',
              case when p_link = 'ended' then date '2026-09-10' end);
  end loop;
end $$;

select pg_temp.student('e1000000-0000-0000-0000-000000000001', 'SA');
select pg_temp.student('e2000000-0000-0000-0000-000000000002', 'SB');
select pg_temp.student('e3000000-0000-0000-0000-000000000003', 'SC');
select pg_temp.student('e4000000-0000-0000-0000-000000000004', 'SB', 'SA');           -- انتقل من SA إلى SB
select pg_temp.guardian('91000000-0000-0000-0000-000000000001', '+201000000001', array['e1000000-0000-0000-0000-000000000001'::uuid]);                                   -- SA
select pg_temp.guardian('92000000-0000-0000-0000-000000000002', '+201000000002', array['e1000000-0000-0000-0000-000000000001'::uuid, 'e2000000-0000-0000-0000-000000000002'::uuid]);   -- SA + SB
select pg_temp.guardian('93000000-0000-0000-0000-000000000003', '+201000000003', array['e3000000-0000-0000-0000-000000000003'::uuid]);                                   -- SC
select pg_temp.guardian('94000000-0000-0000-0000-000000000004', '+201000000004', array['e4000000-0000-0000-0000-000000000004'::uuid]);                                   -- ابنه انتقل
select pg_temp.guardian('95000000-0000-0000-0000-000000000005', '+201000000005', array['e1000000-0000-0000-0000-000000000001'::uuid], 'pending', 'ended');           -- ارتباط منتهٍ
select pg_temp.guardian('98000000-0000-0000-0000-000000000008', '+201000000008', array['e1000000-0000-0000-0000-000000000001'::uuid, 'e3000000-0000-0000-0000-000000000003'::uuid]);   -- SA (A) + SC (C)
select pg_temp.guardian('96000000-0000-0000-0000-000000000006', '+201000000006', array['e3000000-0000-0000-0000-000000000003'::uuid], 'active');                     -- مُستكمل

-- الفاعلون
create function pg_temp.member(p_auth uuid, p_role text, p_scope_type text, p_school text) returns void
language plpgsql as $$
declare v_p uuid := pg_temp.account(p_auth); v_m uuid;
begin
  insert into public.memberships (platform_tenant_id, profile_id) values ('10000000-0000-0000-0000-000000000001', v_p) returning id into v_m;
  insert into public.membership_roles (membership_id, role_id, platform_tenant_id, role_owner_key)
    values (v_m, (select id from public.roles where code = p_role and platform_tenant_id is null), '10000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000000');
  insert into public.membership_scopes (membership_id, platform_tenant_id, scope_type, school_id)
    values (v_m, '10000000-0000-0000-0000-000000000001', p_scope_type,
            (select id from public.schools where school_code = p_school and platform_tenant_id = '10000000-0000-0000-0000-000000000001'));
end $$;
select pg_temp.member('c1000000-0000-0000-0000-000000000001', 'tenant_admin', 'tenant', null);
select pg_temp.member('c2000000-0000-0000-0000-000000000002', 'school_admin', 'school', 'SA');
select pg_temp.member('c3000000-0000-0000-0000-000000000003', 'secretary',    'school', 'SC');

-- ============ 1. النمط ============
select pg_temp.rec('m.default', $q$select string_agg(guardian_first_login_mode, ',' order by school_code) from public.schools where platform_tenant_id = '10000000-0000-0000-0000-000000000001'$q$);
select pg_temp.rec('m.bad_value', $q$update public.schools set guardian_first_login_mode = 'D' where school_code = 'SA' returning 'ok'$q$);
select pg_temp.run('m.secretary',  'c3000000-0000-0000-0000-000000000003', $q$select app.set_guardian_first_login_mode('5c000000-0000-0000-0000-000000000003', 'B', 'x')$q$);
select pg_temp.run('m.out_scope',  'c2000000-0000-0000-0000-000000000002', $q$select app.set_guardian_first_login_mode('5b000000-0000-0000-0000-000000000002', 'B', 'x')$q$);
select pg_temp.run('m.no_reason',  'c2000000-0000-0000-0000-000000000002', $q$select app.set_guardian_first_login_mode('5a000000-0000-0000-0000-000000000001', 'B', ' ')$q$);
select pg_temp.run('m.bad_mode',   'c2000000-0000-0000-0000-000000000002', $q$select app.set_guardian_first_login_mode('5a000000-0000-0000-0000-000000000001', 'Z', 'x')$q$);
select pg_temp.run('m.direct',     'c1000000-0000-0000-0000-000000000001', $q$update public.schools set guardian_first_login_mode = 'B' where school_code = 'SB' returning 'ok'$q$);
select pg_temp.run('m.set_B',      'c1000000-0000-0000-0000-000000000001', $q$select app.set_guardian_first_login_mode('5b000000-0000-0000-0000-000000000002', 'B', 'pilot')$q$);
select pg_temp.run('m.set_C',      'c1000000-0000-0000-0000-000000000001', $q$select app.set_guardian_first_login_mode('5c000000-0000-0000-0000-000000000003', 'C', 'pilot')$q$);
select pg_temp.rec('m.audit', $q$select string_agg(action || ':' || coalesce(reason, ''), ',') from public.audit_log where entity_type = 'schools' and action = 'set_guardian_first_login_mode'
  and entity_id in ('5b000000-0000-0000-0000-000000000002', '5c000000-0000-0000-0000-000000000003')$q$);

-- ============ 2. الحساب الجديد pending ============
insert into public.guardians (id, platform_tenant_id, first_name, family_name, phone_e164) values ('97000000-0000-0000-0000-000000000007', '10000000-0000-0000-0000-000000000001', 'N', 'N', '+201000000007');
insert into public.student_guardians (student_id, guardian_id, platform_tenant_id, relationship_type, is_primary, receives_whatsapp, can_pickup, status, effective_from)
  values ('e1000000-0000-0000-0000-000000000001', '97000000-0000-0000-0000-000000000007', '10000000-0000-0000-0000-000000000001', 'mother', false, false, false, 'active', '2026-09-01');
insert into auth.users (id, email) values ('97000000-0000-0000-0000-000000000007', 'n@m27.invalid');
select pg_temp.run('p.provision', 'c1000000-0000-0000-0000-000000000001', $q$select (app.provision_account('guardian', '97000000-0000-0000-0000-000000000007', '97000000-0000-0000-0000-000000000007') is not null)::text$q$);
select pg_temp.rec('p.state', $q$select credential_state || '|' || coalesce(credential_issued_at::text, 'null') from public.auth_identities where auth_user_id = '97000000-0000-0000-0000-000000000007'$q$);

-- ============ 3. إصدار OTP: المدرسة الهدف والنمط ============
select pg_temp.svc('o.no_school',      $q$select (app.otp_issue('t1', 'guardian', '+201000000001') is not null)::text$q$);
select pg_temp.svc('o.no_child_there', $q$select (app.otp_issue('t1', 'guardian', '+201000000001', 'sb') is not null)::text$q$);
select pg_temp.svc('o.A',              $q$select (app.otp_issue('t1', 'guardian', '+201000000001', 'SA') is not null)::text$q$);
select pg_temp.svc('o.B',              $q$select (app.otp_issue('t1', 'guardian', '+201000000002', 'sb') is not null)::text$q$);
select pg_temp.svc('o.C',              $q$select (app.otp_issue('t1', 'guardian', '+201000000003', 'sc') is not null)::text$q$);
select pg_temp.svc('o.moved_old',      $q$select (app.otp_issue('t1', 'guardian', '+201000000004', 'sa') is not null)::text$q$);
select pg_temp.svc('o.moved_new',      $q$select (app.otp_issue('t1', 'guardian', '+201000000004', 'sb') is not null)::text$q$);
select pg_temp.svc('o.ended_link',     $q$select (app.otp_issue('t1', 'guardian', '+201000000005', 'sa') is not null)::text$q$);
select pg_temp.svc('o.onboarded_any',  $q$select (app.otp_issue('t1', 'guardian', '+201000000006') is not null)::text$q$);

-- ============ 4. التحقق: A و B ============
select pg_temp.svc('a.code', $q$select app.otp_issue('t1', 'guardian', '+201000000001', 'sa')$q$);
select pg_temp.svc('a.wrong_school', format($q$select coalesce(app.otp_verify('t1', 'guardian', '+201000000001', %L, 'sb')::text, 'null')$q$, (select v from r where k = 'a.code')));
select pg_temp.svc('a.verify', format($q$select app.otp_verify('t1', 'guardian', '+201000000001', %L, 'sa')::text$q$, (select v from r where k = 'a.code')));
select pg_temp.rec('a.state', $q$select credential_state || '|' || (credential_issued_at = '2026-09-26 10:00+00')::text from public.auth_identities where auth_user_id = '91000000-0000-0000-0000-000000000001'$q$);
select pg_temp.run('a.context_closed', '91000000-0000-0000-0000-000000000001', $q$select coalesce(app.current_profile_id()::text, 'NULL')$q$);
-- تغيير الكلمة (إشارة Supabase Auth) ثم التفعيل (D2 بلا تغيير)
insert into auth.audit_log_entries (instance_id, id, payload, created_at, ip_address)
  values ('00000000-0000-0000-0000-000000000000', gen_random_uuid(),
          json_build_object('action', 'user_updated_password', 'actor_id', '91000000-0000-0000-0000-000000000001'), '2026-09-26 11:00+00', '');
select pg_temp.run('a.activate', '91000000-0000-0000-0000-000000000001', $q$select app.activate_first_login()$q$);

select pg_temp.svc('b.code', $q$select app.otp_issue('t1', 'guardian', '+201000000002', 'sb')$q$);
select pg_temp.svc('b.verify', format($q$select app.otp_verify('t1', 'guardian', '+201000000002', %L, 'sb')::text$q$, (select v from r where k = 'b.code')));
select pg_temp.rec('b.state', $q$select credential_state || '|' || (credential_activated_at is not null)::text from public.auth_identities where auth_user_id = '92000000-0000-0000-0000-000000000002'$q$);
select pg_temp.run('b.context_open', '92000000-0000-0000-0000-000000000002', $q$select (app.current_profile_id() is not null)::text$q$);
select pg_temp.rec('ab.audit', $q$select string_agg(distinct action, ',' order by action) from public.audit_log where entity_type = 'auth_identities'
  and entity_id in ('91000000-0000-0000-0000-000000000001', '92000000-0000-0000-0000-000000000002') and action like 'guardian_onboarding_%'$q$);

-- بوابة التحقق مستقلة عن بوابة الإصدار: رمز صدر عبر SA (A) لا يُقبل عبر SC (C)
select pg_temp.svc('g.code', $q$select app.otp_issue('t1', 'guardian', '+201000000008', 'sa')$q$);
select pg_temp.svc('g.verify_via_C', format($q$select coalesce(app.otp_verify('t1', 'guardian', '+201000000008', %L, 'sc')::text, 'null')$q$, (select v from r where k = 'g.code')));
select pg_temp.svc('g.verify_via_A', format($q$select app.otp_verify('t1', 'guardian', '+201000000008', %L, 'sa')::text$q$, (select v from r where k = 'g.code')));

-- D4.1: بعد الـonboarding لا أثر للنمط
select pg_temp.run('d41.set_C', 'c1000000-0000-0000-0000-000000000001', $q$select app.set_guardian_first_login_mode('5b000000-0000-0000-0000-000000000002', 'C', 'switch')$q$);
select pg_temp.svc('d41.otp', $q$select (app.otp_issue('t1', 'guardian', '+201000000002') is not null)::text$q$);

-- ============ 5. C: كلمة مرور مؤقتة ============
select pg_temp.run('c.secretary', 'c3000000-0000-0000-0000-000000000003', $q$select app.begin_guardian_temporary_password('93000000-0000-0000-0000-000000000003')::text$q$);
select pg_temp.run('c.out_scope', 'c2000000-0000-0000-0000-000000000002', $q$select app.begin_guardian_temporary_password('93000000-0000-0000-0000-000000000003')::text$q$);
select pg_temp.run('c.onboarded', 'c1000000-0000-0000-0000-000000000001', $q$select app.begin_guardian_temporary_password('96000000-0000-0000-0000-000000000006')::text$q$);
select pg_temp.run('c.begin',     'c1000000-0000-0000-0000-000000000001', $q$select app.begin_guardian_temporary_password('93000000-0000-0000-0000-000000000003')::text$q$);
update auth.users set updated_at = '2026-09-26 12:00+00' where id = '93000000-0000-0000-0000-000000000003';   -- كتابة Admin API للكلمة
select pg_temp.run('c.arm',       'c1000000-0000-0000-0000-000000000001', $q$select app.arm_guardian_temporary_password('93000000-0000-0000-0000-000000000003')$q$);
select pg_temp.rec('c.state', $q$select credential_state || '|' || (credential_issued_at = '2026-09-26 12:00+00')::text from public.auth_identities where auth_user_id = '93000000-0000-0000-0000-000000000003'$q$);
select pg_temp.svc('c.still_no_otp', $q$select (app.otp_issue('t1', 'guardian', '+201000000003', 'sc') is not null)::text$q$);
select pg_temp.svc('c.password_ok',  $q$select app.password_login_account('t1', 'guardian', '+201000000003')::text$q$);
select pg_temp.run('c.activate_early', '93000000-0000-0000-0000-000000000003', $q$select app.activate_first_login()$q$);
insert into auth.audit_log_entries (instance_id, id, payload, created_at, ip_address)
  values ('00000000-0000-0000-0000-000000000000', gen_random_uuid(),
          json_build_object('action', 'user_updated_password', 'actor_id', '93000000-0000-0000-0000-000000000003'), '2026-09-26 13:00+00', '');
select pg_temp.run('c.activate', '93000000-0000-0000-0000-000000000003', $q$select app.activate_first_login()$q$);

-- ============ 6. الامتيازات ============
select pg_temp.run('x.auth_otp', 'c1000000-0000-0000-0000-000000000001', $q$select app.otp_issue('t1', 'guardian', '+201000000001', 'sa')$q$);
select pg_temp.svc('x.svc_helper', $q$select app.guardian_onboarding_mode('91000000-0000-0000-0000-000000000001', 'sa')$q$);

select plan(41);

select is((select v from r where k = 'm.default'), 'A,A,A', 'D4.2: default mode A');
select ok((select v from r where k = 'm.bad_value')  like 'ERR 23514%schools_guardian_first_login_mode_chk%', 'mode is A|B|C');
select ok((select v from r where k = 'm.secretary')  like 'ERR 42501%forbidden%', 'set mode: without security.manage → forbidden');
select ok((select v from r where k = 'm.out_scope')  like 'ERR P0002%not found%', 'set mode: a school outside the caller''s scope → not found');
select ok((select v from r where k = 'm.no_reason')  like 'ERR 22023%reason required%', 'set mode: a reason is required');
select ok((select v from r where k = 'm.bad_mode')   like 'ERR 22023%mode must be A, B or C%', 'set mode: invalid mode');
select ok((select v from r where k = 'm.direct')     like 'ERR 42501%permission denied%schools%', 'the mode is not client-writable');
select is((select v from r where k = 'm.set_B'), 'B', 'set mode by security.manage in scope');
select is((select v from r where k = 'm.audit'), 'set_guardian_first_login_mode:pilot,set_guardian_first_login_mode:pilot', 'mode changes audited with their reason');

select is((select v from r where k = 'p.provision'), 'true', 'provision_account (guardian)');
select is((select v from r where k = 'p.state'), 'pending|null', 'a new guardian account starts pending (not onboarded)');

select is((select v from r where k = 'o.no_school'),      'false', 'pending: no login-context school → no code');
select is((select v from r where k = 'o.no_child_there'), 'false', 'pending: a school where the guardian has no active child → no code');
select is((select v from r where k = 'o.A'),              'true',  'pending: the child''s school (mode A) → code (slug normalized)');
select is((select v from r where k = 'o.B'),              'true',  'pending: a second child''s school (mode B) → code');
select is((select v from r where k = 'o.C'),              'false', 'pending: mode C disables OTP onboarding');
select is((select v from r where k = 'o.moved_old'),      'false', 'the child''s former school is not a target (latest enrollment — H2)');
select is((select v from r where k = 'o.moved_new'),      'true',  'the child''s current school is');
select is((select v from r where k = 'o.ended_link'),     'false', 'an ended link does not qualify');
select is((select v from r where k = 'o.onboarded_any'),  'true',  'D4.1: an onboarded account needs no school context');

select is((select v from r where k = 'a.wrong_school'), 'null', 'the code does not verify through another school');
select is((select v from r where k = 'a.verify'),  '91000000-0000-0000-0000-000000000001', 'A: the code verifies through the target school');
select is((select v from r where k = 'a.state'),   'pending|true', 'A: onboarding started — pending, issuance from the Supabase Auth clock');
select is((select v from r where k = 'a.context_closed'), 'NULL', 'A: still closed until the password is created');
select is((select v from r where k = 'a.activate'), 'active', 'A: password created ⇒ activate_first_login opens the account (D2 unchanged)');
select is((select v from r where k = 'b.verify'),  '92000000-0000-0000-0000-000000000002', 'B: the code verifies');
select is((select v from r where k = 'b.state'),   'active|true', 'B: OTP alone completes onboarding');
select is((select v from r where k = 'b.context_open'), 'true', 'B: the context opens immediately');
select is((select v from r where k = 'ab.audit'),  'guardian_onboarding_a,guardian_onboarding_b', 'onboarding steps audited by mode');
select is((select v from r where k = 'g.verify_via_C'), 'null', 'the verify gate stands alone: a code issued through an A school is refused through a C school');
select is((select v from r where k = 'g.verify_via_A'), '98000000-0000-0000-0000-000000000008', '… and accepted through the A school');
select is((select v from r where k = 'd41.otp'),   'true', 'D4.1: switching the school to C does not affect an onboarded account');

select ok((select v from r where k = 'c.secretary') like 'ERR 42501%forbidden%', 'C: issuing requires security.manage');
select ok((select v from r where k = 'c.out_scope') like 'ERR P0002%not found%', 'C: a guardian outside the caller''s scope → not found');
select ok((select v from r where k = 'c.onboarded') like 'ERR 23505%already onboarded%', 'C: not for an onboarded account — a reset is a separate flow (5c)');
select is((select v from r where k = 'c.arm'),   'pending', 'C: armed after the password write');
select is((select v from r where k = 'c.state'), 'pending|true', 'C: issuance time from auth.users.updated_at');
select is((select v from r where k = 'c.still_no_otp'), 'false', 'C: still no OTP onboarding');
select is((select v from r where k = 'c.password_ok'),  '93000000-0000-0000-0000-000000000003', 'C: the temporary password path is open');
select is((select v from r where k = 'c.activate_early') || '→' || (select v from r where k = 'c.activate'), 'pending→active', 'C: forced change — active only after the guardian''s own change');

select ok((select v from r where k = 'x.auth_otp') like 'ERR 42501%permission denied for function otp_issue%'
      and (select v from r where k = 'x.svc_helper') like 'ERR 42501%permission denied for function guardian_onboarding_mode%',
          'otp_* for service_role only; the onboarding helper for no one');

select * from finish();
rollback;
