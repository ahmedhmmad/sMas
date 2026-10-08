-- M49 — staff_lifecycle (Phase 3A / 3-3 — T10، T11؛ P10 ودورة حياة التفويض)
-- المرجع: docs/PHASE3_3_ASSIGNMENTS.md §5؛ docs/PHASE3_2_ACCOUNT_ACCESS.md §5 (القاعدة)، منقّحة بـT11.
--
-- امتداد **متحكَّم به** لدالتَي M21 — نصّاهما حرفياً + الإضافات المعلَّمة «M49». لا تغيير في التوقيع ولا الصلاحية
-- ولا النطاق ولا الانتقالات ولا رسائل الخطأ القائمة (21_state_functions بلا تعديل).
--
--   end_staff_assignment — **مدرسة ذلك التكليف وحدها**، وفقط إن لم يبقَ للموظف تكليف مدرسة نشط آخر فيها:
--     • إنهاء تكليفات التدريس والمربي النشطة له في تلك المدرسة (السنوات غير المغلقة — T7)
--     • حذف نطاق تلك المدرسة من عضوية حسابه (G2، مُدقَّق) — **الأدوار لا تُمس والعضوية تبقى active** (T11)
--   set_staff_status(ended) — انتهاء نهائي على مستوى الـTenant:
--     • إنهاء **كل** تكليفات التدريس والمربي النشطة له (السنوات غير المغلقة)
--     • memberships.status = 'ended' — **بلا حذف أي صف**؛ كل دوال التفويض تشترط عضوية active
--   active ↔ on_leave، ended → archived — لا أثر (Q4).
--
-- لا مسّ لـT8: حذف النطاق غير مفحوص في tg_authz_integrity (M19: المنح مفحوص، السحب لا)، وتعطيل العضوية تحديث
-- على memberships. الأدوار لا تُحذف في أي مسار. الإسقاط نتيجة للعملية المصرَّح بها (staff.assign / staff.update +
-- النطاق)، مُدقَّق باسم الفاعل وبسببه؛ لا يُشترط membership.end.
-- الأمان لا يعتمد على شيء من هذا (P5 مشتق من العلاقة الحالية — 3-4): الإسقاط لاتساق دورة الحياة وإزالة المنح الخاملة.

grant select, delete on public.membership_scopes to app_owner;
grant select, update (status, ended_at) on public.memberships to app_owner;

set local role app_owner;

create or replace function app.set_staff_status(p_staff_id uuid, p_status text, p_reason text, p_effective_to date default null)
returns void
language plpgsql security definer set search_path = app, public, pg_temp
as $$
declare v_status text; v_tenant uuid; v_profile uuid;
begin
  if not app.has_permission(case when p_status = 'archived' then 'staff.archive' else 'staff.update' end) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  perform app.require_reason(p_reason);
  select st.status, st.platform_tenant_id, st.profile_id into v_status, v_tenant, v_profile from public.staff st
   where st.id = p_staff_id
     and (app.staff_in_scope(st.id) or app.can_access_tenant(st.platform_tenant_id))
   for update;
  if not found then raise exception 'not found' using errcode = 'P0002'; end if;
  if (v_status, p_status) not in (('active', 'on_leave'), ('on_leave', 'active'),
                                  ('active', 'ended'), ('on_leave', 'ended'),
                                  ('ended', 'archived')) then
    raise exception 'invalid transition % -> %', v_status, p_status using errcode = '22023';
  end if;
  if p_status = 'ended' then
    if p_effective_to is null then
      raise exception 'effective_to required when ending' using errcode = '22023';
    end if;
    if exists (select 1 from public.staff_school_assignments a
               where a.staff_id = p_staff_id and a.status = 'active' and not app.can_access_school(a.school_id)) then
      raise exception 'invariant: staff has active assignments outside the actor''s scope' using errcode = '23514';
    end if;
    perform 1 from public.staff_school_assignments a where a.staff_id = p_staff_id and a.status = 'active' for update;
    perform app.set_audit_context('end', p_reason);
    update public.staff_school_assignments
       set status = 'ended', effective_to = p_effective_to
     where staff_id = p_staff_id and status = 'active';
    -- M49 (P10): كل التكليفات التشغيلية في مدارس الـTenant — السنوات غير المغلقة (T7)
    update public.teaching_assignments t
       set status = 'ended', effective_to = greatest(p_effective_to, t.effective_from)
     where t.staff_id = p_staff_id and t.status = 'active'
       and exists (select 1 from public.academic_years y where y.id = t.academic_year_id and y.status <> 'closed');
    update public.class_teacher_assignments t
       set status = 'ended', effective_to = greatest(p_effective_to, t.effective_from)
     where t.staff_id = p_staff_id and t.status = 'active'
       and exists (select 1 from public.academic_years y where y.id = t.academic_year_id and y.status <> 'closed');
    -- M49 (T11): تعطيل عضوية الحساب — بلا حذف أي صف
    update public.memberships m
       set status = 'ended', ended_at = now()
     where m.profile_id = v_profile and m.status in ('active', 'suspended');
  else
    perform app.set_audit_context(case p_status when 'archived' then 'archive' else 'set_status' end, p_reason);
  end if;
  update public.staff
     set status = p_status,
         archived_at = case when p_status = 'archived' then now() else archived_at end
   where id = p_staff_id;
  perform app.set_audit_context(null, null);
