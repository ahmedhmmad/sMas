-- M12 — authz_helpers
-- المرجع: docs/DB_IMPLEMENTATION_SPEC_v1.md §B10 (M12)؛ docs/RLS_MODEL_v1.md §8.1–§8.3، §8.4 (identity scope)، §10.0، §10.4
-- المتبقي فقط: دوال العلاقة و can_see/can_manage_membership.
-- دوال الهوية والصلاحية والنطاق أُنشئت في M03 و M05 و M06 و M07.
--
-- كل الدوال SECURITY DEFINER بهوية app_owner (BYPASSRLS، R2): تقرأ جداول FORCE RLS دون تداخل سياساتها،
-- والفاعل يُقرأ عبر app.current_profile_id() ← app.auth_uid(). لا EXECUTE لأحد هنا — M20.
-- لا تمنح أي منها صلاحية: هي شق «العلاقة/النطاق» فقط، وتُجمع مع has_permission() في السياسة (§1.1).

-- ------------------------------------------------------------------
-- قراءة جداول العلاقة — لمالك الدوال فقط
-- ------------------------------------------------------------------
grant select on public.enrollments, public.students, public.guardians, public.student_guardians,
                public.staff, public.staff_school_assignments, public.identity_scopes to app_owner;

set local role app_owner;

-- ------------------------------------------------------------------
-- مسارات الطالب الثلاثة (RLS_MODEL §8.1–§8.3)
-- ------------------------------------------------------------------

-- موظف: للطالب تسجيل (بأي حالة) في مدرسة ضمن نطاقه. التاريخ مرئي (§10.4).
create function app.student_in_scope(p_student_id uuid)
returns boolean
language sql
stable
security definer
set search_path = app, public, pg_temp
as $$
  select exists (
    select 1
    from public.enrollments e
    where e.student_id = p_student_id
      and app.can_access_school(e.school_id)
  );
$$;

-- ولي أمر: ارتباط نشط، وولي الأمر نفسه نشط
create function app.student_linked_to_guardian(p_student_id uuid)
returns boolean
language sql
stable
security definer
set search_path = app, public, pg_temp
as $$
  select exists (
    select 1
    from public.student_guardians sg
    join public.guardians g on g.id = sg.guardian_id
    where sg.student_id = p_student_id
      and sg.status = 'active'
      and g.profile_id = app.current_profile_id()
      and g.status = 'active'
  );
$$;

-- الطالب نفسه: student_profile_id NOT NULL (A4) فالنتيجة حتمية
create function app.student_is_self(p_student_id uuid)
returns boolean
language sql
stable
security definer
set search_path = app, public, pg_temp
as $$
  select exists (
    select 1 from public.students s
    join public.profiles p on p.id = app.current_profile_id()
    where s.id = p_student_id
      and s.student_profile_id = p.id
  );
$$;

-- ------------------------------------------------------------------
-- جداول الهوية الأخرى (RLS_MODEL §10.4، F6)
-- ------------------------------------------------------------------

-- موظف مرئي: له تكليف (بأي حالة) في مدرسة ضمن النطاق
create function app.staff_in_scope(p_staff_id uuid)
returns boolean
language sql
stable
security definer
set search_path = app, public, pg_temp
as $$
  select exists (
    select 1 from public.staff_school_assignments a
    where a.staff_id = p_staff_id
      and app.can_access_school(a.school_id)
  );
$$;

-- ولي أمر مرئي: مرتبط (بأي حالة) بطالب ضمن النطاق
create function app.guardian_in_scope(p_guardian_id uuid)
returns boolean
language sql
stable
security definer
set search_path = app, public, pg_temp
as $$
  select exists (
    select 1 from public.student_guardians sg
    where sg.guardian_id = p_guardian_id
      and app.student_in_scope(sg.student_id)
  );
$$;

