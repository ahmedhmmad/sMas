-- M25 — first_login_credential (F2/D2 الخيار B): الحالة، بوابة الجذر، arm، activate بالشروط التسعة
-- سجل Supabase Auth يُحاكى هنا بإدراج صفوف auth.audit_log_entries بالصيغة التي أثبتها V9b؛ السلوك الحقيقي
-- لـSupabase Auth يحرسه عقد pytest (services/api/tests/test_auth_contract.py).
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

create function pg_temp.run(p_key text, p_sub uuid, p_sql text, p_role text default 'authenticated') returns void
language plpgsql as $$
begin
  perform set_config('request.jwt.claims', case when p_sub is null then '' else json_build_object('sub', p_sub, 'role', 'authenticated')::text end, true);
  perform set_config('request.jwt.claim.sub', coalesce(p_sub::text, ''), true);
  execute format('set local role %I', p_role);
  perform pg_temp.rec(p_key, p_sql);
  execute 'reset role';
end $$;

-- حدث في سجل Supabase Auth
create function pg_temp.ev(p_user uuid, p_action text, p_actor text, p_at timestamptz) returns void
language sql as $$
  insert into auth.audit_log_entries (instance_id, id, payload, created_at, ip_address)
  values ('00000000-0000-0000-0000-000000000000', gen_random_uuid(),
          json_build_object('action', p_action, 'actor_id', p_actor, 'traits', json_build_object('user_id', p_user)), p_at, '');
$$;

-- ============ Fixture ============
insert into public.platform_tenants (id, tenant_code, name) values ('10000000-0000-0000-0000-000000000001', 'T1', 'T1');
insert into public.schools (id, platform_tenant_id, group_id, school_code, name, slug) values
  ('55000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', null, 'SA', 'SA', 'sa'),
  ('55000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001', null, 'SB', 'SB', 'sb');
create temp table sec (code text primary key, id uuid) on commit drop;
grant select on sec to public;
do $$
declare s record; v_y uuid; v_st uuid; v_g uuid; v_sec uuid;
begin
  for s in select id, school_code from public.schools where platform_tenant_id = '10000000-0000-0000-0000-000000000001' loop
    insert into public.academic_years (school_id, name, start_date, end_date, status) values (s.id, 'Y', '2026-09-01', '2027-06-30', 'active') returning id into v_y;
    insert into public.stages (school_id, name, sequence_no) values (s.id, 'P', 1) returning id into v_st;
    insert into public.grade_levels (school_id, stage_id, name, sequence_no) values (s.id, v_st, 'G1', 1) returning id into v_g;
    insert into public.sections (school_id, academic_year_id, grade_level_id, name) values (s.id, v_y, v_g, 'A') returning id into v_sec;
    insert into sec values (s.school_code, v_sec);
  end loop;
end $$;

-- فاعلون: سكرتير SA (دور secretary المبذور)، سكرتير SB، بلا صلاحيات
create function pg_temp.member(p_auth uuid, p_role text, p_school text) returns void
language plpgsql as $$
declare v_p uuid; v_m uuid;
begin
  insert into auth.users (id, email) values (p_auth, p_auth::text || '@m25.invalid');
  insert into public.auth_identities (auth_user_id, kind) values (p_auth, 'tenant');
  insert into public.profiles (platform_tenant_id, auth_user_id, display_name) values ('10000000-0000-0000-0000-000000000001', p_auth, 'm') returning id into v_p;
  insert into public.memberships (platform_tenant_id, profile_id) values ('10000000-0000-0000-0000-000000000001', v_p) returning id into v_m;
  if p_role is not null then
    insert into public.membership_roles (membership_id, role_id, platform_tenant_id, role_owner_key)
      values (v_m, (select id from public.roles where code = p_role and platform_tenant_id is null), '10000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000000');
  end if;
  insert into public.membership_scopes (membership_id, platform_tenant_id, scope_type, school_id)
    values (v_m, '10000000-0000-0000-0000-000000000001', 'school', (select id from public.schools where school_code = p_school and platform_tenant_id = '10000000-0000-0000-0000-000000000001'));
end $$;
select pg_temp.member('a1000000-0000-0000-0000-00000000000a', 'secretary', 'SA');
select pg_temp.member('a2000000-0000-0000-0000-00000000000b', 'secretary', 'SB');
select pg_temp.member('a3000000-0000-0000-0000-00000000000c', null,        'SA');

