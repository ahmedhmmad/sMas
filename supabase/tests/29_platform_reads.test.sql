-- M29 — platform_reads (F1/W1): قراءة Platform Admin لبيانات Tenant مسار واحد مُدقَّق؛ لا قراءة مباشرة.
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
  perform set_config('request.jwt.claims', case when p_sub is null then '' else json_build_object('sub', p_sub, 'role', 'authenticated')::text end, true);
  perform set_config('request.jwt.claim.sub', coalesce(p_sub::text, ''), true);
  execute 'set local role authenticated';
  perform pg_temp.rec(p_key, p_sql);
  execute 'reset role';
end $$;

-- صفوف التدقيق لـTenantي هذا الاختبار وحدهما (قاعدة قد تحوي seed أو بيانات اختبارات أخرى)
create function pg_temp.audits() returns int language sql as $$
  select count(*)::int from public.audit_log where action = 'read' and entity_type = 'platform_tenants'
     and entity_id in ('10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000002')
$$;

-- ============ Fixture ============
insert into public.platform_tenants (id, tenant_code, host_label, name) values
  ('10000000-0000-0000-0000-000000000001', 'T1', 't1', 'T1'), ('20000000-0000-0000-0000-000000000002', 'T2', 't2', 'T2');
insert into public.groups (platform_tenant_id, group_code, name) values ('10000000-0000-0000-0000-000000000001', 'GA', 'GA');
insert into public.schools (platform_tenant_id, group_id, school_code, name, slug) values
  ('10000000-0000-0000-0000-000000000001', null, 'SS', 'SS', 'ss');

insert into public.platform_admin_roles (id, code, name) values
  ('81000000-0000-0000-0000-000000000001', 'zt_reader', 'Reader'), ('82000000-0000-0000-0000-000000000002', 'zt_none', 'None');
insert into public.platform_admin_role_permissions select '81000000-0000-0000-0000-000000000001', id from public.permissions
  where code in ('tenant.read', 'group.read', 'school.read');
do $$
declare l record;
begin
  for l in select * from (values ('b1000000-0000-0000-0000-000000000001'::uuid, '81000000-0000-0000-0000-000000000001'::uuid),
                                 ('b2000000-0000-0000-0000-000000000002'::uuid, '82000000-0000-0000-0000-000000000002'::uuid)) v(a, role) loop
    insert into auth.users (id, email) values (l.a, l.a::text || '@m29.invalid');
    insert into public.auth_identities (auth_user_id, kind) values (l.a, 'platform');
    insert into public.system_users (id, auth_user_id, display_name) values (l.a, l.a, 'pa');
    insert into public.platform_admin_assignments (system_user_id, platform_admin_role_id) values (l.a, l.role);
  end loop;
end $$;
-- مستخدم Tenant بـtenant.read (tenant_admin المبذور)
insert into auth.users (id, email) values ('c1000000-0000-0000-0000-000000000001', 'ta@m29.invalid');
insert into public.auth_identities (auth_user_id, kind) values ('c1000000-0000-0000-0000-000000000001', 'tenant');
with p as (insert into public.profiles (platform_tenant_id, auth_user_id, display_name)
           values ('10000000-0000-0000-0000-000000000001', 'c1000000-0000-0000-0000-000000000001', 'ta') returning id),
     m as (insert into public.memberships (platform_tenant_id, profile_id) select '10000000-0000-0000-0000-000000000001', id from p returning id),
     s as (insert into public.membership_scopes (membership_id, platform_tenant_id, scope_type) select id, '10000000-0000-0000-0000-000000000001', 'tenant' from m)
insert into public.membership_roles (membership_id, role_id, platform_tenant_id, role_owner_key)
  select m.id, r.id, '10000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000000'
  from m, public.roles r where r.code = 'tenant_admin' and r.platform_tenant_id is null;

-- ============ القراءة المُدقَّقة ============
create temp table mark (n int);
grant all on mark to public;
insert into mark select pg_temp.audits();
select pg_temp.run('list', 'b1000000-0000-0000-0000-000000000001', $q$select string_agg(tenant_code, ',' order by tenant_code) from app.platform_read_tenants() where tenant_code in ('T1', 'T2')$q$);
select pg_temp.rec('list.audits', $q$select (pg_temp.audits() - (select n from mark))::text$q$);
select pg_temp.rec('list.shape', $q$select string_agg(distinct actor_type || ':' || actor_id || ':' || source || ':' || (new_values->>'resource'), ',')
  from public.audit_log where action = 'read' and entity_type = 'platform_tenants' and entity_id in ('10000000-0000-0000-0000-000000000001','20000000-0000-0000-0000-000000000002')$q$);
