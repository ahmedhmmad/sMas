-- M51 — teacher_assigned_keys (Phase 3A / 3-4 — N3، N4، N8؛ P4 — **لحظة تحول R5**)
-- المرجع: docs/PHASE3_4_TEACHER_NARROWING.md §5؛ docs/ROLE_PERMISSION_SEED_v1.md §4 (الخريطة بعد 3-4)؛ PLAN §9 (2026-10-08).
--
-- خريطة أدوار النظام بعد M50 (المفاتيح والدوال والسياسات قائمة ولا يحملها أحد):
--   teacher (N3 + N8): −student.read −enrollment.read −guardian.read −family.read −profile.read
--                      +student.read_assigned +enrollment.read_assigned +guardian.read_assigned +family.read_assigned        (12 ← 11)
--     • profile.read يُسحب لأن profiles_select تُظهر لحامله صف profile (الاسم الظاهر) لكل من في نطاق مدرسته — يُبقي
--       للمعلم قائمة بأسماء كل الطلاب بعد التضييق. صفّه هو يبقى مرئياً بفرع الذات.
--   tenant_admin، group_manager، school_admin (N4): +الأربعة — T8 يشترط أن يملك المانح كل صلاحيات الدور الممنوح؛ بدونها
--       لا يستطيع أحد إسناد دور teacher. لا أثر على رؤيتهم (يملكون المفاتيح الأوسع، والمفتاح الجديد لا يفتح شيئاً بلا تكليف).
--       **T8 لا يُعدَّل ولا يُستثنى.**
--   بقية الأدوار: بلا تغيير.
-- الروابط: 265 − 5 + 4 + 12 = 276. سياق service (migration): T7 يسجل system، T8 مُعفى (G7) — نمط M23/M38.
-- لا مفتاح جديد هنا (الكتالوج 79 من M50).

delete from public.role_permissions rp
 using public.roles r, public.permissions p
 where r.id = rp.role_id and p.id = rp.permission_id
   and r.platform_tenant_id is null and r.code = 'teacher'
   and p.code in ('student.read', 'enrollment.read', 'guardian.read', 'family.read', 'profile.read');

insert into public.role_permissions (role_id, permission_id)
select r.id, p.id
  from (values ('teacher'), ('tenant_admin'), ('group_manager'), ('school_admin')) m(role_code)
  cross join (values ('student.read_assigned'), ('enrollment.read_assigned'), ('guardian.read_assigned'), ('family.read_assigned')) k(permission_code)
  join public.roles r on r.code = m.role_code and r.platform_tenant_id is null
  join public.permissions p on p.code = k.permission_code;

-- حارس داخل الـmigration — وإلا لا نشر
do $$
declare v_teacher text;
begin
  if (select count(*) from public.permissions) <> 79 then
    raise exception 'M51: the permission catalog must hold exactly 79 keys';
  end if;
  -- أدوار النظام وحدها: الأدوار المخصصة للـTenants لا تدخل العدّ
  if (select count(*) from public.role_permissions rp join public.roles r on r.id = rp.role_id where r.platform_tenant_id is null) <> 276 then
    raise exception 'M51: exactly 276 system-role links are expected, found %',
      (select count(*) from public.role_permissions rp join public.roles r on r.id = rp.role_id where r.platform_tenant_id is null);
  end if;
  select string_agg(p.code, ',' order by p.code) into v_teacher
    from public.role_permissions rp join public.permissions p on p.id = rp.permission_id join public.roles r on r.id = rp.role_id
   where r.code = 'teacher' and r.platform_tenant_id is null;
  if v_teacher is distinct from 'academic_year.read,enrollment.read_assigned,family.read_assigned,grade_level.read,guardian.read_assigned,school.read,section.read,staff.read,student.read_assigned,subject.read,term.read' then
    raise exception 'M51: the teacher role is not the approved 11 keys: %', v_teacher;
  end if;
  if (select string_agg(r.code, ',' order by r.code) from public.roles r
       where r.platform_tenant_id is null
         and (select count(*) from public.role_permissions rp join public.permissions p on p.id = rp.permission_id
               where rp.role_id = r.id and p.code like '%.read_assigned') = 4)
     is distinct from 'group_manager,school_admin,teacher,tenant_admin' then
    raise exception 'M51: the four read_assigned keys must be held by exactly teacher and the three admin roles';
  end if;
end $$;
