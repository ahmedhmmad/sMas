-- M40 — copy_grade_subjects (Phase 2B / 2B-1 — B13؛ عقد M37 نفسه)
-- المرجع: docs/PHASE2B_SCOPE.md §3، §0 (B13)؛ docs/PHASE2_SCHOOL_SETUP.md §8 (عقد النسخ المنقّح في M37).
--
-- عملية domain واحدة ذرية: تنسخ ربط المواد بالصفوف من سنة مصدر إلى سنة planned في المدرسة نفسها. نسخ لا تعديل.
-- المفتاح الطبيعي = (academic_year_id الهدف, grade_level_id, subject_id) — قيد grade_subjects_key_uq.
--   • غير موجود      → يُنشأ active بالحصص الأسبوعية و«الدخول في المجموع» من المصدر.
--   • موجود ومطابق   → «منسوخ سابقاً»: يُحسب ولا يُمس. المطابقة = active + الحصص والمجموع مساويان.
--   • موجود وغير مطابق (ومنه المعطَّل) → العملية كلها تُرفض (23514) بقائمة المفاتيح؛ لا تصحيح للموجود.
--   الإضافي في الهدف لا يُمس. التشغيل الثاني يعيد 0.
-- يُنسخ: الربط active لصف active ومادة active. لا بيانات تشغيلية. الإدراج يمر بحارس T13.
-- الصلاحية: subject.manage (B10). النطاق: can_access_school على السنتين بعد قراءتهما. قفل الهدف FOR UPDATE.
-- التدقيق: T7 لكل ربط مُنشأ بالسبب + صف domain واحد copy_grade_subjects.

grant insert on public.grade_subjects to app_owner;

set local role app_owner;

create function app.copy_grade_subjects(p_source_year_id uuid, p_target_year_id uuid, p_reason text)
returns integer
language plpgsql security definer set search_path = app, public, pg_temp
as $$
declare
  v_src public.academic_years%rowtype;
  v_tgt public.academic_years%rowtype;
  v_tenant uuid; v_conflicts text; v_already integer; v_created integer; v_source text;
begin
  if not app.has_permission('subject.manage') then
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

  with plan as (
    select gs.grade_level_id, gs.subject_id, t.id as existing_id,
           t.id is not null and t.status = 'active' and t.weekly_periods = gs.weekly_periods
                            and t.counts_toward_total = gs.counts_toward_total as existing_ok
      from public.grade_subjects gs
      join public.grade_levels g on g.id = gs.grade_level_id and g.status = 'active'
      join public.subjects s on s.id = gs.subject_id and s.status = 'active'
      left join public.grade_subjects t on t.academic_year_id = v_tgt.id
                                       and t.grade_level_id = gs.grade_level_id and t.subject_id = gs.subject_id
     where gs.academic_year_id = v_src.id and gs.status = 'active')
  select string_agg(format('%s/%s', p.grade_level_id, p.subject_id), ', ' order by p.grade_level_id, p.subject_id)
           filter (where p.existing_id is not null and not p.existing_ok),
         count(*) filter (where p.existing_id is not null)
    into v_conflicts, v_already
    from plan p;
  if v_conflicts is not null then
    raise exception 'invariant: the target year already has grade subjects that differ from the source: %', v_conflicts using errcode = '23514';
  end if;

  perform app.set_audit_context('copy_grade_subjects', p_reason);
  insert into public.grade_subjects (school_id, academic_year_id, grade_level_id, subject_id, weekly_periods, counts_toward_total, status)
  select v_tgt.school_id, v_tgt.id, gs.grade_level_id, gs.subject_id, gs.weekly_periods, gs.counts_toward_total, 'active'
    from public.grade_subjects gs
    join public.grade_levels g on g.id = gs.grade_level_id and g.status = 'active'
    join public.subjects s on s.id = gs.subject_id and s.status = 'active'
   where gs.academic_year_id = v_src.id and gs.status = 'active'
     and not exists (select 1 from public.grade_subjects t where t.academic_year_id = v_tgt.id
                                                             and t.grade_level_id = gs.grade_level_id and t.subject_id = gs.subject_id);
  get diagnostics v_created = row_count;

  select sc.platform_tenant_id into v_tenant from public.schools sc where sc.id = v_tgt.school_id;
  v_source := coalesce(nullif(current_setting('app.request_source', true), ''), 'api');
  if v_source not in ('web', 'mobile', 'api', 'system') then v_source := 'api'; end if;
  insert into public.audit_log (platform_tenant_id, school_id, actor_type, actor_id, action, entity_type, entity_id, new_values, reason, source)
  values (v_tenant, v_tgt.school_id, 'tenant_user', app.current_profile_id(), 'copy_grade_subjects', 'academic_years', v_tgt.id::text,
          jsonb_build_object('source_year_id', v_src.id, 'target_year_id', v_tgt.id, 'created', v_created, 'already_copied', v_already),
          p_reason, v_source);
  perform app.set_audit_context(null, null);
  return v_created;
end;
$$;

reset role;

grant execute on function app.copy_grade_subjects(uuid, uuid, text) to authenticated;
