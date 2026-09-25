-- M20b — privileges_followup
-- المرجع: قرارات مراجعة M20 (2026-09-25)؛ docs/DB_IMPLEMENTATION_SPEC_v1.md §4.6، §5.2
--
-- 1. platform_tenants_platform_insert (M14): لا أعمدة INSERT لـauthenticated على platform_tenants (§4.6)،
--    والمسار المعتمد الوحيد bootstrap_tenant (§5.2). سياسة لا يمكن استعمالها تُضلّل عن عقد الـAPI الفعلي — تُحذف.
-- 2. families.family_code: قاعدة الثوابت «كل الأكواد لا يعدّلها المستخدم» تتقدم على صف §4.6 الاستثنائي.
--    أي تغيير إداري لاحق للكود قرار مستقل بمسار متحكَّم به.

drop policy platform_tenants_platform_insert on public.platform_tenants;

revoke update (family_code) on public.families from authenticated;
