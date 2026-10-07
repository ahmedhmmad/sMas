-- M47 — staff_membership_grant (Phase 3A / 3-2 — P13، Q3)
-- المرجع: docs/PHASE3_SCOPE.md §2 (P13، Q3 المنقّحان 2026-10-07)؛ docs/RLS_MODEL_v1.md §10.0.
--
-- امتداد **متحكَّم به** لـM12 — لا تعديل على قرار Foundation: نص `app.can_manage_membership` (M12) حرفياً + فرع واحد.
--
-- الفجوة (كشفها استهلاك Foundation في المرحلة 3): العضوية **بلا نطاقات** تُدار في M12 بنطاق Tenant أو بعلاقة
-- طالب/ولي أمر فقط. حساب الموظف الجديد (provision_account) يولد بلا دور ولا نطاق، فمدير المدرسة ينشئ الموظف
-- والحساب ثم لا يستطيع منحه أول دور/نطاق (RLS ترفض الإدراج في membership_roles/membership_scopes).
-- `can_see_membership` تحمل فرع الموظف منذ M12؛ `can_manage_membership` لا تحمله.
--
-- الفرع المضاف — نقطة دخول لأول منح فقط:
--   العضوية بلا نطاقات ∧ الـprofile لموظف ∧ للموظف تكليف مدرسة **نشط** ضمن نطاق الفاعل (`app.staff_in_scope` — H2).
--   DB مصدر الحقيقة لأول منح لعضوية موظف (Q3): لا تكليف نشط في نطاق الفاعل ← لا إدارة.
--
-- ما لا يتغير (مُثبت في 46_staff_membership_grant):
--   • لا إدارة ذاتية (F5) · عزل الـTenant · كل نطاقات الهدف ⊆ نطاقات الفاعل متى وُجد نطاق (F4)
--   • سياسات membership_roles / membership_scopes (M15) — النطاق الممنوح نفسه يجب أن يكون ضمن نطاق الفاعل
--   • T8 (M19): الدور الممنوح ⊆ صلاحيات الفاعل · مسار tenant_admin · فرعا الطالب وولي الأمر
--   • لا مفتاح صلاحية ولا سياسة ولا EXECUTE جديد (التوقيع والمالك والمنح كما هي — create or replace)

set local role app_owner;

create or replace function app.can_manage_membership(p_membership_id uuid)
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
         or exists (select 1 from public.staff st    where st.profile_id = m.profile_id and app.staff_in_scope(st.id))   -- M47: أول منح لموظف
      )
  );
$$;

reset role;
