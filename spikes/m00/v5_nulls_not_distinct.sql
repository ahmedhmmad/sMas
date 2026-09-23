-- V5 — UNIQUE NULLS NOT DISTINCT (PG15+) لـmembership_scopes، مع ضابط سلبي يثبت خطأ D8

select m00.rec('V5.server_version',     'select current_setting(''server_version'')');
select m00.rec('V5.server_version_num', 'select current_setting(''server_version_num'')');

-- الضابط السلبي: الصيغة الأصلية في Data Dictionary قبل Gate B
create table m00.scopes_plain (
  membership_id uuid not null, scope_type text not null, group_id uuid, school_id uuid,
  unique (membership_id, scope_type, group_id, school_id)
);
insert into m00.scopes_plain values ('aaaaaaaa-0000-0000-0000-000000000001', 'tenant', null, null);
select m00.rec('V5.plain_unique_duplicate_tenant_scope',
  $q$insert into m00.scopes_plain values ('aaaaaaaa-0000-0000-0000-000000000001','tenant',null,null) returning 'accepted'$q$);

-- الصيغة المصحَّحة
create table m00.scopes_nnd (
  membership_id uuid not null, scope_type text not null, group_id uuid, school_id uuid,
  unique nulls not distinct (membership_id, scope_type, group_id, school_id)
);
insert into m00.scopes_nnd values ('aaaaaaaa-0000-0000-0000-000000000001', 'tenant', null, null);
select m00.rec('V5.nnd_duplicate_tenant_scope',
  $q$insert into m00.scopes_nnd values ('aaaaaaaa-0000-0000-0000-000000000001','tenant',null,null) returning 'accepted'$q$);
select m00.rec('V5.nnd_second_school_scope',
  $q$insert into m00.scopes_nnd values ('aaaaaaaa-0000-0000-0000-000000000001','school',null,'a0000000-0000-0000-0000-00000000000a') returning 'accepted'$q$);

select plan(4);
select ok((select v from m00_res where k = 'V5.server_version_num')::int >= 150000,
  'V5: Postgres >= 15');
select is((select v from m00_res where k = 'V5.plain_unique_duplicate_tenant_scope'), 'accepted',
  'V5 negative control: plain UNIQUE accepts duplicate tenant scope (D8 bug is real)');
select ok((select v from m00_res where k = 'V5.nnd_duplicate_tenant_scope') like 'ERR 23505%',
  'V5: NULLS NOT DISTINCT rejects duplicate tenant scope');
select is((select v from m00_res where k = 'V5.nnd_second_school_scope'), 'accepted',
  'V5: distinct scopes on the same membership still allowed');
select * from finish();
