-- M12b — authz_helpers_current_scope
-- المرجع: قرار H2 (2026-09-25) — CLAUDE.md §3 (تقدم B10)، docs/PLAN_v3.md §9؛ docs/RLS_MODEL_v1.md §8.1، §10.4
--
-- H2: A school is operationally in scope for a student only through the student's current/authorized enrollment
--     in that school. Historical enrollments provide historical access only where a specific permission/policy
--     explicitly permits historical records; they do not grant operational access to the student's current account
--     or guardian account.
--
-- M12 باقية في التاريخ كما هي (بند 18)؛ هنا تُعاد كتابة أجسام ثلاث دوال بالاسم والتوقيع نفسيهما:
--   Student  → أحدث Enrollment للطالب، أياً كانت حالته، حتى يظهر أحدث منه
--   Guardian → ارتباط نشط + الطالب ضمن النطاق الحالي
--   Staff    → التكليف النشط فقط
-- family_in_scope و can_see_membership و can_manage_membership لا تتغير نصوصها: تستدعي هذه الدوال فترث الدلالة الجديدة.

set local role app_owner;

-- المدرسة التشغيلية الحالية = مدرسة أحدث تسجيل (effective_from الأكبر).
-- التفرد مضمون: G6 (enrollments_no_overlap) يمنع تسجيلين للطالب يبدآن في اليوم نفسه.
-- الحالة لا تحدد المدرسة الحالية: completed في نهاية السنة و withdrawn بالخطأ لا يسحبان الوصول.
create or replace function app.student_in_scope(p_student_id uuid)
returns boolean
language sql
stable
security definer
set search_path = app, public, pg_temp
as $$
  select exists (
    select 1
    from (select e.school_id
          from public.enrollments e
          where e.student_id = p_student_id
          order by e.effective_from desc
          limit 1) cur
    where app.can_access_school(cur.school_id)
  );
$$;

-- موظف مرئي: له تكليف نشط في مدرسة ضمن النطاق
create or replace function app.staff_in_scope(p_staff_id uuid)
returns boolean
language sql
stable
security definer
set search_path = app, public, pg_temp
as $$
  select exists (
    select 1 from public.staff_school_assignments a
    where a.staff_id = p_staff_id
      and a.status = 'active'
      and app.can_access_school(a.school_id)
  );
$$;

-- ولي أمر مرئي: ارتباط نشط بطالب ضمن النطاق الحالي
create or replace function app.guardian_in_scope(p_guardian_id uuid)
returns boolean
language sql
stable
security definer
set search_path = app, public, pg_temp
as $$
  select exists (
    select 1 from public.student_guardians sg
    where sg.guardian_id = p_guardian_id
      and sg.status = 'active'
      and app.student_in_scope(sg.student_id)
  );
$$;

reset role;
