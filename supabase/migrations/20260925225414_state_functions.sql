-- M21 — state_functions
-- المرجع: docs/DB_IMPLEMENTATION_SPEC_v1.md §5.0 (العقد والمتطلبات السبعة)، §5.3، B6؛ CLAUDE.md §1.1 بند 13؛
--         قرارات H2، M17b، M19، M20، و 2026-09-25 (النقل، التكليف، حالات الموظف)
--
-- كل انتقال حالة أُخرج عمداً من CRUD المباشر (M17b، M19، M20) يمر هنا. لكل دالة:
--   1. الفاعل = app.auth_uid() عبر has_permission()/has_platform_permission() — لا p_actor_id
--   2. الصلاحية أولاً (42501 forbidden) قبل أي قراءة
--   3. النطاق على الصف المقروء من الجدول، لا على قيمة مُمرَّرة؛ خارج النطاق = غير موجود (P0002، عدم الكشف)
--   4. SELECT ... FOR UPDATE ثم مطابقة (from, to) مع قائمة انتقالات صريحة (22023 لما سواها)
--   5. invariants قبل الكتابة (23514)
--   6. app.audit_action / app.audit_reason تُضبط قبل الكتابة وتُعاد فارغة بعدها مباشرة (متطلب M11)
--   7. SECURITY DEFINER بهوية app_owner، search_path ثابت، أسماء مؤهَّلة، لا SQL ديناميكي؛ EXECUTE لـauthenticated فقط
-- reason إلزامي في كل الدوال. التواريخ صريحة (لا current_date ضمني: B6 — date بمنطقة المدرسة الزمنية، يمررها FastAPI).
--
-- قرارات 2026-09-25 (قبل الكتابة):
--   • النقل: فاعل واحد يملك enrollment.transfer ونطاقاً على المدرستين معاً (الطالب في نطاقه الحالي — H2)؛
--     عملية ذرية واحدة: إغلاق القديم transferred عند d + فتح الجديد من d. سير الطلب/الموافقة بين مدرستين: المرحلة 4.
--     close_enrollment لا تقبل transferred — لا حالة وسطية بلا تسجيل نشط.
--   • تكليف الموظف: إنهاء فقط؛ العودة = تكليف جديد (قرار b). لا إعادة فتح لفترة مغلقة.
--   • حالات الموظف: active ↔ on_leave؛ active|on_leave → ended؛ ended → archived. لا عودة من ended/archived.
--   • تفعيل/تعطيل الدور المخصص (M19): role.update + tenant scope + صلاحيات الدور ⊆ الفاعل (منطق T8)،
--     في الاتجاهين كقاعدة T8 للسحب (§10.2.1).

-- ------------------------------------------------------------------
-- ما تكتبه الدوال فقط — لمالكها
-- ------------------------------------------------------------------
grant select, update on public.platform_tenants, public.groups, public.schools, public.memberships,
                        public.students, public.staff, public.staff_school_assignments, public.guardians,
                        public.academic_years, public.student_guardians, public.enrollments, public.roles
  to app_owner;
grant insert on public.enrollments to app_owner;
grant select on public.sections to app_owner;

set local role app_owner;

-- ------------------------------------------------------------------
-- أدوات داخلية (لا EXECUTE لأحد): سياق التدقيق، والتحقق من السبب
-- ------------------------------------------------------------------
create function app.set_audit_context(p_action text, p_reason text)
returns void
language sql
volatile
security definer
set search_path = app, public, pg_temp
as $$
  select set_config('app.audit_action', coalesce(p_action, ''), true),
         set_config('app.audit_reason', coalesce(p_reason, ''), true);
$$;

create function app.require_reason(p_reason text)
returns void
language plpgsql
set search_path = app, public, pg_temp
as $$
begin
  if coalesce(btrim(p_reason), '') = '' then
    raise exception 'reason required' using errcode = '22023';
  end if;
end;
$$;

-- ------------------------------------------------------------------
-- Tenant — سياق المنصة (tenant.suspend)
-- ------------------------------------------------------------------
create function app.suspend_tenant(p_tenant_id uuid, p_reason text)
returns void
language plpgsql security definer set search_path = app, public, pg_temp
as $$
declare v_status text;
begin
  if not app.has_platform_permission('tenant.suspend') then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  perform app.require_reason(p_reason);
  select t.status into v_status from public.platform_tenants t where t.id = p_tenant_id for update;
  if not found then raise exception 'not found' using errcode = 'P0002'; end if;
  if v_status <> 'active' then
    raise exception 'invalid transition % -> suspended', v_status using errcode = '22023';
  end if;
  perform app.set_audit_context('suspend', p_reason);
  update public.platform_tenants set status = 'suspended', suspended_at = now() where id = p_tenant_id;
  perform app.set_audit_context(null, null);
