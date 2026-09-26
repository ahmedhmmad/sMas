-- M05 — platform_admin_identity: G10 من جهة المنصة، القيود، دوال السياق الأمني، RLS
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

create function pg_temp.as_user(p_key text, p_sub uuid) returns void
language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p_sub, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', coalesce(p_sub::text, ''), true);
  perform pg_temp.rec(p_key || '.ctx',   'select coalesce(app.current_security_context(), ''<null>'')');
  perform pg_temp.rec(p_key || '.su',    'select coalesce(app.current_system_user_id()::text, ''<null>'')');
  perform pg_temp.rec(p_key || '.admin', 'select app.is_platform_admin()::text');
end $$;

insert into auth.users (id, email) values
  ('c1000000-0000-0000-0000-000000000001', 'm05-admin@test.invalid'),
  ('c2000000-0000-0000-0000-000000000002', 'm05-revoked@test.invalid'),
  ('c3000000-0000-0000-0000-000000000003', 'm05-suspended@test.invalid'),
  ('c4000000-0000-0000-0000-000000000004', 'm05-tenant@test.invalid'),
  ('c5000000-0000-0000-0000-000000000005', 'm05-norole@test.invalid');

insert into public.auth_identities (auth_user_id, kind) values
  ('c1000000-0000-0000-0000-000000000001', 'platform'),
  ('c2000000-0000-0000-0000-000000000002', 'platform'),
  ('c3000000-0000-0000-0000-000000000003', 'platform'),
  ('c4000000-0000-0000-0000-000000000004', 'tenant'),
  ('c5000000-0000-0000-0000-000000000005', 'platform');

insert into public.system_users (id, auth_user_id, display_name, status) values
  ('d1000000-0000-0000-0000-000000000001', 'c1000000-0000-0000-0000-000000000001', 'Admin',     'active'),
  ('d2000000-0000-0000-0000-000000000002', 'c2000000-0000-0000-0000-000000000002', 'Revoked',   'active'),
  ('d3000000-0000-0000-0000-000000000003', 'c3000000-0000-0000-0000-000000000003', 'Suspended', 'suspended'),
  ('d5000000-0000-0000-0000-000000000005', 'c5000000-0000-0000-0000-000000000005', 'No role',   'active');

insert into public.platform_admin_roles (id, code, name) values
  ('e1000000-0000-0000-0000-000000000001', 'zt_platform_admin', 'Platform Admin');

insert into public.platform_admin_assignments (system_user_id, platform_admin_role_id, status, revoked_at) values
  ('d1000000-0000-0000-0000-000000000001', 'e1000000-0000-0000-0000-000000000001', 'active',  null),
  ('d2000000-0000-0000-0000-000000000002', 'e1000000-0000-0000-0000-000000000001', 'revoked', now()),
  ('d3000000-0000-0000-0000-000000000003', 'e1000000-0000-0000-0000-000000000001', 'active',  null);

-- G10 من جهة المنصة
select pg_temp.rec('g10.tenant_as_system_user',
  $q$insert into public.system_users (auth_user_id, display_name) values ('c4000000-0000-0000-0000-000000000004','X') returning 'ok'$q$);
select pg_temp.rec('g10.forged_kind',
  $q$update public.system_users set identity_kind = 'tenant' where id = 'd1000000-0000-0000-0000-000000000001' returning 'ok'$q$);

-- القيود
select pg_temp.rec('su.dup_auth',
  $q$insert into public.system_users (auth_user_id, display_name) values ('c1000000-0000-0000-0000-000000000001','X') returning 'ok'$q$);
select pg_temp.rec('par.bad_code',
  $q$insert into public.platform_admin_roles (code, name) values ('Platform Admin','x') returning 'ok'$q$);
select pg_temp.rec('paa.dup',
  $q$insert into public.platform_admin_assignments (system_user_id, platform_admin_role_id) values ('d1000000-0000-0000-0000-000000000001','e1000000-0000-0000-0000-000000000001') returning 'ok'$q$);
select pg_temp.rec('paa.revoke_no_ts',
  $q$update public.platform_admin_assignments set status = 'revoked' where system_user_id = 'd1000000-0000-0000-0000-000000000001' returning 'ok'$q$);
select pg_temp.rec('paa.granted_at_immutable',
  $q$update public.platform_admin_assignments set granted_at = '2000-01-01' where system_user_id = 'd1000000-0000-0000-0000-000000000001' returning (granted_at <> '2000-01-01')::text$q$);

-- دوال السياق
select pg_temp.as_user('admin',     'c1000000-0000-0000-0000-000000000001');
select pg_temp.as_user('revoked',   'c2000000-0000-0000-0000-000000000002');
select pg_temp.as_user('suspended', 'c3000000-0000-0000-0000-000000000003');
select pg_temp.as_user('tenant',    'c4000000-0000-0000-0000-000000000004');
select pg_temp.as_user('norole',    'c5000000-0000-0000-0000-000000000005');
select pg_temp.as_user('service',   null);

