-- M30 — tenant_host_context (F3): host_label، ودوال الدخول تبحث داخل سياق الـhost
-- يثبت: القيد (DNS، محجوز، فريد، ليس tenant_code، لا يكتبه العميل)؛ البحث بالـlabel لا بالرمز؛ الـslug نفسه في
-- Tenantين بلا تصادم؛ سياق مدرسة مؤرشفة/غير موجودة أو Tenant موقوف ⇒ لا حساب (NULL واحد)؛ bootstrap_tenant؛
-- والـlabel ليس مدخل تفويض (لا سياسة ولا دالة غير المحلّل و bootstrap تقرؤه).
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

-- كما يستدعيها FastAPI قبل JWT: دور service_role
create function pg_temp.svc(p_key text, p_sql text) returns void
language plpgsql as $$
begin
  execute 'set local role service_role';
  perform pg_temp.rec(p_key, p_sql);
  execute 'reset role';
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

-- ============ Fixture ============
-- A: رمز الأعمال T_A (بشرطة سفلية) ≠ الـlabel tenant-a · B: الـslug نفسه school-a · C: موقوف
insert into public.platform_tenants (id, tenant_code, host_label, name, status, suspended_at) values
  ('10000000-0000-0000-0000-000000000001', 'T_A', 'tenant-a', 'A', 'active', null),
  ('20000000-0000-0000-0000-000000000002', 'TB',  'tenant-b', 'B', 'active', null),
  ('30000000-0000-0000-0000-000000000003', 'TC',  'tenant-c', 'C', 'suspended', now());
insert into public.schools (id, platform_tenant_id, school_code, name, slug) values
  ('5a000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', 'SA', 'SA', 'school-a'),
  ('5c000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001', 'SX', 'SX', 'closed-a'),
  ('5b000000-0000-0000-0000-000000000003', '20000000-0000-0000-0000-000000000002', 'SA', 'SA', 'school-a'),
  ('5d000000-0000-0000-0000-000000000004', '30000000-0000-0000-0000-000000000003', 'SA', 'SA', 'school-a');
update public.schools set status = 'archived', archived_at = now() where id = '5c000000-0000-0000-0000-000000000002';

create function pg_temp.account(p_id uuid, p_tenant uuid) returns uuid
language plpgsql as $$
declare v uuid;
begin
  insert into auth.users (id, email) values (p_id, p_id::text || '@m30.invalid');
  insert into public.auth_identities (auth_user_id, kind) values (p_id, 'tenant');
  insert into public.profiles (platform_tenant_id, auth_user_id, display_name) values (p_tenant, p_id, 'x') returning id into v;
  return v;
end $$;
create function pg_temp.student(p_id uuid, p_tenant uuid, p_school uuid, p_official text) returns void
language plpgsql as $$
declare v_profile uuid := pg_temp.account(p_id, p_tenant);
begin
  insert into public.students (id, platform_tenant_id, identity_scope_id, student_profile_id, official_id, official_id_type, first_name, family_name)
    select p_id, p_tenant, i.id, v_profile, p_official, 'national_id', 'S', 'T'
    from public.schools sc join public.identity_scopes i on i.owner_id = sc.scope_owner_id where sc.id = p_school;
end $$;
create function pg_temp.staff(p_id uuid, p_tenant uuid, p_email text) returns void
language plpgsql as $$
declare v_profile uuid := pg_temp.account(p_id, p_tenant);
begin
  insert into public.staff (id, platform_tenant_id, employee_code, first_name, family_name, email, profile_id)
    values (p_id, p_tenant, 'E1', 'S', 'X', p_email, v_profile);
end $$;
create function pg_temp.guardian(p_id uuid, p_tenant uuid, p_phone text) returns void
language plpgsql as $$
declare v_profile uuid := pg_temp.account(p_id, p_tenant);
begin
  insert into public.guardians (id, platform_tenant_id, first_name, family_name, phone_e164, profile_id)
    values (p_id, p_tenant, 'G', 'X', p_phone, v_profile);
end $$;