end;
$$;

create function app.reactivate_tenant(p_tenant_id uuid, p_reason text)
returns void
language plpgsql security definer set search_path = app, public, pg_temp
as $$
declare v_status text;
begin
  if not app.has_platform_permission('tenant.suspend') then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  perform app.require_reason(p_reason);
  select t.status into v_status from public.platform_tenants t where t.id = p_tenant_id for update;
  if not found then raise exception 'not found' using errcode = 'P0002'; end if;
  if v_status <> 'suspended' then
    raise exception 'invalid transition % -> active', v_status using errcode = '22023';
  end if;
  perform app.set_audit_context('reactivate', p_reason);
  update public.platform_tenants set status = 'active', suspended_at = null where id = p_tenant_id;
  perform app.set_audit_context(null, null);
end;
$$;

-- ------------------------------------------------------------------
-- Group / School
-- ------------------------------------------------------------------
create function app.archive_group(p_group_id uuid, p_reason text)
returns void
language plpgsql security definer set search_path = app, public, pg_temp
as $$
declare v_status text;
begin
  if not app.has_permission('group.archive') then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  perform app.require_reason(p_reason);
  select g.status into v_status from public.groups g
   where g.id = p_group_id and app.can_access_group(g.id) for update;
  if not found then raise exception 'not found' using errcode = 'P0002'; end if;
  if v_status <> 'active' then
    raise exception 'invalid transition % -> inactive', v_status using errcode = '22023';
  end if;
  if exists (select 1 from public.schools s where s.group_id = p_group_id and s.status = 'active') then
    raise exception 'invariant: group has active schools' using errcode = '23514';
  end if;
  perform app.set_audit_context('archive', p_reason);
  update public.groups set status = 'inactive' where id = p_group_id;
  perform app.set_audit_context(null, null);
end;
$$;

create function app.archive_school(p_school_id uuid, p_reason text)
returns void
language plpgsql security definer set search_path = app, public, pg_temp
as $$
declare v_status text;
begin
  if not app.has_permission('school.archive') then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  perform app.require_reason(p_reason);
  select s.status into v_status from public.schools s
   where s.id = p_school_id and app.can_access_school(s.id) for update;
  if not found then raise exception 'not found' using errcode = 'P0002'; end if;
  if v_status <> 'active' then
    raise exception 'invalid transition % -> archived', v_status using errcode = '22023';
  end if;
  if exists (select 1 from public.enrollments e where e.school_id = p_school_id and e.status = 'active') then
    raise exception 'invariant: school has active enrollments' using errcode = '23514';
  end if;
  if exists (select 1 from public.staff_school_assignments a where a.school_id = p_school_id and a.status = 'active') then
    raise exception 'invariant: school has active staff assignments' using errcode = '23514';
  end if;
  perform app.set_audit_context('archive', p_reason);
  update public.schools set status = 'archived', archived_at = now() where id = p_school_id;
  perform app.set_audit_context(null, null);
end;
$$;

-- ------------------------------------------------------------------
-- Membership — membership.end + can_manage_membership (لا إدارة ذاتية)
-- ------------------------------------------------------------------
create function app.end_membership(p_membership_id uuid, p_reason text)
returns void
language plpgsql security definer set search_path = app, public, pg_temp
as $$
declare v_status text;
begin
  if not app.has_permission('membership.end') then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  perform app.require_reason(p_reason);
  select m.status into v_status from public.memberships m
   where m.id = p_membership_id and app.can_manage_membership(m.id) for update;
  if not found then raise exception 'not found' using errcode = 'P0002'; end if;
  if v_status not in ('active', 'suspended') then
    raise exception 'invalid transition % -> ended', v_status using errcode = '22023';
  end if;
  perform app.set_audit_context('end', p_reason);
  update public.memberships set status = 'ended', ended_at = now() where id = p_membership_id;
  perform app.set_audit_context(null, null);
end;
$$;

