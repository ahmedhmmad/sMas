-- M34 — term_lifecycle (Phase 2A / P2-B، ف5 — القرار 6، Q1، Q2، Q3، Q7أ، 2026-10-02)
-- المرجع: docs/PHASE2_SCHOOL_SETUP.md §1.4، §2، §6.1، §6.2، §7 (T11).
--
-- المشكلة: terms.status عمود يكتبه العميل بـterm.manage بلا قواعد انتقال، ويمكن أن يكون أكثر من فصل active.
--
--   1. فصل active واحد على الأكثر لكل سنة — فهرس فريد جزئي (إعلاني).
--   2. T11 — trigger حارس BEFORE INSERT OR UPDATE يسري على كل مسار:
--        • الفصل يولد planned، في سنة غير مغلقة.
--        • الانتقالات المعلنة فقط: planned → active → closed.
--        • الفصل active داخل سنة active فقط.
--        • planned: كل شيء · active: الاسم فقط · closed: لا شيء · فصول السنة closed مجمدة معها.
--        • academic_year_id و school_id ثابتان.
--      الصلاحية والنطاق ليسا في الحارس: يبقيان في RLS وفي الدوال.
--      نسخ حدود السنة (year_start_date / year_end_date) خارج الحارس: يملكها الـFK (ON UPDATE CASCADE) ولا يكتبها العميل.
--   3. status يخرج من منح العميل؛ الانتقال بدالتين: app.activate_term و app.close_term (term.manage — لا مفتاح جديد).
--   4. app.close_academic_year: يرفض إغلاق سنة فيها فصل active — لا إغلاق ضمني للفصل.

-- ------------------------------------------------------------------
-- البيانات القائمة: fail before mutation + تعداد المخالفات (قاعدة M30b) — لا تصحيح تلقائي
-- ------------------------------------------------------------------
do $$
declare v_bad text;
begin
  select string_agg(format('year %s: %s active terms', x.academic_year_id, x.n), '; ' order by x.academic_year_id)
    into v_bad
    from (select t.academic_year_id, count(*) as n from public.terms t where t.status = 'active'
           group by t.academic_year_id having count(*) > 1) x;
  if v_bad is not null then
    raise exception 'M34: more than one active term per academic year — resolve before migrating: %', v_bad;
  end if;
  select string_agg(format('term %s (%s) in %s year %s', t.id, t.status, y.status, y.id), '; ' order by t.id)
    into v_bad
    from public.terms t join public.academic_years y on y.id = t.academic_year_id
   where t.status = 'active' and y.status <> 'active';
  if v_bad is not null then
    raise exception 'M34: active terms outside an active academic year — resolve before migrating: %', v_bad;
  end if;
end $$;

-- ------------------------------------------------------------------
-- 1. فصل نشط واحد لكل سنة
-- ------------------------------------------------------------------
create unique index terms_active_uq on public.terms (academic_year_id) where status = 'active';

-- ------------------------------------------------------------------
-- 3 (أ). سجل الأعمدة: status خارج INSERT و UPDATE؛ هوية الفصل ونسخ حدود السنة خارج UPDATE
-- ------------------------------------------------------------------
revoke insert (status) on public.terms from authenticated;
revoke update (academic_year_id, school_id, year_start_date, year_end_date, status) on public.terms from authenticated;

-- ما تقرؤه وتكتبه دوال هذه الـmigration — لمالكها (نمط M21)
grant select, update (status) on public.terms to app_owner;

set local role app_owner;

