-- M01 — setup
-- المرجع: docs/DB_IMPLEMENTATION_SPEC_v1.md §B10 (M01)، §5.0.2 متطلب 7؛ R2؛ M00 V2 و V3c
-- لا جداول هنا. هذه الـmigration تهيّئ حدّ الأمان الذي تقف عليه كل ما بعدها.

-- ------------------------------------------------------------------
-- 1. الامتدادات
-- ------------------------------------------------------------------
-- EXCLUDE على نطاقات التواريخ (academic_years، terms، enrollments)
create extension if not exists btree_gist with schema extensions;

-- ------------------------------------------------------------------
-- 2. schema app — ملك postgres (R2)
--    لا يملكه app_owner: مالك الـschema يستطيع حذف أي كائن داخله، فكان سيستبدل app.auth_uid().
-- ------------------------------------------------------------------
create schema app;

-- المستدعي يحتاج USAGE لتقييم السياسات التي تستدعي دوال app. anon لا يُمنح شيئاً.
grant usage on schema app to authenticated, service_role;

-- ------------------------------------------------------------------
-- 3. app_owner — مالك كل دوال SECURITY DEFINER في app (R2)
--    الأدوار على مستوى الـcluster وتبقى بعد `db reset`، فالإنشاء قابل للتكرار.
-- ------------------------------------------------------------------
do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'app_owner') then
    create role app_owner nologin bypassrls;
  end if;
end $$;

-- PG16+: نقل ملكية الدوال إلى app_owner يتطلب أن يستطيع المنفِّذ SET ROLE إليه
grant app_owner to postgres;

-- USAGE + CREATE فقط — CREATE تكفي لإنشاء الدوال ولا تسمح بحذف كائنات الغير
grant usage, create on schema app to app_owner;

-- كل دالة ينشئها app_owner تولد بلا EXECUTE لأحد؛ المسموح يُمنح صراحةً (M00 V3c)
-- ⚠️ لا `IN SCHEMA`: الصلاحيات الافتراضية المقيّدة بـschema تضيف فقط ولا تسحب منح PUBLIC العالمي
--    (ثبت في اختبار M01: `IN SCHEMA app REVOKE ... FROM PUBLIC` بلا أثر). `FOR ROLE app_owner` لا يمس
--    ما ينشئه postgres في أي schema آخر.
-- القاعدة لكل migration لاحقة: دوال SECURITY DEFINER في app تُنشأ تحت `set local role app_owner`.
alter default privileges for role app_owner revoke execute on functions from public;

-- ------------------------------------------------------------------
-- 4. app.auth_uid() — سلسلة الهوية (R2، RLS_MODEL_v1.md §4.5)
--    app_owner لا يصل إلى schema auth؛ كل دالة يملكها تقرأ الفاعل من هنا.
--    ملك postgres، بلا معاملات، search_path فارغ، EXECUTE لـapp_owner وحده.
-- ------------------------------------------------------------------
create function app.auth_uid()
returns uuid
language sql
stable
security definer
set search_path = ''
as $$ select auth.uid() $$;

revoke execute on function app.auth_uid() from public, anon, authenticated, service_role;
grant  execute on function app.auth_uid() to app_owner;

comment on function app.auth_uid() is
  'R2: caller identity for SECURITY DEFINER functions owned by app_owner. '
  'Owned by postgres; executable by app_owner only. Policies use auth.uid() directly.';
