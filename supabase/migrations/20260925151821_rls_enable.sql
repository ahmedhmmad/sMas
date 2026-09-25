-- M13 — rls_enable
-- المرجع: docs/DB_IMPLEMENTATION_SPEC_v1.md §B10 (M13)، §4.5؛ docs/RLS_MODEL_v1.md §14، §15 (T2)
--
-- بوابة تحقق فقط — لا تفعيل ولا سياسات هنا.
-- RLS يُفعَّل ويُفرض في migration كل جدول لحظة إنشائه (M03–M11)، لأن صلاحيات Supabase الافتراضية
-- تمنح anon/authenticated الوصول لجداول public فور إنشائها. هذه الـmigration تفشل النشر إن وُجد:
--   1. جدول في public بلا ENABLE أو بلا FORCE ROW LEVEL SECURITY
--   2. جدول في schema app (خارج نطاق هذا الفحص وخارج RLS الموحدة)
--   3. أي سياسة قبل M14 — السياسات تبدأ بعد هذه البوابة
-- القائمة الاسمية الكاملة (29 جدولاً) في supabase/tests/13_rls_enable.test.sql.

do $$
declare
  v_bad text;
begin
  select string_agg(c.relname, ', ' order by c.relname) into v_bad
  from pg_class c
  where c.relnamespace = 'public'::regnamespace
    and c.relkind in ('r', 'p')
    and not (c.relrowsecurity and c.relforcerowsecurity);
  if v_bad is not null then
    raise exception 'M13: RLS not enabled and forced on: %', v_bad;
  end if;

  select string_agg(c.relname, ', ' order by c.relname) into v_bad
  from pg_class c
  where c.relnamespace = 'app'::regnamespace
    and c.relkind in ('r', 'p');
  if v_bad is not null then
    raise exception 'M13: tables in schema app are not allowed: %', v_bad;
  end if;

  select string_agg(schemaname || '.' || tablename || ':' || policyname, ', ') into v_bad
  from pg_policies
  where schemaname in ('public', 'app');
  if v_bad is not null then
    raise exception 'M13: policies must not exist before M14: %', v_bad;
  end if;
end $$;
