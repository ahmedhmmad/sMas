-- M31 — security_relationship_source (مراجعة Stage 1 / S1 + S2، 2026-10-01)
-- المرجع: docs/STAGE1_REVIEW.md §9.1. إصلاحان أمنيان معتمدان؛ لا إعادة فتح لقاعدة §10.5 (student_guardians INSERT).
--
-- S1 — صلاحية ربط ولي الأمر ≠ صلاحية إدارة حسابه.
--   المشكلة: إصدار كلمة المرور المؤقتة كان يكتفي بـguardian_in_scope، وهو نطاق يستطيع الفاعل إنشاؤه بنفسه
--   (student_guardians INSERT المشروع، §10.5) فيصير مصدر النطاق الذي يمنحه إدارة الحساب.
--   الحل (S1-أ): مصدر العلاقة جزء من الـinvariant. عمود `relationship_source` ('direct'|'provisioned') غير قابل
--   للكتابة من العميل (ليس في منح §4.6)، تضعه `provision_guardian` وحدها 'provisioned'. إصدار الكلمة المؤقتة
--   يشترط ارتباطاً نشطاً **provisioned** بطالب في نطاق الفاعل الحالي — لا ربطاً مباشراً منه. الربط المباشر (direct)
--   يبقى مشروعاً للرؤية وفق §10.5، لكنه وحده لا يمنح إدارة credentials.
--
-- S2 — self-created scope لا يكون مصدر النطاق.
--   المشكلة: students.family_id يكتبه العميل وWITH CHECK لا يفحص الأسرة الهدف، فيسند الفاعل طالبه إلى أسرة خارج
--   نطاقه فيراها ويعدّلها.
--   الحل: WITH CHECK يشترط family_id IS NULL أو app.family_in_scope(family_id) — الأسرة ضمن نطاق الفاعل **أصلاً**.
--   «أصلاً» مضمون بدلالات PostgreSQL: فحص RLS UPDATE WITH CHECK يجري قبل كتابة الصف الجديد، والدالة تقرأ لقطة
--   الجملة فترى الصف القديم (الحقيقة نفسها التي بُني عليها WITH CHECK في M14) — فالطالب الجاري نقله لا يجعل الأسرة
--   الهدف «في النطاق» بنفسه، والأسرة غير المتغيرة تبقى مقبولة (الطالب نفسه فيها في اللقطة). يثبته `32`.

-- ------------------------------------------------------------------
-- S1 (1): العمود — غير قابل للكتابة من العميل (لا GRANT؛ الافتراضي 'direct')
-- ------------------------------------------------------------------
-- الصفوف القائمة تأخذ 'direct' (الأحفظ)؛ على قاعدة جديدة لا صفوف قبل هذه الـmigration.
alter table public.student_guardians
  add column relationship_source text not null default 'direct',
  add constraint student_guardians_relationship_source_chk check (relationship_source in ('direct', 'provisioned'));

set local role app_owner;

-- ------------------------------------------------------------------
-- S1 (2): provision_guardian — نص M22 نفسه + وسم العلاقة 'provisioned'
-- ------------------------------------------------------------------
create or replace function app.provision_guardian(
  p_guardian_id uuid, p_student_id uuid, p_relationship_type text, p_phone_e164 text,
  p_first_name text, p_family_name text, p_effective_from date,
  p_father_name text default null, p_grandfather_name text default null,
  p_alt_phone_e164 text default null, p_email text default null, p_national_id text default null,
  p_is_primary boolean default false)
returns uuid
language plpgsql security definer set search_path = app, public, pg_temp
as $$
declare v_tenant uuid;
begin
  if not (app.has_permission('guardian.create') and app.has_permission('guardian.link')) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  select st.platform_tenant_id into v_tenant from public.students st
   where st.id = p_student_id and app.student_in_scope(st.id);
  if not found then raise exception 'not found' using errcode = 'P0002'; end if;
  if exists (select 1 from public.guardians g where g.id = p_guardian_id) then
    if exists (select 1 from public.student_guardians l join public.guardians g on g.id = l.guardian_id
               where l.guardian_id = p_guardian_id and l.student_id = p_student_id and g.phone_e164 = p_phone_e164) then
      return p_guardian_id;
    end if;
    raise exception 'conflict: guardian % already exists with different data', p_guardian_id using errcode = '23505';
  end if;

  perform app.set_audit_context('provision', 'provision_guardian');
  insert into public.guardians (id, platform_tenant_id, first_name, father_name, grandfather_name, family_name,
                                phone_e164, alt_phone_e164, email, national_id)
    values (p_guardian_id, v_tenant, p_first_name, p_father_name, p_grandfather_name, p_family_name,
            p_phone_e164, p_alt_phone_e164, p_email, p_national_id);
  insert into public.student_guardians (student_id, guardian_id, platform_tenant_id, relationship_type, is_primary,
                                        effective_from, relationship_source)
    values (p_student_id, p_guardian_id, v_tenant, p_relationship_type, p_is_primary, p_effective_from, 'provisioned');
  perform app.set_audit_context(null, null);
  return p_guardian_id;
end;
$$;

-- ------------------------------------------------------------------
-- S1 (3): بوابة إصدار الكلمة المؤقتة — نص M27 نفسه + شرط العلاقة الـprovisioned
--          (begin_guardian_temporary_password و arm_guardian_temporary_password تستدعيانها)
-- ------------------------------------------------------------------
create or replace function app.guardian_account_for_issue(p_guardian_id uuid)
returns uuid
language plpgsql
security definer
set search_path = app, public, pg_temp
as $$
declare v_account uuid; v_state text; v_activated timestamptz;
begin
  if not app.has_permission('security.manage') then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  select p.auth_user_id into v_account
    from public.guardians g join public.profiles p on p.id = g.profile_id
   where g.id = p_guardian_id and g.status = 'active' and app.guardian_in_scope(g.id)
     -- S1: مصدر النطاق علاقة provisioned بطالب في النطاق الحالي — لا ربط مباشر أنشأه المُصدِر
     and exists (select 1 from public.student_guardians sg
                  where sg.guardian_id = g.id and sg.status = 'active'
                    and sg.relationship_source = 'provisioned' and app.student_in_scope(sg.student_id));
  if not found then
    raise exception 'not found' using errcode = 'P0002';
  end if;
  select ai.credential_state, ai.credential_activated_at into v_state, v_activated
    from public.auth_identities ai where ai.auth_user_id = v_account for update;
  if v_state <> 'pending' or v_activated is not null then
    raise exception 'conflict: the guardian account is already onboarded — a reset is a separate flow (5c)' using errcode = '23505';
  end if;
  return v_account;
end;
$$;

reset role;

-- ------------------------------------------------------------------
-- S2: students UPDATE WITH CHECK — + الأسرة ضمن النطاق أصلاً (USING بلا تغيير؛ لا دالة جديدة:
--     app.family_in_scope مساعد RLS قائم منذ M12b)
-- ------------------------------------------------------------------
alter policy students_update on public.students
  with check (    platform_tenant_id = (select app.current_tenant_id())
              and app.has_permission('student.update')
              and (family_id is null or app.family_in_scope(family_id)));
