-- M13 — rls_enable: RLS مفعّل ومفروض على كل جداول Foundation، بالاسم (RLS_MODEL §15 T2)
--
-- القائمة المتوقعة صريحة (29 = الـ28 في DB_IMPLEMENTATION_SPEC §4.5 + auth_identities من G10).
-- أي جدول يُضاف إلى public دون إضافته هنا يُفشل التحقق الأول — فلا يدخل جدول بلا مراجعة RLS.
-- «لا سياسات قبل M14» تفرضه migration M13 نفسها لحظة تطبيقها؛ هذا الملف يعمل على المخطط النهائي
-- الذي سيحوي سياسات بعد M14، فلا يتحقق منها.
begin;

create temp table expected (t text primary key) on commit drop;
insert into expected values
  ('auth_identities'), ('platform_tenants'), ('profiles'),
  ('groups'), ('schools'), ('identity_scopes'),
  ('system_users'), ('platform_admin_roles'), ('platform_admin_assignments'),
  ('permissions'), ('roles'), ('role_permissions'), ('platform_admin_role_permissions'),
  ('memberships'), ('membership_roles'), ('membership_scopes'),
  ('academic_years'), ('terms'), ('stages'), ('grade_levels'), ('sections'),
  ('staff'), ('staff_school_assignments'), ('families'), ('students'), ('guardians'), ('student_guardians'),
  ('enrollments'),
  ('audit_log');

create temp view actual as
  select c.relname::text as t, c.relrowsecurity as enabled, c.relforcerowsecurity as forced
  from pg_class c
  where c.relnamespace = 'public'::regnamespace
    and c.relkind in ('r', 'p');

select plan(1 + 1 + 29 + 29 + 1 + 1);

select is((select count(*)::int from expected), 29, 'the expected Foundation list has 29 tables');

select set_eq('select t from actual', 'select t from expected',
              'public holds exactly the 29 expected Foundation tables — none missing, none unlisted');

-- لكل جدول بالاسم؛ LEFT JOIN: جدول متوقع غير موجود يُنتج فشلاً لا اختباراً ناقصاً
select ok(coalesce(a.enabled, false), format('%s: ROW LEVEL SECURITY enabled', e.t))
  from expected e left join actual a using (t) order by e.t;
select ok(coalesce(a.forced, false), format('%s: ROW LEVEL SECURITY forced (applies to the owner too)', e.t))
  from expected e left join actual a using (t) order by e.t;

select is((select count(*)::int from pg_class where relnamespace = 'app'::regnamespace and relkind in ('r', 'p')), 0,
          'schema app holds no tables (functions and sequences only)');

-- RLS §15.5 T3: لا جدول بلا سياسة SELECT (منع النسيان الصامت — F6)، عدا الاستثناءات الموثقة بقرار:
--   auth_identities (G10، M13)، platform_admin_roles و platform_admin_role_permissions (service فقط، قرار 2026-09-25)
select is((select string_agg(e.t, ',' order by e.t) from expected e
            where not exists (select 1 from pg_policies p where p.schemaname = 'public' and p.tablename = e.t and p.cmd in ('SELECT','ALL'))),
          'auth_identities,platform_admin_role_permissions,platform_admin_roles',
          'T3: every Foundation table has a SELECT policy except the three documented exceptions');

select * from finish();
rollback;
