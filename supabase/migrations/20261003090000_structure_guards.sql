-- M35 — structure_guards (Phase 2A / P2-B، ف6 — القرار 7، Q1، Q7، 2026-10-02)
-- المرجع: docs/PHASE2_SCHOOL_SETUP.md §1.5، §1.6، §2، §7 (T12).
--
-- المشكلة: حالة المرحلة/الصف/الشعبة عمود حر بلا حواجز، والشعبة تُنقل بين السنوات والصفوف بـUPDATE، وتُنشأ في سنة
-- مغلقة، وتُعطَّل وفيها تسجيلات نشطة.
--
-- الـinvariants (T12 — ثلاثة triggers حارسة BEFORE، على كل مسار):
--   sections     • school_id + academic_year_id + grade_level_id هوية ثابتة بعد الإنشاء.
--                • لا إنشاء ولا تعديل في سنة closed (بنية السنة المغلقة مجمدة معها).
--                • الشعبة active تحت صف active فقط (عند الإنشاء وعند إعادة التفعيل).
--                • لا تعطيل وفيها enrollments نشطة.
--   grade_levels • school_id ثابت. • الصف active تحت مرحلة active فقط.
--                • لا تعطيل وله شعب active في سنة غير مغلقة.
--   stages       • school_id ثابت. • لا تعطيل ولها صفوف active.
-- أي: شعبة نشطة (في سنة غير مغلقة) ⇒ صف نشط ⇒ مرحلة نشطة — من الجهتين (الابن عند تفعيله، الأب عند تعطيله).
--
-- الصلاحية والنطاق ليسا هنا: يبقيان في RLS (stage.manage / grade_level.manage / section.manage + can_access_school).
-- الدوال SECURITY DEFINER: تقرأ السنة والأب والأبناء والتسجيلات أياً كان ما تراه RLS للمستدعي، وتقفل الأب FOR SHARE
-- (تفعيل ابن وتعطيل أبيه لا يتسابقان: UPDATE الأب يقفل صفه قبل الحارس).
-- لا مفتاح صلاحية جديد ولا دالة انتقال: الحالة active ↔ inactive تبقى عموداً يكتبه العميل، بحواجز.

-- ------------------------------------------------------------------
-- البيانات القائمة: fail before mutation + تعداد المخالفات (قاعدة M30b) — لا تصحيح تلقائي
-- ------------------------------------------------------------------
do $$
declare v_bad text;
begin
  select string_agg(format('section %s under inactive grade level %s', s.id, g.id), '; ' order by s.id) into v_bad
    from public.sections s
    join public.grade_levels g on g.id = s.grade_level_id
    join public.academic_years y on y.id = s.academic_year_id
   where s.status = 'active' and g.status <> 'active' and y.status <> 'closed';
  if v_bad is not null then
    raise exception 'M35: active sections under an inactive grade level — resolve before migrating: %', v_bad;
  end if;
  select string_agg(format('grade level %s under inactive stage %s', g.id, st.id), '; ' order by g.id) into v_bad
    from public.grade_levels g join public.stages st on st.id = g.stage_id
   where g.status = 'active' and st.status <> 'active';
  if v_bad is not null then
    raise exception 'M35: active grade levels under an inactive stage — resolve before migrating: %', v_bad;
  end if;
end $$;

-- ------------------------------------------------------------------
-- سجل الأعمدة: هوية الصف في الجداول الثلاثة خارج UPDATE
-- ------------------------------------------------------------------
revoke update (school_id, academic_year_id, grade_level_id) on public.sections     from authenticated;
revoke update (school_id)                                   on public.grade_levels from authenticated;
revoke update (school_id)                                   on public.stages       from authenticated;

-- ما تقرؤه وتقفله الحراس — لمالكها. FOR SHARE يشترط امتياز UPDATE على عمود واحد على الأقل.
grant select, update (status) on public.grade_levels, public.stages to app_owner;

set local role app_owner;

-- ------------------------------------------------------------------
-- T12 — sections
-- ------------------------------------------------------------------
create function app.tg_section_guard()
returns trigger
language plpgsql
security definer
set search_path = app, public, pg_temp
as $$
declare v_year_status text; v_grade_status text;
begin
  if tg_op = 'UPDATE'
     and (new.school_id is distinct from old.school_id
          or new.academic_year_id is distinct from old.academic_year_id
          or new.grade_level_id is distinct from old.grade_level_id) then
    raise exception 'invariant: a section cannot move to another school, year or grade level' using errcode = '23514';
  end if;

  select y.status into v_year_status from public.academic_years y where y.id = new.academic_year_id for share;
  if v_year_status = 'closed' then
    if tg_op = 'INSERT' then
      raise exception 'invariant: the academic year is closed — no new sections' using errcode = '23514';
    end if;
    raise exception 'invariant: the academic year is closed — its sections cannot be modified' using errcode = '23514';
  end if;

  if new.status = 'active' and (tg_op = 'INSERT' or old.status <> 'active') then
    select g.status into v_grade_status from public.grade_levels g where g.id = new.grade_level_id for share;
    if v_grade_status <> 'active' then
      raise exception 'invariant: a section can be active only under an active grade level' using errcode = '23514';
    end if;
  end if;

  if tg_op = 'UPDATE' and old.status = 'active' and new.status <> 'active'
     and exists (select 1 from public.enrollments e where e.section_id = old.id and e.status = 'active') then
    raise exception 'invariant: the section has active enrollments' using errcode = '23514';
  end if;
  return new;
end;
$$;

-- ------------------------------------------------------------------
-- T12 — grade_levels
-- ------------------------------------------------------------------
create function app.tg_grade_level_guard()
returns trigger
language plpgsql
security definer
set search_path = app, public, pg_temp
as $$
declare v_stage_status text;
begin
  if tg_op = 'UPDATE' and new.school_id is distinct from old.school_id then
    raise exception 'invariant: a grade level cannot move to another school' using errcode = '23514';
  end if;

  if new.status = 'active'
     and (tg_op = 'INSERT' or old.status <> 'active' or new.stage_id is distinct from old.stage_id) then
    select st.status into v_stage_status from public.stages st where st.id = new.stage_id for share;
    if v_stage_status <> 'active' then
      raise exception 'invariant: a grade level can be active only under an active stage' using errcode = '23514';
    end if;
  end if;

  if tg_op = 'UPDATE' and old.status = 'active' and new.status <> 'active'
     and exists (select 1 from public.sections s join public.academic_years y on y.id = s.academic_year_id
                  where s.grade_level_id = old.id and s.status = 'active' and y.status <> 'closed') then
    raise exception 'invariant: the grade level has active sections' using errcode = '23514';
  end if;
  return new;
end;
$$;

-- ------------------------------------------------------------------
-- T12 — stages
-- ------------------------------------------------------------------
create function app.tg_stage_guard()
returns trigger
language plpgsql
security definer
set search_path = app, public, pg_temp
as $$
begin
  if new.school_id is distinct from old.school_id then
    raise exception 'invariant: a stage cannot move to another school' using errcode = '23514';
  end if;
  if old.status = 'active' and new.status <> 'active'
     and exists (select 1 from public.grade_levels g where g.stage_id = old.id and g.status = 'active') then
    raise exception 'invariant: the stage has active grade levels' using errcode = '23514';
  end if;
  return new;
end;
$$;

reset role;

create trigger guard before insert or update on public.sections
  for each row execute function app.tg_section_guard();
create trigger guard before insert or update on public.grade_levels
  for each row execute function app.tg_grade_level_guard();
create trigger guard before update on public.stages
  for each row execute function app.tg_stage_guard();
