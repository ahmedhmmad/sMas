-- M43 — bell_schedules (Phase 2B / 2B-3 — B11، B12؛ القرارات D1–D7)
-- المرجع: docs/PHASE2B_3_BELL_SCHEDULES.md؛ docs/DATA_DICTIONARY_v1.md §2.32–§2.34.
--
-- bell_schedules              [S عبر السنة] فترة دوام (صباحية/مسائية…) في سنة.
-- bell_periods                [S عبر السنة] حصة (lesson) أو استراحة (break) في يوم أسبوع داخل جدول (D1).
--                                            id معرّف ثابت للفتحة — **ليس رقم الحصة الظاهر**: الترتيب والرقم مشتقان من
--                                            start_time للحصص النشطة من نوع lesson (D5). لا عمود تسلسل.
-- grade_level_bell_schedules  [S عبر السنة] الصف ← جدول واحد في السنة (D2)؛ الشعب ترث صفها.
--
-- منع التداخل (D6) قيد DB على كل مسار: EXCLUDE داخل (الجدول، اليوم) على مدى [) — 09:00–10:00 مع 09:30–10:30 يفشل،
-- و09:00–10:00 مع 10:00–11:00 مسموح؛ جدولان مختلفان قد يتداخلان.
-- T15 (نمط T12–T14): حالة السنة (D3 — planned حرة، active بسبب في سياق التدقيق، closed مجمدة)؛ الهوية؛ الحصة النشطة تحت
-- جدول نشط وعلى يوم دوام نشط (D4)؛ لا تعطيل لجدول له حصص نشطة أو إسناد.
-- D4 الجهة الثانية: استبدال tg_calendar_weekday_guard (M41 تبقى في التاريخ) — لا تعطيل يوم دوام له حصص نشطة، على كل مسار
-- ومنه set_calendar_weekdays.
-- app.copy_bell_day: نسخ يوم إلى أيام داخل الجدول — عملية واحدة؛ الأيام الهدف بلا حصص نشطة وإلا رفض (لا دمج صامت).
-- الصلاحية B12: academic_year.read / academic_year.update. لا مفتاح جديد. لا جدول دراسي ولا حضور بالحصة.

-- ------------------------------------------------------------------
-- bell_schedules
-- ------------------------------------------------------------------
create table public.bell_schedules (
  id               uuid        not null default gen_random_uuid(),
  school_id        uuid        not null,
  academic_year_id uuid        not null,
  name             text        not null,
  status           text        not null default 'active',
  created_at       timestamptz not null default now(),
  created_by       uuid,
  updated_at       timestamptz not null default now(),
  updated_by       uuid,
  constraint bell_schedules_pkey          primary key (id),
  constraint bell_schedules_ref_uq        unique (id, school_id, academic_year_id),
  constraint bell_schedules_name_uq       unique (academic_year_id, name),
  constraint bell_schedules_year_fk       foreign key (academic_year_id, school_id) references public.academic_years (id, school_id),
  constraint bell_schedules_name_chk      check (length(btrim(name)) > 0),
  constraint bell_schedules_status_chk    check (status in ('active', 'inactive')),
  constraint bell_schedules_created_by_fk foreign key (created_by) references public.profiles (id),
  constraint bell_schedules_updated_by_fk foreign key (updated_by) references public.profiles (id)
);
create index bell_schedules_year_idx       on public.bell_schedules (academic_year_id, school_id);
create index bell_schedules_created_by_idx on public.bell_schedules (created_by);
create index bell_schedules_updated_by_idx on public.bell_schedules (updated_by);

