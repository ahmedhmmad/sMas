-- M48 — teaching_assignments (Phase 3A / 3-3 — T1–T9؛ P6، P7، P8، P9)
-- المرجع: docs/PHASE3_3_ASSIGNMENTS.md §1–§4؛ docs/DATA_DICTIONARY_v1.md §2.39، §2.40.
--
-- teaching_assignments       [S عبر السنة]  معلم ↔ شعبة ↔ مادة في سنة — معلم **نشط واحد** لكل (شعبة، مادة) (P6)
-- class_teacher_assignments  [S عبر السنة]  مربي فصل ↔ شعبة — مربٍّ **نشط واحد** لكل شعبة (P7)؛ لا يُشترط أن يدرّسها
--
-- الإعلاني (المحرك يفرضه على كل مسار):
--   • FK الشعبة بسياقها (مدرسة، سنة، صف) — لا تركيب عبر مدارس أو سنوات
--   • FK ربط المادة (سنة، صف، مادة) → grade_subjects — المادة مربوطة بصف الشعبة في السنة نفسها
--   • FK الموظف والمدرسة بالـTenant (§0.6)
--   • فهرس فريد جزئي «نشط واحد» — **سلطة التزامن** (T3): إدراجان متزامنان ← واحد ينجح والآخر 23505
-- T17 (حارس، SECURITY DEFINER، 23514، كل مسار): ما لا يصلح له FK لأنه حالة تتغير —
--   السنة غير مغلقة (وفي النشطة سبب — عقد C3، بإعادة استعمال app.require_year_setup_writable من M43)،
--   وعند الإنشاء: الشعبة active، المادة وربطها active، الموظف active وله تكليف مدرسة نشط فيها (Q4: لا تكليف جديد لـon_leave)؛
--   الهوية ثابتة؛ الانتقال الوحيد active → ended؛ الصف ended مجمَّد.
-- الكتابة (T4، T5): INSERT تحت RLS (staff.assign + نطاق المدرسة)؛ **لا UPDATE ولا DELETE للعميل**؛ الإنهاء بدالتين متحكَّم بهما.
-- خارج هذه الـmigration: P10 ودورة حياة التفويض (M49)، مفاتيح *.read_assigned والتضييق (3-4)، النصاب (3-5)،
--   أي حارس عكسي على جداول المرحلة 2 (T8: لا)، إنهاء تكليفات السنة عند إغلاقها (T7: لا).

-- ------------------------------------------------------------------
-- teaching_assignments
-- ------------------------------------------------------------------
create table public.teaching_assignments (
  id                 uuid        not null default gen_random_uuid(),
  platform_tenant_id uuid        not null,
  school_id          uuid        not null,
  academic_year_id   uuid        not null,
  grade_level_id     uuid        not null,
  section_id         uuid        not null,
  subject_id         uuid        not null,
  staff_id           uuid        not null,
  status             text        not null default 'active',
  effective_from     date        not null,
  effective_to       date,
  created_at         timestamptz not null default now(),
  created_by         uuid,
  updated_at         timestamptz not null default now(),
  updated_by         uuid,
  constraint teaching_assignments_pkey             primary key (id),
  constraint teaching_assignments_school_fk        foreign key (school_id, platform_tenant_id) references public.schools (id, platform_tenant_id),
  constraint teaching_assignments_staff_fk         foreign key (staff_id, platform_tenant_id)  references public.staff (id, platform_tenant_id),
  constraint teaching_assignments_section_fk       foreign key (section_id, school_id, academic_year_id, grade_level_id)
                                                     references public.sections (id, school_id, academic_year_id, grade_level_id),
  constraint teaching_assignments_grade_subject_fk foreign key (academic_year_id, grade_level_id, subject_id)
                                                     references public.grade_subjects (academic_year_id, grade_level_id, subject_id),
  constraint teaching_assignments_status_chk       check (status in ('active', 'ended')),
  constraint teaching_assignments_active_chk       check ((status = 'active') = (effective_to is null)),
  constraint teaching_assignments_dates_chk        check (effective_to is null or effective_to >= effective_from),
  constraint teaching_assignments_created_by_fk    foreign key (created_by) references public.profiles (id),
  constraint teaching_assignments_updated_by_fk    foreign key (updated_by) references public.profiles (id)
);
create unique index teaching_assignments_active_uq        on public.teaching_assignments (section_id, subject_id) where status = 'active';   -- P6، T3
create index teaching_assignments_school_idx              on public.teaching_assignments (school_id, platform_tenant_id);
create index teaching_assignments_staff_idx               on public.teaching_assignments (staff_id, platform_tenant_id);
create index teaching_assignments_section_idx             on public.teaching_assignments (section_id, school_id, academic_year_id, grade_level_id);
create index teaching_assignments_grade_subject_idx       on public.teaching_assignments (academic_year_id, grade_level_id, subject_id);
create index teaching_assignments_staff_active_idx        on public.teaching_assignments (staff_id, academic_year_id) where status = 'active';   -- P5 (3-4)، النصاب (3-5)
create index teaching_assignments_created_by_idx          on public.teaching_assignments (created_by);
create index teaching_assignments_updated_by_idx          on public.teaching_assignments (updated_by);