-- طلاب عبر provision_student (المسار الحقيقي) — الحساب = معرّف الطالب (D1)
create function pg_temp.new_student(p_id uuid) returns void
language plpgsql as $$
begin
  insert into auth.users (id, email, updated_at) values (p_id, p_id::text || '@students.smas.invalid', '2026-09-26 10:00+00');
  perform pg_temp.run('prov:' || p_id, 'a1000000-0000-0000-0000-00000000000a',
    format($q$select app.provision_student(%L, %L, %L, '2026-09-01', 'S', 'T')::text$q$, p_id, p_id, (select id from sec where code = 'SA')));
end $$;
select pg_temp.new_student('e1000000-0000-0000-0000-000000000001');   -- المسار الرئيسي
select pg_temp.new_student('e2000000-0000-0000-0000-000000000002');   -- لم يُصدَر (بلا arm)
select pg_temp.new_student('e3000000-0000-0000-0000-000000000003');   -- حدث قبل الإصدار فقط
select pg_temp.new_student('e4000000-0000-0000-0000-000000000004');   -- حدث user_modified فقط / فاعل آخر
select pg_temp.new_student('e5000000-0000-0000-0000-000000000005');   -- user_modified بفاعل = الحساب نفسه (V9b: يكتبه Auth بعد تعديلات المستخدم)

-- حساب منصة
insert into auth.users (id, email) values ('b0000000-0000-0000-0000-00000000000b', 'pa@m25.invalid');
insert into public.auth_identities (auth_user_id, kind) values ('b0000000-0000-0000-0000-00000000000b', 'platform');

-- ============ 1. البنية والقيود ============
select pg_temp.rec('c.platform_pending', $q$update public.auth_identities set credential_state = 'pending' where auth_user_id = 'b0000000-0000-0000-0000-00000000000b' returning 'ok'$q$);
select pg_temp.rec('c.bad_state',        $q$update public.auth_identities set credential_state = 'locked' where auth_user_id = 'e1000000-0000-0000-0000-000000000001' returning 'ok'$q$);
select pg_temp.rec('c.activated_pending',$q$update public.auth_identities set credential_activated_at = now() where auth_user_id = 'e1000000-0000-0000-0000-000000000001' returning 'ok'$q$);
select pg_temp.rec('c.provisioned',      $q$select credential_state || '|' || coalesce(credential_issued_at::text, 'null') from public.auth_identities where auth_user_id = 'e1000000-0000-0000-0000-000000000001'$q$);
select pg_temp.rec('c.others_active',    $q$select string_agg(distinct credential_state, ',') from public.auth_identities
     where auth_user_id in ('a1000000-0000-0000-0000-00000000000a', 'a2000000-0000-0000-0000-00000000000b', 'a3000000-0000-0000-0000-00000000000c', 'b0000000-0000-0000-0000-00000000000b')$q$);

-- ============ 2. بوابة الجذر أثناء pending ============
select pg_temp.run('g.pending_profile', 'e1000000-0000-0000-0000-000000000001', $q$select coalesce(app.current_profile_id()::text, 'NULL') || '|' || coalesce(app.current_tenant_id()::text, 'NULL')$q$);
select pg_temp.run('g.pending_rows',    'e1000000-0000-0000-0000-000000000001', $q$select count(*)::text from public.students$q$);
select pg_temp.run('g.client_write',    'e1000000-0000-0000-0000-000000000001', $q$update public.auth_identities set credential_state = 'active' returning 'ok'$q$);

