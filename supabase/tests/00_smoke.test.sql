-- اختبار دخان: يثبت أن سلسلة CI (Supabase محلي + pgTAP) تعمل قبل وجود أي migration.
-- الامتدادات التي تعتمد عليها migrations الـFoundation متاحة للتثبيت.
begin;
select plan(3);

select ok(current_setting('server_version_num')::int >= 150000,
  'Postgres >= 15 (UNIQUE NULLS NOT DISTINCT)');
select ok(exists (select 1 from pg_available_extensions where name = 'btree_gist'),
  'btree_gist available (EXCLUDE constraints)');
select ok(exists (select 1 from pg_roles where rolname = 'authenticated')
      and exists (select 1 from pg_roles where rolname = 'anon'),
  'Supabase API roles exist');

select * from finish();
rollback;