update mark set n = pg_temp.audits();
select pg_temp.run('one', 'b1000000-0000-0000-0000-000000000001', $q$select tenant_code from app.platform_read_tenants('20000000-0000-0000-0000-000000000002')$q$);
select pg_temp.rec('one.audits', $q$select (pg_temp.audits() - (select n from mark))::text$q$);

-- ============ الرفض ============
update mark set n = pg_temp.audits();
select pg_temp.run('no_perm', 'b2000000-0000-0000-0000-000000000002', $q$select count(*)::text from app.platform_read_tenants()$q$);
select pg_temp.run('tenant_user', 'c1000000-0000-0000-0000-000000000001', $q$select count(*)::text from app.platform_read_tenants()$q$);
select pg_temp.run('no_jwt', null, $q$select count(*)::text from app.platform_read_tenants()$q$);
select pg_temp.rec('reject.audits', $q$select (pg_temp.audits() - (select n from mark))::text$q$);

-- ============ لا قراءة مباشرة (نظير PostgREST) ============
select pg_temp.run('direct', 'b1000000-0000-0000-0000-000000000001', $q$select (select count(*) from public.platform_tenants) || '/' ||
  (select count(*) from public.groups) || '/' || (select count(*) from public.schools)$q$);
select pg_temp.run('direct_update', 'b1000000-0000-0000-0000-000000000001', $q$update public.platform_tenants set name = 'x' returning 'ok'$q$);
select pg_temp.run('tenant_direct', 'c1000000-0000-0000-0000-000000000001', $q$select string_agg(tenant_code, ',') from public.platform_tenants$q$);

-- ============ fail closed: التدقيق يفشل ⇒ لا بيانات ============
update mark set n = pg_temp.audits();
do $$
declare x text;
begin
  begin
    revoke insert on public.audit_log from app_owner;                  -- يُلغى مع الـsubtransaction
    perform pg_temp.run('audit_fails', 'b1000000-0000-0000-0000-000000000001', $q$select string_agg(tenant_code, ',') from app.platform_read_tenants()$q$);
    select v into x from r where k = 'audit_fails';
    raise exception 'undo';
  exception when others then
    if sqlerrm <> 'undo' then raise; end if;
  end;
  insert into r values ('audit_fails', x) on conflict (k) do update set v = excluded.v;   -- المتغير يبقى بعد الإلغاء
end $$;

select plan(15);

select is((select v from r where k = 'list'), 'T1,T2', 'platform admin with tenant.read: the tenants, through the function');
select is((select v from r where k = 'list.audits'), '2', 'one N5 audit row per tenant returned');
select is((select v from r where k = 'list.shape'), 'platform_admin:b1000000-0000-0000-0000-000000000001:api:platform_tenant_list',
          'audited as the platform admin (system user), source api, resource platform_tenant_list');
select is((select v from r where k = 'one'), 'T2', 'single tenant read');
select is((select v from r where k = 'one.audits'), '1', '… audited once');
select is((select v from r where k = 'no_perm'), '0', 'platform admin without tenant.read: no rows');
select ok((select v from r where k = 'tenant_user') like 'ERR 42501%forbidden%', 'a tenant user is not in platform context: forbidden');
select ok((select v from r where k = 'no_jwt') like 'ERR 42501%forbidden%', 'no JWT: forbidden');
select is((select v from r where k = 'reject.audits'), '0', 'refusals write no audit rows');
select is((select v from r where k = 'direct'), '0/0/0', 'W1: no direct Platform Admin read of platform_tenants, groups or schools');
select is((select v from r where k = 'direct_update'), '<null>', 'no direct Platform Admin update either (0 rows)');
select is((select v from r where k = 'tenant_direct'), 'T1', 'tenant users keep their own-tenant row (tenant policies unchanged)');
select ok((select v from r where k = 'audit_fails') like 'ERR 42501%permission denied for table audit_log%', 'fail closed: the audit write fails ⇒ the read fails, no data returned');
select ok(not has_function_privilege('anon', 'app.platform_read_tenants(uuid)', 'execute'), 'anon cannot execute');
select is((select pg_get_userbyid(proowner) || ':' || prosecdef || ':' || array_to_string(proconfig, ',') from pg_proc
            where oid = 'app.platform_read_tenants(uuid)'::regprocedure),
          'app_owner:true:search_path=app, public, pg_temp', 'owned by app_owner, SECURITY DEFINER, pinned search_path (R2)');

select * from finish();
rollback;
