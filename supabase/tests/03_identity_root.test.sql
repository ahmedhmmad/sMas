-- M03 — identity_root: G10، O1، قيود platform_tenants و profiles، T6 بالدالة الحقيقية، RLS
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

create function pg_temp.claims(p_sub uuid) returns void
language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p_sub, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', coalesce(p_sub::text, ''), true);
end $$;

-- حسابات Auth للاختبار (تُلغى مع المعاملة)
insert into auth.users (id, email) values
  ('a1000000-0000-0000-0000-000000000001', 'm03-a@test.invalid'),
  ('a2000000-0000-0000-0000-000000000002', 'm03-b@test.invalid'),
  ('a3000000-0000-0000-0000-000000000003', 'm03-platform@test.invalid'),
  ('a4000000-0000-0000-0000-000000000004', 'm03-noident@test.invalid');

insert into public.auth_identities (auth_user_id, kind) values
  ('a1000000-0000-0000-0000-000000000001', 'tenant'),
  ('a2000000-0000-0000-0000-000000000002', 'tenant'),
  ('a3000000-0000-0000-0000-000000000003', 'platform');

insert into public.platform_tenants (id, tenant_code, name) values
  ('10000000-0000-0000-0000-000000000001', 'PAL-01', 'Tenant One'),
  ('20000000-0000-0000-0000-000000000002', 'PAL-02', 'Tenant Two');

-- profile A بلا فاعل (سياق service) ← created_by NULL
select pg_temp.claims(null);
insert into public.profiles (id, platform_tenant_id, auth_user_id, display_name) values
  ('b1000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', 'a1000000-0000-0000-0000-000000000001', 'A');

-- profile B بفاعل A ← created_by = profile A (T6 عبر app.current_profile_id() الحقيقية)
select pg_temp.claims('a1000000-0000-0000-0000-000000000001');
insert into public.profiles (id, platform_tenant_id, auth_user_id, display_name, created_by) values
  ('b2000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001', 'a2000000-0000-0000-0000-000000000002', 'B',
   'ffffffff-ffff-ffff-ffff-ffffffffffff');
select pg_temp.rec('fn.current_profile_as_a', 'select app.current_profile_id()::text');
select pg_temp.rec('fn.current_tenant_as_a',  'select app.current_tenant_id()::text');
select pg_temp.claims(null);

-- G10: حساب مسجَّل platform لا يصبح profile في Tenant
select pg_temp.rec('g10.platform_as_profile',
  $q$insert into public.profiles (platform_tenant_id, auth_user_id, display_name) values ('10000000-0000-0000-0000-000000000001','a3000000-0000-0000-0000-000000000003','X') returning 'ok'$q$);
-- G10: حساب بلا auth_identities لا يصبح profile
select pg_temp.rec('g10.no_identity_row',
  $q$insert into public.profiles (platform_tenant_id, auth_user_id, display_name) values ('10000000-0000-0000-0000-000000000001','a4000000-0000-0000-0000-000000000004','X') returning 'ok'$q$);
-- G10: لا سياقان لحساب واحد
select pg_temp.rec('g10.second_kind',
  $q$insert into public.auth_identities (auth_user_id, kind) values ('a1000000-0000-0000-0000-000000000001','platform') returning 'ok'$q$);
-- G10: identity_kind لا يُزوَّر
select pg_temp.rec('g10.forged_kind',
  $q$update public.profiles set identity_kind = 'platform' where id = 'b1000000-0000-0000-0000-000000000001' returning 'ok'$q$);
-- O1: نفس حساب Auth في Tenant ثانٍ
select pg_temp.rec('o1.same_auth_second_tenant',
  $q$insert into public.profiles (platform_tenant_id, auth_user_id, display_name) values ('20000000-0000-0000-0000-000000000002','a1000000-0000-0000-0000-000000000001','A2') returning 'ok'$q$);

-- platform_tenants
select pg_temp.rec('pt.bad_code',      $q$insert into public.platform_tenants (tenant_code, name) values ('pal 3','x') returning 'ok'$q$);
select pg_temp.rec('pt.dup_code',      $q$insert into public.platform_tenants (tenant_code, name) values ('PAL-01','x') returning 'ok'$q$);
select pg_temp.rec('pt.suspend_no_ts', $q$update public.platform_tenants set status = 'suspended' where tenant_code = 'PAL-01' returning 'ok'$q$);
select pg_temp.rec('pt.suspend_ok',    $q$update public.platform_tenants set status = 'suspended', suspended_at = now() where tenant_code = 'PAL-02' returning 'ok'$q$);

-- profiles
select pg_temp.rec('pr.bad_status', $q$update public.profiles set status = 'deleted' where id = 'b1000000-0000-0000-0000-000000000001' returning 'ok'$q$);
select pg_temp.rec('pr.blank_name', $q$update public.profiles set display_name = '   ' where id = 'b1000000-0000-0000-0000-000000000001' returning 'ok'$q$);

-- دالة الهوية تتجاهل الحساب المعلَّق
update public.profiles set status = 'suspended' where id = 'b2000000-0000-0000-0000-000000000002';
select pg_temp.claims('a2000000-0000-0000-0000-000000000002');
select pg_temp.rec('fn.current_profile_suspended', 'select coalesce(app.current_profile_id()::text, ''<null>'')');
select pg_temp.claims(null);