-- RLS
select set_config('request.jwt.claims', '{"sub":"c1000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
set local role authenticated;
select pg_temp.rec('rls.system_users', 'select count(*)::text from public.system_users');
select pg_temp.rec('rls.assignments',  'select count(*)::text from public.platform_admin_assignments');
reset role;

select plan(27);

select ok((select bool_and(relrowsecurity and relforcerowsecurity) from pg_class
           where oid in ('public.system_users'::regclass, 'public.platform_admin_roles'::regclass, 'public.platform_admin_assignments'::regclass)),
          'RLS enabled and forced on the three platform tables');
select hasnt_column('public', 'system_users', 'created_by', 'system_users has no always-NULL created_by');

-- G10
select ok((select v from r where k = 'g10.tenant_as_system_user') like 'ERR 23503%system_users_identity_fk%', 'G10: tenant-kind account cannot become a system user');
select ok((select v from r where k = 'g10.forged_kind')           like 'ERR 23514%system_users_identity_kind_chk%', 'G10: system_users.identity_kind cannot change from platform');

-- القيود
select ok((select v from r where k = 'su.dup_auth')       like 'ERR 23505%system_users_auth_user_uq%', 'one system user per Auth account');
select ok((select v from r where k = 'par.bad_code')      like 'ERR 23514%platform_admin_roles_code_chk%', 'platform role code format enforced');
select ok((select v from r where k = 'paa.dup')           like 'ERR 23505%platform_admin_assignments_uq%', 'role assigned once per system user');
select ok((select v from r where k = 'paa.revoke_no_ts')  like 'ERR 23514%platform_admin_assignments_revoked_chk%', 'revoked status requires revoked_at');
select is((select v from r where k = 'paa.granted_at_immutable'), 'true',    'T6: granted_at immutable after insert');

-- السياق الأمني
select is((select v from r where k = 'admin.ctx'),   'platform', 'active platform admin: context = platform');
select is((select v from r where k = 'admin.su'),    'd1000000-0000-0000-0000-000000000001', 'active platform admin: system user resolved');
select is((select v from r where k = 'admin.admin'), 'true',     'active platform admin with active assignment: is_platform_admin');
select is((select v from r where k = 'revoked.ctx'),   'platform', 'revoked admin: still platform context');
select is((select v from r where k = 'revoked.admin'), 'false',    'revoked assignment: not platform admin');
select is((select v from r where k = 'suspended.su'),    '<null>', 'suspended system user: no system user identity');
select is((select v from r where k = 'suspended.admin'), 'false',  'suspended system user: not platform admin');
select is((select v from r where k = 'norole.admin'), 'false',     'system user without assignment: not platform admin');
select is((select v from r where k = 'tenant.ctx'),   'tenant',    'tenant account: context = tenant');
select is((select v from r where k = 'tenant.su'),    '<null>',    'tenant account: no system user identity');
select is((select v from r where k = 'tenant.admin'), 'false',     'tenant account: not platform admin');
select is((select v from r where k = 'service.ctx'),   '<null>',   'service context: no security context');
select is((select v from r where k = 'service.admin'), 'false',    'service context: not platform admin');

-- الدوال
select ok((select bool_and(pg_get_userbyid(proowner) = 'app_owner' and prosecdef) from pg_proc
           where oid in ('app.current_security_context()'::regprocedure, 'app.current_system_user_id()'::regprocedure, 'app.is_platform_admin()'::regprocedure)),
          'context functions: SECURITY DEFINER owned by app_owner');
select is((select count(*)::int from pg_proc p where p.pronamespace = 'app'::regnamespace
             and has_function_privilege('anon', p.oid, 'EXECUTE')), 0,
          'no function in schema app is executable by anon');
-- استثناءات R2 — قائمة مغلقة مسمّاة (M25، قرار 2026-09-26): قراءة schema auth التي لا يصلها app_owner
select is((select coalesce(string_agg(p.oid::regprocedure::text, ',' order by p.oid::regprocedure::text), 'none') from pg_proc p
            where p.pronamespace = 'app'::regnamespace and pg_get_userbyid(p.proowner) <> 'app_owner'),
          'app.auth_password_changed_by_self_after(uuid,timestamp with time zone),app.auth_uid(),app.auth_user_updated_at(uuid)',
          'every app function is owned by app_owner except the closed R2 list (auth_uid; M25: auth_user_updated_at, auth_password_changed_by_self_after)');

-- RLS
select is((select v from r where k = 'rls.system_users'), '1', 'RLS (M14 self policy): a platform admin sees only its own system user, none of the others');
select is((select v from r where k = 'rls.assignments'),  '1', 'RLS (M14 self policy): a platform admin sees only its own assignment');

select * from finish();
rollback;
