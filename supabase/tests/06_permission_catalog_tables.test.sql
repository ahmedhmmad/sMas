-- M06 — permission_catalog_tables: I16–I18، سلوك الحذف، has_platform_permission (G10)
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

create function pg_temp.hpp(p_key text, p_sub uuid, p_code text) returns void
language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p_sub, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', coalesce(p_sub::text, ''), true);
  perform pg_temp.rec(p_key, format('select app.has_platform_permission(%L)::text', p_code));
end $$;

insert into public.platform_tenants (id, tenant_code, name) values
  ('10000000-0000-0000-0000-000000000001', 'T1', 'Tenant One'),
  ('20000000-0000-0000-0000-000000000002', 'T2', 'Tenant Two');

insert into public.permissions (id, code, resource, operation, description) values
  ('f1000000-0000-0000-0000-000000000001', 'zt_tenant.read',   'zt_tenant',  'read',   'read tenant'),
  ('f2000000-0000-0000-0000-000000000002', 'zt_tenant.create', 'zt_tenant',  'create', 'create tenant'),
  ('f3000000-0000-0000-0000-000000000003', 'zt_student.read',  'zt_student', 'read',   'read student');

-- permissions — I18
select pg_temp.rec('p.parts_mismatch', $q$insert into public.permissions (code, resource, operation, description) values ('student.read','student','update','x') returning 'ok'$q$);
select pg_temp.rec('p.bad_format',     $q$insert into public.permissions (code, resource, operation, description) values ('Student.Read','Student','Read','x') returning 'ok'$q$);
select pg_temp.rec('p.dup',            $q$insert into public.permissions (code, resource, operation, description) values ('tenant.read','tenant','read','x') returning 'ok'$q$);

-- roles — I17 وتفرد الأكواد
insert into public.roles (id, platform_tenant_id, code, name, is_system) values
  ('71000000-0000-0000-0000-000000000001', null,                                   'zt_teacher', 'Teacher',        true),
  ('72000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001', 'teacher', 'Custom T1',      false),
  ('73000000-0000-0000-0000-000000000003', '20000000-0000-0000-0000-000000000002', 'teacher', 'Custom T2',      false);
select pg_temp.rec('r.system_not_flagged', $q$insert into public.roles (platform_tenant_id, code, name, is_system) values (null,'x','x',false) returning 'ok'$q$);
select pg_temp.rec('r.custom_flagged',     $q$insert into public.roles (platform_tenant_id, code, name, is_system) values ('10000000-0000-0000-0000-000000000001','y','y',true) returning 'ok'$q$);
select pg_temp.rec('r.dup_system_code',    $q$insert into public.roles (platform_tenant_id, code, name, is_system) values (null,'zt_teacher','x',true) returning 'ok'$q$);
select pg_temp.rec('r.dup_custom_code',    $q$insert into public.roles (platform_tenant_id, code, name, is_system) values ('10000000-0000-0000-0000-000000000001','teacher','x',false) returning 'ok'$q$);
select pg_temp.rec('r.bad_code',           $q$insert into public.roles (platform_tenant_id, code, name, is_system) values ('10000000-0000-0000-0000-000000000001','Head Teacher','x',false) returning 'ok'$q$);

-- role_permissions — سلوك الحذف
insert into public.role_permissions values
  ('72000000-0000-0000-0000-000000000002', 'f3000000-0000-0000-0000-000000000003');
select pg_temp.rec('rp.dup',              $q$insert into public.role_permissions values ('72000000-0000-0000-0000-000000000002','f3000000-0000-0000-0000-000000000003') returning 'ok'$q$);
select pg_temp.rec('rp.delete_used_perm', $q$delete from public.permissions where id = 'f3000000-0000-0000-0000-000000000003' returning 'ok'$q$);
delete from public.roles where id = '72000000-0000-0000-0000-000000000002';
select pg_temp.rec('rp.cascade_rows', $q$select count(*)::text from public.role_permissions where role_id = '72000000-0000-0000-0000-000000000002'$q$);