-- ------------------------------------------------------------------
-- Student — student.archive + المدرسة الحالية (H2)
-- ------------------------------------------------------------------
create function app.archive_student(p_student_id uuid, p_reason text)
returns void
language plpgsql security definer set search_path = app, public, pg_temp
as $$
declare v_status text;
begin
  if not app.has_permission('student.archive') then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  perform app.require_reason(p_reason);
  select s.status into v_status from public.students s
   where s.id = p_student_id and app.student_in_scope(s.id) for update;
  if not found then raise exception 'not found' using errcode = 'P0002'; end if;
  if v_status not in ('active', 'withdrawn') then
    raise exception 'invalid transition % -> archived', v_status using errcode = '22023';
  end if;
  if exists (select 1 from public.enrollments e where e.student_id = p_student_id and e.status = 'active') then
    raise exception 'invariant: student has an active enrollment' using errcode = '23514';
  end if;
  perform app.set_audit_context('archive', p_reason);
  update public.students set status = 'archived', archived_at = now() where id = p_student_id;
  perform app.set_audit_context(null, null);
end;
$$;

-- ------------------------------------------------------------------
-- Staff — حالات محافظة (قرار 2026-09-25)
--   النطاق: staff_in_scope (تكليف نشط) أو نطاق tenant — الموظف المنتهي بلا تكليف نشط لا تصله مدرسة (H2)
--   → ended: تُغلق تكليفاته النشطة في العملية نفسها؛ كلها يجب أن تكون في مدارس ضمن نطاق الفاعل
-- ------------------------------------------------------------------
create function app.set_staff_status(p_staff_id uuid, p_status text, p_reason text, p_effective_to date default null)
returns void
language plpgsql security definer set search_path = app, public, pg_temp
as $$
declare v_status text; v_tenant uuid;
begin
  if not app.has_permission(case when p_status = 'archived' then 'staff.archive' else 'staff.update' end) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  perform app.require_reason(p_reason);
  select st.status, st.platform_tenant_id into v_status, v_tenant from public.staff st
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

-- تكليف: إنهاء فقط (قرار 2026-09-25 — العودة تكليف جديد)
create function app.end_staff_assignment(p_assignment_id uuid, p_effective_to date, p_reason text)
returns void
language plpgsql security definer set search_path = app, public, pg_temp
as $$
declare v_status text; v_from date;
begin
  if not app.has_permission('staff.assign') then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  perform app.require_reason(p_reason);
  select a.status, a.effective_from into v_status, v_from from public.staff_school_assignments a
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
  perform app.set_audit_context(null, null);
end;
$$;

-- ------------------------------------------------------------------
-- Guardian — أرشفة بـguardian.update (G8)؛ فك الارتباط بـguardian.unlink
-- ------------------------------------------------------------------
create function app.archive_guardian(p_guardian_id uuid, p_reason text)
returns void
language plpgsql security definer set search_path = app, public, pg_temp
as $$
declare v_status text;
begin
  if not app.has_permission('guardian.update') then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  perform app.require_reason(p_reason);
  select g.status into v_status from public.guardians g
   where g.id = p_guardian_id and app.guardian_in_scope(g.id) for update;
  if not found then raise exception 'not found' using errcode = 'P0002'; end if;
  if v_status <> 'active' then
    raise exception 'invalid transition % -> archived', v_status using errcode = '22023';
  end if;
  perform app.set_audit_context('archive', p_reason);
  update public.guardians set status = 'archived', archived_at = now() where id = p_guardian_id;
  perform app.set_audit_context(null, null);
end;
$$;

create function app.unlink_guardian(p_link_id uuid, p_effective_to date, p_reason text)
returns void
language plpgsql security definer set search_path = app, public, pg_temp
as $$
declare v_status text; v_from date;
begin
  if not app.has_permission('guardian.unlink') then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  perform app.require_reason(p_reason);
  select l.status, l.effective_from into v_status, v_from from public.student_guardians l
   where l.id = p_link_id and app.student_in_scope(l.student_id) for update;
  if not found then raise exception 'not found' using errcode = 'P0002'; end if;
  if v_status <> 'active' then
    raise exception 'invalid transition % -> ended', v_status using errcode = '22023';
  end if;
  if p_effective_to is null or p_effective_to <= v_from then
    raise exception 'effective_to must be after effective_from' using errcode = '22023';
  end if;
  perform app.set_audit_context('unlink', p_reason);
  update public.student_guardians set status = 'ended', effective_to = p_effective_to where id = p_link_id;
  perform app.set_audit_context(null, null);
end;
$$;

