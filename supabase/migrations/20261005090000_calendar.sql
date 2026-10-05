-- M41 — calendar (Phase 2B / 2B-2 — B7، B8، B12؛ القرارات C1–C5)
-- المرجع: docs/PHASE2B_2_CALENDAR.md؛ docs/DATA_DICTIONARY_v1.md §2.30، §2.31.
--
-- calendar_weekdays   [S عبر السنة] أيام الدوام الأسبوعية (0 = الأحد … 6 = السبت). لا كتابة للعميل:
--                                   app.set_calendar_weekdays وحدها (والنسخ في M42).
-- calendar_exceptions [S عبر السنة] عطلة (يوم/فترة) أو يوم دراسي استثنائي (يوم واحد — C5). CRUD + RLS + T14.
--
-- «اليوم» (C1) = app.school_today(school): التاريخ الحالي بتوقيت schools.timezone لحظة المعاملة — لا توقيت الخادم
-- ولا المتصفح. السبب (C3) invariant في DB: كل كتابة على تقويم سنة active تشترط app.audit_reason في المعاملة نفسها
-- (الـAPI يضعه من الجسم)؛ على كل مسار، ومنه الكتابة المباشرة عبر PostgREST.
-- app.is_school_day(school, date): العقد الوحيد لـ«هل اليوم دراسي؟» — تستهلكه المرحلة 5؛ بلا EXECUTE لأدوار الـAPI.
-- الصلاحية B12: academic_year.read / academic_year.update. لا مفتاح جديد. لا منطق حضور.

-- ------------------------------------------------------------------
-- calendar_weekdays
-- ------------------------------------------------------------------
create table public.calendar_weekdays (
  id               uuid        not null default gen_random_uuid(),
  school_id        uuid        not null,
  academic_year_id uuid        not null,
  weekday          smallint    not null,
  status           text        not null default 'active',
  created_at       timestamptz not null default now(),
  created_by       uuid,
  updated_at       timestamptz not null default now(),
  updated_by       uuid,
  constraint calendar_weekdays_pkey          primary key (id),
  constraint calendar_weekdays_key_uq        unique (academic_year_id, weekday),
  constraint calendar_weekdays_year_fk       foreign key (academic_year_id, school_id) references public.academic_years (id, school_id),
  constraint calendar_weekdays_weekday_chk   check (weekday between 0 and 6),
  constraint calendar_weekdays_status_chk    check (status in ('active', 'inactive')),
  constraint calendar_weekdays_created_by_fk foreign key (created_by) references public.profiles (id),
  constraint calendar_weekdays_updated_by_fk foreign key (updated_by) references public.profiles (id)
);
create index calendar_weekdays_year_idx       on public.calendar_weekdays (academic_year_id, school_id);
create index calendar_weekdays_created_by_idx on public.calendar_weekdays (created_by);
create index calendar_weekdays_updated_by_idx on public.calendar_weekdays (updated_by);

-- ------------------------------------------------------------------
-- calendar_exceptions
-- ------------------------------------------------------------------
create table public.calendar_exceptions (
  id               uuid        not null default gen_random_uuid(),
  school_id        uuid        not null,
  academic_year_id uuid        not null,
  year_start_date  date        not null,
  year_end_date    date        not null,
  kind             text        not null,
  name             text        not null,
  start_date       date        not null,
  end_date         date        not null,
  status           text        not null default 'active',
  created_at       timestamptz not null default now(),
  created_by       uuid,
  updated_at       timestamptz not null default now(),
  updated_by       uuid,
  constraint calendar_exceptions_pkey            primary key (id),
  constraint calendar_exceptions_year_fk         foreign key (academic_year_id, school_id, year_start_date, year_end_date)
                                                   references public.academic_years (id, school_id, start_date, end_date)
                                                   on update cascade,
  constraint calendar_exceptions_kind_chk        check (kind in ('holiday', 'study_day')),
  constraint calendar_exceptions_name_chk        check (length(btrim(name)) > 0),
  constraint calendar_exceptions_dates_chk       check (start_date <= end_date),
  constraint calendar_exceptions_within_year_chk check (start_date >= year_start_date and end_date <= year_end_date),
  constraint calendar_exceptions_study_day_chk   check (kind <> 'study_day' or start_date = end_date),   -- C5
  constraint calendar_exceptions_status_chk      check (status in ('active', 'cancelled')),
  constraint calendar_exceptions_no_overlap      exclude using gist (
                                                   academic_year_id with =,
                                                   daterange(start_date, end_date, '[]') with &&)
                                                   where (kind = 'holiday' and status = 'active'),
  constraint calendar_exceptions_created_by_fk   foreign key (created_by) references public.profiles (id),
  constraint calendar_exceptions_updated_by_fk   foreign key (updated_by) references public.profiles (id)
);
create unique index calendar_exceptions_study_day_uq on public.calendar_exceptions (academic_year_id, start_date)
  where kind = 'study_day' and status = 'active';
