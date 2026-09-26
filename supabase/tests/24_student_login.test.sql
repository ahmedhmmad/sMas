-- M24 — student_login: resolve_student_login (D1) — حل معرّف الدخول قبل JWT
-- يثبت: الحل داخل نطاق الهوية الصحيح فقط؛ الـTenant جزء من المدخل (الـslug فريد داخل الـTenant)؛
-- NULL واحد لكل أسباب الفشل (لا كشف لسبب)؛ لا يعيد إلا معرّف الحساب؛ EXECUTE لـservice_role وحده.
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

-- الحل كما يستدعيه FastAPI: دور service_role
create function pg_temp.resolve(p_key text, p_tenant text, p_slug text, p_id text) returns void
language plpgsql as $$
begin
  execute 'set local role service_role';
  perform pg_temp.rec(p_key, format('select app.resolve_student_login(%L, %L, %L)::text', p_tenant, p_slug, p_id));
  execute 'reset role';
end $$;

-- ============ Fixture ============
-- T1: GA (sa1، sa2)، GB (sb1)، مستقلة ss، مؤرشفة sx (في GA)   ·   T2: مستقلة بالـslug نفسه sa1
insert into public.platform_tenants (id, tenant_code, name) values
  ('10000000-0000-0000-0000-000000000001', 'T1', 'T1'), ('20000000-0000-0000-0000-000000000002', 'T2', 'T2');
insert into public.groups (id, platform_tenant_id, group_code, name) values
  ('a1000000-0000-0000-0000-00000000000a', '10000000-0000-0000-0000-000000000001', 'GA', 'GA'),
  ('a2000000-0000-0000-0000-00000000000b', '10000000-0000-0000-0000-000000000001', 'GB', 'GB');
insert into public.schools (id, platform_tenant_id, group_id, school_code, name, slug) values
  ('5a100000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', 'a1000000-0000-0000-0000-00000000000a', 'SA1', 'SA1', 'sa1'),
  ('5a200000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001', 'a1000000-0000-0000-0000-00000000000a', 'SA2', 'SA2', 'sa2'),
  ('5b100000-0000-0000-0000-000000000003', '10000000-0000-0000-0000-000000000001', 'a2000000-0000-0000-0000-00000000000b', 'SB1', 'SB1', 'sb1'),
  ('55000000-0000-0000-0000-000000000004', '10000000-0000-0000-0000-000000000001', null,                                   'SS',  'SS',  'ss'),
  ('5c000000-0000-0000-0000-000000000005', '10000000-0000-0000-0000-000000000001', 'a1000000-0000-0000-0000-00000000000a', 'SX',  'SX',  'sx'),
  ('52000000-0000-0000-0000-000000000006', '20000000-0000-0000-0000-000000000002', null,                                   'S2',  'S2',  'sa1');
update public.schools set status = 'archived', archived_at = now() where school_code = 'SX';

-- طالب بحساب: auth.users ← auth_identities ← profile ← student (D1: معرّف الحساب = معرّف الطالب)
create function pg_temp.student(p_id uuid, p_tenant uuid, p_scope_school text, p_official text, p_temp text, p_status text default 'active')
returns void language plpgsql as $$
declare v_scope uuid; v_profile uuid;
begin
  select i.id into v_scope from public.schools sc join public.identity_scopes i on i.owner_id = sc.scope_owner_id
    where sc.platform_tenant_id = p_tenant and sc.school_code = p_scope_school;
  insert into auth.users (id, email) values (p_id, p_id::text || '@students.smas.invalid');
  insert into public.auth_identities values (p_id, 'tenant');
  insert into public.profiles (platform_tenant_id, auth_user_id, display_name) values (p_tenant, p_id, 'st') returning id into v_profile;
  insert into public.students (id, platform_tenant_id, identity_scope_id, student_profile_id, official_id, official_id_type,
                               temporary_id, first_name, family_name, status, archived_at)
    values (p_id, p_tenant, v_scope, v_profile, p_official, case when p_official is not null then 'national_id' end,
            p_temp, 'S', 'T', p_status, case when p_status = 'archived' then now() end);
end $$;

select pg_temp.student('e1000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', 'SA1', '111', null);                -- GA
select pg_temp.student('e2000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001', 'SA1', null,  'TMP-2026-000102');   -- GA، مؤقت
select pg_temp.student('e3000000-0000-0000-0000-000000000003', '10000000-0000-0000-0000-000000000001', 'SS',  '111', null);                -- SS، المعرّف نفسه
select pg_temp.student('e4000000-0000-0000-0000-000000000004', '20000000-0000-0000-0000-000000000002', 'S2',  '111', null);                -- T2
select pg_temp.student('e5000000-0000-0000-0000-000000000005', '10000000-0000-0000-0000-000000000001', 'SA1', '555', null, 'withdrawn');
select pg_temp.student('e6000000-0000-0000-0000-000000000006', '10000000-0000-0000-0000-000000000001', 'SA1', '666', null, 'archived');
-- تطابق مزدوج في GA: Official لطالب = Temporary لآخر
select pg_temp.student('e7000000-0000-0000-0000-000000000007', '10000000-0000-0000-0000-000000000001', 'SA1', 'TMP-2026-000103', null);
select pg_temp.student('e8000000-0000-0000-0000-000000000008', '10000000-0000-0000-0000-000000000001', 'SA1', null, 'TMP-2026-000103');

