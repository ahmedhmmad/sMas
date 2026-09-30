-- M28 — my_permissions: effective keys بالشروط نفسها التي تقرر بها has_permission / has_platform_permission
-- الإثبات الأساسي: لكل فاعل، my_permissions() = { key ∈ الكتالوج : has_permission(key) ∨ has_platform_permission(key) }
-- (المساواة تُحسب في الاختبار عبر المحمولين القائمين — والدالة نفسها لا تستعملهما)
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

-- الكتالوج كاملاً (يُقرأ قبل تبديل الدور — جدول permissions نفسه تحت RLS المستخدم)
create temp table catalog as select code from public.permissions;
grant select on catalog to public;

-- لكل فاعل: قيمة my_permissions، والمطابقة مع المحمولين على الكتالوج كله
create function pg_temp.probe(p_key text, p_sub uuid) returns void
language plpgsql as $$
begin
  perform set_config('request.jwt.claims', case when p_sub is null then '' else json_build_object('sub', p_sub, 'role', 'authenticated')::text end, true);
  perform set_config('request.jwt.claim.sub', coalesce(p_sub::text, ''), true);
  execute 'set local role authenticated';
  perform pg_temp.rec(p_key, $q$select array_to_string(app.my_permissions(), ',')$q$);
  perform pg_temp.rec(p_key || '#eq', $q$select (app.my_permissions() = coalesce((
      select array_agg(code order by code) from catalog
       where app.has_permission(code) or app.has_platform_permission(code)), '{}'))::text$q$);
  execute 'reset role';
end $$;

-- ============ Fixture ============
insert into public.platform_tenants (id, tenant_code, host_label, name) values
  ('10000000-0000-0000-0000-000000000001', 'T1', 't1', 'T1'), ('20000000-0000-0000-0000-000000000002', 'T2', 't2', 'T2');
insert into public.schools (id, platform_tenant_id, group_id, school_code, name, slug) values
  ('55000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', null, 'SA', 'SA', 'sa'),
  ('56000000-0000-0000-0000-000000000002', '20000000-0000-0000-0000-000000000002', null, 'S2', 'S2', 's2');

create function pg_temp.member(p_auth uuid, p_tenant uuid, p_roles text[], p_state text default 'active') returns uuid
language plpgsql as $$
declare v_p uuid; v_m uuid; x text;
begin
  insert into auth.users (id, email) values (p_auth, p_auth::text || '@m28.invalid');
  insert into public.auth_identities (auth_user_id, kind, credential_state) values (p_auth, 'tenant', p_state);
  insert into public.profiles (platform_tenant_id, auth_user_id, display_name) values (p_tenant, p_auth, 'm') returning id into v_p;
  insert into public.memberships (platform_tenant_id, profile_id) values (p_tenant, v_p) returning id into v_m;
  foreach x in array p_roles loop
    insert into public.membership_roles (membership_id, role_id, platform_tenant_id, role_owner_key)
      select v_m, r.id, p_tenant, coalesce(r.platform_tenant_id, '00000000-0000-0000-0000-000000000000') from public.roles r
       where r.code = x and (r.platform_tenant_id is null or r.platform_tenant_id = p_tenant);
  end loop;
  insert into public.membership_scopes (membership_id, platform_tenant_id, scope_type, school_id)
    values (v_m, p_tenant, 'school', (select id from public.schools where platform_tenant_id = p_tenant));
  return v_m;
end $$;

-- دور مخصص: نشط ثم يُعطَّل
insert into public.roles (id, platform_tenant_id, code, name, is_system) values
  ('7c000000-0000-0000-0000-00000000000c', '10000000-0000-0000-0000-000000000001', 'zt_custom', 'Custom', false);
insert into public.role_permissions (role_id, permission_id)
  select '7c000000-0000-0000-0000-00000000000c', id from public.permissions where code in ('student.export', 'audit.read');

select pg_temp.member('a1000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', array['secretary']);
select pg_temp.member('a2000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001', array['secretary', 'zt_custom']);
select pg_temp.member('a3000000-0000-0000-0000-000000000003', '10000000-0000-0000-0000-000000000001', array['bus_supervisor']);
select pg_temp.member('a4000000-0000-0000-0000-000000000004', '10000000-0000-0000-0000-000000000001', array['secretary']);   -- عضوية منتهية
update public.memberships set status = 'ended', ended_at = now()
 where profile_id = (select id from public.profiles where auth_user_id = 'a4000000-0000-0000-0000-000000000004');
select pg_temp.member('a5000000-0000-0000-0000-000000000005', '10000000-0000-0000-0000-000000000001', array['student'], 'pending');   -- D2 pending
select pg_temp.member('a6000000-0000-0000-0000-000000000006', '20000000-0000-0000-0000-000000000002', array['school_admin']);  -- T2 (يُوقف)

