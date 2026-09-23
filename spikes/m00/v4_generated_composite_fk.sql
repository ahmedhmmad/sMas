-- V4 — عمود GENERATED STORED طرفاً مرجَعاً في FK مركّب
--   (a) I9: مدرسة داخل Group لا تملك نطاق هوية خاصاً (schools.is_standalone)
--   (b) I16: الدور المُسنَد نظامي أو من Tenant العضوية (roles.owner_key) — يحل محل T1
--   (c) تغيير group_id لمدرسة لها نطاق مستقل يُرفض (الانضمام لمجموعة = إجراء دمج)

-- (a)
create table m00.schools (
  id            uuid primary key default gen_random_uuid(),
  group_id      uuid,
  is_standalone boolean generated always as (group_id is null) stored,
  unique (id, is_standalone)
);
create table m00.identity_scopes (
  id                   uuid primary key default gen_random_uuid(),
  school_id            uuid,
  school_is_standalone boolean not null default true check (school_is_standalone),
  foreign key (school_id, school_is_standalone) references m00.schools (id, is_standalone)
);

insert into m00.schools (id, group_id) values
  ('a0000000-0000-0000-0000-00000000000a', null),                                   -- مستقلة
  ('b0000000-0000-0000-0000-00000000000b', '99999999-9999-9999-9999-999999999999');  -- داخل Group

select m00.rec('V4a.scope_for_standalone',
  $q$insert into m00.identity_scopes (school_id) values ('a0000000-0000-0000-0000-00000000000a') returning 'ok'$q$);
select m00.rec('V4a.scope_for_grouped_school',
  $q$insert into m00.identity_scopes (school_id) values ('b0000000-0000-0000-0000-00000000000b') returning 'ok'$q$);

-- (c) مدرسة مستقلة لها نطاق تنضم إلى مجموعة → is_standalone يتغير → FK يرفض
select m00.rec('V4c.join_group_with_scope',
  $q$update m00.schools set group_id = '99999999-9999-9999-9999-999999999999' where id = 'a0000000-0000-0000-0000-00000000000a' returning 'ok'$q$);

-- (b)
create table m00.roles (
  id                 uuid primary key default gen_random_uuid(),
  platform_tenant_id uuid,
  owner_key          uuid generated always as
                       (coalesce(platform_tenant_id, '00000000-0000-0000-0000-000000000000'::uuid)) stored,
  unique (id, owner_key)
);
create table m00.membership_roles (
  membership_tenant_id uuid not null,
  role_id              uuid not null,
  role_owner_key       uuid not null,
  foreign key (role_id, role_owner_key) references m00.roles (id, owner_key),
  check (role_owner_key in (membership_tenant_id, '00000000-0000-0000-0000-000000000000'::uuid))
);
insert into m00.roles (id, platform_tenant_id) values
  ('10000000-0000-0000-0000-000000000001', null),                                     -- دور نظام
  ('20000000-0000-0000-0000-000000000002', '11111111-1111-1111-1111-111111111111'),   -- مخصص T1
  ('30000000-0000-0000-0000-000000000003', '22222222-2222-2222-2222-222222222222');   -- مخصص T2

select m00.rec('V4b.system_role_into_T1',
  $q$insert into m00.membership_roles values ('11111111-1111-1111-1111-111111111111','10000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-000000000000') returning 'ok'$q$);
select m00.rec('V4b.own_custom_role_into_T1',
  $q$insert into m00.membership_roles values ('11111111-1111-1111-1111-111111111111','20000000-0000-0000-0000-000000000002','11111111-1111-1111-1111-111111111111') returning 'ok'$q$);
-- دور T2 في عضوية T1: المفتاح الصادق يُرفض بالـCHECK
select m00.rec('V4b.foreign_role_honest_key',
  $q$insert into m00.membership_roles values ('11111111-1111-1111-1111-111111111111','30000000-0000-0000-0000-000000000003','22222222-2222-2222-2222-222222222222') returning 'ok'$q$);
-- دور T2 في عضوية T1 مع مفتاح مزوَّر: يُرفض بالـFK
select m00.rec('V4b.foreign_role_forged_key',
  $q$insert into m00.membership_roles values ('11111111-1111-1111-1111-111111111111','30000000-0000-0000-0000-000000000003','11111111-1111-1111-1111-111111111111') returning 'ok'$q$);

select plan(7);
select is((select v from m00_res where k = 'V4a.scope_for_standalone'), 'ok',
  'V4a: standalone school can own an identity scope');
select ok((select v from m00_res where k = 'V4a.scope_for_grouped_school') like 'ERR 23503%',
  'V4a: school inside a group cannot own a scope (FK on generated column)');
select ok((select v from m00_res where k = 'V4c.join_group_with_scope') like 'ERR 23503%',
  'V4c: changing group_id of a school that owns a scope is blocked');
select is((select v from m00_res where k = 'V4b.system_role_into_T1'), 'ok',
  'V4b: system role assignable in any tenant');
select is((select v from m00_res where k = 'V4b.own_custom_role_into_T1'), 'ok',
  'V4b: own custom role assignable');
select ok((select v from m00_res where k = 'V4b.foreign_role_honest_key') like 'ERR 23514%',
  'V4b: other tenant role rejected by CHECK');
select ok((select v from m00_res where k = 'V4b.foreign_role_forged_key') like 'ERR 23503%',
  'V4b: other tenant role with forged key rejected by FK');
select * from finish();