create index calendar_exceptions_year_fk_idx    on public.calendar_exceptions (academic_year_id, school_id, year_start_date, year_end_date);
create index calendar_exceptions_created_by_idx on public.calendar_exceptions (created_by);
create index calendar_exceptions_updated_by_idx on public.calendar_exceptions (updated_by);

-- ------------------------------------------------------------------
-- T6 ختم، T7 تدقيق، RLS مفعّل ومفروض من الإنشاء
-- ------------------------------------------------------------------
create trigger stamp before insert or update on public.calendar_weekdays   for each row execute function app.tg_stamp();
create trigger stamp before insert or update on public.calendar_exceptions for each row execute function app.tg_stamp();
create trigger audit after insert or update or delete on public.calendar_weekdays   for each row execute function app.tg_audit();
create trigger audit after insert or update or delete on public.calendar_exceptions for each row execute function app.tg_audit();

alter table public.calendar_weekdays   enable row level security;
alter table public.calendar_weekdays   force  row level security;
alter table public.calendar_exceptions enable row level security;
alter table public.calendar_exceptions force  row level security;

-- ------------------------------------------------------------------
-- السياسات — School-level، TO authenticated، لا DELETE؛ أيام الدوام بلا سياسة كتابة (لا منح)
-- ------------------------------------------------------------------
create policy calendar_weekdays_select on public.calendar_weekdays
  for select to authenticated
  using (app.can_access_school(school_id) and app.has_permission('academic_year.read'));

create policy calendar_exceptions_select on public.calendar_exceptions
  for select to authenticated
  using (app.can_access_school(school_id) and app.has_permission('academic_year.read'));
create policy calendar_exceptions_insert on public.calendar_exceptions
  for insert to authenticated
  with check (app.can_access_school(school_id) and app.has_permission('academic_year.update'));
create policy calendar_exceptions_update on public.calendar_exceptions
  for update to authenticated
  using      (app.can_access_school(school_id) and app.has_permission('academic_year.update'))
  with check (app.can_access_school(school_id) and app.has_permission('academic_year.update'));

-- ------------------------------------------------------------------
-- الامتيازات — منح صريح فقط (secure-by-default، M20)
-- ------------------------------------------------------------------
grant select on public.calendar_weekdays to authenticated;
grant select on public.calendar_exceptions to authenticated;
grant insert (school_id, academic_year_id, year_start_date, year_end_date, kind, name, start_date, end_date)
  on public.calendar_exceptions to authenticated;
grant update (name, start_date, end_date, status) on public.calendar_exceptions to authenticated;

-- ما تقرؤه وتكتبه الحراس والدوال — لمالكها
grant select, insert, update (status) on public.calendar_weekdays to app_owner;
grant select                          on public.calendar_exceptions to app_owner;

set local role app_owner;

-- «اليوم» بتوقيت المدرسة (C1) — بلا EXECUTE لأحد غير مالكها
create function app.school_today(p_school_id uuid)
returns date
language sql
stable
set search_path = app, public, pg_temp
as $$
  select (now() at time zone s.timezone)::date from public.schools s where s.id = p_school_id