-- Platform Admins: إسناد نشط وآخر مسحوب
insert into public.platform_admin_roles (id, code, name) values ('81000000-0000-0000-0000-000000000001', 'zt_ops', 'Ops');
insert into public.platform_admin_role_permissions select '81000000-0000-0000-0000-000000000001', id from public.permissions where code in ('tenant.read', 'school.read');
do $$
declare l record;
begin
  for l in select * from (values ('b1000000-0000-0000-0000-000000000001'::uuid, 'active'), ('b2000000-0000-0000-0000-000000000002'::uuid, 'revoked')) v(a, st) loop
    insert into auth.users (id, email) values (l.a, l.a::text || '@m28.invalid');
    insert into public.auth_identities (auth_user_id, kind) values (l.a, 'platform');
    insert into public.system_users (id, auth_user_id, display_name) values (l.a, l.a, 'pa');
    insert into public.platform_admin_assignments (system_user_id, platform_admin_role_id, status, revoked_at)
      values (l.a, '81000000-0000-0000-0000-000000000001', l.st, case when l.st = 'revoked' then now() end);
  end loop;
end $$;

-- ============ القياس ============
select pg_temp.probe('secretary',      'a1000000-0000-0000-0000-000000000001');
select pg_temp.probe('custom_active',  'a2000000-0000-0000-0000-000000000002');
update public.roles set status = 'inactive' where id = '7c000000-0000-0000-0000-00000000000c';
select pg_temp.probe('custom_inactive','a2000000-0000-0000-0000-000000000002');
select pg_temp.probe('bus',            'a3000000-0000-0000-0000-000000000003');
select pg_temp.probe('ended',          'a4000000-0000-0000-0000-000000000004');
select pg_temp.probe('pending',        'a5000000-0000-0000-0000-000000000005');
select pg_temp.probe('t2',             'a6000000-0000-0000-0000-000000000006');
update public.platform_tenants set status = 'suspended', suspended_at = now() where tenant_code = 'T2';
select pg_temp.probe('t2_suspended',   'a6000000-0000-0000-0000-000000000006');
select pg_temp.probe('pa',             'b1000000-0000-0000-0000-000000000001');
select pg_temp.probe('pa_revoked',     'b2000000-0000-0000-0000-000000000002');
select pg_temp.probe('service',        null);
select pg_temp.rec('bus_seed', $q$select array_to_string(array_agg(p.code order by p.code), ',') from public.role_permissions rp
  join public.roles ro on ro.id = rp.role_id join public.permissions p on p.id = rp.permission_id where ro.code = 'bus_supervisor' and ro.platform_tenant_id is null$q$);
select pg_temp.rec('secretary_seed', $q$select array_to_string(array_agg(p.code order by p.code), ',') from public.role_permissions rp
  join public.roles ro on ro.id = rp.role_id join public.permissions p on p.id = rp.permission_id where ro.code = 'secretary' and ro.platform_tenant_id is null$q$);
select pg_temp.rec('anon', $q$select 1$q$);
do $$ begin
  execute 'set local role anon';
  perform pg_temp.rec('anon', $q$select array_to_string(app.my_permissions(), ',')$q$);
  execute 'reset role';
end $$;

select plan(20);

select is((select v from r where k = 'secretary'), (select v from r where k = 'secretary_seed'), 'secretary: exactly the keys of the seeded secretary role');
select is((select v from r where k = 'secretary#eq'), 'true', 'secretary: equals has_permission over the whole catalog');
select ok((select v from r where k = 'custom_active') like '%student.export%', 'an active custom role contributes its keys');
select is((select v from r where k = 'custom_active#eq'), 'true', 'custom (active): equals has_permission');
select ok((select v from r where k = 'custom_inactive') not like '%student.export%', 'an inactive role contributes nothing (roles.status)');
select is((select v from r where k = 'custom_inactive#eq'), 'true', 'custom (inactive): equals has_permission');
select is((select v from r where k = 'bus'), (select v from r where k = 'bus_seed'), 'bus_supervisor: exactly its seeded keys (no student.read)');
select is((select v from r where k = 'ended'), '', 'ended membership → no keys (memberships.status)');
select is((select v from r where k = 'ended#eq'), 'true', 'ended: equals has_permission');
select is((select v from r where k = 'pending'), '', 'pending first-login account (D2) → no keys (root context closed)');
select ok((select v from r where k = 't2') like '%security.manage%', 'another tenant''s school_admin has its own keys');
select is((select v from r where k = 't2_suspended'), '', 'suspended tenant → no keys (M21b)');
select is((select v from r where k = 't2_suspended#eq'), 'true', 'suspended: equals has_permission');
select is((select v from r where k = 'pa'), 'school.read,tenant.read', 'platform context → platform keys only');
select is((select v from r where k = 'pa#eq'), 'true', 'platform: equals has_platform_permission');
select is((select v from r where k = 'pa_revoked'), '', 'revoked assignment → no keys');
select is((select v from r where k = 'service'), '', 'no JWT → no keys');
select ok((select v from r where k = 'anon') like 'ERR 42501%', 'anon cannot execute');
select is(pg_get_function_result('app.my_permissions()'::regprocedure), 'text[]', 'returns keys only — no roles, scopes or ids');
select is((select pg_get_userbyid(proowner) || ':' || prosecdef from pg_proc where oid = 'app.my_permissions()'::regprocedure), 'app_owner:true', 'owned by app_owner, SECURITY DEFINER (R2)');

select * from finish();
rollback;
