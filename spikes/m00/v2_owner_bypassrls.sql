-- V2 — مالك الدوال: إعداد R2 المعتمد (2026-09-23)
--
--   SECURITY DEFINER app functions
--           ↓
--   custom owner (NOLOGIN, BYPASSRLS)
--           ↓
--   app.auth_uid()        ← يملكها postgres، search_path فارغ، EXECUTE للمالك المخصص وحده
--           ↓
--   auth.uid()
--           ↓
--   real caller identity
--
-- m00 هنا يمثّل schema app، و m00_owner يمثّل app_owner.

-- ============ حقائق الأدوار ============
select m00.rec('V2.current_user',            'select current_user::text');
select m00.rec('V2.rolsuper',                $q$select rolsuper::text      from pg_roles where rolname = current_user$q$);
select m00.rec('V2.rolbypassrls',            $q$select rolbypassrls::text  from pg_roles where rolname = current_user$q$);
select m00.rec('V2.service_role_bypassrls',  $q$select rolbypassrls::text  from pg_roles where rolname = 'service_role'$q$);
select m00.rec('V2.authenticated_bypassrls', $q$select rolbypassrls::text  from pg_roles where rolname = 'authenticated'$q$);

-- ============ الدور المخصص ============
create role m00_owner nologin bypassrls;
grant m00_owner to current_user;                    -- PG16+: شرط ALTER ... OWNER TO
-- الـschema يبقى ملك postgres؛ المالك المخصص يُمنح USAGE و CREATE فقط (لا ملكية)
grant usage, create on schema m00 to m00_owner;

select m00.rec('V2.owner_attrs', $q$select format('login=%s bypassrls=%s super=%s createrole=%s', rolcanlogin, rolbypassrls, rolsuper, rolcreaterole) from pg_roles where rolname = 'm00_owner'$q$);
select m00.rec('V2.schema_owner', $q$select pg_get_userbyid(nspowner) from pg_namespace where nspname = 'm00'$q$);

-- ============ الدليل: المالك المخصص لا يصل إلى auth.uid() مباشرة ============
create table m00.profiles (
  id uuid primary key default gen_random_uuid(),
  auth_user_id uuid not null unique,
  tenant_id uuid not null
);
insert into m00.profiles (auth_user_id, tenant_id) values
  (:uid_a, '11111111-1111-1111-1111-111111111111'),
  (:uid_b, '11111111-1111-1111-1111-111111111111'),
  (:uid_c, '22222222-2222-2222-2222-222222222222');
grant select on m00.profiles to authenticated, m00_owner;
alter table m00.profiles enable row level security;
alter table m00.profiles force  row level security;

create function m00.tenant_direct() returns uuid
language sql stable security definer set search_path = m00, pg_temp
as $$ select tenant_id from m00.profiles where auth_user_id = auth.uid() $$;
alter function m00.tenant_direct() owner to m00_owner;

select m00.claims(:uid_a);
set local role authenticated;
select m00.rec('V2.direct_auth_uid_from_owner', 'select m00.tenant_direct()::text');
reset role;

-- ============ app.auth_uid() — الوسيط ============
create function m00.auth_uid() returns uuid
language sql stable security definer set search_path = ''
as $$ select auth.uid() $$;
revoke execute on function m00.auth_uid() from public, anon, authenticated;
grant  execute on function m00.auth_uid() to m00_owner;

select m00.rec('V2.wrapper_owner', $q$select pg_get_userbyid(proowner) from pg_proc where oid = 'm00.auth_uid()'::regprocedure$q$);
select m00.rec('V2.wrapper_config', $q$select array_to_string(proconfig, ',') from pg_proc where oid = 'm00.auth_uid()'::regprocedure$q$);
select m00.rec('V2.wrapper_args',   $q$select pronargs::text from pg_proc where oid = 'm00.auth_uid()'::regprocedure$q$);

-- ============ الدالة المساعدة كما ستُكتب: يملكها المالك المخصص وتستعمل الوسيط ============
create function m00.current_tenant_id() returns uuid
language sql stable security definer set search_path = m00, pg_temp
as $$ select tenant_id from m00.profiles where auth_user_id = m00.auth_uid() $$;
alter function m00.current_tenant_id() owner to m00_owner;
revoke execute on function m00.current_tenant_id() from public, anon;
grant  execute on function m00.current_tenant_id() to authenticated;

create policy profiles_same_tenant on m00.profiles for select to authenticated
  using (tenant_id = m00.current_tenant_id());

select m00.rec('V2.helper_owner', $q$select pg_get_userbyid(proowner) from pg_proc where oid = 'm00.current_tenant_id()'::regprocedure$q$);

select m00.claims(:uid_a);
set local role authenticated;
select m00.rec('V2.user_a_rows',   'select count(*)::text from m00.profiles');
select m00.rec('V2.user_a_tenant', 'select m00.current_tenant_id()::text');
reset role;