-- ============ الحل ============
select pg_temp.resolve('official',        'T1', 'sa1', '111');
select pg_temp.resolve('group_school',    'T1', 'sa2', '111');               -- مدرسة أخرى في المجموعة نفسها = نطاق الهوية نفسه
select pg_temp.resolve('standalone',      'T1', 'ss',  '111');               -- المعرّف نفسه في نطاق آخر
select pg_temp.resolve('other_tenant',    'T2', 'sa1', '111');               -- الـslug نفسه في Tenant آخر
select pg_temp.resolve('temporary',       'T1', 'sa1', 'TMP-2026-000102');
select pg_temp.resolve('normalized',      ' t1 ', ' SA1 ', ' tmp-2026-000102 ');
-- فشل: كلها NULL واحد
select pg_temp.resolve('other_group',     'T1', 'sb1', '111');
select pg_temp.resolve('unknown_id',      'T1', 'sa1', '999');
select pg_temp.resolve('unknown_slug',    'T1', 'nope', '111');
select pg_temp.resolve('unknown_tenant',  'T9', 'sa1', '111');
select pg_temp.resolve('withdrawn',       'T1', 'sa1', '555');
select pg_temp.resolve('archived',        'T1', 'sa1', '666');
select pg_temp.resolve('archived_school', 'T1', 'sx',  '111');
select pg_temp.resolve('ambiguous',       'T1', 'sa1', 'TMP-2026-000103');
select pg_temp.resolve('empty',           'T1', 'sa1', '');
select pg_temp.resolve('null_id',         'T1', 'sa1', null);
update public.platform_tenants set status = 'suspended', suspended_at = now() where tenant_code = 'T1';
select pg_temp.resolve('suspended',       'T1', 'sa1', '111');
update public.platform_tenants set status = 'active', suspended_at = null where tenant_code = 'T1';

-- ============ الامتيازات ============
create function pg_temp.as_role(p_key text, p_role text) returns void
language plpgsql as $$
begin
  execute format('set local role %I', p_role);
  perform pg_temp.rec(p_key, $q$select app.resolve_student_login('T1', 'sa1', '111')::text$q$);
  execute 'reset role';
end $$;
select pg_temp.as_role('as_authenticated', 'authenticated');
select pg_temp.as_role('as_anon',          'anon');

select plan(26);

select is((select v from r where k = 'official'),     'e1000000-0000-0000-0000-000000000001', 'Official ID resolves to the account (D1: account id = student id)');
select is((select v from r where k = 'group_school'), 'e1000000-0000-0000-0000-000000000001', 'another school of the same group shares the identity scope');
select is((select v from r where k = 'standalone'),   'e3000000-0000-0000-0000-000000000003', 'the same ID in another identity scope resolves to that scope''s student');
select is((select v from r where k = 'other_tenant'), 'e4000000-0000-0000-0000-000000000004', 'the same slug in another tenant resolves inside that tenant only');
select is((select v from r where k = 'temporary'),    'e2000000-0000-0000-0000-000000000002', 'Temporary ID resolves');
select is((select v from r where k = 'normalized'),   'e2000000-0000-0000-0000-000000000002', 'input is trimmed; tenant code, slug and TMP prefix are case-normalized');

select is((select v from r where k = 'other_group'),     '<null>', 'a school of another group: another identity scope → NULL');
select is((select v from r where k = 'unknown_id'),      '<null>', 'unknown identifier → NULL');
select is((select v from r where k = 'unknown_slug'),    '<null>', 'unknown school → NULL');
select is((select v from r where k = 'unknown_tenant'),  '<null>', 'unknown tenant → NULL');
select is((select v from r where k = 'withdrawn'),       '<null>', 'withdrawn student → NULL');
select is((select v from r where k = 'archived'),        '<null>', 'archived student → NULL');
select is((select v from r where k = 'archived_school'), '<null>', 'archived school → NULL');
select is((select v from r where k = 'ambiguous'),       '<null>', 'two matches (an Official ID equal to another student''s Temporary ID) → NULL, never a guess');
select is((select v from r where k = 'empty'),           '<null>', 'empty identifier → NULL');
select is((select v from r where k = 'null_id'),         '<null>', 'NULL identifier → NULL');
select is((select v from r where k = 'suspended'),       '<null>', 'suspended tenant → NULL (M21b)');
select is((select count(distinct v)::int from r where k in ('other_group','unknown_id','unknown_slug','unknown_tenant','withdrawn','archived',
                                                            'archived_school','ambiguous','empty','null_id','suspended')), 1,
          'every failure reason yields the same single result — the caller cannot tell them apart');

select ok((select v from r where k = 'as_authenticated') like 'ERR 42501%permission denied for function resolve_student_login%', 'authenticated cannot execute (pre-login channel is the service only)');
select ok((select v from r where k = 'as_anon')          like 'ERR 42501%permission denied for schema app%', 'anon cannot even reach schema app (M01/M20: anon has nothing)');
select ok(has_function_privilege('service_role', 'app.resolve_student_login(text,text,text)', 'execute'), 'service_role can execute');
select is((select string_agg(g.rolname, ',' order by g.rolname) from pg_proc p, aclexplode(p.proacl) a join pg_roles g on g.oid = a.grantee
            where p.oid = 'app.resolve_student_login(text,text,text)'::regprocedure and a.privilege_type = 'EXECUTE'),
          'app_owner,service_role', 'EXECUTE: owner and service_role only');
select is(pg_get_userbyid((select proowner from pg_proc where oid = 'app.resolve_student_login(text,text,text)'::regprocedure)), 'app_owner', 'owned by app_owner (R2)');
select ok((select prosecdef from pg_proc where oid = 'app.resolve_student_login(text,text,text)'::regprocedure), 'SECURITY DEFINER');
select is((select array_to_string(proconfig, ',') from pg_proc where oid = 'app.resolve_student_login(text,text,text)'::regprocedure),
          'search_path=app, public, pg_temp', 'pinned search_path');
select is(pg_get_function_result('app.resolve_student_login(text,text,text)'::regprocedure), 'uuid', 'returns the account id only — no tenant, school or student data');

select * from finish();
rollback;
