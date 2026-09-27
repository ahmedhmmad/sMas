-- M29 — platform_reads (F1/W1 — قرار 2026-09-28)
-- المرجع: RLS_MODEL_v1.md §11 («Audit إلزامي: كل قراءة Platform Admin لبيانات Tenant تُسجَّل»، والنمط نفسه على
-- groups و schools)؛ N5.
--
-- قبلها: Platform Admin يقرأ platform_tenants/groups/schools عبر PostgREST مباشرة بلا تدقيق، والمسار المُدقَّق
-- (FastAPI) واحد من مسارين. بعدها: **لا قراءة مباشرة**؛ المسار الوحيد من جهة العميل دالة متحكَّم بها تقرأ وتكتب
-- صف التدقيق في المعاملة نفسها (fail closed: فشل التدقيق يلغي القراءة).
--
-- 1. حذف سياسات Platform Admin الثماني على الجداول الثلاثة: SELECT، ومعها INSERT/UPDATE التي تعتمد على رؤية
--    الصف (UPDATE بشرط، INSERT بإرجاع) فتصير نصف معطلة ومضللة؛ لا مسار منتج يستعملها، وكتابات المنصة القائمة
--    دوال متحكَّم بها (bootstrap_tenant، suspend/reactivate، archive_*). كتابة منصة جديدة = دالة متحكَّم بها.
-- 2. app.platform_read_tenants() و app.platform_read_tenant(id): سياق المنصة (وإلا forbidden)، ثم
--    has_platform_permission('tenant.read') (وإلا لا صفوف ولا تدقيق)، ثم صف تدقيق read لكل Tenant يُعاد.
--    groups/schools: لا دالة الآن — تُضاف مع أول شاشة تحتاجها، بالنمط نفسه.

drop policy platform_tenants_platform_select on public.platform_tenants;
drop policy platform_tenants_platform_update on public.platform_tenants;
drop policy groups_platform_select           on public.groups;
drop policy groups_platform_insert           on public.groups;
drop policy groups_platform_update           on public.groups;
drop policy schools_platform_select          on public.schools;
drop policy schools_platform_insert          on public.schools;
drop policy schools_platform_update          on public.schools;

set local role app_owner;

create function app.platform_read_tenants(p_tenant_id uuid default null)
returns table (id uuid, tenant_code text, name text, status text, suspended_at timestamptz)
language plpgsql
volatile
security definer
set search_path = app, public, pg_temp
as $$
declare v_actor uuid := app.current_system_user_id();
begin
  if v_actor is null then
    raise exception 'forbidden' using errcode = '42501';            -- ليس سياق منصة (G10)
  end if;
  if not app.has_platform_permission('tenant.read') then
    return;                                                        -- بلا صلاحية: لا صفوف ولا تدقيق
  end if;
  return query
    with rows as (
      select t.id, t.tenant_code, t.name, t.status, t.suspended_at
      from public.platform_tenants t
      where p_tenant_id is null or t.id = p_tenant_id
    ), audited as (
      insert into public.audit_log (platform_tenant_id, actor_type, actor_id, action, entity_type, entity_id, new_values, source)
      select r.id, 'platform_admin', v_actor, 'read', 'platform_tenants', r.id::text,
             jsonb_build_object('channel', 'api', 'resource', case when p_tenant_id is null then 'platform_tenant_list' else 'platform_tenant' end),
             'api'
      from rows r
      returning 1
    )
    select r.id, r.tenant_code, r.name, r.status, r.suspended_at
    from rows r
    where (select count(*) from audited) = (select count(*) from rows)   -- القراءة لا تعود إلا مع تدقيقها كاملاً
    order by r.tenant_code;
end;
$$;

reset role;

revoke all on function app.platform_read_tenants(uuid) from public;
grant execute on function app.platform_read_tenants(uuid) to authenticated;
