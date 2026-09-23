-- M02 — T5، T6، temporary_id
-- app.current_profile_id() تُنشأ في M12؛ هنا بديل مؤقت داخل المعاملة (يُلغى) يقرأ GUC test.profile.
-- اختبار M12 يعيد التحقق من T6 مع الدالة الحقيقية.
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

create or replace function app.current_profile_id() returns uuid
language sql stable as $$ select nullif(current_setting('test.profile', true), '')::uuid $$;

-- ============ T5 ============
create table public.t5_target (id int primary key, v text);
insert into public.t5_target values (1, 'a'), (2, 'b');
create trigger t5_row  before update or delete on public.t5_target for each row       execute function app.tg_reject_mutation();
create trigger t5_stmt before truncate         on public.t5_target for each statement execute function app.tg_reject_mutation();
grant all on public.t5_target to service_role;

set local role service_role;
select pg_temp.rec('t5.service_update',   $q$update public.t5_target set v = 'x' where id = 1 returning 'ok'$q$);
select pg_temp.rec('t5.service_delete',   $q$delete from public.t5_target where id = 1 returning 'ok'$q$);
select pg_temp.rec('t5.service_truncate', $q$truncate public.t5_target; select 'ok'$q$);
select pg_temp.rec('t5.service_insert',   $q$insert into public.t5_target values (3, 'c') returning 'ok'$q$);
reset role;
select pg_temp.rec('t5.rows_after', 'select count(*)::text from public.t5_target');

-- ============ T6 ============
create table public.t6_full (
  id int primary key, v text,
  created_at timestamptz, created_by uuid, updated_at timestamptz, updated_by uuid);
create table public.t6_partial (id int primary key, v text, created_at timestamptz, updated_at timestamptz);
create table public.t6_grant   (id int primary key, granted_at timestamptz, granted_by uuid);
create trigger stamp before insert or update on public.t6_full    for each row execute function app.tg_stamp();
create trigger stamp before insert or update on public.t6_partial for each row execute function app.tg_stamp();
create trigger stamp before insert or update on public.t6_grant   for each row execute function app.tg_stamp();

-- إدراج بفاعل A مع قيم مزوّرة من العميل
select set_config('test.profile', 'aaaaaaaa-0000-0000-0000-000000000001', true);
insert into public.t6_full values
  (1, 'x', '2000-01-01', 'ffffffff-ffff-ffff-ffff-ffffffffffff', '2000-01-01', 'ffffffff-ffff-ffff-ffff-ffffffffffff');
insert into public.t6_partial (id, v, created_at) values (1, 'x', '2000-01-01');
insert into public.t6_grant values (1, '2000-01-01', 'ffffffff-ffff-ffff-ffff-ffffffffffff');

-- تعديل بفاعل B يحاول تغيير created_* و updated_*
select set_config('test.profile', 'bbbbbbbb-0000-0000-0000-000000000002', true);
update public.t6_full set v = 'y', created_at = '1999-01-01', created_by = 'ffffffff-ffff-ffff-ffff-ffffffffffff',
                          updated_at = '1999-01-01', updated_by = 'ffffffff-ffff-ffff-ffff-ffffffffffff' where id = 1;
update public.t6_grant set granted_by = 'ffffffff-ffff-ffff-ffff-ffffffffffff' where id = 1;

-- سياق service: لا فاعل
select set_config('test.profile', '', true);
insert into public.t6_full (id, v) values (2, 'svc');

-- ============ temporary_id ============
select pg_temp.rec('tmp.first',  'select app.next_temporary_id()');
select pg_temp.rec('tmp.second', 'select app.next_temporary_id()');
-- فجوة بعد rollback: الرقم المهجور لا يُعاد
-- (الرقم المهجور يُستهلك داخل savepoint لا يُسجَّل فيه شيء — الـrollback يلغي أي سجل بداخله)
savepoint sp;
select app.next_temporary_id();
rollback to savepoint sp;
select pg_temp.rec('tmp.after_rollback', 'select app.next_temporary_id()');
-- حدود الطول: لا قطع بعد 6 خانات
select setval('app.temporary_id_seq', 999998);
select pg_temp.rec('tmp.n999999',  'select app.next_temporary_id()');
select pg_temp.rec('tmp.n1000000', 'select app.next_temporary_id()');

select plan(26);