-- الطالب نفسه (المعرّف نفسه) في مدرستين بالـslug نفسه في Tenantين
select pg_temp.student('e1000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', '5a000000-0000-0000-0000-000000000001', '111');
select pg_temp.student('e2000000-0000-0000-0000-000000000002', '20000000-0000-0000-0000-000000000002', '5b000000-0000-0000-0000-000000000003', '111');
select pg_temp.student('e3000000-0000-0000-0000-000000000003', '30000000-0000-0000-0000-000000000003', '5d000000-0000-0000-0000-000000000004', '111');
select pg_temp.staff('a1000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', 'teacher@m30.test');
select pg_temp.staff('a2000000-0000-0000-0000-000000000002', '20000000-0000-0000-0000-000000000002', 'teacher@m30.test');
select pg_temp.staff('a3000000-0000-0000-0000-000000000003', '30000000-0000-0000-0000-000000000003', 'teacher@m30.test');
select pg_temp.guardian('91000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', '+201000000001');

-- Platform Admin بـtenant.create (للـbootstrap) + tenant_admin لـA (للكتابة المباشرة)
insert into public.platform_admin_roles (id, code, name) values ('81000000-0000-0000-0000-000000000001', 'zt_creator', 'Creator');
insert into public.platform_admin_role_permissions select '81000000-0000-0000-0000-000000000001', id from public.permissions where code = 'tenant.create';
insert into auth.users (id, email) values ('b1000000-0000-0000-0000-000000000001', 'pa@m30.invalid');
insert into public.auth_identities (auth_user_id, kind) values ('b1000000-0000-0000-0000-000000000001', 'platform');
insert into public.system_users (id, auth_user_id, display_name) values ('b1000000-0000-0000-0000-000000000001', 'b1000000-0000-0000-0000-000000000001', 'pa');
insert into public.platform_admin_assignments (system_user_id, platform_admin_role_id)
  values ('b1000000-0000-0000-0000-000000000001', '81000000-0000-0000-0000-000000000001');
with m as (insert into public.memberships (platform_tenant_id, profile_id)
             select '10000000-0000-0000-0000-000000000001', pg_temp.account('c1000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001')
           returning id),
     s as (insert into public.membership_scopes (membership_id, platform_tenant_id, scope_type) select id, '10000000-0000-0000-0000-000000000001', 'tenant' from m)
insert into public.membership_roles (membership_id, role_id, platform_tenant_id, role_owner_key)
  select m.id, r.id, '10000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000000'
  from m, public.roles r where r.code = 'tenant_admin' and r.platform_tenant_id is null;

-- ============ 1. القيد ============
create function pg_temp.ins(p_key text, p_code text, p_label text) returns void language sql as $$
  select pg_temp.rec(p_key, format($f$insert into public.platform_tenants (tenant_code, host_label, name) values (%L, %L, 'x') returning 'ok'$f$, p_code, p_label)) $$;
select pg_temp.ins('c.upper',      'X1', 'Tenant');
select pg_temp.ins('c.underscore', 'X2', 't_x');
select pg_temp.ins('c.lead_dash',  'X3', '-tx');
select pg_temp.ins('c.dot',        'X4', 'a.b');
select pg_temp.ins('c.empty',      'X5', '');
select pg_temp.ins('c.too_long',   'X6', repeat('a', 64));
select pg_temp.ins('c.max_len',    'X7', repeat('a', 63));
select pg_temp.ins('c.one_char',   'X8', 'x');
select pg_temp.ins('c.admin',      'X9', 'admin');
select pg_temp.ins('c.api',        'XA', 'api');
select pg_temp.ins('c.www',        'XB', 'www');
select pg_temp.ins('c.dup',        'XC', 'tenant-a');
select pg_temp.ins('c.null',       'XD', null);
select pg_temp.rec('c.tenant_code_kept', $q$select tenant_code from public.platform_tenants where host_label = 'tenant-a'$q$);

-- لا يكتبه العميل
select pg_temp.run('w.update', 'c1000000-0000-0000-0000-000000000001',
  $q$update public.platform_tenants set host_label = 'hijack' where id = '10000000-0000-0000-0000-000000000001' returning 'ok'$q$);
select pg_temp.run('w.read_own', 'c1000000-0000-0000-0000-000000000001', $q$select string_agg(host_label, ',') from public.platform_tenants$q$);