-- RLS: لا سياسات بعد → لا صفوف لأدوار الـAPI
select pg_temp.claims('a1000000-0000-0000-0000-000000000001');
set local role authenticated;
select pg_temp.rec('rls.auth_profiles', 'select count(*)::text from public.profiles');
select pg_temp.rec('rls.auth_tenants',  'select count(*)::text from public.platform_tenants');
select pg_temp.rec('rls.auth_insert',   $q$insert into public.platform_tenants (tenant_code, name) values ('HACK','x') returning 'ok'$q$);
reset role;
set local role anon;
select pg_temp.rec('rls.anon_profiles', 'select count(*)::text from public.profiles');
reset role;

select plan(28);

-- البنية
select has_table('public', 'auth_identities',  'auth_identities exists');
select has_table('public', 'platform_tenants', 'platform_tenants exists');
select has_table('public', 'profiles',         'profiles exists');
select ok((select bool_and(relrowsecurity and relforcerowsecurity) from pg_class
           where oid in ('public.auth_identities'::regclass, 'public.platform_tenants'::regclass, 'public.profiles'::regclass)),
          'RLS enabled and forced on all three tables at creation');

-- G10
select ok((select v from r where k = 'g10.platform_as_profile') like 'ERR 23503%', 'G10: platform-kind account cannot become a tenant profile');
select ok((select v from r where k = 'g10.no_identity_row')     like 'ERR 23503%', 'G10: account without identity row cannot become a profile');
select ok((select v from r where k = 'g10.second_kind')         like 'ERR 23505%', 'G10: one account cannot hold two security contexts');
select ok((select v from r where k = 'g10.forged_kind')         like 'ERR 23514%', 'G10: identity_kind cannot be changed from tenant');

-- O1
select ok((select v from r where k = 'o1.same_auth_second_tenant') like 'ERR 23505%', 'O1: same Auth user cannot have a profile in a second tenant');
select col_is_unique('public', 'profiles', array['auth_user_id'], 'O1: profiles.auth_user_id is globally unique');

-- platform_tenants
select ok((select v from r where k = 'pt.bad_code')      like 'ERR 23514%', 'tenant_code format enforced');
select ok((select v from r where k = 'pt.dup_code')      like 'ERR 23505%', 'tenant_code globally unique');
select ok((select v from r where k = 'pt.suspend_no_ts') like 'ERR 23514%', 'status suspended requires suspended_at');
select is((select v from r where k = 'pt.suspend_ok'), 'ok',                  'suspension with timestamp accepted');

-- profiles
select ok((select v from r where k = 'pr.bad_status') like 'ERR 23514%', 'profile status restricted');
select ok((select v from r where k = 'pr.blank_name') like 'ERR 23514%', 'profile display_name cannot be blank');
select col_is_unique('public', 'profiles', array['id', 'platform_tenant_id'], 'profiles (id, platform_tenant_id) unique for composite FKs');

-- دوال الهوية + T6
select is((select v from r where k = 'fn.current_profile_as_a'), 'b1000000-0000-0000-0000-000000000001', 'current_profile_id() resolves the caller profile');
select is((select v from r where k = 'fn.current_tenant_as_a'),  '10000000-0000-0000-0000-000000000001', 'current_tenant_id() resolves the caller tenant');
select is((select v from r where k = 'fn.current_profile_suspended'), '<null>', 'suspended profile yields no identity');
select is((select created_by from public.profiles where id = 'b1000000-0000-0000-0000-000000000001'), null::uuid,
          'T6: service context → created_by NULL');
select is((select created_by::text from public.profiles where id = 'b2000000-0000-0000-0000-000000000002'), 'b1000000-0000-0000-0000-000000000001',
          'T6: created_by = caller profile via real current_profile_id() (forged value ignored)');
select ok((select bool_and(pg_get_userbyid(proowner) = 'app_owner' and prosecdef) from pg_proc
           where oid in ('app.current_profile_id()'::regprocedure, 'app.current_tenant_id()'::regprocedure)),
          'identity functions: SECURITY DEFINER owned by app_owner');
select ok(not has_function_privilege('anon', 'app.current_profile_id()', 'EXECUTE')
      and not has_function_privilege('anon', 'app.current_tenant_id()', 'EXECUTE'),
          'identity functions: no EXECUTE for anon');

-- RLS
select is((select v from r where k = 'rls.auth_profiles'), '1', 'RLS (M15 self branch): an authenticated user without permissions sees only its own profile');
select is((select v from r where k = 'rls.auth_tenants'),  '0', 'RLS: an authenticated user without tenant scope and tenant.read sees no tenant');
select ok((select v from r where k = 'rls.auth_insert') like 'ERR 42501%', 'RLS: an authenticated tenant user cannot insert a tenant (platform only, K4)');
select ok((select v from r where k = 'rls.anon_profiles') like 'ERR 42501%permission denied%profiles%', 'anon has no privilege on profiles (M20)');

select * from finish();
rollback;
