-- M14 — policies_tenancy_platform
-- المرجع: docs/DB_IMPLEMENTATION_SPEC_v1.md §B10 (M14)، §4.5؛ docs/RLS_MODEL_v1.md §6، §7، §10.6، §11؛ CLAUDE.md §1.1
--
-- أول طبقة سياسات: platform_tenants، groups، schools، identity_scopes، system_users، platform_admin_assignments.
--   • سياق Tenant: can_access_*() + has_permission() — لا تطابق Tenant وحده (§1.1 بند 5، F1).
--   • سياق Platform: has_platform_permission() — سياسات منفصلة، لا OR بين السياقين (C3، G10).
--   • كل السياسات TO authenticated: anon بلا أي سياسة، فلا يرى ولا يكتب شيئاً ولا يستدعي أي دالة.
--   • لا DELETE على أي جدول هنا (§5.2).
--
-- قرارات 2026-09-25 (قبل الكتابة):
--   • platform_admin_roles و platform_admin_role_permissions: service فقط — بلا سياسة SELECT.
--     (§10.6 كتب is_platform_admin() وحدها، و§11 يمنعها بلا has_platform_permission؛ حُسم لصالح §11 و G8.)
--   • EXECUTE على الدوال التي تستدعيها سياسات M14 يُمنح هنا لـ authenticated، لا في M20؛
--     وإلا فشلت كل استعلامات authenticated بـ«permission denied for function» حتى M20.
--
-- WITH CHECK في UPDATE يضيف عزل Tenant على قيم الصف الجديد:
--   can_access_group(id) / can_access_school(id) تقرأ الجدول بلقطة الجملة، فترى Tenant الصف القديم لا الجديد.
--   بلا هذا الشرط يستطيع tenant_admin نقل مجموعة فارغة إلى Tenant آخر قبل أن تمنعه أعمدة GRANT في M20.
--   (platform_tenant_id ليس عموداً قابلاً للتعديل أصلاً — §4.6؛ هذا دفاع في العمق.)

-- ------------------------------------------------------------------
-- EXECUTE للدوال التي تستدعيها السياسات مباشرة. الدوال التي تستدعيها هي داخلياً تعمل بهوية app_owner.
-- ------------------------------------------------------------------
grant execute on function
  app.current_tenant_id(),
  app.current_system_user_id(),
  app.has_permission(text),
  app.has_platform_permission(text),
  app.can_access_tenant(uuid),
  app.can_access_group(uuid),
  app.can_access_school(uuid),
  app.can_access_identity_scope(uuid)
to authenticated;

-- ------------------------------------------------------------------
-- platform_tenants
-- ------------------------------------------------------------------
create policy platform_tenants_tenant_select on public.platform_tenants
  for select to authenticated
  using (app.can_access_tenant(id) and app.has_permission('tenant.read'));

create policy platform_tenants_tenant_update on public.platform_tenants
  for update to authenticated
  using      (app.can_access_tenant(id) and app.has_permission('tenant.update'))
  with check (app.can_access_tenant(id) and app.has_permission('tenant.update'));
-- INSERT من سياق Tenant: لا سياسة — إنشاء Tenant عملية منصة (K4).

create policy platform_tenants_platform_select on public.platform_tenants
  for select to authenticated
  using (app.has_platform_permission('tenant.read'));

create policy platform_tenants_platform_insert on public.platform_tenants
  for insert to authenticated
  with check (app.has_platform_permission('tenant.create'));

create policy platform_tenants_platform_update on public.platform_tenants
  for update to authenticated
  using      (app.has_platform_permission('tenant.update'))
  with check (app.has_platform_permission('tenant.update'));

-- ------------------------------------------------------------------
-- groups
-- ------------------------------------------------------------------
create policy groups_tenant_select on public.groups
  for select to authenticated
  using (app.can_access_group(id) and app.has_permission('group.read'));

create policy groups_tenant_insert on public.groups
  for insert to authenticated
  with check (app.can_access_tenant(platform_tenant_id) and app.has_permission('group.create'));

create policy groups_tenant_update on public.groups
  for update to authenticated
  using      (app.can_access_group(id) and app.has_permission('group.update'))
  with check (platform_tenant_id = (select app.current_tenant_id())
              and app.can_access_group(id) and app.has_permission('group.update'));

create policy groups_platform_select on public.groups
  for select to authenticated
  using (app.has_platform_permission('group.read'));

create policy groups_platform_insert on public.groups
  for insert to authenticated
  with check (app.has_platform_permission('group.create'));

create policy groups_platform_update on public.groups
  for update to authenticated
  using      (app.has_platform_permission('group.update'))
  with check (app.has_platform_permission('group.update'));

-- ------------------------------------------------------------------
-- schools — الإنشاء: group_manager داخل مجموعته، أو نطاق tenant (PLAN §7.9)
-- ------------------------------------------------------------------
create policy schools_tenant_select on public.schools
  for select to authenticated
  using (app.can_access_school(id) and app.has_permission('school.read'));

create policy schools_tenant_insert on public.schools
  for insert to authenticated
  with check ((app.can_access_group(group_id) or app.can_access_tenant(platform_tenant_id))
              and app.has_permission('school.create'));

create policy schools_tenant_update on public.schools
  for update to authenticated
  using      (app.can_access_school(id) and app.has_permission('school.update'))
  with check (platform_tenant_id = (select app.current_tenant_id())
              and app.can_access_school(id) and app.has_permission('school.update'));

create policy schools_platform_select on public.schools
  for select to authenticated
  using (app.has_platform_permission('school.read'));

create policy schools_platform_insert on public.schools
  for insert to authenticated
  with check (app.has_platform_permission('school.create'));

create policy schools_platform_update on public.schools
  for update to authenticated
  using      (app.has_platform_permission('school.update'))
  with check (app.has_platform_permission('school.update'));

-- ------------------------------------------------------------------
-- identity_scopes — قراءة فقط لمن له سلطة على النطاق كله (§10.6؛ H1: السكرتير لا يحتاج رؤيته)
-- الإنشاء: T9 وحده (G9). لا سياسة Platform (بيانات هوية عملاء — §11).
-- ------------------------------------------------------------------
create policy identity_scopes_tenant_select on public.identity_scopes
  for select to authenticated
  using (platform_tenant_id = (select app.current_tenant_id())
         and app.has_permission('school.read')
         and app.can_access_identity_scope(id));

-- ------------------------------------------------------------------
-- هوية المنصة: الذات فقط. الإدارة service فقط (G8).
-- ------------------------------------------------------------------
create policy system_users_self_select on public.system_users
  for select to authenticated
  using (auth_user_id = auth.uid());

create policy platform_admin_assignments_self_select on public.platform_admin_assignments
  for select to authenticated
  using (system_user_id = (select app.current_system_user_id()));

-- platform_admin_roles، platform_admin_role_permissions: service فقط (قرار 2026-09-25)
-- auth_identities: بلا سياسة بتصميمه (M13)
