-- M50 — assigned_read (Phase 3A / 3-4 — N1، N2، N5، N6، N7؛ P3، P5 — إغلاق D1/R5 يبدأ هنا ويكتمل بـM51)
-- المرجع: docs/PHASE3_4_TEACHER_NARROWING.md §2–§4؛ docs/PHASE3_SCOPE.md §4؛ PLAN §9 (2026-10-08).
--
-- فتح الكتالوج بقرار مسجل (75 ← 79): أربع صلاحيات قراءة «بالتكليف» — تُقيَّم بالمفتاح + **العلاقة** لا بنطاق المدرسة وحده،
-- ولا باسم الدور إطلاقاً (أي عضوية تحملها تتصرف بالدلالة نفسها). لا `*.export_assigned` ولا `*.sensitive_read_assigned`.
--
-- **هذه الـmigration لا تغيّر سلوك أحد:** لا دور يحمل المفاتيح الجديدة حتى M51 (N1).
--
-- P5 — «مُكلَّف به» (N5): التسجيل **الأحدث** للطالب و**حالته active**، في شعبة active سنتها ليست closed، وللفاعل — موظفاً active
-- له تكليف مدرسة نشط في مدرسة الشعبة — عليها تكليف **فعّال**: مربي فصل active، أو تدريس active مادته active وربطها بالصف active.
-- التكليف «المعلَّق» (T8) لا يمنح رؤية. الأمان مشتق من العلاقة الحالية — لا يعتمد على أي cascade.
--
-- السياسات (N7): فرع OR واحد يُضاف إلى خمس سياسات SELECT؛ **الفروع القائمة (M17) حرفياً كما هي**؛ لا سياسة جديدة ولا تغيير في الكتابة.
-- ولي الأمر والأسرة وصف الارتباط تُشتق من **الطالب المكلَّف به** (guardian ← ارتباط نشط ← طالب مُكلَّف به) — لا مدخل مستقل.
-- لا مسّ لـ: student_in_scope / guardian_in_scope / family_in_scope / can_see_membership / T8 / سياسات الكتابة.

insert into public.permissions (code, resource, operation, description, is_sensitive) values
  ('student.read_assigned',    'student',    'read_assigned', 'قراءة الطلاب المكلَّف بهم (تكليف تدريس أو مربي فصل)', false),
  ('enrollment.read_assigned', 'enrollment', 'read_assigned', 'قراءة تسجيلات الطلاب المكلَّف بهم في شعب التكليف', false),
  ('guardian.read_assigned',   'guardian',   'read_assigned', 'قراءة أولياء أمور الطلاب المكلَّف بهم', false),
  ('family.read_assigned',     'family',     'read_assigned', 'قراءة أسر الطلاب المكلَّف بهم', false);

set local role app_owner;

-- الموظف النشط الذي حسابه الفاعل (NULL إن لم يكن موظفاً نشطاً)
create function app.current_staff_id()
returns uuid
language sql stable security definer set search_path = app, public, pg_temp
as $$
  select s.id from public.staff s
   where s.profile_id = app.current_profile_id()
     and s.status = 'active';
$$;

-- الشعبة مُكلَّف بها: P5 (أ) تدريس فعّال أو (ب) مربي فصل
create function app.section_assigned_to_me(p_section_id uuid)
returns boolean
language sql stable security definer set search_path = app, public, pg_temp
as $$
  select exists (
    select 1
      from public.sections sec
      join public.academic_years y on y.id = sec.academic_year_id
     where sec.id = p_section_id
       and sec.status = 'active'
       and y.status <> 'closed'
       and exists (select 1 from public.staff_school_assignments a
                    where a.staff_id = app.current_staff_id() and a.school_id = sec.school_id and a.status = 'active')
       and (   exists (select 1 from public.class_teacher_assignments c
                        where c.section_id = sec.id and c.staff_id = app.current_staff_id() and c.status = 'active')
            or exists (select 1
                         from public.teaching_assignments t
                         join public.subjects sb on sb.id = t.subject_id
                         join public.grade_subjects gs on gs.academic_year_id = t.academic_year_id
                                                      and gs.grade_level_id = t.grade_level_id and gs.subject_id = t.subject_id
                        where t.section_id = sec.id and t.staff_id = app.current_staff_id() and t.status = 'active'
                          and sb.status = 'active' and gs.status = 'active'))
  );
$$;

-- للمرحلة 6 (درجات كل مواد الفصل): الفاعل مربي الشعبة بشروط P5 (ب) — لا سياسة تستدعيها في 3-4
create function app.is_class_teacher_of(p_section_id uuid)
returns boolean
language sql stable security definer set search_path = app, public, pg_temp
as $$
  select exists (
    select 1
      from public.sections sec
      join public.academic_years y on y.id = sec.academic_year_id
     where sec.id = p_section_id
       and sec.status = 'active'
       and y.status <> 'closed'
       and exists (select 1 from public.staff_school_assignments a
                    where a.staff_id = app.current_staff_id() and a.school_id = sec.school_id and a.status = 'active')
       and exists (select 1 from public.class_teacher_assignments c
                    where c.section_id = sec.id and c.staff_id = app.current_staff_id() and c.status = 'active')
  );
