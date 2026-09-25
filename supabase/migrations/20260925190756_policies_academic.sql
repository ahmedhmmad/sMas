-- M16 — policies_academic
-- المرجع: docs/DB_IMPLEMENTATION_SPEC_v1.md §B10 (M16)، §4.5؛ docs/RLS_MODEL_v1.md §6.3، §7، §12.1؛
--         docs/ROLE_PERMISSION_SEED_v1.md §4 (Academic)
--
-- academic_years، terms، stages، grade_levels، sections — School-level: can_access_school(school_id) + has_permission().
-- كل السياسات TO authenticated؛ لا DELETE (§5.2)؛ لا سياسة Platform (بيانات تشغيل مدرسية).
--
-- المفاتيح من الكتالوج المجمَّد (المصدر الرسمي — CLAUDE.md §0):
--   academic_years: read / create / update — لا `.manage` في الكتالوج (RLS §7 جمعها مع البقية تحت `<res>.manage`؛
--                   §12.1 والكتالوج يفصلانها). activate و close انتقالات حالة (M21)، لا UPDATE مباشر.
--   terms، stages، grade_levels، sections: read / manage.
--
-- WITH CHECK في UPDATE يقيّم school_id من الصف الجديد مباشرة (عمود، لا قراءة جدول)، فنقل الصف إلى مدرسة
-- خارج النطاق يُرفض هنا. لا دوال جديدة ولا EXECUTE جديد: can_access_school و has_permission ممنوحتان منذ M14.

-- ------------------------------------------------------------------
-- academic_years
-- ------------------------------------------------------------------
create policy academic_years_select on public.academic_years
  for select to authenticated
  using (app.can_access_school(school_id) and app.has_permission('academic_year.read'));

create policy academic_years_insert on public.academic_years
  for insert to authenticated
  with check (app.can_access_school(school_id) and app.has_permission('academic_year.create'));

create policy academic_years_update on public.academic_years
  for update to authenticated
  using      (app.can_access_school(school_id) and app.has_permission('academic_year.update'))
  with check (app.can_access_school(school_id) and app.has_permission('academic_year.update'));

-- ------------------------------------------------------------------
-- terms، stages، grade_levels، sections — read / manage
-- ------------------------------------------------------------------
create policy terms_select on public.terms
  for select to authenticated
  using (app.can_access_school(school_id) and app.has_permission('term.read'));
create policy terms_insert on public.terms
  for insert to authenticated
  with check (app.can_access_school(school_id) and app.has_permission('term.manage'));
create policy terms_update on public.terms
  for update to authenticated
  using      (app.can_access_school(school_id) and app.has_permission('term.manage'))
  with check (app.can_access_school(school_id) and app.has_permission('term.manage'));

create policy stages_select on public.stages
  for select to authenticated
  using (app.can_access_school(school_id) and app.has_permission('stage.read'));
create policy stages_insert on public.stages
  for insert to authenticated
  with check (app.can_access_school(school_id) and app.has_permission('stage.manage'));
create policy stages_update on public.stages
  for update to authenticated
  using      (app.can_access_school(school_id) and app.has_permission('stage.manage'))
  with check (app.can_access_school(school_id) and app.has_permission('stage.manage'));

create policy grade_levels_select on public.grade_levels
  for select to authenticated
  using (app.can_access_school(school_id) and app.has_permission('grade_level.read'));
create policy grade_levels_insert on public.grade_levels
  for insert to authenticated
  with check (app.can_access_school(school_id) and app.has_permission('grade_level.manage'));
create policy grade_levels_update on public.grade_levels
  for update to authenticated
  using      (app.can_access_school(school_id) and app.has_permission('grade_level.manage'))
  with check (app.can_access_school(school_id) and app.has_permission('grade_level.manage'));

create policy sections_select on public.sections
  for select to authenticated
  using (app.can_access_school(school_id) and app.has_permission('section.read'));
create policy sections_insert on public.sections
  for insert to authenticated
  with check (app.can_access_school(school_id) and app.has_permission('section.manage'));
create policy sections_update on public.sections
  for update to authenticated
  using      (app.can_access_school(school_id) and app.has_permission('section.manage'))
  with check (app.can_access_school(school_id) and app.has_permission('section.manage'));
