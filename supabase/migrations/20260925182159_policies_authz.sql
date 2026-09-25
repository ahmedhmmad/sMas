-- M15 — policies_authz
-- المرجع: docs/DB_IMPLEMENTATION_SPEC_v1.md §B10 (M15)، §4.5؛ docs/RLS_MODEL_v1.md §10.0–§10.3؛ CLAUDE.md §1.1
--
-- profiles، memberships، membership_roles، membership_scopes، roles، permissions، role_permissions.
-- كل السياسات TO authenticated؛ anon بلا سياسة. DELETE فقط حيث G2: membership_roles، membership_scopes، role_permissions.
--
-- قرارات 2026-09-25 (قبل الكتابة):
--   • membership_scopes INSERT/DELETE تشترط أيضاً can_manage_membership(membership_id) — كـmembership_roles (F4).
--     بدونها يضيف school_admin في SA1 نطاق SA1 لعضوية لا يديرها (محاسب SB1)، فتسري صلاحيات أدوارها في SA1.
--     (تغطية T8 لهذه الحالة — صلاحيات أدوار الهدف ⊆ صلاحيات الفاعل — سؤال مفتوح يُطرح في M19.)
--   • app.membership_id_of(profile_id): دالة ربط فقط تُرجع معرّف العضوية (1:1، I12). §10.1–10.2 كانت تستعلم
--     memberships مباشرة داخل السياسة — خلاف §1.1 بند 6، وتمر بـRLS العضويات فيُحجب profile عن من يملك
--     profile.read بلا membership.read (المعلم). القرار يبقى في can_see/can_manage_membership.
--
-- T8 (منح دور/صلاحية ⊆ صلاحيات الفاعل) في M19: حتى ذلك الحين RLS هنا تحكم «على أي عضوية/نطاق» لا «أي صلاحيات».

set local role app_owner;

-- معرّف عضوية profile — داخل Tenant الفاعل فقط (لا كاشف عضويات عبر Tenant)
create function app.membership_id_of(p_profile_id uuid)
returns uuid
language sql
stable
security definer
set search_path = app, public, pg_temp
as $$
  select m.id from public.memberships m
  where m.profile_id = p_profile_id
    and m.platform_tenant_id = app.current_tenant_id();
$$;

reset role;

grant execute on function
  app.current_profile_id(),
  app.membership_id_of(uuid),
  app.can_see_membership(uuid),
  app.can_manage_membership(uuid)
to authenticated;

-- ------------------------------------------------------------------
-- profiles (F2، G1) — الذات بلا صلاحية؛ غيرها بالعلاقة. لا تعديل ذاتي. INSERT: دوال الإنشاء فقط.
-- ------------------------------------------------------------------
create policy profiles_select on public.profiles
  for select to authenticated
  using (   auth_user_id = auth.uid()
         or (    platform_tenant_id = (select app.current_tenant_id())
             and app.has_permission('profile.read')
             and app.can_see_membership(app.membership_id_of(id))));

create policy profiles_update on public.profiles
  for update to authenticated
  using      (    platform_tenant_id = (select app.current_tenant_id())
              and app.has_permission('profile.update')
              and app.can_manage_membership(app.membership_id_of(id)))
  with check (platform_tenant_id = (select app.current_tenant_id()));

-- ------------------------------------------------------------------
-- memberships (F3) — قراءة فقط؛ الإنشاء والإنهاء بدوال (§5.2، §5.3)
-- ------------------------------------------------------------------
create policy memberships_select on public.memberships
  for select to authenticated
  using (   profile_id = (select app.current_profile_id())
         or (app.has_permission('membership.read') and app.can_see_membership(id)));

-- ------------------------------------------------------------------
-- membership_roles (F4، G2) — T8 يُضاف في M19
-- ------------------------------------------------------------------
create policy membership_roles_select on public.membership_roles
  for select to authenticated
  using (   membership_id = app.membership_id_of((select app.current_profile_id()))
         or (app.has_permission('membership.read') and app.can_see_membership(membership_id)));