-- ------------------------------------------------------------------
-- bell_periods
-- ------------------------------------------------------------------
create table public.bell_periods (
  id               uuid        not null default gen_random_uuid(),
  school_id        uuid        not null,
  academic_year_id uuid        not null,
  bell_schedule_id uuid        not null,
  weekday          smallint    not null,
  kind             text        not null,
  name             text,
  start_time       time        not null,
  end_time         time        not null,
  status           text        not null default 'active',
  created_at       timestamptz not null default now(),
  created_by       uuid,
  updated_at       timestamptz not null default now(),
  updated_by       uuid,
  constraint bell_periods_pkey          primary key (id),
  constraint bell_periods_schedule_fk   foreign key (bell_schedule_id, school_id, academic_year_id)
                                          references public.bell_schedules (id, school_id, academic_year_id),
  constraint bell_periods_weekday_chk   check (weekday between 0 and 6),
  constraint bell_periods_kind_chk      check (kind in ('lesson', 'break')),
  constraint bell_periods_name_chk      check ((name is null or length(btrim(name)) > 0) and (kind <> 'break' or name is not null)),
  constraint bell_periods_times_chk     check (start_time < end_time),   -- لا عبور لمنتصف الليل
  constraint bell_periods_status_chk    check (status in ('active', 'inactive')),
  constraint bell_periods_no_overlap    exclude using gist (                -- D6
                                          bell_schedule_id with =,
                                          weekday with =,
                                          tsrange(date '2000-01-01' + start_time, date '2000-01-01' + end_time, '[)') with &&)
                                          where (status = 'active'),
  constraint bell_periods_created_by_fk foreign key (created_by) references public.profiles (id),
  constraint bell_periods_updated_by_fk foreign key (updated_by) references public.profiles (id)
);
create index bell_periods_schedule_idx   on public.bell_periods (bell_schedule_id, school_id, academic_year_id);
create index bell_periods_year_day_idx   on public.bell_periods (academic_year_id, weekday) where status = 'active';
create index bell_periods_created_by_idx on public.bell_periods (created_by);
create index bell_periods_updated_by_idx on public.bell_periods (updated_by);

-- ------------------------------------------------------------------
-- grade_level_bell_schedules
-- ------------------------------------------------------------------
create table public.grade_level_bell_schedules (
  id               uuid        not null default gen_random_uuid(),
  school_id        uuid        not null,
  academic_year_id uuid        not null,
  grade_level_id   uuid        not null,
  bell_schedule_id uuid        not null,
  created_at       timestamptz not null default now(),
  created_by       uuid,
  updated_at       timestamptz not null default now(),
  updated_by       uuid,
  constraint grade_level_bell_schedules_pkey           primary key (id),
  constraint grade_level_bell_schedules_key_uq         unique (academic_year_id, grade_level_id),
  constraint grade_level_bell_schedules_grade_level_fk foreign key (grade_level_id, school_id) references public.grade_levels (id, school_id),
  constraint grade_level_bell_schedules_schedule_fk    foreign key (bell_schedule_id, school_id, academic_year_id)
                                                         references public.bell_schedules (id, school_id, academic_year_id),
  constraint grade_level_bell_schedules_created_by_fk  foreign key (created_by) references public.profiles (id),
  constraint grade_level_bell_schedules_updated_by_fk  foreign key (updated_by) references public.profiles (id)
);
create index grade_level_bell_schedules_grade_level_idx on public.grade_level_bell_schedules (grade_level_id, school_id);
create index grade_level_bell_schedules_schedule_idx    on public.grade_level_bell_schedules (bell_schedule_id, school_id, academic_year_id);
create index grade_level_bell_schedules_created_by_idx  on public.grade_level_bell_schedules (created_by);
create index grade_level_bell_schedules_updated_by_idx  on public.grade_level_bell_schedules (updated_by);

-- ------------------------------------------------------------------
-- T6 ختم، T7 تدقيق، RLS مفعّل ومفروض من الإنشاء
-- ------------------------------------------------------------------
create trigger stamp before insert or update on public.bell_schedules             for each row execute function app.tg_stamp();
create trigger stamp before insert or update on public.bell_periods               for each row execute function app.tg_stamp();
create trigger stamp before insert or update on public.grade_level_bell_schedules for each row execute function app.tg_stamp();
create trigger audit after insert or update or delete on public.bell_schedules             for each row execute function app.tg_audit();
create trigger audit after insert or update or delete on public.bell_periods               for each row execute function app.tg_audit();
create trigger audit after insert or update or delete on public.grade_level_bell_schedules for each row execute function app.tg_audit();

alter table public.bell_schedules             enable row level security;
alter table public.bell_schedules             force  row level security;
alter table public.bell_periods               enable row level security;
alter table public.bell_periods               force  row level security;
alter table public.grade_level_bell_schedules enable row level security;
alter table public.grade_level_bell_schedules force  row level security;