end;
$$;

create or replace function app.end_staff_assignment(p_assignment_id uuid, p_effective_to date, p_reason text)
returns void
language plpgsql security definer set search_path = app, public, pg_temp
as $$
declare v_status text; v_from date; v_staff uuid; v_school uuid;
begin
  if not app.has_permission('staff.assign') then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  perform app.require_reason(p_reason);
  select a.status, a.effective_from, a.staff_id, a.school_id into v_status, v_from, v_staff, v_school
    from public.staff_school_assignments a
   where a.id = p_assignment_id and app.can_access_school(a.school_id) for update;
  if not found then raise exception 'not found' using errcode = 'P0002'; end if;
  if v_status <> 'active' then
    raise exception 'invalid transition % -> ended', v_status using errcode = '22023';
  end if;
  if p_effective_to is null or p_effective_to <= v_from then
    raise exception 'effective_to must be after effective_from' using errcode = '22023';
  end if;
  perform app.set_audit_context('end', p_reason);
  update public.staff_school_assignments set status = 'ended', effective_to = p_effective_to where id = p_assignment_id;
  -- M49 (P10، T11): هذه المدرسة وحدها، وفقط إن لم يبقَ له تكليف مدرسة نشط آخر فيها
  if not exists (select 1 from public.staff_school_assignments a
                  where a.staff_id = v_staff and a.school_id = v_school and a.status = 'active') then
    update public.teaching_assignments t
       set status = 'ended', effective_to = greatest(p_effective_to, t.effective_from)
     where t.staff_id = v_staff and t.school_id = v_school and t.status = 'active'
       and exists (select 1 from public.academic_years y where y.id = t.academic_year_id and y.status <> 'closed');
    update public.class_teacher_assignments t
       set status = 'ended', effective_to = greatest(p_effective_to, t.effective_from)
     where t.staff_id = v_staff and t.school_id = v_school and t.status = 'active'
       and exists (select 1 from public.academic_years y where y.id = t.academic_year_id and y.status <> 'closed');
    -- نطاق تلك المدرسة وحده (G2)؛ الأدوار والعضوية كما هي. T7 يسجله delete بالفاعل والسبب والصف القديم
    delete from public.membership_scopes ms
     using public.memberships m, public.staff s
     where s.id = v_staff and m.profile_id = s.profile_id and ms.membership_id = m.id
       and ms.scope_type = 'school' and ms.school_id = v_school;
  end if;
  perform app.set_audit_context(null, null);
end;
$$;

reset role;