-- ============ 2. البحث داخل سياق الـhost ============
-- الطالب: الـslug نفسه في Tenantين ⇒ حسابان مختلفان بلا تصادم
select pg_temp.svc('st.a',          $q$select app.resolve_student_login('tenant-a', 'school-a', '111')::text$q$);
select pg_temp.svc('st.b',          $q$select app.resolve_student_login('tenant-b', 'school-a', '111')::text$q$);
select pg_temp.svc('st.by_code',    $q$select app.resolve_student_login('T_A', 'school-a', '111')::text$q$);          -- رمز الأعمال ليس label
select pg_temp.svc('st.code_lower', $q$select app.resolve_student_login('t_a', 'school-a', '111')::text$q$);
select pg_temp.svc('st.no_school',  $q$select app.resolve_student_login('tenant-a', null, '111')::text$q$);           -- سياق Tenant: لا طالب
select pg_temp.svc('st.archived',   $q$select app.resolve_student_login('tenant-a', 'closed-a', '111')::text$q$);
select pg_temp.svc('st.suspended',  $q$select app.resolve_student_login('tenant-c', 'school-a', '111')::text$q$);
-- الموظف: host الـTenant أو host مدرسة نشطة فيه؛ مدرسة مؤرشفة/غير موجودة/من Tenant آخر ⇒ لا شيء
select pg_temp.svc('sf.tenant_host',  $q$select app.password_login_account('tenant-a', 'staff', 'teacher@m30.test')::text$q$);
select pg_temp.svc('sf.school_host',  $q$select app.password_login_account('tenant-a', 'staff', 'teacher@m30.test', 'school-a')::text$q$);
select pg_temp.svc('sf.tenant_b',     $q$select app.password_login_account('tenant-b', 'staff', 'teacher@m30.test', 'school-a')::text$q$);
select pg_temp.svc('sf.archived',     $q$select app.password_login_account('tenant-a', 'staff', 'teacher@m30.test', 'closed-a')::text$q$);
select pg_temp.svc('sf.unknown',      $q$select app.password_login_account('tenant-a', 'staff', 'teacher@m30.test', 'nope')::text$q$);
select pg_temp.svc('sf.suspended',    $q$select app.password_login_account('tenant-c', 'staff', 'teacher@m30.test')::text$q$);
select pg_temp.svc('sf.unknown_tenant', $q$select app.password_login_account('tenant-z', 'staff', 'teacher@m30.test')::text$q$);
select pg_temp.svc('sf.by_code',      $q$select app.password_login_account('T_A', 'staff', 'teacher@m30.test')::text$q$);
-- OTP (ولي أمر مُستكمل): السياق نفسه
select pg_temp.svc('g.school_host', $q$select (app.otp_issue('tenant-a', 'guardian', '+201000000001', 'school-a') is not null)::text$q$);
select pg_temp.svc('g.archived',    $q$select (app.otp_issue('tenant-a', 'guardian', '+201000000001', 'closed-a') is not null)::text$q$);
select pg_temp.svc('g.verify_archived', $q$select coalesce(app.otp_verify('tenant-a', 'guardian', '+201000000001', '000000', 'closed-a')::text, 'null')$q$);
-- نتيجة كلمة المرور في سياق غير صالح لا تمس الحساب
select pg_temp.svc('pr.archived', $q$select app.password_login_result('tenant-a', 'staff', 'teacher@m30.test', false, 'closed-a')::text$q$);
select pg_temp.rec('pr.count', $q$select failed_login_count::text from public.staff where id = 'a1000000-0000-0000-0000-000000000001'$q$);

-- ============ 3. bootstrap_tenant ============
create function pg_temp.bt(p_id uuid, p_code text, p_label text) returns text language sql as $$
  select format($f$select app.bootstrap_tenant(%L, %L, %L, 'New', 'b2000000-0000-0000-0000-000000000002', 'Admin')::text$f$, p_id, p_code, p_label) $$;
insert into auth.users (id, email) values ('b2000000-0000-0000-0000-000000000002', 'adm@m30.invalid');
select pg_temp.run('bt.reserved', 'b1000000-0000-0000-0000-000000000001', pg_temp.bt('40000000-0000-0000-0000-000000000004', 'T4', 'admin'));
select pg_temp.run('bt.ok',       'b1000000-0000-0000-0000-000000000001', pg_temp.bt('40000000-0000-0000-0000-000000000004', 'T_4', 'tenant-4'));
select pg_temp.run('bt.again',    'b1000000-0000-0000-0000-000000000001', pg_temp.bt('40000000-0000-0000-0000-000000000004', 'T_4', 'tenant-4'));
select pg_temp.run('bt.relabel',  'b1000000-0000-0000-0000-000000000001', pg_temp.bt('40000000-0000-0000-0000-000000000004', 'T_4', 'other-4'));
select pg_temp.rec('bt.row',   $q$select tenant_code || '|' || host_label from public.platform_tenants where id = '40000000-0000-0000-0000-000000000004'$q$);
select pg_temp.rec('bt.audit', $q$select new_values->>'host_label' from public.audit_log
  where entity_type = 'platform_tenants' and entity_id = '40000000-0000-0000-0000-000000000004' and action = 'insert'$q$);

