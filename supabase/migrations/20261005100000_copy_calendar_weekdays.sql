-- M42 — copy_calendar_weekdays (Phase 2B / 2B-2 — B13؛ عقد M37/M40 نفسه)
-- المرجع: docs/PHASE2B_2_CALENDAR.md §4.
--
-- عملية domain واحدة ذرية: تنسخ أيام الدوام النشطة من سنة مصدر إلى سنة planned في المدرسة نفسها. نسخ لا تعديل.
-- المفتاح الطبيعي = (academic_year_id الهدف, weekday) — قيد calendar_weekdays_key_uq.
--   • غير موجود               → يُنشأ active.
--   • موجود active            → «منسوخ سابقاً»: يُحسب ولا يُمس.
--   • موجود inactive          → العملية كلها تُرفض (23514) بقائمة الأيام؛ لا تصحيح للموجود.
--   الإضافي في الهدف لا يُمس. التشغيل الثاني يعيد 0. الاستثناءات المؤرخة لا تُنسخ (B13).
-- الصلاحية: academic_year.update (B12). النطاق: can_access_school على السنتين بعد قراءتهما. قفل الهدف FOR UPDATE.
-- التدقيق: T7 لكل يوم مُنشأ بالسبب + صف domain واحد copy_calendar_weekdays.

set local role app_owner;

create function app.copy_calendar_weekdays(p_source_year_id uuid, p_target_year_id uuid, p_reason text)
returns integer
language plpgsql security definer set search_path = app, public, pg_temp
as $$
declare
  v_src public.academic_years%rowtype;
  v_tgt public.academic_years%rowtype;
  v_tenant uuid; v_conflicts text; v_already integer; v_created integer; v_source text;
begin
  if not app.has_permission('academic_year.update') then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  perform app.require_reason(p_reason);

  select y.* into v_tgt from public.academic_years y
   where y.id = p_target_year_id and app.can_access_school(y.school_id) for update;
  if not found then raise exception 'not found' using errcode = 'P0002'; end if;
  select y.* into v_src from public.academic_years y
   where y.id = p_source_year_id and app.can_access_school(y.school_id) for share;
  if not found then raise exception 'not found' using errcode = 'P0002'; end if;

  if v_src.id = v_tgt.id then
    raise exception 'invalid: source and target are the same academic year' using errcode = '22023';
  end if;
  if v_src.school_id <> v_tgt.school_id then
    raise exception 'invalid: source and target belong to different schools' using errcode = '22023';
  end if;
  if v_tgt.status <> 'planned' then
    raise exception 'invalid: the target academic year must be planned (is %)', v_tgt.status using errcode = '22023';
  end if;

  select string_agg(w.weekday::text, ', ' order by w.weekday) filter (where t.id is not null and t.status <> 'active'),
         count(*) filter (where t.id is not null)
    into v_conflicts, v_already
    from public.calendar_weekdays w
    left join public.calendar_weekdays t on t.academic_year_id = v_tgt.id and t.weekday = w.weekday
   where w.academic_year_id = v_src.id and w.status = 'active';
  if v_conflicts is not null then
    raise exception 'invariant: the target year already has weekdays that differ from the source: %', v_conflicts using errcode = '23514';
  end if;

  perform app.set_audit_context('copy_calendar_weekdays', p_reason);
  insert into public.calendar_weekdays (school_id, academic_year_id, weekday)
  select v_tgt.school_id, v_tgt.id, w.weekday
    from public.calendar_weekdays w
   where w.academic_year_id = v_src.id and w.status = 'active'
     and not exists (select 1 from public.calendar_weekdays t where t.academic_year_id = v_tgt.id and t.weekday = w.weekday);
  get diagnostics v_created = row_count;

  select sc.platform_tenant_id into v_tenant from public.schools sc where sc.id = v_tgt.school_id;
  v_source := coalesce(nullif(current_setting('app.request_source', true), ''), 'api');
  if v_source not in ('web', 'mobile', 'api', 'system') then v_source := 'api'; end if;
  insert into public.audit_log (platform_tenant_id, school_id, actor_type, actor_id, action, entity_type, entity_id, new_values, reason, source)
  values (v_tenant, v_tgt.school_id, 'tenant_user', app.current_profile_id(), 'copy_calendar_weekdays', 'academic_years', v_tgt.id::text,
          jsonb_build_object('source_year_id', v_src.id, 'target_year_id', v_tgt.id, 'created', v_created, 'already_copied', v_already),
          p_reason, v_source);
  perform app.set_audit_context(null, null);
  return v_created;
end;
$$;

reset role;

grant execute on function app.copy_calendar_weekdays(uuid, uuid, text) to authenticated;
