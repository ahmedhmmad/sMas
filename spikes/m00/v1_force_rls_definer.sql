-- V1 — FORCE RLS + SECURITY DEFINER بلا recursion
-- نموذج مصغّر لـapp.current_tenant_id(): سياسة على profiles تستدعي دالة تقرأ profiles نفسها.

create table m00.profiles (
  id           uuid primary key default gen_random_uuid(),
  auth_user_id uuid not null unique,
  tenant_id    uuid not null
);
insert into m00.profiles (auth_user_id, tenant_id) values
  (:uid_a, '11111111-1111-1111-1111-111111111111'),
  (:uid_b, '11111111-1111-1111-1111-111111111111'),
  (:uid_c, '22222222-2222-2222-2222-222222222222');

create function m00.current_tenant_id() returns uuid
language sql stable security definer set search_path = m00, pg_temp
as $$ select tenant_id from m00.profiles where auth_user_id = auth.uid() $$;

alter table m00.profiles enable row level security;
alter table m00.profiles force  row level security;
create policy profiles_same_tenant on m00.profiles for select to authenticated
  using (tenant_id = m00.current_tenant_id());
grant select on m00.profiles to authenticated;

select m00.rec('V1.fn_owner',
  $q$select pg_get_userbyid(proowner) from pg_proc where proname = 'current_tenant_id' and pronamespace = 'm00'::regnamespace$q$);

-- المالك نفسه تحت FORCE وبلا سياسة له: يرى الكل فقط إن كان يحمل BYPASSRLS
select m00.rec('V1.owner_direct_rows', 'select count(*)::text from m00.profiles');

-- المستخدم A (tenant 1) — يجب أن يرى صفَّي tenant 1 بلا خطأ recursion
select m00.claims(:uid_a);
set local role authenticated;
select m00.rec('V1.user_a_rows',  'select count(*)::text from m00.profiles');
select m00.rec('V1.user_a_tenant','select m00.current_tenant_id()::text');
reset role;

-- المستخدم C (tenant 2) — يرى صفه وحده
select m00.claims(:uid_c);
set local role authenticated;
select m00.rec('V1.user_c_rows', 'select count(*)::text from m00.profiles');
reset role;

select plan(3);
select is((select v from m00_res where k = 'V1.user_a_rows'), '2',
  'V1: user A sees exactly the 2 rows of tenant 1 (no recursion)');
select is((select v from m00_res where k = 'V1.user_c_rows'), '1',
  'V1: user C sees only its own tenant row');
select ok((select v from m00_res where k = 'V1.user_a_rows') not like 'ERR%',
  'V1: policy calling a SECURITY DEFINER helper on the same table does not raise');
select * from finish();