select plan(49);

-- ---------- القيد ----------
select ok((select v from r where k = 'c.upper')      like 'ERR 23514%platform_tenants_host_label_chk%', 'label: uppercase refused (DNS labels are lowercase here)');
select ok((select v from r where k = 'c.underscore') like 'ERR 23514%platform_tenants_host_label_chk%', 'label: underscore refused (why tenant_code cannot be the label)');
select ok((select v from r where k = 'c.lead_dash')  like 'ERR 23514%platform_tenants_host_label_chk%', 'label: leading hyphen refused');
select ok((select v from r where k = 'c.dot')        like 'ERR 23514%platform_tenants_host_label_chk%', 'label: a dot (two labels) refused');
select ok((select v from r where k = 'c.empty')      like 'ERR 23514%platform_tenants_host_label_chk%', 'label: empty refused');
select ok((select v from r where k = 'c.too_long')   like 'ERR 23514%platform_tenants_host_label_chk%', 'label: 64 characters refused');
select is((select v from r where k = 'c.max_len'),   'ok', 'label: 63 characters accepted');
select is((select v from r where k = 'c.one_char'),  'ok', 'label: one character accepted');
select ok((select v from r where k = 'c.admin')      like 'ERR 23514%platform_tenants_host_label_reserved%', 'reserved: admin (the platform host)');
select ok((select v from r where k = 'c.api')        like 'ERR 23514%platform_tenants_host_label_reserved%', 'reserved: api');
select ok((select v from r where k = 'c.www')        like 'ERR 23514%platform_tenants_host_label_reserved%', 'reserved: www');
select ok((select v from r where k = 'c.dup')        like 'ERR 23505%platform_tenants_host_label_uq%', 'unique platform-wide');
select ok((select v from r where k = 'c.null')       like 'ERR 23502%host_label%', 'required');
select is((select v from r where k = 'c.tenant_code_kept'), 'T_A', 'tenant_code unchanged: the business identifier keeps its own rule');
select ok(not has_column_privilege('authenticated', 'public.platform_tenants', 'host_label', 'UPDATE')
      and not has_column_privilege('authenticated', 'public.platform_tenants', 'host_label', 'INSERT'), 'no client INSERT/UPDATE grant on host_label');
select ok(not has_column_privilege('anon', 'public.platform_tenants', 'host_label', 'SELECT'), 'anon cannot read it');
select ok((select v from r where k = 'w.update') like 'ERR 42501%permission denied%platform_tenants%', 'a tenant_admin cannot change the host label');
select is((select v from r where k = 'w.read_own'), 'tenant-a', 'tenant users read their own tenant''s label only (RLS unchanged)');

-- ---------- البحث ----------
select is((select v from r where k = 'st.a'), 'e1000000-0000-0000-0000-000000000001', 'student: tenant-a / school-a → the tenant A student');
select is((select v from r where k = 'st.b'), 'e2000000-0000-0000-0000-000000000002', 'student: tenant-b / school-a → the tenant B student (same slug, no collision)');
select is((select v from r where k = 'st.by_code'),    '<null>', 'the tenant_code is not a host context');
select is((select v from r where k = 'st.code_lower'), '<null>', '… nor its lowercase form');
select is((select v from r where k = 'st.no_school'),  '<null>', 'student: a tenant-level host has no school ⇒ no student');
select is((select v from r where k = 'st.archived'),   '<null>', 'student: archived school host ⇒ nothing');
select is((select v from r where k = 'st.suspended'),  '<null>', 'student: suspended tenant ⇒ nothing');
select is((select v from r where k = 'sf.tenant_host'), 'a1000000-0000-0000-0000-000000000001', 'staff: tenant host');
select is((select v from r where k = 'sf.school_host'), 'a1000000-0000-0000-0000-000000000001', 'staff: a school host of the same tenant');
select is((select v from r where k = 'sf.tenant_b'),    'a2000000-0000-0000-0000-000000000002', 'staff: same email in tenant B → tenant B account only');
select is((select v from r where k = 'sf.archived'),    '<null>', 'staff: archived school host ⇒ nothing (the host context must resolve fully)');
select is((select v from r where k = 'sf.unknown'),     '<null>', 'staff: unknown school host ⇒ nothing');
select is((select v from r where k = 'sf.suspended'),   '<null>', 'staff: suspended tenant ⇒ nothing');
select is((select v from r where k = 'sf.unknown_tenant'), '<null>', 'staff: unknown tenant ⇒ nothing');
select is((select v from r where k = 'sf.by_code'),     '<null>', 'staff: the tenant_code is not a host context');
select is((select v from r where k = 'g.school_host'),  'true',   'guardian OTP: active school host');
select is((select v from r where k = 'g.archived'),     'false',  'guardian OTP: archived school host ⇒ no code');
select is((select v from r where k = 'g.verify_archived'), 'null', 'guardian verify: archived school host ⇒ nothing');
select is((select v from r where k = 'pr.count'),       '0',      'a password result in an invalid context does not touch the account');

