-- M44 — copy_bell_schedules (Phase 2B / 2B-3 — B13؛ عقد M37/M40/M42)
-- المرجع: docs/PHASE2B_3_BELL_SCHEDULES.md §3.
--
-- عملية domain واحدة ذرية تنسخ إلى سنة planned في المدرسة نفسها، **الأجزاء الثلاثة معاً**:
--   • الجداول النشطة            — المفتاح (السنة الهدف، الاسم)؛ موجود active = «منسوخ سابقاً»، موجود inactive = تعارض.
--   • حصصها النشطة              — المفتاح (الجدول بالاسم، اليوم، البداية)؛ المطابقة = النهاية والنوع والاسم؛ أي حصة نشطة
--                                  في الهدف تتداخل معها ولا تطابقها = تعارض؛ يوم ليس دوام نشطاً في السنة الهدف = تعارض (D4 —
--                                  تُنسخ أيام الدوام أولاً، M42).
--   • إسناد الصفوف النشطة       — المفتاح (السنة الهدف، الصف)؛ المطابقة = الجدول نفسه بالاسم؛ غيره = تعارض.
-- أي تعارض يُفشل الكل (23514) بقائمة مسماة؛ لا تعديل للموجود؛ الإضافي في الهدف لا يُمس؛ التشغيل الثاني يعيد 0.
-- الصلاحية: academic_year.update (B12). التدقيق: T7 لكل صف مُنشأ بالسبب + صف domain واحد copy_bell_schedules.

grant insert on public.bell_schedules, public.grade_level_bell_schedules to app_owner;

set local role app_owner;

create function app.copy_bell_schedules(p_source_year_id uuid, p_target_year_id uuid, p_reason text)
returns integer
language plpgsql security definer set search_path = app, public, pg_temp
as $$
declare
  v_src public.academic_years%rowtype;
  v_tgt public.academic_years%rowtype;
  v_conflicts text; v_s integer; v_p integer; v_g integer; v_tenant uuid; v_source text;
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

  -- التعارضات — كلها قبل أي كتابة
  with src_s as (
    select s.id, s.name from public.bell_schedules s where s.academic_year_id = v_src.id and s.status = 'active'),
  src_p as (
    select ss.name as sname, p.weekday, p.kind, p.name, p.start_time, p.end_time
      from public.bell_periods p join src_s ss on ss.id = p.bell_schedule_id where p.status = 'active'),
  tgt_s as (
    select s.id, s.name, s.status from public.bell_schedules s where s.academic_year_id = v_tgt.id),
  c as (
    select 'schedule ' || t.name || ' is inactive in the target' as msg
      from src_s s join tgt_s t on t.name = s.name where t.status <> 'active'
    union all
    select format('%s/%s %s is not an active school weekday in the target', p.sname, p.weekday, p.start_time)
      from src_p p
     where not exists (select 1 from public.calendar_weekdays w where w.academic_year_id = v_tgt.id and w.weekday = p.weekday and w.status = 'active')
    union all
    select format('%s/%s %s differs from the target', p.sname, p.weekday, p.start_time)
      from src_p p join tgt_s t on t.name = p.sname
      join public.bell_periods tp on tp.bell_schedule_id = t.id and tp.weekday = p.weekday and tp.status = 'active'
       and tsrange(date '2000-01-01' + tp.start_time, date '2000-01-01' + tp.end_time, '[)')
        && tsrange(date '2000-01-01' + p.start_time, date '2000-01-01' + p.end_time, '[)')
     where (tp.start_time, tp.end_time, tp.kind, tp.name) is distinct from (p.start_time, p.end_time, p.kind, p.name)
    union all
    select format('grade %s is assigned to another schedule in the target', ga.grade_level_id)
      from public.grade_level_bell_schedules ga
      join src_s ss on ss.id = ga.bell_schedule_id
      join public.grade_levels g on g.id = ga.grade_level_id and g.status = 'active'
      join public.grade_level_bell_schedules gt on gt.academic_year_id = v_tgt.id and gt.grade_level_id = ga.grade_level_id
      join public.bell_schedules ts on ts.id = gt.bell_schedule_id
     where ga.academic_year_id = v_src.id and ts.name <> ss.name)
  select string_agg(msg, '; ' order by msg) into v_conflicts from c;
  if v_conflicts is not null then
    raise exception 'invariant: the target year already has bell schedules that differ from the source: %', v_conflicts using errcode = '23514';
  end if;

  perform app.set_audit_context('copy_bell_schedules', p_reason);
  insert into public.bell_schedules (school_id, academic_year_id, name)
  select v_tgt.school_id, v_tgt.id, s.name from public.bell_schedules s
   where s.academic_year_id = v_src.id and s.status = 'active'
     and not exists (select 1 from public.bell_schedules t where t.academic_year_id = v_tgt.id and t.name = s.name);
  get diagnostics v_s = row_count;

  insert into public.bell_periods (school_id, academic_year_id, bell_schedule_id, weekday, kind, name, start_time, end_time)
  select v_tgt.school_id, v_tgt.id, t.id, p.weekday, p.kind, p.name, p.start_time, p.end_time
    from public.bell_periods p
    join public.bell_schedules s on s.id = p.bell_schedule_id and s.status = 'active'
    join public.bell_schedules t on t.academic_year_id = v_tgt.id and t.name = s.name
   where p.academic_year_id = v_src.id and p.status = 'active'
     and not exists (select 1 from public.bell_periods tp where tp.bell_schedule_id = t.id and tp.weekday = p.weekday
                                                            and tp.start_time = p.start_time and tp.status = 'active');
  get diagnostics v_p = row_count;

  insert into public.grade_level_bell_schedules (school_id, academic_year_id, grade_level_id, bell_schedule_id)
  select v_tgt.school_id, v_tgt.id, ga.grade_level_id, t.id
    from public.grade_level_bell_schedules ga
    join public.bell_schedules s on s.id = ga.bell_schedule_id and s.status = 'active'
    join public.grade_levels g on g.id = ga.grade_level_id and g.status = 'active'
    join public.bell_schedules t on t.academic_year_id = v_tgt.id and t.name = s.name
   where ga.academic_year_id = v_src.id
     and not exists (select 1 from public.grade_level_bell_schedules gt where gt.academic_year_id = v_tgt.id and gt.grade_level_id = ga.grade_level_id);
  get diagnostics v_g = row_count;

  select sc.platform_tenant_id into v_tenant from public.schools sc where sc.id = v_tgt.school_id;
  v_source := coalesce(nullif(current_setting('app.request_source', true), ''), 'api');
  if v_source not in ('web', 'mobile', 'api', 'system') then v_source := 'api'; end if;
  insert into public.audit_log (platform_tenant_id, school_id, actor_type, actor_id, action, entity_type, entity_id, new_values, reason, source)
  values (v_tenant, v_tgt.school_id, 'tenant_user', app.current_profile_id(), 'copy_bell_schedules', 'academic_years', v_tgt.id::text,
          jsonb_build_object('source_year_id', v_src.id, 'target_year_id', v_tgt.id, 'schedules', v_s, 'periods', v_p, 'assignments', v_g),
          p_reason, v_source);
  perform app.set_audit_context(null, null);
  return v_s + v_p + v_g;
end;
$$;

reset role;

grant execute on function app.copy_bell_schedules(uuid, uuid, text) to authenticated;
