-- M52 — teacher_load_limits (Phase 3A / 3-5 — L1–L7؛ P11)
-- المرجع: docs/PHASE3_5_WORKLOAD.md §1–§3؛ docs/DATA_DICTIONARY_v1.md §2.41؛ PLAN §9 (2026-10-09).
--
-- teacher_load_limits [S عبر السنة] — الحد **الاختياري** لنصاب موظف في سنة: max_weekly_periods، و NULL = بلا حد
--   (الإزالة بـNULL لا بالحذف — لا DELETE).
-- **النصاب نفسه غير مخزّن** (L2): Σ grade_subjects.weekly_periods لتكليفات التدريس الفعّالة — قراءة مشتقة في الـAPI.
-- **النصاب لا يصبح قيداً على التكليف** (L7): لا شيء هنا يقرأ التكليفات أو يمسّها؛ T17 ودالتا الإنهاء (M48) كما هي.
--
-- الرؤية (L5): صف الحد يقرؤه حامل staff.assign ضمن نطاق المدرسة، والموظف صفّه هو فقط — **لا بـstaff.read** (PD1).
--   فرع الذات يستعمل app.current_staff_id() القائمة منذ M50؛ تُمنح EXECUTE هنا لأن سياسة تستدعيها (فئة RLS helpers — حارس 20).
-- T18 (حارس، SECURITY DEFINER، كل مسار): السنة المغلقة مجمدة والنشطة بسبب (C3 — إعادة استعمال app.require_year_setup_writable)؛
--   الهوية ثابتة؛ عند الإنشاء: للموظف تكليف مدرسة نشط في مدرسة السنة.
-- لا مفتاح صلاحية (الكتالوج 79)، لا دالة متحكَّم بها، لا تعديل على M48–M51.

create table public.teacher_load_limits (
  id                 uuid        not null default gen_random_uuid(),
  platform_tenant_id uuid        not null,
  school_id          uuid        not null,
  academic_year_id   uuid        not null,
  staff_id           uuid        not null,
  max_weekly_periods integer,
  created_at         timestamptz not null default now(),
  created_by         uuid,
  updated_at         timestamptz not null default now(),
  updated_by         uuid,
  constraint teacher_load_limits_pkey          primary key (id),
  constraint teacher_load_limits_school_fk     foreign key (school_id, platform_tenant_id) references public.schools (id, platform_tenant_id),
  constraint teacher_load_limits_year_fk       foreign key (academic_year_id, school_id)   references public.academic_years (id, school_id),
  constraint teacher_load_limits_staff_fk      foreign key (staff_id, platform_tenant_id)  references public.staff (id, platform_tenant_id),
  constraint teacher_load_limits_year_staff_uq unique (academic_year_id, staff_id),
  constraint teacher_load_limits_max_chk       check (max_weekly_periods is null or max_weekly_periods >= 1 and max_weekly_periods <= 100),
  constraint teacher_load_limits_created_by_fk foreign key (created_by) references public.profiles (id),
  constraint teacher_load_limits_updated_by_fk foreign key (updated_by) references public.profiles (id)
);
create index teacher_load_limits_school_idx     on public.teacher_load_limits (school_id, platform_tenant_id);
create index teacher_load_limits_year_idx       on public.teacher_load_limits (academic_year_id, school_id);
create index teacher_load_limits_staff_idx      on public.teacher_load_limits (staff_id, platform_tenant_id);
create index teacher_load_limits_created_by_idx on public.teacher_load_limits (created_by);
create index teacher_load_limits_updated_by_idx on public.teacher_load_limits (updated_by);

-- T6 ختم، T7 تدقيق، RLS مفعّل ومفروض من الإنشاء
create trigger stamp before insert or update on public.teacher_load_limits for each row execute function app.tg_stamp();
create trigger audit after insert or update or delete on public.teacher_load_limits for each row execute function app.tg_audit();

alter table public.teacher_load_limits enable row level security;
alter table public.teacher_load_limits force  row level security;

-- السياسات — School-level، TO authenticated؛ لا DELETE
create policy teacher_load_limits_select on public.teacher_load_limits
  for select to authenticated
  using ((app.can_access_school(school_id) and app.has_permission('staff.assign'))
      or staff_id = (select app.current_staff_id()));
create policy teacher_load_limits_insert on public.teacher_load_limits
  for insert to authenticated
  with check (app.can_access_school(school_id) and app.has_permission('staff.assign'));
create policy teacher_load_limits_update on public.teacher_load_limits
  for update to authenticated
  using      (app.can_access_school(school_id) and app.has_permission('staff.assign'))
  with check (app.can_access_school(school_id) and app.has_permission('staff.assign'));

-- الامتيازات — منح صريح فقط (M20)
grant insert (platform_tenant_id, school_id, academic_year_id, staff_id, max_weekly_periods) on public.teacher_load_limits to authenticated;
grant update (max_weekly_periods) on public.teacher_load_limits to authenticated;
grant select on public.teacher_load_limits to app_owner;

-- فرع الذات في السياسة يستدعيها مباشرة
grant execute on function app.current_staff_id() to authenticated;

set local role app_owner;

-- T18 — حارس الجدول
create function app.tg_teacher_load_limit_guard()
returns trigger
language plpgsql
security definer
set search_path = app, public, pg_temp
as $$
declare
  v_new jsonb := to_jsonb(new);
  v_old jsonb := case when tg_op = 'UPDATE' then to_jsonb(old) end;
begin
  if tg_op = 'UPDATE'
     and (v_new - array['max_weekly_periods', 'updated_at', 'updated_by'])
         is distinct from (v_old - array['max_weekly_periods', 'updated_at', 'updated_by']) then
    raise exception 'invariant: a load limit cannot change its school, year or staff member' using errcode = '23514';
  end if;

  -- السنة: المغلقة مجمدة؛ النشطة بسبب (C3) — على كل مسار
  perform 1 from public.academic_years y where y.id = new.academic_year_id for share;
  perform app.require_year_setup_writable(new.academic_year_id, 'load limits');

  if tg_op = 'INSERT'
     and not exists (select 1 from public.staff_school_assignments a
                      where a.staff_id = new.staff_id and a.school_id = new.school_id and a.status = 'active') then
    raise exception 'invariant: the staff member has no active assignment in this school' using errcode = '23514';
  end if;
  return new;
end;
$$;

reset role;

create trigger guard before insert or update on public.teacher_load_limits
  for each row execute function app.tg_teacher_load_limit_guard();

revoke all on function app.tg_teacher_load_limit_guard() from public;
