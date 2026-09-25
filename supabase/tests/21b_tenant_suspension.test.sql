-- M21b — tenant_suspension: الـTenant الموقوف يفقد كل مسار Tenant؛ سياق المنصة لا يتأثر
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

create temp table ids (label text primary key, auth uuid) on commit drop;
grant all on ids to public;

create function pg_temp.run(p_key text, p_label text, p_sql text) returns void
language plpgsql as $$
declare v_sub uuid := (select auth from ids where label = p_label);
begin
  perform set_config('request.jwt.claims', json_build_object('sub', v_sub, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', coalesce(v_sub::text, ''), true);
  execute 'set local role authenticated';
  perform pg_temp.rec(p_key, p_sql);
  execute 'reset role';
end $$;

-- ============ Fixture: T1 (سيوقف) و T2 (يبقى نشطاً) ============
insert into public.platform_tenants (id, tenant_code, name) values
  ('10000000-0000-0000-0000-000000000001', 'T1', 'T1'), ('20000000-0000-0000-0000-000000000002', 'T2', 'T2');
insert into public.schools (id, platform_tenant_id, school_code, name, slug) values
  ('51000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', 'S1', 'S1', 's1'),
  ('52000000-0000-0000-0000-000000000002', '20000000-0000-0000-0000-000000000002', 'S2', 'S2', 's2');
insert into public.academic_years (school_id, name, start_date, end_date, status) values
  ('51000000-0000-0000-0000-000000000001', 'Y', '2026-09-01', '2027-06-30', 'active'),
  ('52000000-0000-0000-0000-000000000002', 'Y', '2026-09-01', '2027-06-30', 'active');

insert into public.permissions (code, resource, operation, description)
  select c, split_part(c, '.', 1), split_part(c, '.', 2), 'test' from unnest(array['tenant.read','school.read','academic_year.read','tenant.suspend']) c;
insert into public.roles (id, platform_tenant_id, code, name, is_system) values ('71000000-0000-0000-0000-000000000001', null, 'reader', 'R', true);
insert into public.role_permissions select '71000000-0000-0000-0000-000000000001', id from public.permissions where code <> 'tenant.suspend';

do $$
declare l text; t uuid; v_auth uuid; v_p uuid; v_m uuid;
begin
  foreach l in array array['u1','u2'] loop
    t := case l when 'u1' then '10000000-0000-0000-0000-000000000001'::uuid else '20000000-0000-0000-0000-000000000002'::uuid end;
    v_auth := gen_random_uuid();
    insert into auth.users (id, email) values (v_auth, l || '@m21b.invalid');
    insert into public.auth_identities values (v_auth, 'tenant');
    insert into public.profiles (platform_tenant_id, auth_user_id, display_name) values (t, v_auth, l) returning id into v_p;
    insert into public.memberships (platform_tenant_id, profile_id) values (t, v_p) returning id into v_m;
    insert into public.membership_roles (membership_id, role_id, platform_tenant_id, role_owner_key) values (v_m, '71000000-0000-0000-0000-000000000001', t, '00000000-0000-0000-0000-000000000000');
    insert into public.membership_scopes (membership_id, platform_tenant_id, scope_type) values (v_m, t, 'tenant');
    insert into ids values (l, v_auth);
  end loop;
end $$;

insert into public.platform_admin_roles (id, code, name) values ('81000000-0000-0000-0000-000000000001', 'ops', 'Ops');
insert into public.platform_admin_role_permissions select '81000000-0000-0000-0000-000000000001', id from public.permissions where code in ('tenant.suspend','tenant.read');
insert into auth.users (id, email) values ('c7000000-0000-0000-0000-000000000007', 'pa@m21b.invalid');
insert into public.auth_identities values ('c7000000-0000-0000-0000-000000000007', 'platform');
insert into public.system_users (id, auth_user_id, display_name) values ('d7000000-0000-0000-0000-000000000007', 'c7000000-0000-0000-0000-000000000007', 'pa');
insert into public.platform_admin_assignments (system_user_id, platform_admin_role_id) values ('d7000000-0000-0000-0000-000000000007', '81000000-0000-0000-0000-000000000001');
insert into ids values ('pa', 'c7000000-0000-0000-0000-000000000007');

create function pg_temp.probe(p_prefix text, p_label text) returns void
language plpgsql as $$
begin
  perform pg_temp.run(p_prefix || '.ctx',    p_label, $q$select coalesce(app.current_tenant_id()::text, 'null') || '|' || (app.current_profile_id() is not null)::text$q$);
  perform pg_temp.run(p_prefix || '.perm',   p_label, $q$select app.has_permission('school.read')::text || '|' || app.can_access_school(coalesce((select id from public.schools limit 0), '51000000-0000-0000-0000-000000000001'))::text$q$);
  perform pg_temp.run(p_prefix || '.rows',   p_label, $q$select (select count(*) from public.platform_tenants) || '/' || (select count(*) from public.schools) || '/' || (select count(*) from public.academic_years)$q$);
  perform pg_temp.run(p_prefix || '.self',   p_label, $q$select count(*)::text from public.profiles$q$);
end $$;

-- قبل الإيقاف
select pg_temp.probe('before', 'u1');
-- الإيقاف بسياق المنصة
select pg_temp.run('pa.suspend', 'pa', $q$select 'ok' from app.suspend_tenant('10000000-0000-0000-0000-000000000001', 'unpaid')$q$);
select pg_temp.probe('during', 'u1');
select pg_temp.probe('other',  'u2');
select pg_temp.run('during.pa_sees', 'pa', $q$select status from public.platform_tenants where id = '10000000-0000-0000-0000-000000000001'$q$);
-- إعادة التفعيل
select pg_temp.run('pa.react', 'pa', $q$select 'ok' from app.reactivate_tenant('10000000-0000-0000-0000-000000000001', 'paid')$q$);
select pg_temp.probe('after', 'u1');

select plan(15);

select is((select v from r where k = 'before.ctx'),  '10000000-0000-0000-0000-000000000001|true', 'before: the tenant context resolves');
select is((select v from r where k = 'before.perm'), 'true|true', 'before: permission and school scope hold');
select is((select v from r where k = 'before.rows'), '1/1/1',     'before: tenant, school and school-level rows visible');
select is((select v from r where k = 'pa.suspend'),  'ok',        'platform admin suspends T1');

select is((select v from r where k = 'during.ctx'),  'null|false', 'suspended: current_tenant_id() and current_profile_id() both resolve to nothing');
select is((select v from r where k = 'during.perm'), 'false|false', 'suspended: has_permission and can_access_school fail (they read current_profile_id)');
select is((select v from r where k = 'during.rows'), '0/0/0',     'suspended: no tenant-level, group/school-level or school-scoped row is visible');
select is((select v from r where k = 'during.self'), '1',         'suspended: the user still sees its own profile row (self path uses auth.uid()) — identity, not tenant data');

select is((select v from r where k = 'other.ctx'),   '20000000-0000-0000-0000-000000000002|true', 'another tenant is unaffected');
select is((select v from r where k = 'other.rows'),  '1/1/1',     'another tenant keeps its access');
select is((select v from r where k = 'during.pa_sees'), 'suspended', 'platform context is separate: the platform admin still reads the suspended tenant');

select is((select v from r where k = 'pa.react'),    'ok',        'platform admin reactivates T1');
select is((select v from r where k = 'after.ctx'),   '10000000-0000-0000-0000-000000000001|true', 'reactivated: the tenant context resolves again');
select is((select v from r where k = 'after.rows'),  '1/1/1',     'reactivated: access restored');

select ok((select bool_and(pg_get_userbyid(proowner) = 'app_owner' and prosecdef) from pg_proc
           where oid in ('app.current_profile_id()'::regprocedure, 'app.current_tenant_id()'::regprocedure)),
          'both root functions stay SECURITY DEFINER owned by app_owner');

select * from finish();
rollback;
