-- M01 — setup: تحققات R2 و V3c على الكائنات الحقيقية
-- النمط: العمليات بأدوار منتحَلة تُسجَّل في جدول مؤقت، ثم تُفحص بـpgTAP بهوية postgres.
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

create function pg_temp.claims(p_sub uuid, p_role text default 'authenticated') returns void
language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p_sub, 'role', p_role)::text, true);
  perform set_config('request.jwt.claim.sub', coalesce(p_sub::text, ''), true);
  perform set_config('request.jwt.claim.role', p_role, true);
end $$;

-- دالة مساعدة تجريبية كما ستُكتب في M12: تُنشأ بهوية app_owner وتقرأ الفاعل عبر app.auth_uid()
set local role app_owner;
create function app.t_whoami() returns uuid
language sql stable security definer set search_path = app, pg_temp
as $$ select app.auth_uid() $$;
reset role;

-- أثر الصلاحيات الافتراضية: t_whoami لم تُمنح لأحد بعد
select pg_temp.rec('probe_anon_exec_default',          $q$select has_function_privilege('anon', 'app.t_whoami()', 'EXECUTE')::text$q$);
select pg_temp.rec('probe_authenticated_exec_default', $q$select has_function_privilege('authenticated', 'app.t_whoami()', 'EXECUTE')::text$q$);
grant execute on function app.t_whoami() to authenticated;

-- سلسلة الهوية بهوية مستخدم
select pg_temp.claims('aaaaaaaa-0000-0000-0000-000000000001');
set local role authenticated;
select pg_temp.rec('chain_caller',        'select app.t_whoami()::text');
select pg_temp.rec('direct_wrapper_call', 'select app.auth_uid()::text');
reset role;

-- سياق service
select pg_temp.claims(null, 'service_role');
set local role app_owner;
select pg_temp.rec('wrapper_service_context', 'select coalesce(app.auth_uid()::text, ''<null>'')');
reset role;

-- محاولات تلاعب من app_owner
set local role app_owner;
select pg_temp.rec('owner_replace_wrapper',
  $q$create or replace function app.auth_uid() returns uuid language sql as 'select null::uuid'; select 'replaced'$q$);
select pg_temp.rec('owner_drop_wrapper', 'drop function app.auth_uid(); select ''dropped''');
reset role;

select plan(21);

-- الامتدادات
select has_extension('extensions', 'btree_gist', 'btree_gist installed in schema extensions');

-- schema app
select schema_owner_is('app', 'postgres', 'schema app is owned by postgres (not app_owner)');
select ok(has_schema_privilege('authenticated', 'app', 'USAGE'), 'authenticated has USAGE on app');
select ok(not has_schema_privilege('anon', 'app', 'USAGE'), 'anon has no USAGE on app');
select ok(not has_schema_privilege('authenticated', 'app', 'CREATE'), 'authenticated cannot CREATE in app');

-- app_owner
select is((select format('login=%s bypassrls=%s super=%s createrole=%s', rolcanlogin, rolbypassrls, rolsuper, rolcreaterole)
             from pg_roles where rolname = 'app_owner'),
          'login=f bypassrls=t super=f createrole=f', 'app_owner: NOLOGIN, BYPASSRLS, not super, no CREATEROLE');
select ok(has_schema_privilege('app_owner', 'app', 'USAGE') and has_schema_privilege('app_owner', 'app', 'CREATE'),
          'app_owner has USAGE + CREATE on app');
select ok(not pg_has_role('authenticated', 'app_owner', 'MEMBER') and not pg_has_role('anon', 'app_owner', 'MEMBER'),
          'API roles are not members of app_owner');

-- app.auth_uid()
select function_owner_is('app', 'auth_uid', array[]::text[], 'postgres', 'app.auth_uid() owned by postgres');
select is_definer('app', 'auth_uid', array[]::text[], 'app.auth_uid() is SECURITY DEFINER');
select is((select array_to_string(proconfig, ',') from pg_proc where oid = 'app.auth_uid()'::regprocedure),
          'search_path=""', 'app.auth_uid() has empty search_path');
select ok(not has_function_privilege('anon', 'app.auth_uid()', 'EXECUTE')
      and not has_function_privilege('authenticated', 'app.auth_uid()', 'EXECUTE')
      and has_function_privilege('app_owner', 'app.auth_uid()', 'EXECUTE'),
          'app.auth_uid(): EXECUTE for app_owner only');

-- الصلاحيات الافتراضية (V3c)
select ok(exists (select 1 from pg_default_acl
                  where defaclrole = 'app_owner'::regrole and defaclnamespace = 0 and defaclobjtype = 'f'),
          'default ACL for functions is set FOR ROLE app_owner (global, not IN SCHEMA)');
select function_owner_is('app', 't_whoami', array[]::text[], 'app_owner', 'function created under app_owner is born owned by app_owner');
select is((select v from r where k = 'probe_anon_exec_default'), 'false',          'new app function: no EXECUTE for anon by default');
select is((select v from r where k = 'probe_authenticated_exec_default'), 'false', 'new app function: no EXECUTE for authenticated by default');

-- سلسلة الهوية
select is((select v from r where k = 'chain_caller'), 'aaaaaaaa-0000-0000-0000-000000000001',
          'identity chain: helper owned by app_owner sees the real caller via app.auth_uid()');
select ok((select v from r where k = 'direct_wrapper_call') like 'ERR 42501%',
          'authenticated cannot call app.auth_uid() directly');
select is((select v from r where k = 'wrapper_service_context'), '<null>',
          'app.auth_uid() yields no identity in service context');
select ok((select v from r where k = 'owner_replace_wrapper') like 'ERR 42501%',
          'app_owner cannot replace app.auth_uid()');
select ok((select v from r where k = 'owner_drop_wrapper') like 'ERR 42501%',
          'app_owner cannot drop app.auth_uid()');

select * from finish();
rollback;