-- ------------------------------------------------------------------
-- class_teacher_assignments
-- ------------------------------------------------------------------
create table public.class_teacher_assignments (
  id                 uuid        not null default gen_random_uuid(),
  platform_tenant_id uuid        not null,
  school_id          uuid        not null,
  academic_year_id   uuid        not null,
  grade_level_id     uuid        not null,
  section_id         uuid        not null,
  staff_id           uuid        not null,
  status             text        not null default 'active',
  effective_from     date        not null,
  effective_to       date,
  created_at         timestamptz not null default now(),
  created_by         uuid,
  updated_at         timestamptz not null default now(),
  updated_by         uuid,
  constraint class_teacher_assignments_pkey          primary key (id),
  constraint class_teacher_assignments_school_fk     foreign key (school_id, platform_tenant_id) references public.schools (id, platform_tenant_id),
  constraint class_teacher_assignments_staff_fk      foreign key (staff_id, platform_tenant_id)  references public.staff (id, platform_tenant_id),
  constraint class_teacher_assignments_section_fk    foreign key (section_id, school_id, academic_year_id, grade_level_id)
                                                       references public.sections (id, school_id, academic_year_id, grade_level_id),
  constraint class_teacher_assignments_status_chk    check (status in ('active', 'ended')),
  constraint class_teacher_assignments_active_chk    check ((status = 'active') = (effective_to is null)),
  constraint class_teacher_assignments_dates_chk     check (effective_to is null or effective_to >= effective_from),
  constraint class_teacher_assignments_created_by_fk foreign key (created_by) references public.profiles (id),
  constraint class_teacher_assignments_updated_by_fk foreign key (updated_by) references public.profiles (id)
);
create unique index class_teacher_assignments_active_uq   on public.class_teacher_assignments (section_id) where status = 'active';   -- P7، T3
create index class_teacher_assignments_school_idx         on public.class_teacher_assignments (school_id, platform_tenant_id);
create index class_teacher_assignments_staff_idx          on public.class_teacher_assignments (staff_id, platform_tenant_id);
create index class_teacher_assignments_section_idx        on public.class_teacher_assignments (section_id, school_id, academic_year_id, grade_level_id);
create index class_teacher_assignments_staff_active_idx   on public.class_teacher_assignments (staff_id, academic_year_id) where status = 'active';
create index class_teacher_assignments_created_by_idx     on public.class_teacher_assignments (created_by);
create index class_teacher_assignments_updated_by_idx     on public.class_teacher_assignments (updated_by);