-- ------------------------------------------------------------------
-- 2. T11 — SECURITY DEFINER: يقرأ حالة السنة أياً كان ما تراه RLS للمستدعي، ويقفلها FOR SHARE
--    (تفعيل فصل وإغلاق سنته لا يتسابقان).
-- ------------------------------------------------------------------
create function app.tg_term_guard()
returns trigger
language plpgsql
security definer
set search_path = app, public, pg_temp
as $$
declare v_year_status text;
begin
  select y.status into v_year_status from public.academic_years y where y.id = new.academic_year_id for share;

  if tg_op = 'INSERT' then
    if v_year_status = 'closed' then
      raise exception 'invariant: the academic year is closed — no new terms' using errcode = '23514';
    end if;
    if new.status <> 'planned' then
      raise exception 'invariant: a term is created planned' using errcode = '23514';
    end if;
    return new;
  end if;

  if new.academic_year_id is distinct from old.academic_year_id or new.school_id is distinct from old.school_id then
    raise exception 'invariant: a term cannot move to another year or school' using errcode = '23514';
  end if;
  if v_year_status = 'closed' then
    raise exception 'invariant: the academic year is closed — its terms cannot be modified' using errcode = '23514';
  end if;
  if old.status = 'closed' then
    raise exception 'invariant: term % is closed and cannot be modified', old.id using errcode = '23514';
  end if;
  if new.status is distinct from old.status
     and not ((old.status = 'planned' and new.status = 'active') or (old.status = 'active' and new.status = 'closed')) then
    raise exception 'invariant: term transition % -> % is not allowed', old.status, new.status using errcode = '23514';
  end if;
  if new.status = 'active' and v_year_status <> 'active' then
    raise exception 'invariant: a term can be active only in an active academic year' using errcode = '23514';
  end if;
  if old.status = 'active'
     and (new.sequence_no is distinct from old.sequence_no
          or new.start_date is distinct from old.start_date or new.end_date is distinct from old.end_date) then
    raise exception 'invariant: only the name of an active term can change' using errcode = '23514';
  end if;
  return new;
end;
$$;

-- ------------------------------------------------------------------
-- 3 (ب). انتقالات الفصل — planned → active → closed (term.manage + نطاق المدرسة)
-- ------------------------------------------------------------------
create function app.activate_term(p_term_id uuid, p_reason text)
returns void
language plpgsql security definer set search_path = app, public, pg_temp
as $$
declare v_status text; v_year uuid; v_year_status text;
begin
  if not app.has_permission('term.manage') then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  perform app.require_reason(p_reason);
  select t.status, t.academic_year_id into v_status, v_year from public.terms t
   where t.id = p_term_id and app.can_access_school(t.school_id) for update;
  if not found then raise exception 'not found' using errcode = 'P0002'; end if;
  if v_status <> 'planned' then
    raise exception 'invalid transition % -> active', v_status using errcode = '22023';
  end if;
  select y.status into v_year_status from public.academic_years y where y.id = v_year for share;
  if v_year_status <> 'active' then
    raise exception 'invariant: the academic year is not active' using errcode = '23514';
  end if;
  if exists (select 1 from public.terms t where t.academic_year_id = v_year and t.status = 'active') then
    raise exception 'invariant: the academic year already has an active term' using errcode = '23514';
  end if;
  perform app.set_audit_context('activate', p_reason);
  update public.terms set status = 'active' where id = p_term_id;
  perform app.set_audit_context(null, null);
end;
$$;

create function app.close_term(p_term_id uuid, p_reason text)
returns void
language plpgsql security definer set search_path = app, public, pg_temp
as $$
declare v_status text;
begin
  if not app.has_permission('term.manage') then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  perform app.require_reason(p_reason);
  select t.status into v_status from public.terms t
   where t.id = p_term_id and app.can_access_school(t.school_id) for update;
  if not found then raise exception 'not found' using errcode = 'P0002'; end if;
  if v_status <> 'active' then
    raise exception 'invalid transition % -> closed', v_status using errcode = '22023';
  end if;
  perform app.set_audit_context('close', p_reason);
  update public.terms set status = 'closed' where id = p_term_id;
  perform app.set_audit_context(null, null);
end;
$$;

-- ------------------------------------------------------------------
-- 4. close_academic_year — نص M21 نفسه + شرط الفصل النشط (Q3)
-- ------------------------------------------------------------------
create or replace function app.close_academic_year(p_year_id uuid, p_reason text)
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
  if exists (select 1 from public.terms t where t.academic_year_id = p_year_id and t.status = 'active') then
    raise exception 'invariant: the year has an active term' using errcode = '23514';
  end if;
  perform app.set_audit_context('close', p_reason);
  update public.academic_years set status = 'closed' where id = p_year_id;
  perform app.set_audit_context(null, null);
end;
$$;

reset role;

grant execute on function app.activate_term(uuid, text), app.close_term(uuid, text) to authenticated;

create trigger guard before insert or update on public.terms
  for each row execute function app.tg_term_guard();
