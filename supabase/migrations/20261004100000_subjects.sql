-- M39 — subjects (Phase 2B / 2B-1 — B9، B10، B15؛ نمط M35)
-- المرجع: docs/PHASE2B_SCOPE.md §3؛ docs/DATA_DICTIONARY_v1.md §2.28، §2.29.
--
-- subjects       [S]           كتالوج مواد المدرسة: رمز ثابت فريد في المدرسة، اسم فريد، حالة active/inactive.
-- grade_subjects [S عبر السنة] ربط المادة بالصف **لكل سنة** (ثابت 15): الحصص الأسبوعية، الدخول في المجموع.
--                               حد النجاح ومكوّنات التقييم خارج 2B (المرحلة 6).
--
-- الحراس (T13 — نمط T12، SECURITY DEFINER، على كل مسار):
--   grade_subjects • الهوية (مدرسة، سنة، صف، مادة) ثابتة · لا إنشاء ولا تعديل في سنة closed ·
--                  الربط active تحت صف active ومادة active (عند الإنشاء وإعادة التفعيل)
--   subjects       • المدرسة والرمز ثابتان · لا تعطيل لمادة لها ربط active في سنة غير مغلقة
--   grade_levels   • (استبدال T12) + لا تعطيل لصف له ربط مادة active في سنة غير مغلقة — الـinvariant من الجهتين
-- الصلاحية والنطاق في RLS: can_access_school(school_id) + subject.read / subject.manage. لا DELETE.

-- ------------------------------------------------------------------
-- subjects
-- ------------------------------------------------------------------
create table public.subjects (
  id           uuid        not null default gen_random_uuid(),
  school_id    uuid        not null,
  subject_code text        not null,
  name         text        not null,
  status       text        not null default 'active',
  created_at   timestamptz not null default now(),
  created_by   uuid,
  updated_at   timestamptz not null default now(),
  updated_by   uuid,
  constraint subjects_pkey            primary key (id),
  constraint subjects_id_school_uq    unique (id, school_id),
  constraint subjects_school_code_uq  unique (school_id, subject_code),
  constraint subjects_school_name_uq  unique (school_id, name),
  constraint subjects_school_fk       foreign key (school_id) references public.schools (id),
  constraint subjects_code_chk        check (subject_code ~ '^[A-Z0-9][A-Z0-9_-]{1,31}$'),
  constraint subjects_name_chk        check (length(btrim(name)) > 0),
  constraint subjects_status_chk      check (status in ('active', 'inactive')),
  constraint subjects_created_by_fk   foreign key (created_by) references public.profiles (id),
  constraint subjects_updated_by_fk   foreign key (updated_by) references public.profiles (id)
);
create index subjects_created_by_idx on public.subjects (created_by);
create index subjects_updated_by_idx on public.subjects (updated_by);

-- ------------------------------------------------------------------
-- grade_subjects
-- ------------------------------------------------------------------
create table public.grade_subjects (
  id                  uuid        not null default gen_random_uuid(),
  school_id           uuid        not null,
  academic_year_id    uuid        not null,
  grade_level_id      uuid        not null,
  subject_id          uuid        not null,
  weekly_periods      integer     not null,
  counts_toward_total boolean     not null default true,
  status              text        not null default 'active',
  created_at          timestamptz not null default now(),
  created_by          uuid,
  updated_at          timestamptz not null default now(),
  updated_by          uuid,
  constraint grade_subjects_pkey            primary key (id),
  constraint grade_subjects_key_uq          unique (academic_year_id, grade_level_id, subject_id),   -- المفتاح الطبيعي
  constraint grade_subjects_year_fk         foreign key (academic_year_id, school_id) references public.academic_years (id, school_id),
  constraint grade_subjects_grade_level_fk  foreign key (grade_level_id, school_id)   references public.grade_levels (id, school_id),
  constraint grade_subjects_subject_fk      foreign key (subject_id, school_id)       references public.subjects (id, school_id),
  constraint grade_subjects_periods_chk     check (weekly_periods between 1 and 60),
  constraint grade_subjects_status_chk      check (status in ('active', 'inactive')),
  constraint grade_subjects_created_by_fk   foreign key (created_by) references public.profiles (id),
  constraint grade_subjects_updated_by_fk   foreign key (updated_by) references public.profiles (id)
);
create index grade_subjects_year_idx        on public.grade_subjects (academic_year_id, school_id);
create index grade_subjects_grade_level_idx on public.grade_subjects (grade_level_id, school_id);
create index grade_subjects_subject_idx     on public.grade_subjects (subject_id, school_id);
create index grade_subjects_created_by_idx  on public.grade_subjects (created_by);
create index grade_subjects_updated_by_idx  on public.grade_subjects (updated_by);

-- ------------------------------------------------------------------
-- T6 ختم، T7 تدقيق، RLS مفعّل ومفروض من الإنشاء
-- ------------------------------------------------------------------
create trigger stamp before insert or update on public.subjects       for each row execute function app.tg_stamp();
create trigger stamp before insert or update on public.grade_subjects for each row execute function app.tg_stamp();
create trigger audit after insert or update or delete on public.subjects       for each row execute function app.tg_audit();
create trigger audit after insert or update or delete on public.grade_subjects for each row execute function app.tg_audit();