-- ------------------------------------------------------------------
-- Academic year — planned → active → closed
-- ------------------------------------------------------------------
create function app.activate_academic_year(p_year_id uuid, p_reason text)
returns void
language plpgsql security definer set search_path = app, public, pg_temp
as $$
declare v_status text; v_school uuid;
begin
  if not app.has_permission('academic_year.activate') then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  perform app.require_reason(p_reason);
  select y.status, y.school_id into v_status, v_school from public.academic_years y
   where y.id = p_year_id and app.can_access_school(y.school_id) for update;
  if not found then raise exception 'not found' using errcode = 'P0002'; end if;
  if v_status <> 'planned' then
    raise exception 'invalid transition % -> active', v_status using errcode = '22023';
  end if;
  if exists (select 1 from public.academic_years y where y.school_id = v_school and y.status = 'active') then
    raise exception 'invariant: the school already has an active academic year' using errcode = '23514';
  end if;
  perform app.set_audit_context('activate', p_reason);
  update public.academic_years set status = 'active' where id = p_year_id;
  perform app.set_audit_context(null, null);
end;
$$;

create function app.close_academic_year(p_year_id uuid, p_reason text)
returns void
language plpgsql security definer set search_path = app, public, pg_temp
as $$
declare v_status text;
begin
  if not app.has_permission('academic_year.close') then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  perform app.require_reason(p_reason);
  select y.status into v_status from public.academic_years y
   where y.id = p_year_id and app.can_access_school(y.school_id) for update;
  if not found then raise exception 'not found' using errcode = 'P0002'; end if;
  if v_status <> 'active' then
    raise exception 'invalid transition % -> closed', v_status using errcode = '22023';
  end if;
  if exists (select 1 from public.enrollments e where e.academic_year_id = p_year_id and e.status = 'active') then
    raise exception 'invariant: the year has active enrollments' using errcode = '23514';
  end if;
  perform app.set_audit_context('close', p_reason);
  update public.academic_years set status = 'closed' where id = p_year_id;
  perform app.set_audit_context(null, null);
end;
$$;

-- ------------------------------------------------------------------
-- Enrollment — إغلاق (withdrawn/completed) ونقل ذري
-- ------------------------------------------------------------------
create function app.close_enrollment(p_enrollment_id uuid, p_status text, p_effective_to date, p_reason text)
returns void
language plpgsql security definer set search_path = app, public, pg_temp
as $$
declare v_status text; v_from date;
begin
  if not app.has_permission('enrollment.archive') then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  perform app.require_reason(p_reason);
  select e.status, e.effective_from into v_status, v_from from public.enrollments e
   where e.id = p_enrollment_id
     and app.can_access_school(e.school_id)
     and app.student_in_scope(e.student_id)          -- المدرسة الحالية فقط (H2)
   for update;
  if not found then raise exception 'not found' using errcode = 'P0002'; end if;
  if (v_status, p_status) not in (('active', 'withdrawn'), ('active', 'completed')) then
    raise exception 'invalid transition % -> % (transfer: app.transfer_enrollment)', v_status, p_status using errcode = '22023';
  end if;
  if p_effective_to is null or p_effective_to <= v_from then
    raise exception 'effective_to must be after effective_from' using errcode = '22023';
  end if;
  perform app.set_audit_context(case p_status when 'withdrawn' then 'withdraw' else 'complete' end, p_reason);
  update public.enrollments
     set status = p_status, effective_to = p_effective_to,
         withdrawal_reason = case when p_status = 'withdrawn' then p_reason end
   where id = p_enrollment_id;
  perform app.set_audit_context(null, null);
end;
$$;

-- النقل: إغلاق القديم transferred عند d وفتح الجديد من d — في عملية واحدة (G3، G6، H2)
create function app.transfer_enrollment(p_enrollment_id uuid, p_target_section_id uuid, p_transfer_date date,
                                        p_reason text, p_enrollment_no text default null)
returns uuid
language plpgsql security definer set search_path = app, public, pg_temp
as $$
declare
  v_old     public.enrollments%rowtype;
  v_sec     public.sections%rowtype;
  v_owner   uuid;
  v_new_id  uuid;