$$;

-- «هل اليوم دراسي؟» — العقد الوحيد للمرحلة 5؛ SECURITY INVOKER؛ حالة السنة لا تدخل؛ الملغى خارج الحساب
create function app.is_school_day(p_school_id uuid, p_date date)
returns boolean
language sql
stable
set search_path = app, public, pg_temp
as $$
  select coalesce((
    select case
             when exists (select 1 from public.calendar_exceptions e
                           where e.academic_year_id = y.id and e.kind = 'study_day' and e.status = 'active' and e.start_date = p_date)
               then true
             when exists (select 1 from public.calendar_exceptions e
                           where e.academic_year_id = y.id and e.kind = 'holiday' and e.status = 'active'
                             and p_date between e.start_date and e.end_date)
               then false
             else exists (select 1 from public.calendar_weekdays w
                           where w.academic_year_id = y.id and w.status = 'active' and w.weekday = extract(dow from p_date))
           end
      from public.academic_years y
     where y.school_id = p_school_id and p_date between y.start_date and y.end_date), false)
$$;

-- T14 — calendar_exceptions: B8 بقرارات C1–C5 (على كل مسار)
create function app.tg_calendar_exception_guard()
returns trigger
language plpgsql
security definer
set search_path = app, public, pg_temp
as $$
declare
  v_year_status text;
  v_today date;
begin
  if tg_op = 'UPDATE'
     and (new.school_id is distinct from old.school_id or new.academic_year_id is distinct from old.academic_year_id
          or new.kind is distinct from old.kind) then
    raise exception 'invariant: a calendar exception cannot change its school, year or kind' using errcode = '23514';
  end if;

  select y.status into v_year_status from public.academic_years y where y.id = new.academic_year_id;

  -- ترحيل حدود السنة (ON UPDATE CASCADE في سنة planned) ليس تعديلاً للاستثناء
  if tg_op = 'UPDATE'
     and (new.name, new.start_date, new.end_date, new.status) is not distinct from (old.name, old.start_date, old.end_date, old.status)
     and v_year_status = 'planned' then
    return new;
  end if;

  if v_year_status = 'closed' then
    raise exception 'invariant: the academic year is closed — its calendar cannot be modified' using errcode = '23514';
  end if;
  if tg_op = 'UPDATE' and old.status = 'cancelled' then
    raise exception 'invariant: a cancelled calendar exception is final' using errcode = '23514';
  end if;

  if v_year_status = 'active' then
    if nullif(btrim(coalesce(current_setting('app.audit_reason', true), '')), '') is null then
      raise exception 'reason required' using errcode = '22023';   -- C3
    end if;
    v_today := app.school_today(new.school_id);                   -- C1
    if tg_op = 'INSERT' then
      if new.start_date < v_today then
        raise exception 'invariant: in an active year a calendar exception can start today or later only' using errcode = '23514';
      end if;
    elsif old.start_date >= v_today then
      if new.start_date < v_today then
        raise exception 'invariant: in an active year a calendar exception can start today or later only' using errcode = '23514';
      end if;
    else
      -- C4: بدأ قبل اليوم — الجزء المستقبلي وحده: end_date، والقديم والجديد ≥ اليوم؛ لا إلغاء
      if (new.name, new.start_date, new.status) is distinct from (old.name, old.start_date, old.status)
         or old.end_date < v_today or new.end_date < v_today then
        raise exception 'invariant: a calendar exception that has started can change only its future end date' using errcode = '23514';
      end if;
    end if;
  end if;

  -- C5: اليوم الدراسي الاستثنائي لا يقع على يوم دراسي عادي (عند إنشائه أو نقل تاريخه)
  if new.kind = 'study_day' and new.status = 'active' and (tg_op = 'INSERT' or new.start_date is distinct from old.start_date)
     and exists (select 1 from public.calendar_weekdays w
                  where w.academic_year_id = new.academic_year_id and w.status = 'active' and w.weekday = extract(dow from new.start_date))
     and not exists (select 1 from public.calendar_exceptions h
                      where h.academic_year_id = new.academic_year_id and h.kind = 'holiday' and h.status = 'active'
                        and new.start_date between h.start_date and h.end_date) then
    raise exception 'invariant: an exceptional study day must fall on a day that is not already a school day' using errcode = '23514';
  end if;
  return new;