-- ============ 3. arm ============
select pg_temp.run('arm.nop',   'a3000000-0000-0000-0000-00000000000c', $q$select app.arm_first_login('e1000000-0000-0000-0000-000000000001')$q$);
select pg_temp.run('arm.other', 'a2000000-0000-0000-0000-00000000000b', $q$select app.arm_first_login('e1000000-0000-0000-0000-000000000001')$q$);
select pg_temp.run('arm.ok',    'a1000000-0000-0000-0000-00000000000a', $q$select app.arm_first_login('e1000000-0000-0000-0000-000000000001')$q$);
select pg_temp.rec('arm.issued', $q$select (credential_issued_at = '2026-09-26 10:00+00')::text from public.auth_identities where auth_user_id = 'e1000000-0000-0000-0000-000000000001'$q$);
update auth.users set updated_at = '2026-09-26 12:00+00' where id = 'e1000000-0000-0000-0000-000000000001';
select pg_temp.run('arm.again', 'a1000000-0000-0000-0000-00000000000a', $q$select app.arm_first_login('e1000000-0000-0000-0000-000000000001')$q$);
select pg_temp.rec('arm.unmoved', $q$select (credential_issued_at = '2026-09-26 10:00+00')::text from public.auth_identities where auth_user_id = 'e1000000-0000-0000-0000-000000000001'$q$);
select pg_temp.run('arm.e3', 'a1000000-0000-0000-0000-00000000000a', $q$select app.arm_first_login('e3000000-0000-0000-0000-000000000003')$q$);
select pg_temp.run('arm.e4', 'a1000000-0000-0000-0000-00000000000a', $q$select app.arm_first_login('e4000000-0000-0000-0000-000000000004')$q$);
select pg_temp.run('arm.e5', 'a1000000-0000-0000-0000-00000000000a', $q$select app.arm_first_login('e5000000-0000-0000-0000-000000000005')$q$);

-- ============ 4. activate — الرفض قبل الإشارة الصالحة ============
select pg_temp.run('act.service',    null, $q$select app.activate_first_login()$q$, 'service_role');
select pg_temp.run('act.no_claims',  null, $q$select app.activate_first_login()$q$);
select pg_temp.run('act.platform',   'b0000000-0000-0000-0000-00000000000b', $q$select app.activate_first_login()$q$);
select pg_temp.run('act.no_event',   'e1000000-0000-0000-0000-000000000001', $q$select app.activate_first_login()$q$);
-- e2: حدث صالح لكن الكلمة لم تُصدَر (arm لم يحدث)
select pg_temp.ev('e2000000-0000-0000-0000-000000000002', 'user_updated_password', 'e2000000-0000-0000-0000-000000000002', '2026-09-26 11:00+00');
select pg_temp.run('act.not_issued', 'e2000000-0000-0000-0000-000000000002', $q$select app.activate_first_login()$q$);
-- e3: حدث صالح الصيغة لكن قبل الإصدار
select pg_temp.ev('e3000000-0000-0000-0000-000000000003', 'user_updated_password', 'e3000000-0000-0000-0000-000000000003', '2026-09-26 09:00+00');
select pg_temp.run('act.before',     'e3000000-0000-0000-0000-000000000003', $q$select app.activate_first_login()$q$);
-- e4: كتابة المدير (user_modified بـservice_role)، و user_updated_password بفاعل آخر
select pg_temp.ev('e4000000-0000-0000-0000-000000000004', 'user_modified', '00000000-0000-0000-0000-000000000000', '2026-09-26 11:00+00');
select pg_temp.ev('e4000000-0000-0000-0000-000000000004', 'user_updated_password', 'a1000000-0000-0000-0000-00000000000a', '2026-09-26 11:00+00');
select pg_temp.run('act.admin_or_other', 'e4000000-0000-0000-0000-000000000004', $q$select app.activate_first_login()$q$);
select pg_temp.ev('e5000000-0000-0000-0000-000000000005', 'user_modified', 'e5000000-0000-0000-0000-000000000005', '2026-09-26 11:00+00');
select pg_temp.run('act.self_modified', 'e5000000-0000-0000-0000-000000000005', $q$select app.activate_first_login()$q$);
-- حدث صالح لـe1 لا يفعّل e4 (الحساب = auth.uid() وحده)
select pg_temp.ev('e1000000-0000-0000-0000-000000000001', 'user_updated_password', 'e1000000-0000-0000-0000-000000000001', '2026-09-26 09:30+00');   -- قبل الإصدار
select pg_temp.ev('e1000000-0000-0000-0000-000000000001', 'user_updated_password', 'e1000000-0000-0000-0000-000000000001', '2026-09-26 11:00+00');   -- صالح
select pg_temp.ev('e1000000-0000-0000-0000-000000000001', 'user_modified', '00000000-0000-0000-0000-000000000000', '2026-09-26 11:30+00');           -- لاحق غير صالح
select pg_temp.run('act.cross',      'e4000000-0000-0000-0000-000000000004', $q$select app.activate_first_login()$q$);
select pg_temp.rec('act.states_before', $q$select string_agg(auth_user_id::text || ':' || credential_state, ',' order by auth_user_id) from public.auth_identities
     where auth_user_id in ('e1000000-0000-0000-0000-000000000001', 'e2000000-0000-0000-0000-000000000002', 'e3000000-0000-0000-0000-000000000003',
                            'e4000000-0000-0000-0000-000000000004', 'e5000000-0000-0000-0000-000000000005')$q$);