$$;

-- الطالب مُكلَّف به: تسجيله الأحدث (H2) وحالته active، في شعبة مُكلَّف بها
create function app.student_assigned_to_me(p_student_id uuid)
returns boolean
language sql stable security definer set search_path = app, public, pg_temp
as $$
  select exists (
    select 1
      from (select e.section_id, e.status
              from public.enrollments e
             where e.student_id = p_student_id
             order by e.effective_from desc
             limit 1) cur
     where cur.status = 'active'
       and app.section_assigned_to_me(cur.section_id)
  );
$$;

-- ولي الأمر: ارتباط **نشط** بطالب مُكلَّف به — العلاقة مشتقة من الطالب
create function app.guardian_assigned_to_me(p_guardian_id uuid)
returns boolean
language sql stable security definer set search_path = app, public, pg_temp
as $$
  select exists (
    select 1 from public.student_guardians sg
     where sg.guardian_id = p_guardian_id
       and sg.status = 'active'
       and app.student_assigned_to_me(sg.student_id)
  );
$$;

-- الأسرة: فيها طالب مُكلَّف به
create function app.family_assigned_to_me(p_family_id uuid)
returns boolean
language sql stable security definer set search_path = app, public, pg_temp
as $$
  select exists (
    select 1 from public.students s
     where s.family_id = p_family_id
       and app.student_assigned_to_me(s.id)
  );
$$;

reset role;

-- EXECUTE: ما تستدعيه سياسة مباشرة فقط (فئة RLS helpers في حارس 20)؛ الثلاث الأخرى بلا EXECUTE لأدوار الـAPI
revoke all on function app.current_staff_id(), app.section_assigned_to_me(uuid), app.is_class_teacher_of(uuid),
                       app.student_assigned_to_me(uuid), app.guardian_assigned_to_me(uuid), app.family_assigned_to_me(uuid) from public;
grant execute on function app.section_assigned_to_me(uuid), app.student_assigned_to_me(uuid),
                          app.guardian_assigned_to_me(uuid), app.family_assigned_to_me(uuid) to authenticated;

-- ------------------------------------------------------------------
-- السياسات الخمس — نص M17 حرفياً + فرع read_assigned واحد
-- ------------------------------------------------------------------
drop policy students_select on public.students;
create policy students_select on public.students
  for select to authenticated
  using ((    platform_tenant_id = (select app.current_tenant_id())
          and app.has_permission('student.read')
          and (   app.student_in_scope(id)
               or app.student_linked_to_guardian(id)
               or app.student_is_self(id)))
      or (    platform_tenant_id = (select app.current_tenant_id())
          and app.has_permission('student.read_assigned')
          and app.student_assigned_to_me(id)));

drop policy enrollments_select on public.enrollments;
create policy enrollments_select on public.enrollments
  for select to authenticated
  using ((    app.has_permission('enrollment.read')
          and (   app.can_access_school(school_id)
               or app.student_linked_to_guardian(student_id)
               or app.student_is_self(student_id)))
      or (    app.has_permission('enrollment.read_assigned')
          and app.student_assigned_to_me(student_id)
          and app.section_assigned_to_me(section_id)));

drop policy guardians_select on public.guardians;
create policy guardians_select on public.guardians
  for select to authenticated
  using ((   profile_id = (select app.current_profile_id())
          or (    platform_tenant_id = (select app.current_tenant_id())
              and app.has_permission('guardian.read') and app.guardian_in_scope(id)))
      or (    platform_tenant_id = (select app.current_tenant_id())
          and app.has_permission('guardian.read_assigned')
          and app.guardian_assigned_to_me(id)));

drop policy families_select on public.families;
create policy families_select on public.families
  for select to authenticated
  using ((    platform_tenant_id = (select app.current_tenant_id())
          and app.has_permission('family.read')
          and (   app.family_in_scope(id)
               or exists (select 1 from public.students s
                          where s.family_id = families.id
                            and app.student_linked_to_guardian(s.id))))
      or (    platform_tenant_id = (select app.current_tenant_id())
          and app.has_permission('family.read_assigned')
          and app.family_assigned_to_me(id)));

drop policy student_guardians_select on public.student_guardians;
create policy student_guardians_select on public.student_guardians
  for select to authenticated
  using ((   guardian_id = (select app.current_guardian_id())
          or (app.has_permission('guardian.read') and app.student_in_scope(student_id))
          or app.student_is_self(student_id))
      or (    app.has_permission('guardian.read_assigned')
          and status = 'active'
          and app.student_assigned_to_me(student_id)));

-- حارس داخل الـmigration: الكتالوج 79، ولا دور يحمل المفاتيح الجديدة بعد (M51 هي لحظة التحول)
do $$
begin
  if (select count(*) from public.permissions) <> 79 then
    raise exception 'M50: the permission catalog must hold exactly 79 keys';
  end if;
  if exists (select 1 from public.role_permissions rp join public.permissions p on p.id = rp.permission_id where p.code like '%.read_assigned') then
    raise exception 'M50: no role may hold a read_assigned key before M51';
  end if;
end $$;