end;
$$;

-- T14 — calendar_weekdays: الهوية ثابتة والسنة المغلقة مجمدة على كل مسار (قاعدة السنة النشطة في الدالة — لا منح للعميل)
create function app.tg_calendar_weekday_guard()
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
  return new;
end;
$$;

-- أيام الدوام: عملية مجموعة ذرية (B8، C2)
create function app.set_calendar_weekdays(p_year_id uuid, p_weekdays smallint[], p_reason text)
returns integer
language plpgsql security definer set search_path = app, public, pg_temp
as $$
declare
  v_year public.academic_years%rowtype;
  v_tenant uuid; v_source text; v_set smallint[]; v_changed integer := 0; v_n integer;
begin
  if not app.has_permission('academic_year.update') then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  perform app.require_reason(p_reason);
  if p_weekdays is null or cardinality(p_weekdays) = 0 or exists (select 1 from unnest(p_weekdays) d where d is null or d not between 0 and 6) then
    raise exception 'invalid: weekdays must be a non-empty set of 0..6' using errcode = '22023';
  end if;
  v_set := array(select distinct d from unnest(p_weekdays) d order by d);

  select y.* into v_year from public.academic_years y
   where y.id = p_year_id and app.can_access_school(y.school_id) for update;
  if not found then raise exception 'not found' using errcode = 'P0002'; end if;

  if v_year.status = 'closed' then
    raise exception 'invalid: the academic year is closed — its weekdays cannot be changed' using errcode = '22023';
  end if;
  if v_year.status = 'active'
     and exists (select 1 from public.calendar_weekdays w where w.academic_year_id = v_year.id and w.status = 'active') then
    raise exception 'invalid: the weekdays of an active year are fixed once defined' using errcode = '22023';   -- C2
  end if;

  perform app.set_audit_context('set_calendar_weekdays', p_reason);
  update public.calendar_weekdays w
     set status = case when w.weekday = any (v_set) then 'active' else 'inactive' end
   where w.academic_year_id = v_year.id
     and w.status is distinct from case when w.weekday = any (v_set) then 'active' else 'inactive' end;
  get diagnostics v_changed = row_count;
  insert into public.calendar_weekdays (school_id, academic_year_id, weekday)
  select v_year.school_id, v_year.id, d from unnest(v_set) d
   where not exists (select 1 from public.calendar_weekdays w where w.academic_year_id = v_year.id and w.weekday = d);
  get diagnostics v_n = row_count;
  v_changed := v_changed + v_n;

  select sc.platform_tenant_id into v_tenant from public.schools sc where sc.id = v_year.school_id;
  v_source := coalesce(nullif(current_setting('app.request_source', true), ''), 'api');
  if v_source not in ('web', 'mobile', 'api', 'system') then v_source := 'api'; end if;
  insert into public.audit_log (platform_tenant_id, school_id, actor_type, actor_id, action, entity_type, entity_id, new_values, reason, source)
  values (v_tenant, v_year.school_id, 'tenant_user', app.current_profile_id(), 'set_calendar_weekdays', 'academic_years', v_year.id::text,
          jsonb_build_object('weekdays', to_jsonb(v_set), 'changed', v_changed), p_reason, v_source);
  perform app.set_audit_context(null, null);
  return v_changed;
end;
$$;

reset role;

create trigger guard before insert or update on public.calendar_exceptions
  for each row execute function app.tg_calendar_exception_guard();
create trigger guard before insert or update on public.calendar_weekdays
  for each row execute function app.tg_calendar_weekday_guard();

grant execute on function app.set_calendar_weekdays(uuid, smallint[], text) to authenticated;
