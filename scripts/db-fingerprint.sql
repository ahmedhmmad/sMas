-- E6 — بصمة حالة قاعدة البيانات: تُشغَّل على المصدر وعلى النسخة المستعادة وتُقارَن سطراً بسطر.
-- البنية (خصائص القاعدة، مالكو الـschemas وصلاحياتها، تعريف الأعمدة، مالكو الجداول، القيود، RLS + FORCE، السياسات، الدوال وملكيتها وصلاحياتها، الـtriggers، الصلاحيات على الجداول
-- والأعمدة، الصلاحيات الافتراضية) + البيانات (عدد وhash كل جدول) + التسلسلات + سجل الـmigrations + حسابات Auth.
-- المخرج: سطر لكل عنصر بصيغة  <فئة> | <مفتاح> | <قيمة>  مرتباً ترتيباً حتمياً.

\set ON_ERROR_STOP on
\pset tuples_only on
\pset format unaligned

with
-- خصائص مستوى القاعدة لا يحملها pg_dump بلا --create (المالك، الصلاحيات، الإعدادات)؛ ملكية القاعدة تحدد
-- عضوية pg_database_owner الذي يملك schema public — فرق فيها يغيّر من يُنشئ في public
db as (
  select 'database' as k, 'owner' as key, pg_get_userbyid(datdba)::text as val from pg_database where datname = current_database()
  union all
  select 'database', 'acl', coalesce(datacl::text, '-')
  from pg_database where datname = current_database()
  union all
  select 'database', 'setting ' || coalesce(pg_get_userbyid(nullif(s.setrole, 0)), '*'), array_to_string(s.setconfig, ',')
  from pg_db_role_setting s join pg_database d on d.oid = s.setdatabase where d.datname = current_database()
),
schemas as (
  select 'schema', nspname::text, format('owner=%s acl=%s', pg_get_userbyid(nspowner), coalesce(nspacl::text, '-'))
  from pg_namespace where nspname in ('public', 'app', 'auth', 'extensions', 'supabase_migrations')
),
tables as (
  select 'table' as k, c.relname as key,
         format('rls=%s force=%s acl=%s', c.relrowsecurity, c.relforcerowsecurity, coalesce(c.relacl::text, '-')) as val
  from pg_class c where c.relnamespace = 'public'::regnamespace and c.relkind = 'r'
),
-- مراجعة Stage 1 (R9): تعريف كل عمود — النوع، NULL، الافتراضي، المحسوب، identity — بترتيبه المنطقي (لا attnum الخام:
-- عمود محذوف يترك فجوة في المصدر لا تظهر بعد الاستعادة)
table_columns as (
  select 'column', c.relname || '.' || a.attname,
         format('pos=%s type=%s notnull=%s default=%s generated=%s identity=%s',
                row_number() over (partition by c.oid order by a.attnum), format_type(a.atttypid, a.atttypmod), a.attnotnull,
                coalesce(pg_get_expr(d.adbin, d.adrelid), '-'), coalesce(nullif(a.attgenerated::text, ''), '-'),
                coalesce(nullif(a.attidentity::text, ''), '-'))
  from pg_class c join pg_attribute a on a.attrelid = c.oid and a.attnum > 0 and not a.attisdropped
  left join pg_attrdef d on d.adrelid = a.attrelid and d.adnum = a.attnum
  where c.relnamespace = 'public'::regnamespace and c.relkind = 'r'
),
table_owners as (
  select 'table_owner', c.relname::text, pg_get_userbyid(c.relowner)::text
  from pg_class c where c.relnamespace = 'public'::regnamespace and c.relkind = 'r'
),
trigger_state as (
  select 'trigger_state', t.tgrelid::regclass::text || '.' || t.tgname, t.tgenabled::text
  from pg_trigger t join pg_class c on c.oid = t.tgrelid
  where not t.tgisinternal and c.relnamespace = 'public'::regnamespace
),
-- ACL الفعلي: ACL صريح يساوي الافتراضي (المالك وحده) لا يكتبه pg_dump فيُستعاد NULL — المعنى واحد، فيُطبَّع بـacldefault
sequence_acl as (
  select 'sequence_acl', c.oid::regclass::text,
         format('owner=%s acl=%s', pg_get_userbyid(c.relowner), coalesce(c.relacl, acldefault('s', c.relowner))::text)
  from pg_class c where c.relkind = 'S' and c.relnamespace in ('app'::regnamespace, 'public'::regnamespace)
),
extensions as (
  select 'extension', extname::text, format('schema=%s version=%s', extnamespace::regnamespace, extversion) from pg_extension
),
columns as (
  select 'column_acl', c.relname || '.' || a.attname, a.attacl::text
  from pg_class c join pg_attribute a on a.attrelid = c.oid and a.attnum > 0 and not a.attisdropped and a.attacl is not null
  where c.relnamespace = 'public'::regnamespace and c.relkind = 'r'
),
constraints as (
  select 'constraint', conrelid::regclass::text || '.' || conname, contype::text || ' ' || pg_get_constraintdef(oid)
  from pg_constraint where connamespace = 'public'::regnamespace
),
indexes as (
  select 'index', indexrelid::regclass::text, pg_get_indexdef(indexrelid)
  from pg_index i join pg_class c on c.oid = i.indrelid where c.relnamespace = 'public'::regnamespace
),
policies as (
  select 'policy', tablename || '.' || policyname,
         format('%s %s roles=%s using=%s check=%s', permissive, cmd, roles::text, coalesce(qual, '-'), coalesce(with_check, '-'))
  from pg_policies where schemaname = 'public'
),
functions as (
  select 'function', p.oid::regprocedure::text,
         format('owner=%s secdef=%s acl=%s config=%s body=%s', pg_get_userbyid(p.proowner), p.prosecdef,
                coalesce(p.proacl::text, '-'), coalesce(array_to_string(p.proconfig, ','), '-'), md5(pg_get_functiondef(p.oid)))
  from pg_proc p where p.pronamespace in ('app'::regnamespace, 'public'::regnamespace)
),
triggers as (
  select 'trigger', tgrelid::regclass::text || '.' || tgname, pg_get_triggerdef(t.oid)
  from pg_trigger t join pg_class c on c.oid = t.tgrelid
  where not t.tgisinternal and c.relnamespace = 'public'::regnamespace
),
default_acl as (
  select 'default_acl', pg_get_userbyid(defaclrole) || '/' || coalesce(defaclnamespace::regnamespace::text, '*') || '/' || defaclobjtype::text,
         defaclacl::text
  from pg_default_acl
),
roles as (
  select 'role', rolname, format('login=%s bypassrls=%s', rolcanlogin, rolbypassrls)
  from pg_roles where rolname in ('app_owner', 'authenticated', 'anon', 'service_role')
),
sequences as (
  select 'sequence', schemaname || '.' || sequencename, coalesce(last_value::text, 'null')
  from pg_sequences where schemaname in ('app', 'public')
),
migrations as (
  select 'migration', version, name from supabase_migrations.schema_migrations
),
auth_users as (
  select 'auth', 'users', count(*)::text || ' ' || coalesce(md5(string_agg(id::text || email || coalesce(encrypted_password, ''), ',' order by id)), '-')
  from auth.users
)
select k || ' | ' || key || ' | ' || val from (
  select * from db union all select * from schemas union all
  select * from tables union all select * from columns union all select * from constraints
  union all select * from indexes union all select * from policies union all select * from functions
  union all select * from triggers union all select * from default_acl union all select * from roles
  union all select * from sequences union all select * from migrations union all select * from auth_users
  union all select * from table_columns union all select * from table_owners union all select * from trigger_state
  union all select * from sequence_acl union all select * from extensions
) x order by 1;