-- has_platform_permission — مستخدمو منصة وحساب Tenant
insert into auth.users (id, email) values
  ('c1000000-0000-0000-0000-000000000001', 'm06-admin@test.invalid'),
  ('c2000000-0000-0000-0000-000000000002', 'm06-support@test.invalid'),
  ('c3000000-0000-0000-0000-000000000003', 'm06-revoked@test.invalid'),
  ('c4000000-0000-0000-0000-000000000004', 'm06-tenant@test.invalid');
insert into public.auth_identities values
  ('c1000000-0000-0000-0000-000000000001', 'platform'),
  ('c2000000-0000-0000-0000-000000000002', 'platform'),
  ('c3000000-0000-0000-0000-000000000003', 'platform'),
  ('c4000000-0000-0000-0000-000000000004', 'tenant');
insert into public.system_users (id, auth_user_id, display_name) values
  ('d1000000-0000-0000-0000-000000000001', 'c1000000-0000-0000-0000-000000000001', 'Admin'),
  ('d2000000-0000-0000-0000-000000000002', 'c2000000-0000-0000-0000-000000000002', 'Support'),
  ('d3000000-0000-0000-0000-000000000003', 'c3000000-0000-0000-0000-000000000003', 'Revoked');
insert into public.platform_admin_roles (id, code, name) values
  ('e1000000-0000-0000-0000-000000000001', 'zt_platform_admin', 'Platform Admin'),
  ('e2000000-0000-0000-0000-000000000002', 'platform_support', 'Platform Support');
insert into public.platform_admin_role_permissions values
  ('e1000000-0000-0000-0000-000000000001', 'f1000000-0000-0000-0000-000000000001'),
  ('e1000000-0000-0000-0000-000000000001', 'f2000000-0000-0000-0000-000000000002'),
  ('e2000000-0000-0000-0000-000000000002', 'f1000000-0000-0000-0000-000000000001');
insert into public.platform_admin_assignments (system_user_id, platform_admin_role_id, status, revoked_at) values
  ('d1000000-0000-0000-0000-000000000001', 'e1000000-0000-0000-0000-000000000001', 'active',  null),
  ('d2000000-0000-0000-0000-000000000002', 'e2000000-0000-0000-0000-000000000002', 'active',  null),
  ('d3000000-0000-0000-0000-000000000003', 'e1000000-0000-0000-0000-000000000001', 'revoked', now());

select pg_temp.hpp('hpp.admin_create',    'c1000000-0000-0000-0000-000000000001', 'zt_tenant.create');
select pg_temp.hpp('hpp.admin_student',   'c1000000-0000-0000-0000-000000000001', 'zt_student.read');
select pg_temp.hpp('hpp.support_read',    'c2000000-0000-0000-0000-000000000002', 'zt_tenant.read');
select pg_temp.hpp('hpp.support_create',  'c2000000-0000-0000-0000-000000000002', 'zt_tenant.create');
select pg_temp.hpp('hpp.revoked_create',  'c3000000-0000-0000-0000-000000000003', 'zt_tenant.create');
select pg_temp.hpp('hpp.tenant_read',     'c4000000-0000-0000-0000-000000000004', 'zt_tenant.read');
select pg_temp.hpp('hpp.service_read',    null,                                   'zt_tenant.read');
select pg_temp.hpp('hpp.unknown_code',    'c1000000-0000-0000-0000-000000000001', 'no.such');