-- ------------------------------------------------------------------
-- T6 ختم، T7 تدقيق، RLS مفعّل ومفروض من الإنشاء
-- ------------------------------------------------------------------
create trigger stamp before insert or update on public.teaching_assignments      for each row execute function app.tg_stamp();
create trigger stamp before insert or update on public.class_teacher_assignments for each row execute function app.tg_stamp();
create trigger audit after insert or update or delete on public.teaching_assignments      for each row execute function app.tg_audit();
create trigger audit after insert or update or delete on public.class_teacher_assignments for each row execute function app.tg_audit();

alter table public.teaching_assignments      enable row level security;
alter table public.teaching_assignments      force  row level security;
alter table public.class_teacher_assignments enable row level security;
alter table public.class_teacher_assignments force  row level security;

-- ------------------------------------------------------------------
-- السياسات — School-level، TO authenticated؛ لا UPDATE ولا DELETE (T4)
-- ------------------------------------------------------------------
create policy teaching_assignments_select on public.teaching_assignments
  for select to authenticated
  using (app.can_access_school(school_id) and app.has_permission('staff.read'));
create policy teaching_assignments_insert on public.teaching_assignments
  for insert to authenticated
  with check (app.can_access_school(school_id) and app.has_permission('staff.assign'));

create policy class_teacher_assignments_select on public.class_teacher_assignments
  for select to authenticated
  using (app.can_access_school(school_id) and app.has_permission('staff.read'));
create policy class_teacher_assignments_insert on public.class_teacher_assignments
  for insert to authenticated
  with check (app.can_access_school(school_id) and app.has_permission('staff.assign'));

-- ------------------------------------------------------------------
-- الامتيازات — منح صريح فقط (M20)؛ status و effective_to خارج المنح (الإنهاء بالدالة — نمط M17b)
-- ------------------------------------------------------------------
grant insert (platform_tenant_id, school_id, academic_year_id, grade_level_id, section_id, subject_id, staff_id, effective_from)
  on public.teaching_assignments to authenticated;
grant insert (platform_tenant_id, school_id, academic_year_id, grade_level_id, section_id, staff_id, effective_from)
  on public.class_teacher_assignments to authenticated;

-- ما تقرؤه وتكتبه الدوال والحراس — لمالكها
grant select, update (status, effective_to) on public.teaching_assignments, public.class_teacher_assignments to app_owner;

set local role app_owner;

-- ------------------------------------------------------------------
-- T17 — حارس الجدولين (دالة واحدة؛ subject_id يُقرأ من الصف إن وُجد)
-- ------------------------------------------------------------------
create function app.tg_teaching_assignment_guard()
returns trigger
language plpgsql
security definer
set search_path = app, public, pg_temp
as $$
declare
  v_new jsonb := to_jsonb(new);
  v_old jsonb := case when tg_op = 'UPDATE' then to_jsonb(old) end;
  v_subject uuid := (v_new ->> 'subject_id')::uuid;        -- NULL في class_teacher_assignments
  v_status text;
begin
  if tg_op = 'UPDATE' then
    if old.status = 'ended' then
      raise exception 'invariant: an ended assignment is final' using errcode = '23514';
    end if;
    if (v_new - array['status', 'effective_to', 'updated_at', 'updated_by'])
       is distinct from (v_old - array['status', 'effective_to', 'updated_at', 'updated_by']) then
      raise exception 'invariant: an assignment cannot change its school, year, section, subject, staff or start date' using errcode = '23514';
    end if;
    if new.status <> 'ended' then
      raise exception 'invariant: the only transition is active -> ended' using errcode = '23514';
    end if;
  end if;

  -- السنة: المغلقة مجمدة؛ النشطة بسبب (C3) — على كل مسار
  perform 1 from public.academic_years y where y.id = new.academic_year_id for share;
  perform app.require_year_setup_writable(new.academic_year_id, 'assignments');

  if tg_op = 'INSERT' then
    if new.status <> 'active' then
      raise exception 'invariant: an assignment is created active' using errcode = '23514';
    end if;
    select s.status into v_status from public.sections s where s.id = new.section_id;
    if v_status <> 'active' then
      raise exception 'invariant: the section is not active' using errcode = '23514';
    end if;
    if v_subject is not null then
      select sb.status into v_status from public.subjects sb where sb.id = v_subject;
      if v_status <> 'active' then
        raise exception 'invariant: the subject is not active' using errcode = '23514';
      end if;
      select gs.status into v_status from public.grade_subjects gs
       where gs.academic_year_id = new.academic_year_id and gs.grade_level_id = new.grade_level_id and gs.subject_id = v_subject;
      if v_status <> 'active' then
        raise exception 'invariant: the subject is not active for this grade level in this year' using errcode = '23514';
      end if;
    end if;
    select st.status into v_status from public.staff st where st.id = new.staff_id;
    if v_status <> 'active' then
      raise exception 'invariant: the staff member is not active' using errcode = '23514';
    end if;
    if not exists (select 1 from public.staff_school_assignments a
                    where a.staff_id = new.staff_id and a.school_id = new.school_id and a.status = 'active') then
      raise exception 'invariant: the staff member has no active assignment in this school' using errcode = '23514';
    end if;
  end if;
  return new;
