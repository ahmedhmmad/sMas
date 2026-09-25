-- M17 — policies_people_enrollment
-- المرجع: docs/DB_IMPLEMENTATION_SPEC_v1.md §B10 (M17)، §4.5؛ docs/RLS_MODEL_v1.md §7، §8.4، §9، §10.5؛ قرار H2
--
-- staff، staff_school_assignments، families، students، guardians، student_guardians، enrollments.
-- الوصول لجداول الهوية بالعلاقة التشغيلية الحالية (H2، M12b) عبر الدوال — لا منطق علاقة داخل السياسة:
--   Student → أحدث تسجيل (student_in_scope)   Guardian → ارتباط نشط + نطاق الطالب الحالي   Staff → تكليف نشط
-- كل السياسات TO authenticated؛ لا DELETE (§5.2)؛ لا سياسة Platform على بيانات العملاء (§11، E7).
-- INSERT على staff/families/students/guardians: لا سياسة — دوال الإنشاء فقط (G4).
--
-- قرار 2026-09-25 (قبل الكتابة): enrollments INSERT و UPDATE تشترطان أيضاً app.student_in_scope(student_id).
--   تحت H2 التسجيل الأحدث يحدد المدرسة التشغيلية؛ بنص §9 وحده تستطيع مدرسة أخرى في نطاق الهوية إدراج تسجيل
--   لاحق لطالب أُغلق تسجيله فتنتزع وصوله دون موافقة مدرسته — نقل يلتف على enrollment.transfer (PLAN §7.10).
--   النقل بين المدارس: دالة M21. التسجيل الأول للطالب الجديد: داخل provision_student (M22).
--   SELECT بلا تغيير: المدرسة السابقة تقرأ صفوف تسجيلاتها (الوصول التاريخي المعتمد في H2).

grant execute on function
  app.student_in_scope(uuid),
  app.student_linked_to_guardian(uuid),
  app.student_is_self(uuid),
  app.staff_in_scope(uuid),
  app.guardian_in_scope(uuid),
  app.family_in_scope(uuid),
  app.current_guardian_id()
to authenticated;

-- ------------------------------------------------------------------
-- staff — الذات؛ أو staff.read + تكليف نشط في النطاق
-- ------------------------------------------------------------------
create policy staff_select on public.staff
  for select to authenticated
  using (   profile_id = (select app.current_profile_id())
         or (    platform_tenant_id = (select app.current_tenant_id())
             and app.has_permission('staff.read') and app.staff_in_scope(id)));

create policy staff_update on public.staff
  for update to authenticated
  using      (app.has_permission('staff.update') and app.staff_in_scope(id))
  with check (platform_tenant_id = (select app.current_tenant_id()));

-- ------------------------------------------------------------------
-- staff_school_assignments — School-level (§7). صفوف المدرسة تبقى مرئية لها ولو انتهت (سجلها هي).
-- ------------------------------------------------------------------
create policy staff_school_assignments_select on public.staff_school_assignments
  for select to authenticated
  using (app.can_access_school(school_id) and app.has_permission('staff.read'));

create policy staff_school_assignments_insert on public.staff_school_assignments
  for insert to authenticated
  with check (app.can_access_school(school_id) and app.has_permission('staff.assign'));

create policy staff_school_assignments_update on public.staff_school_assignments
  for update to authenticated
  using      (app.can_access_school(school_id) and app.has_permission('staff.assign'))
  with check (app.can_access_school(school_id) and app.has_permission('staff.assign'));

-- ------------------------------------------------------------------
-- families — طالب في النطاق الحالي، أو أسرة أبناء ولي الأمر (ارتباط نشط)
-- ------------------------------------------------------------------
create policy families_select on public.families
  for select to authenticated
  using (    platform_tenant_id = (select app.current_tenant_id())
         and app.has_permission('family.read')
         and (   app.family_in_scope(id)
              or exists (select 1 from public.students s
                         where s.family_id = families.id
                           and app.student_linked_to_guardian(s.id))));

create policy families_update on public.families
  for update to authenticated
  using      (app.has_permission('family.update') and app.family_in_scope(id))
  with check (platform_tenant_id = (select app.current_tenant_id()));

-- ------------------------------------------------------------------
-- students — المسارات الثلاثة (§8.4)؛ التعديل للمدرسة الحالية فقط
-- ------------------------------------------------------------------
create policy students_select on public.students
  for select to authenticated
  using (    platform_tenant_id = (select app.current_tenant_id())
         and app.has_permission('student.read')
         and (   app.student_in_scope(id)
              or app.student_linked_to_guardian(id)
              or app.student_is_self(id)));

create policy students_update on public.students
  for update to authenticated
  using      (    platform_tenant_id = (select app.current_tenant_id())
              and app.has_permission('student.update')
              and app.student_in_scope(id))
  with check (    platform_tenant_id = (select app.current_tenant_id())   -- E2
              and app.has_permission('student.update'));

-- ------------------------------------------------------------------
-- guardians — الذات؛ أو guardian.read + ارتباط نشط بطالب في النطاق الحالي
-- phone_e164 خارج GRANT (M20) — مسار OTP في FastAPI
-- ------------------------------------------------------------------
create policy guardians_select on public.guardians
  for select to authenticated
  using (   profile_id = (select app.current_profile_id())
         or (    platform_tenant_id = (select app.current_tenant_id())
             and app.has_permission('guardian.read') and app.guardian_in_scope(id)));

create policy guardians_update on public.guardians
  for update to authenticated
  using      (app.has_permission('guardian.update') and app.guardian_in_scope(id))
  with check (platform_tenant_id = (select app.current_tenant_id()));

-- ------------------------------------------------------------------
-- student_guardians — الإنهاء: app.unlink_guardian (M21)؛ status خارج GRANT
-- ------------------------------------------------------------------
create policy student_guardians_select on public.student_guardians
  for select to authenticated
  using (   guardian_id = (select app.current_guardian_id())
         or (app.has_permission('guardian.read') and app.student_in_scope(student_id))
         or app.student_is_self(student_id));

create policy student_guardians_insert on public.student_guardians
  for insert to authenticated
  with check (app.has_permission('guardian.link') and app.student_in_scope(student_id));

create policy student_guardians_update on public.student_guardians
  for update to authenticated
  using      (app.has_permission('guardian.link') and app.student_in_scope(student_id))
  with check (app.student_in_scope(student_id));

-- ------------------------------------------------------------------
-- enrollments (§9 + قرار 2026-09-25)
-- ------------------------------------------------------------------
create policy enrollments_select on public.enrollments
  for select to authenticated
  using (    app.has_permission('enrollment.read')
         and (   app.can_access_school(school_id)
              or app.student_linked_to_guardian(student_id)
              or app.student_is_self(student_id)));

create policy enrollments_insert on public.enrollments
  for insert to authenticated
  with check (    app.can_access_school(school_id)
              and app.has_permission('enrollment.create')
              and app.student_in_scope(student_id));

create policy enrollments_update on public.enrollments
  for update to authenticated
  using      (    app.can_access_school(school_id)
              and app.has_permission('enrollment.update')
              and app.student_in_scope(student_id))
  with check (    app.can_access_school(school_id)        -- E1: لا نقل إلى مدرسة خارج النطاق
              and app.has_permission('enrollment.update')
              and app.student_in_scope(student_id));
