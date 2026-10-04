-- M38 — subject_permissions (Phase 2B / 2B-1 — القرار B10، 2026-10-04)
-- المرجع: docs/PHASE2B_SCOPE.md §0 (B10، B15)، §3؛ docs/ROLE_PERMISSION_SEED_v1.md §2 (75)، §4؛
--         docs/AUTHORIZATION_MATRIX_v1.md §4.8؛ PLAN §9 (2026-10-04).
--
-- أول فتح للكتالوج المجمَّد (73 ← 75) بقرار مسجل: المادة مورد مستقل تعتمد عليه المراحل 3 و6 و11 — لا إعادة استعمال
-- لـ`grade.*` (محجوزة للدرجات، K1) ولا لـ`grade_level.*`. لا تعديل على أي مفتاح قائم.
-- التوزيع (B15): subject.manage ← tenant_admin، group_manager، school_admin؛
--               subject.read   ← هم + secretary، accountant، teacher، counselor.
-- سياق service (migration): T6 يترك created_by فارغاً، T7 يسجل system، T8 مُعفى (G7) — نمط M23.

insert into public.permissions (code, resource, operation, description, is_sensitive) values
  ('subject.manage', 'subject', 'manage', 'إدارة المواد وربطها بالصفوف', false),
  ('subject.read',   'subject', 'read',   'قراءة المواد وربطها بالصفوف', false);

insert into public.role_permissions (role_id, permission_id)
select r.id, p.id
  from (values ('tenant_admin', 'subject.manage'), ('tenant_admin', 'subject.read'),
               ('group_manager', 'subject.manage'), ('group_manager', 'subject.read'),
               ('school_admin', 'subject.manage'), ('school_admin', 'subject.read'),
               ('secretary', 'subject.read'), ('accountant', 'subject.read'),
               ('teacher', 'subject.read'), ('counselor', 'subject.read')) m(role_code, permission_code)
  join public.roles r on r.code = m.role_code and r.platform_tenant_id is null
  join public.permissions p on p.code = m.permission_code;

-- حارس داخل الـmigration: الكتالوج 75 والروابط العشرة بالضبط — وإلا لا نشر
do $$
begin
  if (select count(*) from public.permissions) <> 75 then
    raise exception 'M38: the permission catalog must hold exactly 75 keys';
  end if;
  if (select count(*) from public.role_permissions rp join public.permissions p on p.id = rp.permission_id
       join public.roles r on r.id = rp.role_id where p.code like 'subject.%' and r.platform_tenant_id is null) <> 10 then
    raise exception 'M38: exactly 10 system-role links to the subject keys are expected';
  end if;
end $$;