end;
$$;

-- ------------------------------------------------------------------
-- الإنهاء — العقد السباعي (staff.assign + نطاق المدرسة + سبب)
-- ------------------------------------------------------------------
create function app.end_teaching_assignment(p_assignment_id uuid, p_effective_to date, p_reason text)
returns void
language plpgsql security definer set search_path = app, public, pg_temp
as $$
declare v_status text; v_from date;
begin
  if not app.has_permission('staff.assign') then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  perform app.require_reason(p_reason);
  select t.status, t.effective_from into v_status, v_from from public.teaching_assignments t
   where t.id = p_assignment_id and app.can_access_school(t.school_id) for update;
  if not found then raise exception 'not found' using errcode = 'P0002'; end if;
  if v_status <> 'active' then
    raise exception 'invalid transition % -> ended', v_status using errcode = '22023';
  end if;
  if p_effective_to is null or p_effective_to < v_from then
    raise exception 'effective_to must not precede effective_from' using errcode = '22023';
  end if;
  perform app.set_audit_context('end', p_reason);
  update public.teaching_assignments set status = 'ended', effective_to = p_effective_to where id = p_assignment_id;
  perform app.set_audit_context(null, null);
end;
$$;

create function app.end_class_teacher_assignment(p_assignment_id uuid, p_effective_to date, p_reason text)
returns void
language plpgsql security definer set search_path = app, public, pg_temp
as $$
declare v_status text; v_from date;
begin
  if not app.has_permission('staff.assign') then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  perform app.require_reason(p_reason);
  select t.status, t.effective_from into v_status, v_from from public.class_teacher_assignments t
   where t.id = p_assignment_id and app.can_access_school(t.school_id) for update;
  if not found then raise exception 'not found' using errcode = 'P0002'; end if;
  if v_status <> 'active' then
    raise exception 'invalid transition % -> ended', v_status using errcode = '22023';
  end if;
  if p_effective_to is null or p_effective_to < v_from then
    raise exception 'effective_to must not precede effective_from' using errcode = '22023';
  end if;
  perform app.set_audit_context('end', p_reason);
  update public.class_teacher_assignments set status = 'ended', effective_to = p_effective_to where id = p_assignment_id;
  perform app.set_audit_context(null, null);
end;
$$;

reset role;

create trigger guard before insert or update on public.teaching_assignments
  for each row execute function app.tg_teaching_assignment_guard();
create trigger guard before insert or update on public.class_teacher_assignments
  for each row execute function app.tg_teaching_assignment_guard();

-- EXECUTE — controlled allowlist (M20)
revoke all on function app.end_teaching_assignment(uuid, date, text), app.end_class_teacher_assignment(uuid, date, text),
                       app.tg_teaching_assignment_guard() from public;
grant execute on function app.end_teaching_assignment(uuid, date, text), app.end_class_teacher_assignment(uuid, date, text) to authenticated;