-- RLS
select set_config('request.jwt.claims', '{"sub":"c1000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
set local role authenticated;
select pg_temp.rec('rls.permissions', 'select count(*)::text from public.permissions');
select pg_temp.rec('rls.roles',       'select count(*)::text from public.roles');
reset role;

select plan(26);

select ok((select bool_and(relrowsecurity and relforcerowsecurity) from pg_class
           where oid in ('public.permissions'::regclass, 'public.roles'::regclass,
                         'public.role_permissions'::regclass, 'public.platform_admin_role_permissions'::regclass)),
          'RLS enabled and forced on the four catalog tables');

-- I18
select ok((select v from r where k = 'p.parts_mismatch') like 'ERR 23514%permissions_code_parts_chk%', 'I18: code must equal resource.operation');
select ok((select v from r where k = 'p.bad_format')     like 'ERR 23514%permissions_code_format_chk%', 'permission code format enforced');
select ok((select v from r where k = 'p.dup')            like 'ERR 23505%permissions_code_uq%', 'permission code unique');

-- I17 وتفرد الأكواد
select ok((select v from r where k = 'r.system_not_flagged') like 'ERR 23514%roles_is_system_chk%', 'I17: tenant-less role must be is_system');
select ok((select v from r where k = 'r.custom_flagged')     like 'ERR 23514%roles_is_system_chk%', 'I17: tenant role cannot be is_system');
select ok((select v from r where k = 'r.dup_system_code')    like 'ERR 23505%roles_system_code_uq%', 'system role code unique');
select ok((select v from r where k = 'r.dup_custom_code')    like 'ERR 23505%roles_tenant_code_uq%', 'custom role code unique within tenant');
select ok((select v from r where k = 'r.bad_code')           like 'ERR 23514%roles_code_chk%', 'role code format enforced');
select is((select count(*)::int from public.roles where code = 'teacher'), 2,
          'same code allowed: system template + custom in another tenant (after T1 custom deleted)');

-- I16 — owner_key
select is((select owner_key::text from public.roles where id = '71000000-0000-0000-0000-000000000001'), '00000000-0000-0000-0000-000000000000',
          'I16: system role owner_key = zero key');
select is((select owner_key::text from public.roles where id = '73000000-0000-0000-0000-000000000003'), '20000000-0000-0000-0000-000000000002',
          'I16: custom role owner_key = its tenant');
select col_is_unique('public', 'roles', array['id', 'owner_key'], 'I16: (id, owner_key) unique — FK target for membership_roles');

-- سلوك الحذف
select ok((select v from r where k = 'rp.dup')              like 'ERR 23505%role_permissions_pkey%', 'role_permissions: no duplicate grant');
select ok((select v from r where k = 'rp.delete_used_perm') like 'ERR 23503%role_permissions_permission_fk%', 'permission in use cannot be deleted (RESTRICT)');
select is((select v from r where k = 'rp.cascade_rows'), '0',                    'deleting a role removes its role_permissions (CASCADE)');

-- has_platform_permission (G10، C3)
select is((select v from r where k = 'hpp.admin_create'),   'true',  'platform admin holds tenant.create');
select is((select v from r where k = 'hpp.admin_student'),  'false', 'C3: platform admin has no student.read unless granted');
select is((select v from r where k = 'hpp.support_read'),   'true',  'limited platform role: granted permission');
select is((select v from r where k = 'hpp.support_create'), 'false', 'limited platform role: ungranted permission denied');
select is((select v from r where k = 'hpp.revoked_create'), 'false', 'revoked platform assignment grants nothing');
select is((select v from r where k = 'hpp.tenant_read'),    'false', 'G10: tenant context never satisfies a platform permission');
select is((select v from r where k = 'hpp.service_read'),   'false', 'service context: no platform permission');
select is((select v from r where k = 'hpp.unknown_code'),   'false', 'unknown permission code: false');

-- RLS
select ok((select v from r where k = 'rls.permissions') = '0' and (select v from r where k = 'rls.roles') = '0',
          'RLS: authenticated sees nothing before policies');
select ok((select pg_get_userbyid(proowner) = 'app_owner' and prosecdef from pg_proc where oid = 'app.has_platform_permission(text)'::regprocedure)
      and not has_function_privilege('anon', 'app.has_platform_permission(text)', 'EXECUTE'),
          'has_platform_permission: SECURITY DEFINER owned by app_owner, no EXECUTE for anon');

select * from finish();
rollback;