-- ============ 5. activate — النجاح، التدقيق، idempotency ============
create temp table audit_mark as select coalesce(max(id), 0) as m from public.audit_log;
grant select on audit_mark to public;
select pg_temp.run('act.ok',     'e1000000-0000-0000-0000-000000000001', $q$select app.activate_first_login()$q$);
select pg_temp.run('act.ctx',    'e1000000-0000-0000-0000-000000000001', $q$select coalesce(current_setting('app.audit_action', true), '') || '|' || coalesce(current_setting('app.audit_reason', true), '')$q$);
select pg_temp.rec('act.audit',  $q$select string_agg(action || ':' || actor_type || ':' || (actor_id = (select id from public.profiles where auth_user_id = 'e1000000-0000-0000-0000-000000000001'))::text, ',')
  from public.audit_log where id > (select m from audit_mark) and entity_type = 'auth_identities'$q$);
select pg_temp.rec('act.row',    $q$select credential_state || '|' || (credential_activated_at is not null)::text from public.auth_identities where auth_user_id = 'e1000000-0000-0000-0000-000000000001'$q$);
select pg_temp.run('act.again',  'e1000000-0000-0000-0000-000000000001', $q$select app.activate_first_login()$q$);
select pg_temp.rec('act.again_audit', $q$select count(*)::text from public.audit_log where id > (select m from audit_mark) and entity_type = 'auth_identities'$q$);
select pg_temp.run('g.active_profile', 'e1000000-0000-0000-0000-000000000001', $q$select ((app.current_profile_id() is not null) and (app.current_tenant_id() = '10000000-0000-0000-0000-000000000001'))::text$q$);
select pg_temp.run('g.active_rows',    'e1000000-0000-0000-0000-000000000001', $q$select count(*)::text from public.students$q$);
select pg_temp.run('arm.active', 'a1000000-0000-0000-0000-00000000000a', $q$select app.arm_first_login('e1000000-0000-0000-0000-000000000001')$q$);

select plan(36);

select ok((select v from r where k = 'c.platform_pending') like 'ERR 23514%auth_identities_credential_kind_chk%', 'a platform account cannot be pending (D2 is for tenant accounts)');
select ok((select v from r where k = 'c.bad_state')        like 'ERR 23514%auth_identities_credential_state_chk%', 'credential_state is active|pending');
select ok((select v from r where k = 'c.activated_pending') like 'ERR 23514%auth_identities_credential_activated_chk%', 'activated_at implies active');
select is((select v from r where k = 'c.provisioned'),     'pending|null', 'provision_student creates the account pending and not yet issued');
select is((select v from r where k = 'c.others_active'),   'active', 'existing and non-student accounts stay active (default)');

select is((select v from r where k = 'g.pending_profile'), 'NULL|NULL', 'pending: current_profile_id and current_tenant_id are NULL (root gate)');
select is((select v from r where k = 'g.pending_rows'),    '0', 'pending: RLS returns nothing');
select ok((select v from r where k = 'g.client_write')     like 'ERR 42501%permission denied%auth_identities%', 'a client cannot write the credential state');

select ok((select v from r where k = 'arm.nop')   like 'ERR 42501%forbidden%', 'arm: without student.create → forbidden');
select ok((select v from r where k = 'arm.other') like 'ERR P0002%not found%', 'arm: a student outside the caller''s scope → not found');
select is((select v from r where k = 'arm.ok'),     'pending', 'arm: records the issuance');
select is((select v from r where k = 'arm.issued'), 'true', 'arm: issuance time = auth.users.updated_at after the temporary password write (Supabase Auth clock)');
select is((select v from r where k = 'arm.again'),  'pending', 'arm again: no-op');
select is((select v from r where k = 'arm.unmoved'),'true', 'arm again does not move the issuance time (re-issuance is a separate flow — 5c)');

