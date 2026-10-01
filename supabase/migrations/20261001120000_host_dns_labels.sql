-- M30b — host_dns_labels (F3 follow-up — قرار مراجعة F3، 2026-10-01)
-- المرجع: docs/F3_HOST_CONTEXT.md؛ RFC 1123 (label: يبدأ وينتهي بحرف أو رقم، 63 حرفاً على الأكثر).
--
-- F3 جعل `platform_tenants.host_label` و`schools.slug` أجزاءً من hostname؛ نمطا M30/M04 كانا يقبلان شرطة ختامية
-- (`tenant-`، `school-`) — قيمة يقبلها DB وليست label DNS صالحاً. يُشدَّد القيدان بالاسم نفسه:
--   host_label : ^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$   (1–63)
--   slug       : ^[a-z0-9][a-z0-9-]{0,61}[a-z0-9]$         (2–63 — الحد الأدنى القائم منذ M04 يبقى)
-- لا يُفتح شيء كان مرفوضاً؛ يُرفض فقط ما ينتهي بشرطة.
--
-- البيانات القائمة: فحص صريح قبل القيد — أي قيمة مخالفة توقف الـmigration بقائمة مسمّاة. لا تصحيح تلقائي:
-- تغيير slug أو label يغيّر عنوان المدرسة/الـTenant، فهو قرار صريح لا أثر جانبي لـmigration.

do $$
declare v_bad text;
begin
  select concat_ws('; ',
           (select string_agg(format('platform_tenants %s host_label=%L', id, host_label), '; ' order by id)
              from public.platform_tenants where host_label !~ '^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$'),
           (select string_agg(format('schools %s slug=%L', id, slug), '; ' order by id)
              from public.schools where slug !~ '^[a-z0-9][a-z0-9-]{0,61}[a-z0-9]$'))
    into v_bad;
  if v_bad <> '' then
    raise exception 'M30b: values that are not DNS labels must be corrected explicitly before this migration: %', v_bad
      using errcode = '23514';
  end if;
end $$;

alter table public.platform_tenants
  drop constraint platform_tenants_host_label_chk,
  add constraint platform_tenants_host_label_chk check (host_label ~ '^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$');

alter table public.schools
  drop constraint schools_slug_chk,
  add constraint schools_slug_chk check (slug ~ '^[a-z0-9][a-z0-9-]{0,61}[a-z0-9]$');
