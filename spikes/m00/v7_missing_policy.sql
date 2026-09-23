-- V7 — جدول بلا سياسة تحت FORCE RLS: منع صامت للقراءة، وخطأ للكتابة؛ وأداة الكشف (أساس اختبار T3)

create table m00.with_policy    (id int primary key);
create table m00.without_policy (id int primary key);
create table m00.rls_disabled   (id int primary key);
insert into m00.with_policy    values (1), (2);
insert into m00.without_policy values (1), (2);
insert into m00.rls_disabled   values (1), (2);

alter table m00.with_policy    enable row level security;
alter table m00.with_policy    force  row level security;
alter table m00.without_policy enable row level security;
alter table m00.without_policy force  row level security;
create policy with_policy_read on m00.with_policy for select to authenticated using (true);
grant select, insert on m00.with_policy, m00.without_policy, m00.rls_disabled to authenticated;

select m00.claims(:uid_a);
set local role authenticated;
select m00.rec('V7.read_without_policy',  'select count(*)::text from m00.without_policy');
select m00.rec('V7.write_without_policy', $q$insert into m00.without_policy values (3) returning 'ok'$q$);
select m00.rec('V7.read_with_policy',     'select count(*)::text from m00.with_policy');
reset role;

-- أداة الكشف: كل جدول بلا RLS، أو بلا FORCE، أو بلا سياسة SELECT
select m00.rec('V7.detector_flags', $q$
  select string_agg(c.relname || ':' ||
           case when not c.relrowsecurity      then 'rls_disabled'
                when not c.relforcerowsecurity then 'not_forced'
                else 'no_select_policy' end, ',' order by c.relname)
  from pg_class c
  where c.relnamespace = 'm00'::regnamespace
    and c.relkind = 'r'
    and (   not c.relrowsecurity
         or not c.relforcerowsecurity
         or not exists (select 1 from pg_policies p
                        where p.schemaname = 'm00' and p.tablename = c.relname
                          and p.cmd in ('SELECT', 'ALL')))
$q$);

select plan(4);
select is((select v from m00_res where k = 'V7.read_without_policy'), '0',
  'V7: read on table without policy returns 0 rows silently (no error)');
select ok((select v from m00_res where k = 'V7.write_without_policy') like 'ERR 42501%',
  'V7: write on table without policy raises RLS violation');
select is((select v from m00_res where k = 'V7.read_with_policy'), '2',
  'V7: control table with policy is readable');
select is((select v from m00_res where k = 'V7.detector_flags'), 'rls_disabled:rls_disabled,without_policy:no_select_policy',
  'V7: detector flags exactly the unprotected tables and nothing else');
select * from finish();
