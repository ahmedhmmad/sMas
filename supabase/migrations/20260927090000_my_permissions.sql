-- M28 — my_permissions (Gate F1 / F1.3 — معتمد 2026-09-27)
--
-- effective permission keys للمستخدم الحالي — لإظهار/إخفاء عناصر الواجهة فقط. **ليست حداً أمنياً**: كل عملية
-- تقررها RLS والدوال المتحكَّم بها عند تنفيذها.
--
-- • تُشتق داخل DB من الجداول نفسها وبالشروط نفسها التي تستعملها has_permission / has_platform_permission
--   (لا enumeration عبر استدعاء has_permission لكل مفتاح، ولا قائمة يرسلها العميل).
-- • السياق من current_security_context(): tenant ⇒ مفاتيح الـTenant؛ platform ⇒ مفاتيح المنصة؛ لا اتحاد بينهما
--   (الحساب سياق واحد — G10). بلا سياق (service، حساب pending، Tenant موقوف…) ⇒ مصفوفة فارغة.
-- • تعيد المفاتيح فقط: لا أسماء أدوار ولا نطاقات ولا معرّفات.

set local role app_owner;

create function app.my_permissions()
returns text[]
language sql
stable
security definer
set search_path = app, public, pg_temp
as $$
  select coalesce(array_agg(distinct k.code order by k.code), '{}')
  from (
    -- tenant: نظير has_permission حرفياً (عضوية نشطة، دور نشط، profile السياق الحالي)
    select perm.code
    from public.memberships m
    join public.membership_roles mr on mr.membership_id = m.id
    join public.roles r              on r.id = mr.role_id
    join public.role_permissions rp  on rp.role_id = mr.role_id
    join public.permissions perm     on perm.id = rp.permission_id
    where app.current_security_context() = 'tenant'
      and m.profile_id = app.current_profile_id()
      and m.status = 'active'
      and r.status = 'active'
    union all
    -- platform: نظير has_platform_permission حرفياً (إسناد نشط لـsystem user السياق الحالي)
    select perm.code
    from public.platform_admin_assignments paa
    join public.platform_admin_role_permissions parp on parp.platform_admin_role_id = paa.platform_admin_role_id
    join public.permissions perm on perm.id = parp.permission_id
    where app.current_security_context() = 'platform'
      and paa.system_user_id = app.current_system_user_id()
      and paa.status = 'active'
  ) k
$$;

reset role;

revoke all on function app.my_permissions() from public;
grant execute on function app.my_permissions() to authenticated;