-- البيانات: عدد الصفوف و hash محتوى كل جدول في public (مرتباً بتمثيله النصي)
do $$
declare t text; n bigint; h text;
begin
  create temp table _fp (line text);
  for t in select c.relname from pg_class c where c.relnamespace = 'public'::regnamespace and c.relkind = 'r' order by 1 loop
    execute format('select count(*), coalesce(md5(string_agg(x::text, %L order by x::text)), %L) from public.%I x', E'\n', '-', t) into n, h;
    insert into _fp values ('data | ' || t || ' | ' || n || ' ' || h);
  end loop;
end $$;
select line from _fp order by 1;

-- 2B-4 (E9): بيانات Storage الوصفية (الـbuckets وقائمة الكائنات) في الـdump، ونتيجة فحص الاتساق بين صفوف الأصول والكائنات.
-- **محتوى الكائنات (البايتات) خارج pg_dump** — نسخه واستعادته Production Readiness Gate (B6)؛ هذه الأسطر تثبت ما يغطيه الـdump.
select 'storage | buckets | ' || count(*) || ' ' || coalesce(md5(string_agg(id || ':' || public::text || ':' || coalesce(file_size_limit::text, '') || ':'
       || coalesce(array_to_string(allowed_mime_types, ','), ''), ',' order by id)), '-') from storage.buckets;
select 'storage | objects | ' || count(*) || ' ' || coalesce(md5(string_agg(bucket_id || '/' || name, ',' order by bucket_id, name)), '-') from storage.objects;
select 'asset_consistency | ' || count(*) || ' ' || coalesce(md5(string_agg(issue || ':' || object_path, ',' order by issue, object_path)), '-') from app.school_asset_consistency();