-- ------------------------------------------------------------------
-- السياسات — School-level، TO authenticated، لا DELETE (B12)
-- ------------------------------------------------------------------
create policy bell_schedules_select on public.bell_schedules for select to authenticated
  using (app.can_access_school(school_id) and app.has_permission('academic_year.read'));
create policy bell_schedules_insert on public.bell_schedules for insert to authenticated
  with check (app.can_access_school(school_id) and app.has_permission('academic_year.update'));
create policy bell_schedules_update on public.bell_schedules for update to authenticated
  using      (app.can_access_school(school_id) and app.has_permission('academic_year.update'))
  with check (app.can_access_school(school_id) and app.has_permission('academic_year.update'));

create policy bell_periods_select on public.bell_periods for select to authenticated
  using (app.can_access_school(school_id) and app.has_permission('academic_year.read'));
create policy bell_periods_insert on public.bell_periods for insert to authenticated
  with check (app.can_access_school(school_id) and app.has_permission('academic_year.update'));
create policy bell_periods_update on public.bell_periods for update to authenticated
  using      (app.can_access_school(school_id) and app.has_permission('academic_year.update'))
  with check (app.can_access_school(school_id) and app.has_permission('academic_year.update'));

create policy grade_level_bell_schedules_select on public.grade_level_bell_schedules for select to authenticated
  using (app.can_access_school(school_id) and app.has_permission('academic_year.read'));
create policy grade_level_bell_schedules_insert on public.grade_level_bell_schedules for insert to authenticated
  with check (app.can_access_school(school_id) and app.has_permission('academic_year.update'));
create policy grade_level_bell_schedules_update on public.grade_level_bell_schedules for update to authenticated
  using      (app.can_access_school(school_id) and app.has_permission('academic_year.update'))
  with check (app.can_access_school(school_id) and app.has_permission('academic_year.update'));

-- ------------------------------------------------------------------
-- الامتيازات — منح صريح فقط (secure-by-default، M20)؛ الهوية خارج UPDATE
-- ------------------------------------------------------------------
grant select on public.bell_schedules, public.bell_periods, public.grade_level_bell_schedules to authenticated;
grant insert (school_id, academic_year_id, name) on public.bell_schedules to authenticated;
grant update (name, status)                      on public.bell_schedules to authenticated;
grant insert (school_id, academic_year_id, bell_schedule_id, weekday, kind, name, start_time, end_time) on public.bell_periods to authenticated;
grant update (weekday, kind, name, start_time, end_time, status)                                       on public.bell_periods to authenticated;
grant insert (school_id, academic_year_id, grade_level_id, bell_schedule_id) on public.grade_level_bell_schedules to authenticated;
grant update (bell_schedule_id)                                              on public.grade_level_bell_schedules to authenticated;

-- ما تقرؤه الحراس وتكتبه copy_bell_day — لمالكها (FOR SHARE يشترط UPDATE على عمود)
grant select, update (status) on public.bell_schedules to app_owner;
grant select, insert          on public.bell_periods to app_owner;
grant select                  on public.grade_level_bell_schedules to app_owner;

set local role app_owner;

-- حالة السنة لإعداداتها (D3، نمط C3): planned حرة · active بسبب في سياق التدقيق · closed مجمدة. أداة داخلية بلا EXECUTE لأحد.
create function app.require_year_setup_writable(p_year_id uuid, p_what text)
returns void
language plpgsql
stable
set search_path = app, public, pg_temp
as $$
declare v_status text;
begin
  select y.status into v_status from public.academic_years y where y.id = p_year_id;
  if v_status = 'closed' then
    raise exception 'invariant: the academic year is closed — its % cannot be modified', p_what using errcode = '23514';
  end if;
  if v_status = 'active' and nullif(btrim(coalesce(current_setting('app.audit_reason', true), '')), '') is null then
    raise exception 'reason required' using errcode = '22023';
  end if;
end;
$$;