select m00.claims(:uid_c);
set local role authenticated;
select m00.rec('V2.user_c_rows', 'select count(*)::text from m00.profiles');
reset role;

-- ============ حماية الوسيط ============
-- (1) لا يستدعيه anon ولا authenticated مباشرة
select m00.rec('V2.wrapper_exec_anon',          $q$select has_function_privilege('anon', 'm00.auth_uid()', 'EXECUTE')::text$q$);
select m00.rec('V2.wrapper_exec_authenticated', $q$select has_function_privilege('authenticated', 'm00.auth_uid()', 'EXECUTE')::text$q$);
select m00.claims(:uid_a);
set local role authenticated;
select m00.rec('V2.wrapper_called_by_authenticated', 'select m00.auth_uid()::text');
reset role;

-- (2) لا يُرجع إلا هوية المستدعي: بلا معاملات، وتحت service role يُرجع NULL
--     (بدور المالك المخصص — الهوية التي تنفَّذ بها الدوال المساعدة فعلاً)
select m00.claims(null, 'service_role');
set local role m00_owner;
select m00.rec('V2.helper_under_service_role', 'select coalesce(m00.auth_uid()::text, ''<null>'')');
reset role;

-- (3) المالك المخصص لا يستطيع استبداله ولا حذفه (الـschema ليس ملكه)
set local role m00_owner;
select m00.rec('V2.owner_replace_wrapper',
  $q$create or replace function m00.auth_uid() returns uuid language sql as 'select ''00000000-0000-0000-0000-000000000000''::uuid'; select 'replaced'$q$);
select m00.rec('V2.owner_drop_wrapper', 'drop function m00.auth_uid(); select ''dropped''');
reset role;

-- (4) الوسيط لم يتغير
select m00.claims(:uid_b);
set local role authenticated;
select m00.rec('V2.after_attempts_user_b_tenant', 'select m00.current_tenant_id()::text');
reset role;

-- ============ التحققات ============
select plan(17);
select is((select v from m00_res where k = 'V2.rolbypassrls'), 'true',            'V2: migration role (postgres) has BYPASSRLS');
select is((select v from m00_res where k = 'V2.authenticated_bypassrls'), 'false', 'V2: authenticated has no BYPASSRLS');
select is((select v from m00_res where k = 'V2.owner_attrs'), 'login=f bypassrls=t super=f createrole=f',
  'V2: custom owner is NOLOGIN, BYPASSRLS, not super, no CREATEROLE');
select is((select v from m00_res where k = 'V2.schema_owner'), 'postgres',
  'V2: schema stays owned by postgres (custom owner has USAGE+CREATE only)');
select ok((select v from m00_res where k = 'V2.direct_auth_uid_from_owner') like 'ERR 42501%schema auth%',
  'V2 evidence: custom owner cannot reach auth.uid() directly');
select is((select v from m00_res where k = 'V2.wrapper_owner'), 'postgres',              'R2: app.auth_uid() owned by postgres');
select is((select v from m00_res where k = 'V2.wrapper_config'), 'search_path=""',       'R2: app.auth_uid() has empty search_path');
select is((select v from m00_res where k = 'V2.wrapper_args'), '0',                      'R2: app.auth_uid() takes no arguments');
select is((select v from m00_res where k = 'V2.helper_owner'), 'm00_owner',              'R2: helper is owned by the custom owner');
select is((select v from m00_res where k = 'V2.user_a_rows'), '2',
  'R2: FORCE RLS + helper owned by custom owner via app.auth_uid(): no recursion, correct rows');
select is((select v from m00_res where k = 'V2.user_c_rows'), '1',                       'R2: tenant isolation preserved for another tenant');
select is((select v from m00_res where k = 'V2.wrapper_exec_anon'), 'false',             'R2: anon cannot execute app.auth_uid()');
select is((select v from m00_res where k = 'V2.wrapper_exec_authenticated'), 'false',    'R2: authenticated cannot execute app.auth_uid()');
select ok((select v from m00_res where k = 'V2.wrapper_called_by_authenticated') like 'ERR 42501%',
  'R2: direct call by authenticated is denied');
select is((select v from m00_res where k = 'V2.helper_under_service_role'), '<null>',
  'R2: app.auth_uid() yields no identity in service context');
select ok((select v from m00_res where k = 'V2.owner_replace_wrapper') like 'ERR 42501%'
      and (select v from m00_res where k = 'V2.owner_drop_wrapper') like 'ERR 42501%',
  'R2: custom owner can neither replace nor drop app.auth_uid()');
select is((select v from m00_res where k = 'V2.after_attempts_user_b_tenant'), '11111111-1111-1111-1111-111111111111',
  'R2: identity chain intact after tampering attempts');
select * from finish();