alter table public.subjects       enable row level security;
alter table public.subjects       force  row level security;
alter table public.grade_subjects enable row level security;
alter table public.grade_subjects force  row level security;

-- ------------------------------------------------------------------
-- السياسات — School-level، TO authenticated، لا DELETE
-- ------------------------------------------------------------------
create policy subjects_select on public.subjects
  for select to authenticated
  using (app.can_access_school(school_id) and app.has_permission('subject.read'));
create policy subjects_insert on public.subjects
  for insert to authenticated
  with check (app.can_access_school(school_id) and app.has_permission('subject.manage'));
create policy subjects_update on public.subjects
  for update to authenticated
  using      (app.can_access_school(school_id) and app.has_permission('subject.manage'))
  with check (app.can_access_school(school_id) and app.has_permission('subject.manage'));

create policy grade_subjects_select on public.grade_subjects
  for select to authenticated
  using (app.can_access_school(school_id) and app.has_permission('subject.read'));
create policy grade_subjects_insert on public.grade_subjects
  for insert to authenticated
  with check (app.can_access_school(school_id) and app.has_permission('subject.manage'));
create policy grade_subjects_update on public.grade_subjects
  for update to authenticated
  using      (app.can_access_school(school_id) and app.has_permission('subject.manage'))
  with check (app.can_access_school(school_id) and app.has_permission('subject.manage'));

-- ------------------------------------------------------------------
-- الامتيازات — منح صريح فقط (secure-by-default، M20)
--   الرمز والمدرسة والهوية خارج UPDATE؛ الربط يولد active (status خارج INSERT)
-- ------------------------------------------------------------------
grant insert (school_id, subject_code, name)                              on public.subjects to authenticated;
grant update (name, status)                                               on public.subjects to authenticated;
grant insert (school_id, academic_year_id, grade_level_id, subject_id, weekly_periods, counts_toward_total) on public.grade_subjects to authenticated;
grant update (weekly_periods, counts_toward_total, status)                on public.grade_subjects to authenticated;

-- ما تقرؤه وتقفله الحراس — لمالكها (FOR SHARE يشترط UPDATE على عمود)
grant select, update (status) on public.subjects       to app_owner;
grant select                  on public.grade_subjects to app_owner;

set local role app_owner;

create function app.tg_subject_guard()
returns trigger
language plpgsql
security definer
set search_path = app, public, pg_temp
as $$
begin
  if new.school_id is distinct from old.school_id or new.subject_code is distinct from old.subject_code then
    raise exception 'invariant: a subject cannot change its school or code' using errcode = '23514';
  end if;
  if old.status = 'active' and new.status <> 'active'
     and exists (select 1 from public.grade_subjects gs join public.academic_years y on y.id = gs.academic_year_id
                  where gs.subject_id = old.id and gs.status = 'active' and y.status <> 'closed') then
    raise exception 'invariant: the subject is taught in a non-closed year' using errcode = '23514';
  end if;
  return new;
end;
$$;

create function app.tg_grade_subject_guard()
returns trigger
language plpgsql
security definer
set search_path = app, public, pg_temp
as $$
declare v_year_status text; v_grade_status text; v_subject_status text;
begin
  if tg_op = 'UPDATE'
     and (new.school_id is distinct from old.school_id or new.academic_year_id is distinct from old.academic_year_id
          or new.grade_level_id is distinct from old.grade_level_id or new.subject_id is distinct from old.subject_id) then
    raise exception 'invariant: a grade subject cannot move to another school, year, grade level or subject' using errcode = '23514';
  end if;

  select y.status into v_year_status from public.academic_years y where y.id = new.academic_year_id for share;
  if v_year_status = 'closed' then
    if tg_op = 'INSERT' then
      raise exception 'invariant: the academic year is closed — no new grade subjects' using errcode = '23514';
    end if;
    raise exception 'invariant: the academic year is closed — its grade subjects cannot be modified' using errcode = '23514';
  end if;

  if new.status = 'active' and (tg_op = 'INSERT' or old.status <> 'active') then
    select g.status into v_grade_status from public.grade_levels g where g.id = new.grade_level_id for share;
    if v_grade_status <> 'active' then
      raise exception 'invariant: a grade subject can be active only under an active grade level' using errcode = '23514';
    end if;
    select s.status into v_subject_status from public.subjects s where s.id = new.subject_id for share;
    if v_subject_status <> 'active' then
      raise exception 'invariant: a grade subject can be active only for an active subject' using errcode = '23514';
    end if;
  end if;
  return new;
end;
$$;

-- T12 (M35) + الجهة الثانية لـ«ربط مادة نشط ⇒ صف نشط»: نص M35 نفسه وشرط واحد
create or replace function app.tg_grade_level_guard()
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
  if tg_op = 'UPDATE' and old.status = 'active' and new.status <> 'active'
     and exists (select 1 from public.grade_subjects gs join public.academic_years y on y.id = gs.academic_year_id
                  where gs.grade_level_id = old.id and gs.status = 'active' and y.status <> 'closed') then
    raise exception 'invariant: the grade level has active subjects' using errcode = '23514';
  end if;
  return new;
end;
$$;

reset role;

create trigger guard before update on public.subjects
  for each row execute function app.tg_subject_guard();
create trigger guard before insert or update on public.grade_subjects
  for each row execute function app.tg_grade_subject_guard();
