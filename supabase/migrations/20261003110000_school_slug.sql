-- M36 — school_slug (Phase 2A / P2-B، ف3 — القرار 4 و Q6، 2026-10-02)
-- المرجع: docs/PHASE2_SCHOOL_SETUP.md §1.2، §6.3.
--
-- المشكلة: schools.slug يعدّله أي حامل school.update بـUPDATE مباشر، وهو منذ F3 جزء من عنوان المدرسة
-- ({slug}.{tenant}.{base}) — تغيير عنوان بلا سبب ولا تدقيق مسمّى.
--
--   1. slug يخرج من منح UPDATE للعميل.
--   2. app.set_school_slug — المكان الوحيد لتغييره: school.update (لا مفتاح جديد) + نطاق المدرسة + سبب + مدرسة active
--      + قيمة مختلفة. الصيغة والتفرد يحكمهما القيدان القائمان وحدهما (schools_slug_chk — M30b،
--      schools_tenant_slug_uq) — لا نسخة ثانية من القاعدة داخل الدالة.
--   3. فشل القيد يُلغي عبارة الاستدعاء كلها، ومعها سياق التدقيق المحلي الذي ضُبط داخلها (GUC محلي يتراجع مع
--      المعاملة/الـsavepoint) — لا slug جزئي ولا سياق تدقيق عالق؛ نمط دوال M21 نفسه.
--
-- لا أثر على التفويض: الدالة تكتب عمود slug وحده — school_id و platform_tenant_id و group_id والعضويات والنطاقات
-- لا تُمس. الـhost سياق لا سلطة (F3). Q6: الـslug القديم يتحرر فوراً — لا حجز ولا سجل تاريخ ولا جدول جديد.

revoke update (slug) on public.schools from authenticated;

set local role app_owner;

create function app.set_school_slug(p_school_id uuid, p_slug text, p_reason text)
returns text
language plpgsql security definer set search_path = app, public, pg_temp
as $$
declare v_status text; v_slug text;
begin
  if not app.has_permission('school.update') then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  perform app.require_reason(p_reason);
  select s.status, s.slug into v_status, v_slug from public.schools s
   where s.id = p_school_id and app.can_access_school(s.id) for update;
  if not found then raise exception 'not found' using errcode = 'P0002'; end if;
  if v_status <> 'active' then
    raise exception 'invalid: the slug of an archived school cannot change' using errcode = '22023';
  end if;
  if p_slug is null or p_slug = v_slug then
    raise exception 'invalid: the new slug must differ from the current one' using errcode = '22023';
  end if;
  perform app.set_audit_context('change_slug', p_reason);
  update public.schools set slug = p_slug where id = p_school_id;
  perform app.set_audit_context(null, null);
  return p_slug;
end;
$$;

reset role;

grant execute on function app.set_school_slug(uuid, text, text) to authenticated;
