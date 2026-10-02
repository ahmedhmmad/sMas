-- M32 — privilege_index_followup (مراجعة Stage 1: C1 + C2 + C3، 2026-10-01)
-- المرجع: docs/STAGE1_REVIEW.md §9.1. تكملة عقد M20 (secure-by-default) وقاعدة المواصفة §3.4 — لا تغيير تصميم.
--
-- C1: M20 سحب امتيازات الجداول ولم يمس الـsequences: `anon` و`authenticated` بقيا يملكان USAGE/SELECT/UPDATE على
--     تسلسلَي الـidentity في public، والامتياز الافتراضي يمنحهما كل sequence جديدة. لا مسار عميل يحتاجها: أعمدة
--     IDENTITY لا تشترط امتيازاً على تسلسلها (T7 يكتب audit_log اليوم بدور app_owner الذي لا يملك عليه شيئاً).
-- C2: الـrevoke في M20 سرد الامتيازات بالاسم قبل MAINTAIN (PG17)، فبقي `authenticated` يملكه على الجداول وعلى كل
--     جدول جديد (الامتياز الافتراضي `authenticated=rm`).
-- C3: «كل FK له فهرس يبدأ بأعمدته»: فهرسان ناقصان على platform_tenant_id. FK الهوية المركّب
--     (auth_user_id, identity_kind) في profiles و system_users مستوفى فعلاً بـUNIQUE (auth_user_id) — صف واحد على
--     الأكثر — فلا فهرس له (استثناء موثق في المواصفة §3.4).
--
-- الامتيازات الافتراضية: لـrole postgres (منشئ كل كائنات الـmigrations في public). افتراضيات supabase_admin لا تُمس —
-- ليست كائناتنا.

-- C1
revoke all on all sequences in schema public from anon, authenticated;
alter default privileges for role postgres in schema public revoke all on sequences from anon, authenticated;

-- C2
revoke maintain on all tables in schema public from anon, authenticated;
alter default privileges for role postgres in schema public revoke maintain on tables from anon, authenticated;

-- C3
create index families_tenant_idx        on public.families (platform_tenant_id);
create index login_challenges_tenant_idx on public.login_challenges (platform_tenant_id);
