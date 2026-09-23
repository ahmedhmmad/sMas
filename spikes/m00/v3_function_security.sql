-- V3 — أمان الدوال المتحكَّم بها
--   (a) auth.uid() داخل SECURITY DEFINER = هوية المستدعي لا المالك
--   (b) search_path الثابت يمنع التظليل عبر pg_temp — مع ضابط سلبي يثبت أن الهجوم حقيقي
--   (c) EXECUTE الافتراضي لـPUBLIC، وأثر REVOKE (أساس اختبار M20)

-- (a)
create function m00.whoami() returns uuid
language sql stable security definer set search_path = m00, pg_temp
as $$ select auth.uid() $$;

select m00.claims(:uid_a);
set local role authenticated;
select m00.rec('V3a.whoami_inside_definer', 'select m00.whoami()::text');
select m00.rec('V3a.current_user_inside_call', 'select current_user::text');
reset role;

-- (b)
create table m00.items (n int);
insert into m00.items select generate_series(1, 3);
grant select on m00.items to authenticated;

set local search_path = m00, extensions, public;     -- لإنشاء الدوال: الاسم غير المؤهَّل يُحل عند الإنشاء
create function m00.count_safe() returns bigint
language sql stable security definer set search_path = m00, pg_temp
as $$ select count(*) from items $$;
create function m00.count_unsafe() returns bigint     -- ضابط سلبي: بلا search_path ثابت
language sql stable security definer
as $$ select count(*) from items $$;
set local search_path = extensions, public;

select m00.claims(:uid_a);
set local role authenticated;
-- المهاجم: جدول مؤقت بنفس الاسم + search_path يضع pg_temp أولاً
-- (يُتاح للجميع كي يصل إليه مالك الدالة: وإلا فشل الضابط السلبي بخطأ صلاحيات لا بتظليل)
create temp table items as select generate_series(1, 100) as n;
grant select on items to public;
set local search_path = pg_temp, m00, extensions, public;
select m00.rec('V3b.count_safe',   'select m00.count_safe()::text');
select m00.rec('V3b.count_unsafe', 'select m00.count_unsafe()::text');
reset role;
set local search_path = extensions, public;

-- (c)
create function m00.probe() returns int language sql as $$ select 1 $$;
select m00.rec('V3c.default_anon_exec',          $q$select has_function_privilege('anon', 'm00.probe()', 'EXECUTE')::text$q$);
select m00.rec('V3c.default_authenticated_exec', $q$select has_function_privilege('authenticated', 'm00.probe()', 'EXECUTE')::text$q$);
select m00.rec('V3c.default_acl',                $q$select coalesce(proacl::text, '<null = PUBLIC default>') from pg_proc where oid = 'm00.probe()'::regprocedure$q$);
select m00.rec('V3c.default_privileges_rows',    $q$select coalesce(string_agg(pg_get_userbyid(defaclrole) || '/' || case when defaclnamespace = 0 then 'ALL_SCHEMAS' else defaclnamespace::regnamespace::text end || '=' || defaclacl::text, ' ; ' order by 1), '<none>') from pg_default_acl where defaclobjtype = 'f'$q$);
-- هل تسري صلاحية افتراضية على schema جديد (مثل app)؟ دالة في schema مُنشأ الآن بلا أي GRANT صريح
create schema m00_fresh;
create function m00_fresh.probe() returns int language sql as $$ select 1 $$;
select m00.rec('V3c.fresh_schema_fn_acl', $q$select coalesce(proacl::text, '<null = PUBLIC default>') from pg_proc where oid = 'm00_fresh.probe()'::regprocedure$q$);

revoke execute on function m00.probe() from public, anon;
grant  execute on function m00.probe() to authenticated;
select m00.rec('V3c.after_revoke_anon_exec',          $q$select has_function_privilege('anon', 'm00.probe()', 'EXECUTE')::text$q$);
select m00.rec('V3c.after_revoke_authenticated_exec', $q$select has_function_privilege('authenticated', 'm00.probe()', 'EXECUTE')::text$q$);

-- استعلام M20: كل دالة في الـschema ينفذها anon — يجب أن يعيد صفراً بعد REVOKE الشامل
revoke execute on all functions in schema m00 from public, anon;
select m00.rec('V3c.m20_anon_executable_count',
  $q$select count(*)::text from pg_proc p where p.pronamespace = 'm00'::regnamespace and has_function_privilege('anon', p.oid, 'EXECUTE')$q$);

select plan(6);
select is((select v from m00_res where k = 'V3a.whoami_inside_definer'), 'aaaaaaaa-0000-0000-0000-000000000001',
  'V3a: auth.uid() inside SECURITY DEFINER is the caller identity (actor preserved)');
select is((select v from m00_res where k = 'V3b.count_safe'), '3',
  'V3b: fixed search_path ignores attacker temp table');
select is((select v from m00_res where k = 'V3b.count_unsafe'), '100',
  'V3b negative control: without fixed search_path the attack works (test is meaningful)');
select is((select v from m00_res where k = 'V3c.after_revoke_anon_exec'), 'false',
  'V3c: after REVOKE, anon cannot execute');
select is((select v from m00_res where k = 'V3c.after_revoke_authenticated_exec'), 'true',
  'V3c: authenticated keeps explicit EXECUTE');
select is((select v from m00_res where k = 'V3c.m20_anon_executable_count'), '0',
  'V3c: M20 catalog query finds no anon-executable function after schema-wide REVOKE');
select * from finish();