begin
  if not app.has_permission('enrollment.transfer') then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  perform app.require_reason(p_reason);
  select e.* into v_old from public.enrollments e
   where e.id = p_enrollment_id
     and app.can_access_school(e.school_id)
     and app.student_in_scope(e.student_id)
   for update;
  if not found then raise exception 'not found' using errcode = 'P0002'; end if;
  if v_old.status <> 'active' then
    raise exception 'invalid transition % -> transferred', v_old.status using errcode = '22023';
  end if;
  select s.* into v_sec from public.sections s
   where s.id = p_target_section_id and app.can_access_school(s.school_id);   -- موافقة المدرسة الجديدة = نطاق عليها
  if not found then raise exception 'not found' using errcode = 'P0002'; end if;
  if v_sec.school_id = v_old.school_id then
    raise exception 'invariant: transfer requires a different school' using errcode = '23514';
  end if;
  select sc.scope_owner_id into v_owner from public.schools sc where sc.id = v_sec.school_id and sc.status = 'active';
  if v_owner is null then
    raise exception 'invariant: target school is not active' using errcode = '23514';
  end if;
  if v_owner is distinct from (select i.owner_id from public.identity_scopes i where i.id = v_old.identity_scope_id) then
    raise exception 'invariant: target school is outside the student''s identity scope (no automatic transfer outside the group)' using errcode = '23514';
  end if;
  if p_transfer_date is null or p_transfer_date <= v_old.effective_from then
    raise exception 'transfer date must be after the current enrollment start' using errcode = '22023';
  end if;

  perform app.set_audit_context('transfer', p_reason);
  update public.enrollments set status = 'transferred', effective_to = p_transfer_date where id = p_enrollment_id;
  insert into public.enrollments (school_id, student_id, platform_tenant_id, academic_year_id, grade_level_id, section_id,
                                  identity_scope_id, scope_owner_id, enrollment_no, effective_from)
  values (v_sec.school_id, v_old.student_id, v_old.platform_tenant_id, v_sec.academic_year_id, v_sec.grade_level_id, v_sec.id,
          v_old.identity_scope_id, v_owner, p_enrollment_no, p_transfer_date)
  returning id into v_new_id;
  perform app.set_audit_context(null, null);
  return v_new_id;
end;
$$;

-- ------------------------------------------------------------------
-- Role — تفعيل/تعطيل الدور المخصص (M19): role.update + نطاق tenant + صلاحيات الدور ⊆ الفاعل
-- ------------------------------------------------------------------
create function app.set_role_status(p_role_id uuid, p_status text, p_reason text)
returns void
language plpgsql security definer set search_path = app, public, pg_temp
as $$
declare v_status text; v_missing text;
begin
  if not app.has_permission('role.update') then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  perform app.require_reason(p_reason);
  select r.status into v_status from public.roles r
   where r.id = p_role_id
     and r.platform_tenant_id = app.current_tenant_id()          -- مخصص ومملوك للـTenant (أدوار النظام خارجها)
     and app.can_access_tenant(r.platform_tenant_id)
   for update;
  if not found then raise exception 'not found' using errcode = 'P0002'; end if;
  if (v_status, p_status) not in (('inactive', 'active'), ('active', 'inactive')) then
    raise exception 'invalid transition % -> %', v_status, p_status using errcode = '22023';
  end if;
  select string_agg(p.code, ', ' order by p.code) into v_missing
  from public.role_permissions rp join public.permissions p on p.id = rp.permission_id
  where rp.role_id = p_role_id and not app.has_permission(p.code);
  if v_missing is not null then
    raise exception 'T8: role status change would affect permissions the actor does not hold: %', v_missing using errcode = '42501';
  end if;
  perform app.set_audit_context(case p_status when 'active' then 'activate' else 'deactivate' end, p_reason);
  update public.roles set status = p_status where id = p_role_id;
  perform app.set_audit_context(null, null);
end;
$$;

reset role;

-- ------------------------------------------------------------------
-- EXECUTE: allowlist الدوال المتحكَّم بها (M20) — authenticated فقط؛ الأدوات الداخلية لا لأحد
-- ------------------------------------------------------------------
grant execute on function
  app.suspend_tenant(uuid, text),
  app.reactivate_tenant(uuid, text),
  app.archive_group(uuid, text),
  app.archive_school(uuid, text),
  app.end_membership(uuid, text),
  app.archive_student(uuid, text),
  app.set_staff_status(uuid, text, text, date),
  app.end_staff_assignment(uuid, date, text),
  app.archive_guardian(uuid, text),
  app.unlink_guardian(uuid, date, text),
  app.activate_academic_year(uuid, text),
  app.close_academic_year(uuid, text),
  app.close_enrollment(uuid, text, date, text),
  app.transfer_enrollment(uuid, uuid, date, text, text),
  app.set_role_status(uuid, text, text)
to authenticated;