select ok((select v from r where k = 'act.service')   like 'ERR 42501%permission denied for function activate_first_login%', '(9) service_role cannot even execute the activation (EXECUTE for authenticated only)');
select ok((select v from r where k = 'act.no_claims') like 'ERR 42501%forbidden%', '(9) no JWT → forbidden');
select ok((select v from r where k = 'act.platform')  like 'ERR 42501%forbidden%', 'platform accounts have no first-login state');
select is((select v from r where k = 'act.no_event'),       'pending', '(3) no Auth event → stays pending');
select is((select v from r where k = 'act.not_issued'),     'pending', '(5) never issued → stays pending even with a valid-looking event');
select is((select v from r where k = 'act.before'),         'pending', '(5) an event before the issuance does not count');
select is((select v from r where k = 'act.admin_or_other'), 'pending', '(4)(6) user_modified by service_role, or user_updated_password by another actor → pending');
select is((select v from r where k = 'act.self_modified'), 'pending', '(6) user_modified — even by the account itself — is not the first-login signal');
select is((select v from r where k = 'act.cross'),          'pending', '(2) another account''s valid event does not activate me');
select is((select v from r where k = 'act.states_before'),
          'e1000000-0000-0000-0000-000000000001:pending,e2000000-0000-0000-0000-000000000002:pending,e3000000-0000-0000-0000-000000000003:pending,e4000000-0000-0000-0000-000000000004:pending,e5000000-0000-0000-0000-000000000005:pending',
          'fail closed: every refusal left the account pending');

select is((select v from r where k = 'act.ok'),   'active', 'valid event after issuance (among earlier invalid and later user_modified rows — EXISTS, not the last row) → active');
select is((select v from r where k = 'act.ctx'),  '|', 'audit context reset after the write (M21 requirement)');
select is((select v from r where k = 'act.audit'),'activate_first_login:tenant_user:true', '(8) audited as activate_first_login by the account itself');
select is((select v from r where k = 'act.row'),  'active|true', 'state active and activated_at stamped');
select is((select v from r where k = 'act.again'),'active', '(7) idempotent');
select is((select v from r where k = 'act.again_audit'), '1', '(7) a second call writes nothing');
select is((select v from r where k = 'g.active_profile'), 'true', 'active: the root context opens');
select is((select v from r where k = 'g.active_rows'), '1', 'active: the student sees their own row');
select is((select v from r where k = 'arm.active'), 'active', 'arm on an active account changes nothing');

select is((select string_agg(p.proname || '=' || pg_get_userbyid(p.proowner) || ':' || coalesce(array_to_string(p.proconfig, ','), '-') || ':' ||
                   (select string_agg(g.rolname, '+' order by g.rolname) from aclexplode(p.proacl) a join pg_roles g on g.oid = a.grantee where a.privilege_type = 'EXECUTE'),
                   ',' order by p.proname) from pg_proc p
            where p.oid in ('app.auth_user_updated_at(uuid)'::regprocedure, 'app.auth_password_changed_by_self_after(uuid,timestamptz)'::regprocedure)),
          'auth_password_changed_by_self_after=postgres:search_path="":app_owner+postgres,auth_user_updated_at=postgres:search_path="":app_owner+postgres',
          'schema auth is read through two R2-style helpers (postgres-owned, empty search_path, EXECUTE for app_owner only) returning a timestamp and a boolean');
select is((select string_agg(p.oid::regprocedure::text || '=' || pg_get_userbyid(p.proowner) || ':' || p.prosecdef, ',' order by p.proname) from pg_proc p
            where p.oid in ('app.arm_first_login(uuid)'::regprocedure, 'app.activate_first_login()'::regprocedure)),
          'app.activate_first_login()=app_owner:true,app.arm_first_login(uuid)=app_owner:true', 'owned by app_owner, SECURITY DEFINER (R2)');
select ok(not has_function_privilege('anon', 'app.activate_first_login()', 'execute') and not has_function_privilege('anon', 'app.arm_first_login(uuid)', 'execute'), 'anon cannot execute');

select * from finish();
rollback;
