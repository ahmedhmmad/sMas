-- M21b — tenant_suspension
-- المرجع: قرار مراجعة M21 (2026-09-25): إيقاف الـTenant يُفرض في جذر سياق أمن الـTenant، لا في كل سياسة.
--
-- suspend_tenant (M21) كان يغيّر platform_tenants.status فقط، ولا دالة مساعدة تقرأه — فيبقى مستخدمو الـTenant
-- الموقوف بكامل وصولهم. الجذر موضعان لا واحد: current_tenant_id() وحدها لا تكفي، لأن has_permission()
-- و can_access_group/school() تقرأ current_profile_id() لا current_tenant_id() — فتبقى سياسات المدرسة
-- (can_access_school + has_permission) عاملة (مُثبت بضابط سلبي في 21b_tenant_suspension).
-- لذلك الدالتان — وكلتاهما تقرأ profiles مباشرة — تُرجعان NULL حين يكون الـTenant موقوفاً:
--   suspended tenant → current_profile_id() = NULL و current_tenant_id() = NULL → كل مسار Tenant يفشل → RLS ترفض.
-- سياق المنصة منفصل (system_users، has_platform_permission) فلا يتأثر: Platform Admin يدير الـTenant الموقوف ويعيد تفعيله.
-- بالاسم والتوقيع نفسيهما (create or replace) بهوية مالكهما app_owner؛ M03 باقية في التاريخ.

set local role app_owner;

create or replace function app.current_profile_id()
returns uuid
language sql
stable
security definer
set search_path = app, public, pg_temp
as $$
  select p.id
  from public.profiles p
  join public.platform_tenants t on t.id = p.platform_tenant_id
  where p.auth_user_id = app.auth_uid()
    and p.status = 'active'
    and t.status = 'active';
$$;

create or replace function app.current_tenant_id()
returns uuid
language sql
stable
security definer
set search_path = app, public, pg_temp
as $$
  select p.platform_tenant_id
  from public.profiles p
  join public.platform_tenants t on t.id = p.platform_tenant_id
  where p.auth_user_id = app.auth_uid()
    and p.status = 'active'
    and t.status = 'active';
$$;

reset role;
