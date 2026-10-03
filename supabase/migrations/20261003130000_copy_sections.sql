-- M37 — copy_sections (Phase 2A / P2-B — القرار 8، Q5، 2026-10-02)
-- المرجع: docs/PHASE2_SCHOOL_SETUP.md §8.
--
-- عملية domain واحدة ذرية: تنسخ «بنية الشعب» من سنة مصدر إلى سنة planned في المدرسة نفسها. نسخ لا تعديل.
--
-- المفتاح الطبيعي للنسخة = (school_id, academic_year_id الهدف, grade_level_id, name) — قيد sections_name_uq القائم.
-- لكل شعبة مصدر مؤهلة (active تحت صف active) شعبة هدف بالمفتاح نفسه:
--   • غير موجودة            → تُنشأ (status = active، والسعة وسياسة الجنس من المصدر).
--   • موجودة ومطابقة        → «منسوخة سابقاً»: تُحسب ولا تُمس (لا تحديث، لا ختم).
--     المطابقة = active + capacity و gender_policy مساويتان للمصدر.
--   • موجودة وغير مطابقة    → الهدف في حالة لا تتوافق مع المصدر: تُرفض العملية كلها (23514) بقائمة المفاتيح
--     المتعارضة، ولا يُنشأ شيء — لا ON CONFLICT DO NOTHING يخفيها، ولا «تصحيح» للموجود.
--   شعب الهدف التي لا مقابل لها في المصدر لا تُمس.
-- فالتشغيل الثاني لنفس المصدر والهدف يعيد 0 ولا يغيّر شيئاً.
--
-- لا يُنسخ: الشعب المعطّلة، شعب الصفوف المعطّلة (من سنة مصدر مغلقة)، الفصول، التسجيلات، أي بيانات تشغيلية.
-- الإدراج يمر بحارس M35 (T12): لا التفاف على دورة حياة السنة أو الصف.
--
-- الصلاحية: section.manage (لا مفتاح جديد). النطاق: can_access_school على مدرسة السنتين بعد قراءتهما — لا معامل
-- school_id من العميل. قفل الهدف FOR UPDATE يسلسل نسختين متزامنتين إلى السنة نفسها.
-- التدقيق: T7 صف لكل شعبة مُنشأة (بالسبب)، وصف domain واحد copy_sections على السنة الهدف بالمصدر والهدف والعددين.

grant insert on public.sections to app_owner;

set local role app_owner;

create function app.copy_sections(p_source_year_id uuid, p_target_year_id uuid, p_reason text)
returns integer
language plpgsql security definer set search_path = app, public, pg_temp
as $$
declare
  v_src public.academic_years%rowtype;
  v_tgt public.academic_years%rowtype;
  v_tenant uuid; v_conflicts text; v_already integer; v_created integer; v_source text;
begin
  if not app.has_permission('section.manage') then
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

  -- الخطة: الشعب المؤهلة في المصدر ومقابلها في الهدف بالمفتاح الطبيعي (عبارتان بالقراءة نفسها؛ الهدف مقفل)
  with plan as (
    select s.grade_level_id, s.name, t.id as existing_id,
           t.id is not null and t.status = 'active' and t.capacity is not distinct from s.capacity
                            and t.gender_policy = s.gender_policy as existing_ok
      from public.sections s
      join public.grade_levels g on g.id = s.grade_level_id and g.status = 'active'
      left join public.sections t on t.school_id = v_tgt.school_id and t.academic_year_id = v_tgt.id
                                 and t.grade_level_id = s.grade_level_id and t.name = s.name
     where s.academic_year_id = v_src.id and s.status = 'active')
  select string_agg(format('%s/%s', p.grade_level_id, p.name), ', ' order by p.grade_level_id, p.name)
           filter (where p.existing_id is not null and not p.existing_ok),
         count(*) filter (where p.existing_id is not null)
    into v_conflicts, v_already
    from plan p;
  if v_conflicts is not null then
    raise exception 'invariant: the target year already has sections that differ from the source: %', v_conflicts using errcode = '23514';
  end if;

  perform app.set_audit_context('copy_sections', p_reason);
  insert into public.sections (school_id, academic_year_id, grade_level_id, name, capacity, gender_policy, status)
  select v_tgt.school_id, v_tgt.id, s.grade_level_id, s.name, s.capacity, s.gender_policy, 'active'
    from public.sections s
    join public.grade_levels g on g.id = s.grade_level_id and g.status = 'active'
   where s.academic_year_id = v_src.id and s.status = 'active'
     and not exists (select 1 from public.sections t where t.school_id = v_tgt.school_id and t.academic_year_id = v_tgt.id
                                                       and t.grade_level_id = s.grade_level_id and t.name = s.name);
  get diagnostics v_created = row_count;

  -- صف التدقيق للعملية نفسها (T7 يسجل كل شعبة؛ هذا يربطها بمصدرها وهدفها)
  select s.platform_tenant_id into v_tenant from public.schools s where s.id = v_tgt.school_id;
  v_source := coalesce(nullif(current_setting('app.request_source', true), ''), 'api');
  if v_source not in ('web', 'mobile', 'api', 'system') then v_source := 'api'; end if;
  insert into public.audit_log (platform_tenant_id, school_id, actor_type, actor_id, action, entity_type, entity_id, new_values, reason, source)
  values (v_tenant, v_tgt.school_id, 'tenant_user', app.current_profile_id(), 'copy_sections', 'academic_years', v_tgt.id::text,
          jsonb_build_object('source_year_id', v_src.id, 'target_year_id', v_tgt.id, 'created', v_created, 'already_copied', v_already),
          p_reason, v_source);
  perform app.set_audit_context(null, null);
  return v_created;
end;
$$;

reset role;

grant execute on function app.copy_sections(uuid, uuid, text) to authenticated;