-- T15 — bell_schedules
create function app.tg_bell_schedule_guard()
returns trigger
language plpgsql
security definer
set search_path = app, public, pg_temp
as $$
begin
  if tg_op = 'UPDATE' and (new.school_id is distinct from old.school_id or new.academic_year_id is distinct from old.academic_year_id) then
    raise exception 'invariant: a bell schedule cannot move to another school or year' using errcode = '23514';
  end if;
  perform app.require_year_setup_writable(new.academic_year_id, 'bell schedules');
  if tg_op = 'UPDATE' and old.status = 'active' and new.status <> 'active' then
    if exists (select 1 from public.bell_periods p where p.bell_schedule_id = old.id and p.status = 'active') then
      raise exception 'invariant: the bell schedule has active periods' using errcode = '23514';
    end if;
    if exists (select 1 from public.grade_level_bell_schedules g where g.bell_schedule_id = old.id) then
      raise exception 'invariant: the bell schedule is assigned to a grade level' using errcode = '23514';
    end if;
  end if;
  return new;
end;
$$;

-- T15 — bell_periods
create function app.tg_bell_period_guard()
returns trigger
language plpgsql
security definer
set search_path = app, public, pg_temp
as $$
declare v_schedule_status text;
begin
  if tg_op = 'UPDATE'
     and (new.school_id is distinct from old.school_id or new.academic_year_id is distinct from old.academic_year_id
          or new.bell_schedule_id is distinct from old.bell_schedule_id) then
    raise exception 'invariant: a bell period cannot move to another school, year or schedule' using errcode = '23514';
  end if;
  perform app.require_year_setup_writable(new.academic_year_id, 'bell periods');
  if new.status = 'active' and (tg_op = 'INSERT' or old.status <> 'active' or new.weekday is distinct from old.weekday) then
    select s.status into v_schedule_status from public.bell_schedules s where s.id = new.bell_schedule_id for share;
    if v_schedule_status <> 'active' then
      raise exception 'invariant: a bell period can be active only under an active bell schedule' using errcode = '23514';
    end if;
    if not exists (select 1 from public.calendar_weekdays w
                    where w.academic_year_id = new.academic_year_id and w.weekday = new.weekday and w.status = 'active') then
      raise exception 'invariant: a bell period can be active only on an active school weekday of its year' using errcode = '23514';   -- D4
    end if;
  end if;
  return new;
end;
$$;

-- T15 — grade_level_bell_schedules
create function app.tg_grade_level_bell_schedule_guard()
returns trigger
language plpgsql
security definer
set search_path = app, public, pg_temp
as $$
declare v_schedule_status text;
begin
  if tg_op = 'UPDATE'
     and (new.school_id is distinct from old.school_id or new.academic_year_id is distinct from old.academic_year_id
          or new.grade_level_id is distinct from old.grade_level_id) then
    raise exception 'invariant: a grade level bell schedule assignment cannot move to another school, year or grade level' using errcode = '23514';
  end if;
  perform app.require_year_setup_writable(new.academic_year_id, 'bell schedule assignments');
  if tg_op = 'INSERT' or new.bell_schedule_id is distinct from old.bell_schedule_id then
    select s.status into v_schedule_status from public.bell_schedules s where s.id = new.bell_schedule_id for share;
    if v_schedule_status <> 'active' then
      raise exception 'invariant: a grade level can be assigned only to an active bell schedule' using errcode = '23514';
    end if;
  end if;
  if tg_op = 'INSERT' and (select g.status from public.grade_levels g where g.id = new.grade_level_id) <> 'active' then
    raise exception 'invariant: only an active grade level can be assigned a bell schedule' using errcode = '23514';
  end if;
  return new;
end;
$$;

-- T14 (M41) + D4 الجهة الثانية: نص M41 نفسه وشرط واحد — لا تعطيل يوم دوام له حصص نشطة (على كل مسار، ومنه set_calendar_weekdays)
create or replace function app.tg_calendar_weekday_guard()
returns trigger
language plpgsql
security definer
set search_path = app, public, pg_temp
as $$
begin
  if tg_op = 'UPDATE'
     and (new.school_id is distinct from old.school_id or new.academic_year_id is distinct from old.academic_year_id
          or new.weekday is distinct from old.weekday) then
    raise exception 'invariant: a calendar weekday cannot change its school, year or weekday' using errcode = '23514';
  end if;
  if (select y.status from public.academic_years y where y.id = new.academic_year_id) = 'closed' then
    raise exception 'invariant: the academic year is closed — its calendar cannot be modified' using errcode = '23514';
  end if;
  if tg_op = 'UPDATE' and old.status = 'active' and new.status <> 'active'
     and exists (select 1 from public.bell_periods p
                  where p.academic_year_id = old.academic_year_id and p.weekday = old.weekday and p.status = 'active') then
    raise exception 'invariant: the school weekday has active bell periods' using errcode = '23514';   -- D4
  end if;
  return new;