create policy membership_roles_insert on public.membership_roles
  for insert to authenticated
  with check (app.has_permission('role.assign') and app.can_manage_membership(membership_id));

create policy membership_roles_delete on public.membership_roles
  for delete to authenticated
  using (app.has_permission('role.assign') and app.can_manage_membership(membership_id));

-- ------------------------------------------------------------------
-- membership_scopes (F1، G2 + can_manage_membership: قرار 2026-09-25)
-- ------------------------------------------------------------------
create policy membership_scopes_select on public.membership_scopes
  for select to authenticated
  using (   membership_id = app.membership_id_of((select app.current_profile_id()))
         or (app.has_permission('membership.read') and app.can_see_membership(membership_id)));

create policy membership_scopes_insert on public.membership_scopes
  for insert to authenticated
  with check (    app.has_permission('scope.assign')
              and platform_tenant_id = (select app.current_tenant_id())
              and app.can_manage_membership(membership_id)
              and (   (scope_type = 'tenant' and app.can_access_tenant(platform_tenant_id))
                   or (scope_type = 'group'  and app.can_access_group(group_id))
                   or (scope_type = 'school' and app.can_access_school(school_id))));

create policy membership_scopes_delete on public.membership_scopes
  for delete to authenticated
  using (    app.has_permission('scope.assign')
         and app.can_manage_membership(membership_id)
         and (   (scope_type = 'tenant' and app.can_access_tenant(platform_tenant_id))
              or (scope_type = 'group'  and app.can_access_group(group_id))
              or (scope_type = 'school' and app.can_access_school(school_id))));

-- ------------------------------------------------------------------
-- roles (§10.3 + تصحيح Gate B: الكتابة بنطاق tenant)
-- ------------------------------------------------------------------
create policy roles_select on public.roles
  for select to authenticated
  using (    (platform_tenant_id is null or platform_tenant_id = (select app.current_tenant_id()))
         and app.has_permission('role.read'));

create policy roles_insert on public.roles
  for insert to authenticated
  with check (    platform_tenant_id = (select app.current_tenant_id())
              and app.can_access_tenant(platform_tenant_id)
              and app.has_permission('role.create'));

create policy roles_update on public.roles
  for update to authenticated
  using      (    platform_tenant_id = (select app.current_tenant_id())
              and app.can_access_tenant(platform_tenant_id)
              and app.has_permission('role.update'))
  with check (    platform_tenant_id = (select app.current_tenant_id())
              and app.can_access_tenant(platform_tenant_id)
              and app.has_permission('role.update'));

-- ------------------------------------------------------------------
-- permissions — كتالوج عالمي، قراءة فقط؛ يكتبه migrations
-- ------------------------------------------------------------------
create policy permissions_select on public.permissions
  for select to authenticated
  using (app.has_permission('permission.read'));

-- ------------------------------------------------------------------
-- role_permissions — الرؤية تتبع roles (الاستعلام يمر بسياسة roles)؛ الكتابة لأدوار Tenant المخصصة فقط + T8 (M19)
-- ------------------------------------------------------------------
create policy role_permissions_select on public.role_permissions
  for select to authenticated
  using (exists (select 1 from public.roles r where r.id = role_id));

create policy role_permissions_insert on public.role_permissions
  for insert to authenticated
  with check (    app.has_permission('role.update')
              and exists (select 1 from public.roles r
                          where r.id = role_id
                            and r.platform_tenant_id = (select app.current_tenant_id())
                            and app.can_access_tenant(r.platform_tenant_id)));

create policy role_permissions_delete on public.role_permissions
  for delete to authenticated
  using (    app.has_permission('role.update')
         and exists (select 1 from public.roles r
                     where r.id = role_id
                       and r.platform_tenant_id = (select app.current_tenant_id())
                       and app.can_access_tenant(r.platform_tenant_id)));