-- T5
select ok((select v from r where k = 't5.service_update')   like 'ERR 42501%', 'T5: UPDATE rejected even for service_role');
select ok((select v from r where k = 't5.service_delete')   like 'ERR 42501%', 'T5: DELETE rejected even for service_role');
select ok((select v from r where k = 't5.service_truncate') like 'ERR 42501%', 'T5: TRUNCATE rejected even for service_role (statement trigger)');
select is((select v from r where k = 't5.service_insert'), 'ok',               'T5: INSERT still allowed');
select is((select v from r where k = 't5.rows_after'), '3',                     'T5: no existing row was changed or removed');
select throws_ok($$update public.t5_target set v = 'z'$$, '42501', null,        'T5: UPDATE rejected for postgres (table owner)');

-- T6 — إدراج
select is((select created_by::text from public.t6_full where id = 1), 'aaaaaaaa-0000-0000-0000-000000000001', 'T6 insert: created_by = actor (forged value ignored)');
select is((select updated_by::text from public.t6_full where id = 1), 'bbbbbbbb-0000-0000-0000-000000000002', 'T6 update: updated_by = new actor');
select ok((select created_at = now() from public.t6_full where id = 1),         'T6 insert: created_at = now() (forged 2000-01-01 ignored)');
select ok((select updated_at = now() from public.t6_full where id = 1),         'T6 update: updated_at = now() (forged 1999-01-01 ignored)');
select is((select v from public.t6_full where id = 1), 'y',                      'T6 update: business column updated normally');
-- T6 — تعديل
select is((select created_by::text from public.t6_full where id = 1), 'aaaaaaaa-0000-0000-0000-000000000001', 'T6 update: created_by immutable');
select ok((select created_at <> '1999-01-01'::timestamptz from public.t6_full where id = 1), 'T6 update: created_at immutable');
-- T6 — جداول بأعمدة ناقصة
select ok((select created_at = now() and updated_at = now() from public.t6_partial where id = 1), 'T6: works on a table without *_by columns');
select is((select granted_by::text from public.t6_grant where id = 1), 'aaaaaaaa-0000-0000-0000-000000000001', 'T6: granted_by stamped on insert and immutable on update');
-- T6 — سياق service
select is((select created_by from public.t6_full where id = 2), null::uuid,     'T6: no actor in service context → created_by NULL');

-- temporary_id
select ok((select v from r where k = 'tmp.first') ~ ('^TMP-' || to_char(now(), 'YYYY') || '-[0-9]{6,}$'), 'temporary_id: format TMP-{YEAR}-{SEQ}');
select ok(split_part((select v from r where k = 'tmp.second'), '-', 3)::bigint = split_part((select v from r where k = 'tmp.first'), '-', 3)::bigint + 1,
          'temporary_id: sequential');
select ok(split_part((select v from r where k = 'tmp.after_rollback'), '-', 3)::bigint = split_part((select v from r where k = 'tmp.second'), '-', 3)::bigint + 2,
          'temporary_id: number abandoned by rollback is never reused (gap of one)');
select is(split_part((select v from r where k = 'tmp.n999999'),  '-', 3), '999999',  'temporary_id: 6-digit boundary');
select is(split_part((select v from r where k = 'tmp.n1000000'), '-', 3), '1000000', 'temporary_id: 7 digits NOT truncated (lpad bug fixed)');

-- الملكية والصلاحيات
select ok((select bool_and(pg_get_userbyid(proowner) = 'app_owner') from pg_proc
           where oid in ('app.tg_reject_mutation()'::regprocedure, 'app.tg_stamp()'::regprocedure, 'app.next_temporary_id()'::regprocedure)),
          'M02 functions owned by app_owner');
select is_definer('app', 'tg_stamp', array[]::text[], 'T6 is SECURITY DEFINER');
select ok(not has_function_privilege('anon', 'app.next_temporary_id()', 'EXECUTE')
      and not has_function_privilege('authenticated', 'app.next_temporary_id()', 'EXECUTE'),
          'next_temporary_id(): no EXECUTE for API roles (provisioning functions only)');
select ok(not has_sequence_privilege('authenticated', 'app.temporary_id_seq', 'USAGE')
      and not has_sequence_privilege('anon', 'app.temporary_id_seq', 'USAGE'),
          'temporary_id_seq: no direct access for API roles');
-- M20 مسبقاً: لا دالة في app ينفذها anon (يستثني البديل المؤقت في هذا الاختبار)
select is((select count(*)::int from pg_proc p where p.pronamespace = 'app'::regnamespace
             and p.oid <> 'app.current_profile_id()'::regprocedure
             and has_function_privilege('anon', p.oid, 'EXECUTE')), 0,
          'no function in schema app is executable by anon');

select * from finish();
rollback;