-- أسرة مرئية: فيها طالب ضمن النطاق
create function app.family_in_scope(p_family_id uuid)
returns boolean
language sql
stable
security definer
set search_path = app, public, pg_temp
as $$
  select exists (
    select 1 from public.students s
    where s.family_id = p_family_id
      and app.student_in_scope(s.id)
  );
$$;

-- نطاق هوية يملك الفاعل سلطة عليه كله (RLS_MODEL §8.4)
create function app.can_access_identity_scope(p_scope_id uuid)
returns boolean
language sql
stable
security definer
set search_path = app, public, pg_temp
as $$
  select exists (
    select 1 from public.identity_scopes i
    where i.id = p_scope_id
      and (   (i.scope_kind = 'group'  and app.can_access_group(i.group_id))
           or (i.scope_kind = 'school' and app.can_access_school(i.school_id)))
  );
$$;

-- هوية الفاعل كولي أمر نشط — صف واحد على الأكثر (guardians_profile_uq، I23)
create function app.current_guardian_id()
returns uuid
language sql
stable
security definer
set search_path = app, public, pg_temp
as $$
  select g.id from public.guardians g
  where g.profile_id = app.current_profile_id()
    and g.status = 'active';
$$;

-- ------------------------------------------------------------------
-- العضويات (RLS_MODEL §10.0، F2–F5)
--   can_see    = تقاطع: نطاق واحد للهدف ضمن نطاق الفاعل، أو علاقة هوية ضمنه.
--   can_manage = احتواء: كل نطاقات الهدف ضمن نطاق الفاعل، ولا إدارة ذاتية.
-- ------------------------------------------------------------------
create function app.can_see_membership(p_membership_id uuid)
returns boolean
language sql
stable
security definer
set search_path = app, public, pg_temp
as $$
  select exists (
    select 1 from public.memberships m
    where m.id = p_membership_id
      and m.platform_tenant_id = app.current_tenant_id()
      and (
            exists (
              select 1 from public.membership_scopes ms
              where ms.membership_id = m.id
                and (   (ms.scope_type = 'tenant' and app.can_access_tenant(ms.platform_tenant_id))
                     or (ms.scope_type = 'group'  and app.can_access_group(ms.group_id))
                     or (ms.scope_type = 'school' and app.can_access_school(ms.school_id)))
            )
         or exists (select 1 from public.students s  where s.student_profile_id = m.profile_id and app.student_in_scope(s.id))
         or exists (select 1 from public.guardians g where g.profile_id = m.profile_id and app.guardian_in_scope(g.id))
         or exists (select 1 from public.staff st    where st.profile_id = m.profile_id and app.staff_in_scope(st.id))
      )
  );
$$;

create function app.can_manage_membership(p_membership_id uuid)
returns boolean
language sql
stable
security definer
set search_path = app, public, pg_temp
as $$
  select exists (
    select 1 from public.memberships m
    where m.id = p_membership_id
      and m.platform_tenant_id = app.current_tenant_id()
      and m.profile_id <> app.current_profile_id()          -- لا إدارة ذاتية (F5)
      and not exists (                                      -- كل نطاقات الهدف ⊆ نطاقات الفاعل (F4)
        select 1 from public.membership_scopes ms
        where ms.membership_id = m.id
          and not (   (ms.scope_type = 'tenant' and app.can_access_tenant(ms.platform_tenant_id))
                   or (ms.scope_type = 'group'  and app.can_access_group(ms.group_id))
                   or (ms.scope_type = 'school' and app.can_access_school(ms.school_id)))
      )
      and (                                                 -- عضوية بلا نطاقات: بالعلاقة أو بنطاق tenant
            exists (select 1 from public.membership_scopes ms where ms.membership_id = m.id)
         or app.can_access_tenant(m.platform_tenant_id)
         or exists (select 1 from public.students s  where s.student_profile_id = m.profile_id and app.student_in_scope(s.id))
         or exists (select 1 from public.guardians g where g.profile_id = m.profile_id and app.guardian_in_scope(g.id))
      )
  );
$$;

reset role;
