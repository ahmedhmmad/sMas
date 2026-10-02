-- M33 — academic_year_guard (Phase 2A / P2-B، ف4 — القرار 5 و Q1، 2026-10-02)
-- المرجع: docs/PHASE2_SCHOOL_SETUP.md §1.3، §2، §7 (T10)؛ CLAUDE.md §1 بند 15.
--
-- المشكلة: سياسة UPDATE على academic_years لا تنظر إلى الحالة، فاسم وتواريخ سنة active أو closed تُعدَّل مباشرة
-- وتنسحب على فصولها (ON UPDATE CASCADE) — تغيير إعداد يمس سنة سابقة.
--
-- T10 — trigger حارس BEFORE UPDATE: الـinvariant يُفرض أياً كان المسار (العميل تحت RLS، دوال M21، service):
--   • الانتقالات المعلنة فقط: planned → active → closed. لا reopening ولا قفز.
--   • closed: لا يتغير فيه شيء.
--   • active: الاسم فقط — التواريخ ثابتة.
--   • planned: الاسم والتواريخ.
--   • school_id ثابت.
-- INSERT خارج الحارس: status ليس في منح INSERT للعميل (M20)، فالسنة تولد planned.
-- الدالة SECURITY INVOKER: لا تقرأ جدولاً، فلا حاجة لتجاوز RLS.

set local role app_owner;

create function app.tg_academic_year_guard()
returns trigger
language plpgsql
set search_path = app, public, pg_temp
as $$
begin
  if old.status = 'closed' then
    raise exception 'invariant: academic year % is closed and cannot be modified', old.id using errcode = '23514';
  end if;
  if new.status is distinct from old.status
     and not ((old.status = 'planned' and new.status = 'active') or (old.status = 'active' and new.status = 'closed')) then
    raise exception 'invariant: academic year transition % -> % is not allowed', old.status, new.status using errcode = '23514';
  end if;
  if new.school_id is distinct from old.school_id then
    raise exception 'invariant: an academic year cannot move to another school' using errcode = '23514';
  end if;
  if old.status = 'active'
     and (new.start_date is distinct from old.start_date or new.end_date is distinct from old.end_date) then
    raise exception 'invariant: the dates of an active academic year cannot change' using errcode = '23514';
  end if;
  return new;
end;
$$;

reset role;

create trigger guard before update on public.academic_years
  for each row execute function app.tg_academic_year_guard();
