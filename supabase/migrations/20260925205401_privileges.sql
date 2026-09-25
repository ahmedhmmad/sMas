-- M20 — privileges
-- المرجع: docs/DB_IMPLEMENTATION_SPEC_v1.md §4.6 (سجل صلاحيات الأعمدة)، §B10 (M20)؛ CLAUDE.md §1.1 بند 12؛
--         قرارات M11 (SELECT على audit_log)، M17b (staff_school_assignments)، M19 (roles.status)، 2026-09-25 (EXECUTE بفئتين)
--
-- طبقة الصلاحيات الفعلية فوق RLS:
--   • RLS تحكم «أي صف»؛ هنا «أي عمود» و«أي عملية». ما لا يرد في §4.6 لا يُكتب مباشرة من أي مستخدم.
--   • صلاحية العمود موحّدة لكل authenticated (§1.1 بند 12): الأعمدة المحكومة بصلاحية مستقلة أو انتقال حالة
--     (status، effective_to، archived_at…) خارج GRANT وتتغير بدوال M21.
--   • قراءة الأعمدة: SELECT على مستوى الجدول لـauthenticated (RLS تحكم الصفوف؛ لا أعمدة حساسة في Foundation — G5).
--   • anon: لا شيء على أي جدول. TRUNCATE/TRIGGER/REFERENCES: لا شيء لـauthenticated (RLS لا تحمي TRUNCATE).
--   • DELETE لـauthenticated: الجداول الثلاثة ذات سياسات G2 فقط.
--   • الامتيازات الافتراضية للجداول المستقبلية: آمنة افتراضياً — كل migration لاحقة تمنح صراحةً ما يلزم.
--
-- تفسير «كل أعمدة الأعمال» في §4.6: كل الأعمدة عدا id، created_*، updated_*، الأعمدة المولَّدة، archived_at،
-- وأعمدة الحالة التي تحكمها صلاحية/انتقال مستقل.
-- EXECUTE: لا تغيير هنا — الدوال التي تستدعيها السياسات مُنحت مع طبقاتها (M14–M17)؛ لا دوال متحكَّم بها بعد
-- (M21/M22 تضيفها مع allowlist). الفحص بفئتين في 20_column_grants.

-- ------------------------------------------------------------------
-- 1. anon: لا شيء على أي جدول في public
-- ------------------------------------------------------------------
revoke all on all tables in schema public from anon;

-- ------------------------------------------------------------------
-- 2. authenticated: نبدأ من الصفر ثم نمنح السجل حرفياً
-- ------------------------------------------------------------------
revoke insert, update, delete, truncate, trigger, references on all tables in schema public from authenticated;
grant select on all tables in schema public to authenticated;   -- يشمل audit_log (تبعية M11؛ السياسة من M18)

-- DELETE: سياسات G2 فقط
grant delete on public.membership_roles, public.membership_scopes, public.role_permissions to authenticated;

-- ------------------------------------------------------------------
-- 3. سجل §4.6 — INSERT / UPDATE بالأعمدة
-- ------------------------------------------------------------------
-- platform_tenants: الإنشاء bootstrap_tenant (service، §5.2)
grant update (name) on public.platform_tenants to authenticated;

grant insert (platform_tenant_id, group_code, name) on public.groups to authenticated;
grant update (name)                                 on public.groups to authenticated;

grant insert (platform_tenant_id, group_id, school_code, name, slug, timezone) on public.schools to authenticated;
grant update (name, slug, timezone)                                            on public.schools to authenticated;

-- profiles: الإنشاء بدوال §5.2؛ لا تعديل ذاتي (G1 — في السياسة)
grant update (display_name) on public.profiles to authenticated;

-- memberships: لا شيء (دوال الإنشاء والانتقال)

grant insert (membership_id, role_id, platform_tenant_id, role_owner_key)          on public.membership_roles  to authenticated;
grant insert (membership_id, platform_tenant_id, scope_type, group_id, school_id)  on public.membership_scopes to authenticated;

-- roles: status خارج GRANT (قرار M19 — التفعيل انتقال حالة في M21)
grant insert (platform_tenant_id, code, name, description) on public.roles to authenticated;
grant update (name, description)                           on public.roles to authenticated;

grant insert (role_id, permission_id) on public.role_permissions to authenticated;

grant update (first_name, father_name, grandfather_name, family_name,
              national_id, phone_e164, email, gender, birth_date, hire_date) on public.staff to authenticated;

-- staff_school_assignments: قرار M17b — status و effective_to خارج GRANT (الإنشاء يبدأ نشطاً، والإنهاء انتقال حالة)
grant insert (staff_id, school_id, platform_tenant_id, job_title, is_primary, effective_from) on public.staff_school_assignments to authenticated;
grant update (job_title, is_primary)                                                          on public.staff_school_assignments to authenticated;

grant update (family_code, family_name, address) on public.families to authenticated;

grant update (first_name, father_name, grandfather_name, family_name,
              gender, birth_date, nationality, family_id, official_id, official_id_type) on public.students to authenticated;

-- guardians: phone_e164 خارج GRANT — مسار OTP في FastAPI (PLAN §7.8)
grant update (first_name, father_name, grandfather_name, family_name,
              alt_phone_e164, email, national_id, residence_country) on public.guardians to authenticated;

grant insert (student_id, guardian_id, platform_tenant_id, relationship_type,
              is_primary, receives_whatsapp, can_pickup, effective_from)           on public.student_guardians to authenticated;
grant update (relationship_type, is_primary, receives_whatsapp, can_pickup)        on public.student_guardians to authenticated;

grant insert (school_id, student_id, platform_tenant_id, academic_year_id, grade_level_id, section_id,
              identity_scope_id, scope_owner_id, enrollment_no, effective_from) on public.enrollments to authenticated;
grant update (enrollment_no)                                                    on public.enrollments to authenticated;

-- academic_years: status (activate/close) انتقال حالة في M21
grant insert (school_id, name, start_date, end_date) on public.academic_years to authenticated;
grant update (name, start_date, end_date)            on public.academic_years to authenticated;

-- terms، stages، grade_levels، sections: كل أعمدة الأعمال (.manage واحدة تحكمها كلها)
grant insert (academic_year_id, school_id, name, sequence_no, start_date, end_date, year_start_date, year_end_date, status),
      update (academic_year_id, school_id, name, sequence_no, start_date, end_date, year_start_date, year_end_date, status)
  on public.terms to authenticated;
grant insert (school_id, name, sequence_no, status),
      update (school_id, name, sequence_no, status)
  on public.stages to authenticated;
grant insert (school_id, stage_id, name, sequence_no, status),
      update (school_id, stage_id, name, sequence_no, status)
  on public.grade_levels to authenticated;
grant insert (school_id, academic_year_id, grade_level_id, name, capacity, gender_policy, status),
      update (school_id, academic_year_id, grade_level_id, name, capacity, gender_policy, status)
  on public.sections to authenticated;

-- ------------------------------------------------------------------
-- 4. الجداول المستقبلية: آمنة افتراضياً (منح Supabase الافتراضي يعطي anon و authenticated كل شيء)
-- ------------------------------------------------------------------
alter default privileges for role postgres in schema public revoke all on tables from anon;
alter default privileges for role postgres in schema public
  revoke insert, update, delete, truncate, trigger, references on tables from authenticated;