end;
$$;

-- نسخ يوم إلى أيام داخل الجدول — عملية واحدة؛ لا دمج صامت
create function app.copy_bell_day(p_schedule_id uuid, p_from_weekday smallint, p_to_weekdays smallint[], p_reason text)
returns integer
language plpgsql security definer set search_path = app, public, pg_temp
as $$
declare
  v_sched public.bell_schedules%rowtype;
  v_to smallint[]; v_busy text; v_created integer; v_tenant uuid; v_source text;
begin
  if not app.has_permission('academic_year.update') then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  perform app.require_reason(p_reason);
  if p_from_weekday is null or p_from_weekday not between 0 and 6 or p_to_weekdays is null or cardinality(p_to_weekdays) = 0
     or exists (select 1 from unnest(p_to_weekdays) d where d is null or d not between 0 and 6 or d = p_from_weekday) then
    raise exception 'invalid: copy from one weekday to a non-empty set of other weekdays (0..6)' using errcode = '22023';
  end if;
  v_to := array(select distinct d from unnest(p_to_weekdays) d order by d);

  select s.* into v_sched from public.bell_schedules s
   where s.id = p_schedule_id and app.can_access_school(s.school_id) for update;
  if not found then raise exception 'not found' using errcode = 'P0002'; end if;

  if not exists (select 1 from public.bell_periods p where p.bell_schedule_id = v_sched.id and p.weekday = p_from_weekday and p.status = 'active') then
    raise exception 'invalid: the source weekday has no active periods' using errcode = '22023';
  end if;
  select string_agg(distinct p.weekday::text, ', ') into v_busy
    from public.bell_periods p where p.bell_schedule_id = v_sched.id and p.weekday = any (v_to) and p.status = 'active';
  if v_busy is not null then
    raise exception 'invariant: the target weekdays already have active periods: %', v_busy using errcode = '23514';
  end if;

  perform app.set_audit_context('copy_bell_day', p_reason);
  insert into public.bell_periods (school_id, academic_year_id, bell_schedule_id, weekday, kind, name, start_time, end_time)
  select p.school_id, p.academic_year_id, p.bell_schedule_id, d, p.kind, p.name, p.start_time, p.end_time
    from public.bell_periods p cross join unnest(v_to) d
   where p.bell_schedule_id = v_sched.id and p.weekday = p_from_weekday and p.status = 'active';
  get diagnostics v_created = row_count;

  select sc.platform_tenant_id into v_tenant from public.schools sc where sc.id = v_sched.school_id;
  v_source := coalesce(nullif(current_setting('app.request_source', true), ''), 'api');
  if v_source not in ('web', 'mobile', 'api', 'system') then v_source := 'api'; end if;
  insert into public.audit_log (platform_tenant_id, school_id, actor_type, actor_id, action, entity_type, entity_id, new_values, reason, source)
  values (v_tenant, v_sched.school_id, 'tenant_user', app.current_profile_id(), 'copy_bell_day', 'bell_schedules', v_sched.id::text,
          jsonb_build_object('from_weekday', p_from_weekday, 'to_weekdays', to_jsonb(v_to), 'created', v_created), p_reason, v_source);
  perform app.set_audit_context(null, null);
  return v_created;
end;
$$;

reset role;

create trigger guard before insert or update on public.bell_schedules
  for each row execute function app.tg_bell_schedule_guard();
create trigger guard before insert or update on public.bell_periods
  for each row execute function app.tg_bell_period_guard();
create trigger guard before insert or update on public.grade_level_bell_schedules
  for each row execute function app.tg_grade_level_bell_schedule_guard();

grant execute on function app.copy_bell_day(uuid, smallint, smallint[], text) to authenticated;