-- ---------- bootstrap ----------
select ok((select v from r where k = 'bt.reserved') like 'ERR 23514%platform_tenants_host_label_reserved%', 'bootstrap_tenant: a reserved label is refused');
select is((select v from r where k = 'bt.ok'),    '40000000-0000-0000-0000-000000000004', 'bootstrap_tenant: sets the host label');
select is((select v from r where k = 'bt.again'), '40000000-0000-0000-0000-000000000004', 'bootstrap_tenant: idempotent with the same label');
select ok((select v from r where k = 'bt.relabel') like 'ERR 23505%conflict: tenant%', 'bootstrap_tenant: same id, another label → conflict');
select is((select v from r where k = 'bt.row'),   'T_4|tenant-4', 'business code and host label stored side by side');
select is((select v from r where k = 'bt.audit'), 'tenant-4', 'the creation audit row carries the label');

-- ---------- البنية ----------
select is((select string_agg(substr(p.oid::regprocedure::text, 5) || ':' || coalesce((select string_agg(a.grantee::regrole::text, '+' order by a.grantee::regrole::text)
             from aclexplode(p.proacl) a where a.privilege_type = 'EXECUTE' and a.grantee <> p.proowner), '-'), ',' order by p.oid::regprocedure::text)
           from pg_proc p where p.pronamespace = 'app'::regnamespace
             and p.proname in ('login_context', 'login_account', 'resolve_student_login', 'otp_issue', 'otp_verify',
                               'password_login_account', 'password_login_result', 'bootstrap_tenant')),
          'bootstrap_tenant(uuid,text,text,text,uuid,text):authenticated,login_account(text,text,text,text):-,login_context(text,text):-,'
          || 'otp_issue(text,text,text,text):service_role,otp_verify(text,text,text,text,text):service_role,'
          || 'password_login_account(text,text,text,text):service_role,password_login_result(text,text,text,boolean,text):service_role,'
          || 'resolve_student_login(text,text,text):service_role',
          'EXECUTE: pre-login functions to service_role only; the two resolvers to nobody; bootstrap in the M20 allowlist; no old overloads');
select is((select string_agg(distinct pg_get_userbyid(proowner) || ':' || prosecdef || ':' || array_to_string(proconfig, ','), ',')
           from pg_proc where pronamespace = 'app'::regnamespace
             and proname in ('login_context', 'login_account', 'resolve_student_login', 'otp_issue', 'otp_verify',
                             'password_login_account', 'password_login_result', 'bootstrap_tenant')),
          'app_owner:true:search_path=app, public, pg_temp', 'owned by app_owner, SECURITY DEFINER, pinned search_path (R2)');
select is((select string_agg(proname, ',') from pg_proc where pronamespace = 'app'::regnamespace and 'p_tenant_code' = any(proargnames)),
          'bootstrap_tenant', 'no lookup by business code remains: only bootstrap_tenant takes a tenant_code (to create the tenant)');
-- الـlabel سياق لا تفويض: لا سياسة تقرؤه، ولا دالة غير المحلّل و bootstrap
select is((select count(*)::int from pg_policies where coalesce(qual, '') || coalesce(with_check, '') ~ 'host_label'), 0,
          'no RLS policy reads the host label');
select is((select string_agg(proname, ',' order by proname) from pg_proc where pronamespace = 'app'::regnamespace and prosrc ~ 'host_label'),
          'bootstrap_tenant,login_context', 'only the context resolver and bootstrap_tenant touch the host label');
select is((select string_agg(proname, ',' order by proname) from pg_proc where pronamespace = 'app'::regnamespace and prosrc ~ 'login_context\('),
          'login_account,resolve_student_login', 'every login lookup goes through the single context resolver');

select * from finish();
rollback;
