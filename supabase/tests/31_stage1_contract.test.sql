-- Stage 1 review (R1–R10، 2026-10-01) — docs/STAGE1_REVIEW.md
-- القسم 1: إغلاق فجوات R2 — قواعد منفذة في DB لم يكن يثبتها اختبار باسم القيد (اختبارات فقط، بلا migrations).
-- القسم 2: حراس دائمة لعقود مستقرة — أي سياسة أو trigger أو دالة تُضاف/تُحذف/يتغير عقدها تُفشل هذا الملف حتى
--          تُحدَّث القائمة عمداً (القوائم هنا = الحالة التي راجعتها المراجعة مقابل التصميم المعتمد).
begin;

create temp table r (k text primary key, v text) on commit drop;
grant all on r to public;

create function pg_temp.rec(p_key text, p_sql text) returns void
language plpgsql as $$
declare x text;
begin
  begin
    execute p_sql into x;
    x := coalesce(x, '<null>');
  exception when others then
    x := 'ERR ' || sqlstate || ': ' || sqlerrm;
  end;
  insert into r values (p_key, x) on conflict (k) do update set v = excluded.v;
end $$;

-- ============ Fixture ============
insert into public.platform_tenants (id, tenant_code, host_label, name) values
  ('10000000-0000-0000-0000-000000000001', 'T1', 't1', 'T1'), ('20000000-0000-0000-0000-000000000002', 'T2', 't2', 'T2');
insert into public.groups (id, platform_tenant_id, group_code, name) values
  ('a1000000-0000-0000-0000-00000000000a', '10000000-0000-0000-0000-000000000001', 'GA', 'GA'),
  ('a2000000-0000-0000-0000-00000000000b', '20000000-0000-0000-0000-000000000002', 'GB', 'GB');
insert into public.schools (id, platform_tenant_id, group_id, school_code, name, slug) values
  ('5a000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', 'a1000000-0000-0000-0000-00000000000a', 'SA', 'SA', 'sa'),
  ('55000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001', null, 'SS', 'SS', 'ss'),
  ('52000000-0000-0000-0000-000000000003', '20000000-0000-0000-0000-000000000002', null, 'S2', 'S2', 's2');

create function pg_temp.account(p_id uuid, p_tenant uuid) returns uuid
language plpgsql as $$
declare v uuid;
begin
  insert into auth.users (id, email) values (p_id, p_id::text || '@m31.invalid');
  insert into public.auth_identities (auth_user_id, kind) values (p_id, 'tenant');
  insert into public.profiles (platform_tenant_id, auth_user_id, display_name) values (p_tenant, p_id, 'x') returning id into v;
  return v;
end $$;
create function pg_temp.student(p_id uuid, p_tenant uuid, p_school uuid) returns void
language plpgsql as $$
declare v_profile uuid := pg_temp.account(p_id, p_tenant);
begin
  insert into public.students (id, platform_tenant_id, identity_scope_id, student_profile_id, official_id, official_id_type, first_name, family_name)
    select p_id, p_tenant, i.id, v_profile, '111', 'national_id', 'S', 'T'
    from public.schools sc join public.identity_scopes i on i.owner_id = sc.scope_owner_id where sc.id = p_school;
end $$;
select pg_temp.student('e1000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', '55000000-0000-0000-0000-000000000002');
select pg_temp.student('e2000000-0000-0000-0000-000000000002', '20000000-0000-0000-0000-000000000002', '52000000-0000-0000-0000-000000000003');
insert into public.families (id, platform_tenant_id, family_name) values ('f1000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', 'F');
insert into public.guardians (id, platform_tenant_id, first_name, family_name, phone_e164, profile_id) values
  ('91000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', 'G', 'X', '+201000000001',
   pg_temp.account('91000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001'));
insert into public.memberships (id, platform_tenant_id, profile_id)
  select '71000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', id from public.profiles
   where auth_user_id = '91000000-0000-0000-0000-000000000001';
insert into auth.users (id, email) values ('c9000000-0000-0000-0000-000000000009', 'kind@m31.invalid');

-- ============ القسم 1: فجوات R2 ============
-- I3: صيغة school_code
select pg_temp.rec('i3.school_code', $q$insert into public.schools (platform_tenant_id, school_code, name, slug)
  values ('10000000-0000-0000-0000-000000000001', 'bad code', 'x', 'okslug') returning 'ok'$q$);
-- I4: status ↔ archived_at للأسرة وولي الأمر والطالب
select pg_temp.rec('i4.family',   $q$update public.families  set status = 'archived' where id = 'f1000000-0000-0000-0000-000000000001' returning 'ok'$q$);
select pg_temp.rec('i4.guardian', $q$update public.guardians set status = 'archived' where id = '91000000-0000-0000-0000-000000000001' returning 'ok'$q$);
select pg_temp.rec('i4.student',  $q$update public.students  set status = 'archived' where id = 'e1000000-0000-0000-0000-000000000001' returning 'ok'$q$);
-- I9: الالتفاف على FK النطاق بـschool_is_standalone = false لمدرسة داخل Group
select pg_temp.rec('i9.forged_flag', $q$insert into public.identity_scopes (platform_tenant_id, scope_kind, school_id, school_is_standalone)
  values ('10000000-0000-0000-0000-000000000001', 'school', '5a000000-0000-0000-0000-000000000001', false) returning 'ok'$q$);
-- I11: نوع هوية خارج المسارين
select pg_temp.rec('i11.kind', $q$insert into public.auth_identities (auth_user_id, kind) values ('c9000000-0000-0000-0000-000000000009', 'service') returning 'ok'$q$);
-- I15: نطاق مجموعة من Tenant آخر؛ ونطاق بـTenant غير Tenant العضوية
select pg_temp.rec('i15.group', $q$insert into public.membership_scopes (membership_id, platform_tenant_id, scope_type, group_id)
  values ('71000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', 'group', 'a2000000-0000-0000-0000-00000000000b') returning 'ok'$q$);
select pg_temp.rec('i15.membership', $q$insert into public.membership_scopes (membership_id, platform_tenant_id, scope_type)
  values ('71000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000002', 'tenant') returning 'ok'$q$);
-- I23: حساب واحد ↔ ولي أمر واحد
select pg_temp.rec('i23.guardian', $q$insert into public.guardians (platform_tenant_id, first_name, family_name, phone_e164, profile_id)
  select '10000000-0000-0000-0000-000000000001', 'G', 'Y', '+201000000002', profile_id from public.guardians
   where id = '91000000-0000-0000-0000-000000000001' returning 'ok'$q$);
-- I27: ربط ولي أمر بطالب من Tenant آخر
select pg_temp.rec('i27.student', $q$insert into public.student_guardians (student_id, guardian_id, platform_tenant_id, relationship_type)
  values ('e2000000-0000-0000-0000-000000000002', '91000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', 'mother') returning 'ok'$q$);

-- ============ القسم 2: القوائم المتوقعة ============
create temp table expected_policies (p text primary key) on commit drop;
insert into expected_policies values
  ('academic_years.academic_years_insert:INSERT'), ('academic_years.academic_years_select:SELECT'), ('academic_years.academic_years_update:UPDATE'),
  ('audit_log.audit_log_platform_select:SELECT'), ('audit_log.audit_log_tenant_select:SELECT'), ('enrollments.enrollments_insert:INSERT'),
  ('enrollments.enrollments_select:SELECT'), ('enrollments.enrollments_update:UPDATE'), ('families.families_select:SELECT'),
  ('families.families_update:UPDATE'), ('grade_levels.grade_levels_insert:INSERT'), ('grade_levels.grade_levels_select:SELECT'),
  ('grade_levels.grade_levels_update:UPDATE'), ('groups.groups_tenant_insert:INSERT'), ('groups.groups_tenant_select:SELECT'),
  ('groups.groups_tenant_update:UPDATE'), ('guardians.guardians_select:SELECT'), ('guardians.guardians_update:UPDATE'),
  ('identity_scopes.identity_scopes_tenant_select:SELECT'), ('membership_roles.membership_roles_delete:DELETE'), ('membership_roles.membership_roles_insert:INSERT'),
  ('membership_roles.membership_roles_select:SELECT'), ('membership_scopes.membership_scopes_delete:DELETE'), ('membership_scopes.membership_scopes_insert:INSERT'),
  ('membership_scopes.membership_scopes_select:SELECT'), ('memberships.memberships_select:SELECT'), ('permissions.permissions_select:SELECT'),
  ('platform_admin_assignments.platform_admin_assignments_self_select:SELECT'), ('platform_tenants.platform_tenants_tenant_select:SELECT'), ('platform_tenants.platform_tenants_tenant_update:UPDATE'),
  ('profiles.profiles_select:SELECT'), ('profiles.profiles_update:UPDATE'), ('role_permissions.role_permissions_delete:DELETE'),
  ('role_permissions.role_permissions_insert:INSERT'), ('role_permissions.role_permissions_select:SELECT'), ('roles.roles_insert:INSERT'),
  ('roles.roles_select:SELECT'), ('roles.roles_update:UPDATE'), ('schools.schools_tenant_insert:INSERT'),
  ('schools.schools_tenant_select:SELECT'), ('schools.schools_tenant_update:UPDATE'), ('sections.sections_insert:INSERT'),
  ('sections.sections_select:SELECT'), ('sections.sections_update:UPDATE'), ('staff.staff_select:SELECT'),
  ('subjects.subjects_insert:INSERT'), ('subjects.subjects_select:SELECT'), ('subjects.subjects_update:UPDATE'),   -- M39
  ('grade_subjects.grade_subjects_insert:INSERT'), ('grade_subjects.grade_subjects_select:SELECT'), ('grade_subjects.grade_subjects_update:UPDATE'),
  ('calendar_weekdays.calendar_weekdays_select:SELECT'),   -- M41
  ('calendar_exceptions.calendar_exceptions_insert:INSERT'), ('calendar_exceptions.calendar_exceptions_select:SELECT'), ('calendar_exceptions.calendar_exceptions_update:UPDATE'),
  ('staff.staff_update:UPDATE'), ('staff_school_assignments.staff_school_assignments_insert:INSERT'), ('staff_school_assignments.staff_school_assignments_select:SELECT'),
  ('staff_school_assignments.staff_school_assignments_update:UPDATE'), ('stages.stages_insert:INSERT'), ('stages.stages_select:SELECT'),
  ('stages.stages_update:UPDATE'), ('student_guardians.student_guardians_insert:INSERT'), ('student_guardians.student_guardians_select:SELECT'),
  ('student_guardians.student_guardians_update:UPDATE'), ('students.students_select:SELECT'), ('students.students_update:UPDATE'),
  ('system_users.system_users_self_select:SELECT'), ('terms.terms_insert:INSERT'), ('terms.terms_select:SELECT'),
  ('terms.terms_update:UPDATE');

create temp table expected_triggers (t text primary key) on commit drop;
insert into expected_triggers values
  ('academic_years.audit:tg_audit:AFTER INSERT OR DELETE OR UPDATE'), ('academic_years.stamp:tg_stamp:BEFORE INSERT OR UPDATE'),
  ('academic_years.guard:tg_academic_year_guard:BEFORE UPDATE'),   -- T10 (M33)
  ('terms.guard:tg_term_guard:BEFORE INSERT OR UPDATE'),           -- T11 (M34)
  ('sections.guard:tg_section_guard:BEFORE INSERT OR UPDATE'), ('grade_levels.guard:tg_grade_level_guard:BEFORE INSERT OR UPDATE'),   -- T12 (M35)
  ('stages.guard:tg_stage_guard:BEFORE UPDATE'),                   -- T12 (M35)
  ('subjects.audit:tg_audit:AFTER INSERT OR DELETE OR UPDATE'), ('subjects.stamp:tg_stamp:BEFORE INSERT OR UPDATE'), ('subjects.guard:tg_subject_guard:BEFORE UPDATE'),   -- M39 (T13)
  ('grade_subjects.audit:tg_audit:AFTER INSERT OR DELETE OR UPDATE'), ('grade_subjects.stamp:tg_stamp:BEFORE INSERT OR UPDATE'), ('grade_subjects.guard:tg_grade_subject_guard:BEFORE INSERT OR UPDATE'),
  ('calendar_weekdays.audit:tg_audit:AFTER INSERT OR DELETE OR UPDATE'), ('calendar_weekdays.stamp:tg_stamp:BEFORE INSERT OR UPDATE'), ('calendar_weekdays.guard:tg_calendar_weekday_guard:BEFORE INSERT OR UPDATE'),   -- M41 (T14)
  ('calendar_exceptions.audit:tg_audit:AFTER INSERT OR DELETE OR UPDATE'), ('calendar_exceptions.stamp:tg_stamp:BEFORE INSERT OR UPDATE'), ('calendar_exceptions.guard:tg_calendar_exception_guard:BEFORE INSERT OR UPDATE'),
  ('audit_log.audit_log_immutable:tg_reject_mutation:BEFORE DELETE OR UPDATE'), ('audit_log.audit_log_no_truncate:tg_reject_mutation:BEFORE TRUNCATE'),
  ('auth_identities.audit:tg_audit:AFTER INSERT OR DELETE OR UPDATE'), ('auth_identities.stamp:tg_stamp:BEFORE INSERT OR UPDATE'),
  ('enrollments.audit:tg_audit:AFTER INSERT OR DELETE OR UPDATE'), ('enrollments.stamp:tg_stamp:BEFORE INSERT OR UPDATE'),
  ('families.audit:tg_audit:AFTER INSERT OR DELETE OR UPDATE'), ('families.stamp:tg_stamp:BEFORE INSERT OR UPDATE'),
  ('grade_levels.audit:tg_audit:AFTER INSERT OR DELETE OR UPDATE'), ('grade_levels.stamp:tg_stamp:BEFORE INSERT OR UPDATE'),
  ('groups.audit:tg_audit:AFTER INSERT OR DELETE OR UPDATE'), ('groups.create_identity_scope:tg_create_identity_scope:AFTER INSERT'),
  ('groups.stamp:tg_stamp:BEFORE INSERT OR UPDATE'), ('guardians.audit:tg_audit:AFTER INSERT OR DELETE OR UPDATE'),
  ('guardians.stamp:tg_stamp:BEFORE INSERT OR UPDATE'), ('identity_scopes.audit:tg_audit:AFTER INSERT OR DELETE OR UPDATE'),
  ('identity_scopes.stamp:tg_stamp:BEFORE INSERT OR UPDATE'), ('membership_roles.audit:tg_audit:AFTER INSERT OR DELETE OR UPDATE'),
  ('membership_roles.authz_integrity:tg_authz_integrity:AFTER INSERT OR DELETE'), ('membership_roles.stamp:tg_stamp:BEFORE INSERT OR UPDATE'),
  ('membership_scopes.audit:tg_audit:AFTER INSERT OR DELETE OR UPDATE'), ('membership_scopes.authz_integrity:tg_authz_integrity:AFTER INSERT'),
  ('membership_scopes.stamp:tg_stamp:BEFORE INSERT OR UPDATE'), ('memberships.audit:tg_audit:AFTER INSERT OR DELETE OR UPDATE'),
  ('memberships.stamp:tg_stamp:BEFORE INSERT OR UPDATE'), ('permissions.audit:tg_audit:AFTER INSERT OR DELETE OR UPDATE'),
  ('permissions.stamp:tg_stamp:BEFORE INSERT OR UPDATE'), ('platform_admin_assignments.audit:tg_audit:AFTER INSERT OR DELETE OR UPDATE'),
  ('platform_admin_assignments.stamp:tg_stamp:BEFORE INSERT OR UPDATE'), ('platform_admin_role_permissions.audit:tg_audit:AFTER INSERT OR DELETE OR UPDATE'),
  ('platform_admin_roles.audit:tg_audit:AFTER INSERT OR DELETE OR UPDATE'), ('platform_admin_roles.stamp:tg_stamp:BEFORE INSERT OR UPDATE'),
  ('platform_tenants.audit:tg_audit:AFTER INSERT OR DELETE OR UPDATE'), ('platform_tenants.stamp:tg_stamp:BEFORE INSERT OR UPDATE'),
  ('profiles.audit:tg_audit:AFTER INSERT OR DELETE OR UPDATE'), ('profiles.stamp:tg_stamp:BEFORE INSERT OR UPDATE'),
  ('role_permissions.audit:tg_audit:AFTER INSERT OR DELETE OR UPDATE'), ('role_permissions.authz_integrity:tg_authz_integrity:AFTER INSERT OR DELETE'),
  ('roles.audit:tg_audit:AFTER INSERT OR DELETE OR UPDATE'), ('roles.stamp:tg_stamp:BEFORE INSERT OR UPDATE'),
  ('schools.audit:tg_audit:AFTER INSERT OR DELETE OR UPDATE'), ('schools.create_identity_scope:tg_create_identity_scope:AFTER INSERT'),
  ('schools.stamp:tg_stamp:BEFORE INSERT OR UPDATE'), ('sections.audit:tg_audit:AFTER INSERT OR DELETE OR UPDATE'),
  ('sections.stamp:tg_stamp:BEFORE INSERT OR UPDATE'), ('staff.audit:tg_audit:AFTER INSERT OR DELETE OR UPDATE'),
  ('staff.stamp:tg_stamp:BEFORE INSERT OR UPDATE'), ('staff_school_assignments.audit:tg_audit:AFTER INSERT OR DELETE OR UPDATE'),
  ('staff_school_assignments.stamp:tg_stamp:BEFORE INSERT OR UPDATE'), ('stages.audit:tg_audit:AFTER INSERT OR DELETE OR UPDATE'),
  ('stages.stamp:tg_stamp:BEFORE INSERT OR UPDATE'), ('student_guardians.audit:tg_audit:AFTER INSERT OR DELETE OR UPDATE'),
  ('student_guardians.stamp:tg_stamp:BEFORE INSERT OR UPDATE'), ('students.audit:tg_audit:AFTER INSERT OR DELETE OR UPDATE'),
  ('students.stamp:tg_stamp:BEFORE INSERT OR UPDATE'), ('system_users.audit:tg_audit:AFTER INSERT OR DELETE OR UPDATE'),
  ('system_users.stamp:tg_stamp:BEFORE INSERT OR UPDATE'), ('terms.audit:tg_audit:AFTER INSERT OR DELETE OR UPDATE'),
  ('terms.stamp:tg_stamp:BEFORE INSERT OR UPDATE');

-- sig | owner | definer/invoker | search_path | من يملك EXECUTE غير المالك
create temp table expected_functions (f text primary key) on commit drop;
insert into expected_functions values
  ('activate_academic_year(uuid,text)|app_owner|definer|app, public, pg_temp|authenticated'),
  ('activate_term(uuid,text)|app_owner|definer|app, public, pg_temp|authenticated'),   -- M34
  ('close_term(uuid,text)|app_owner|definer|app, public, pg_temp|authenticated'),      -- M34
  ('copy_sections(uuid,uuid,text)|app_owner|definer|app, public, pg_temp|authenticated'),   -- M37
  ('copy_grade_subjects(uuid,uuid,text)|app_owner|definer|app, public, pg_temp|authenticated'),   -- M40
  ('tg_subject_guard()|app_owner|definer|app, public, pg_temp|-'), ('tg_grade_subject_guard()|app_owner|definer|app, public, pg_temp|-'),   -- T13 (M39)
  ('set_calendar_weekdays(uuid,smallint[],text)|app_owner|definer|app, public, pg_temp|authenticated'),   -- M41
  ('copy_calendar_weekdays(uuid,uuid,text)|app_owner|definer|app, public, pg_temp|authenticated'),        -- M42
  ('school_today(uuid)|app_owner|invoker|app, public, pg_temp|-'), ('is_school_day(uuid,date)|app_owner|invoker|app, public, pg_temp|-'),   -- M41: داخليتان
  ('tg_calendar_exception_guard()|app_owner|definer|app, public, pg_temp|-'), ('tg_calendar_weekday_guard()|app_owner|definer|app, public, pg_temp|-'),   -- T14 (M41)
  ('tg_term_guard()|app_owner|definer|app, public, pg_temp|-'),                        -- T11 (M34)
  ('tg_section_guard()|app_owner|definer|app, public, pg_temp|-'), ('tg_grade_level_guard()|app_owner|definer|app, public, pg_temp|-'),   -- T12 (M35)
  ('tg_stage_guard()|app_owner|definer|app, public, pg_temp|-'),                       -- T12 (M35)
  ('activate_first_login()|app_owner|definer|app, public, pg_temp|authenticated'),
  ('archive_group(uuid,text)|app_owner|definer|app, public, pg_temp|authenticated'),
  ('archive_guardian(uuid,text)|app_owner|definer|app, public, pg_temp|authenticated'),
  ('archive_school(uuid,text)|app_owner|definer|app, public, pg_temp|authenticated'),
  ('archive_student(uuid,text)|app_owner|definer|app, public, pg_temp|authenticated'),
  ('arm_first_login(uuid)|app_owner|definer|app, public, pg_temp|authenticated'),
  ('arm_guardian_temporary_password(uuid)|app_owner|definer|app, public, pg_temp|authenticated'),
  ('auth_password_changed_by_self_after(uuid,timestamp with time zone)|postgres|definer|""|app_owner'),
  ('auth_uid()|postgres|definer|""|app_owner'),
  ('auth_user_updated_at(uuid)|postgres|definer|""|app_owner'),
  ('begin_guardian_temporary_password(uuid)|app_owner|definer|app, public, pg_temp|authenticated'),
  ('bootstrap_tenant(uuid,text,text,text,uuid,text)|app_owner|definer|app, public, pg_temp|authenticated'),
  ('can_access_group(uuid)|app_owner|definer|app, public, pg_temp|authenticated'),
  ('can_access_identity_scope(uuid)|app_owner|definer|app, public, pg_temp|authenticated'),
  ('can_access_school(uuid)|app_owner|definer|app, public, pg_temp|authenticated'),
  ('can_access_tenant(uuid)|app_owner|definer|app, public, pg_temp|authenticated'),
  ('can_manage_membership(uuid)|app_owner|definer|app, public, pg_temp|authenticated'),
  ('can_see_membership(uuid)|app_owner|definer|app, public, pg_temp|authenticated'),
  ('close_academic_year(uuid,text)|app_owner|definer|app, public, pg_temp|authenticated'),
  ('close_enrollment(uuid,text,date,text)|app_owner|definer|app, public, pg_temp|authenticated'),
  ('current_guardian_id()|app_owner|definer|app, public, pg_temp|authenticated'),
  ('current_profile_id()|app_owner|definer|app, public, pg_temp|authenticated'),
  ('current_security_context()|app_owner|definer|app, public, pg_temp|-'),
  ('current_system_user_id()|app_owner|definer|app, public, pg_temp|authenticated'),
  ('current_tenant_id()|app_owner|definer|app, public, pg_temp|authenticated'),
  ('end_membership(uuid,text)|app_owner|definer|app, public, pg_temp|authenticated'),
  ('end_staff_assignment(uuid,date,text)|app_owner|definer|app, public, pg_temp|authenticated'),
  ('family_in_scope(uuid)|app_owner|definer|app, public, pg_temp|authenticated'),
  ('guardian_account_for_issue(uuid)|app_owner|definer|app, public, pg_temp|-'),
  ('guardian_in_scope(uuid)|app_owner|definer|app, public, pg_temp|authenticated'),
  ('guardian_onboarding_mode(uuid,text)|app_owner|definer|app, public, pg_temp|-'),
  ('has_permission(text)|app_owner|definer|app, public, pg_temp|authenticated'),
  ('has_platform_permission(text)|app_owner|definer|app, public, pg_temp|authenticated'),
  ('is_platform_admin()|app_owner|definer|app, public, pg_temp|-'),
  ('login_account(text,text,text,text)|app_owner|definer|app, public, pg_temp|-'),
  ('login_context(text,text)|app_owner|definer|app, public, pg_temp|-'),
  ('login_outcome(text,uuid,boolean,text)|app_owner|definer|app, public, pg_temp|-'),
  ('membership_id_of(uuid)|app_owner|definer|app, public, pg_temp|authenticated'),
  ('my_permissions()|app_owner|definer|app, public, pg_temp|authenticated'),
  ('new_tenant_account(uuid,uuid,text)|app_owner|definer|app, public, pg_temp|-'),
  ('next_temporary_id()|app_owner|invoker|app, pg_temp|-'),
  ('otp_issue(text,text,text,text)|app_owner|definer|app, public, pg_temp|service_role'),
  ('otp_verify(text,text,text,text,text)|app_owner|definer|app, public, pg_temp|service_role'),
  ('password_login_account(text,text,text,text)|app_owner|definer|app, public, pg_temp|service_role'),
  ('password_login_result(text,text,text,boolean,text)|app_owner|definer|app, public, pg_temp|service_role'),
  ('platform_read_tenants(uuid)|app_owner|definer|app, public, pg_temp|authenticated'),
  ('provision_account(text,uuid,uuid)|app_owner|definer|app, public, pg_temp|authenticated'),
  ('provision_guardian(uuid,uuid,text,text,text,text,date,text,text,text,text,text,boolean)|app_owner|definer|app, public, pg_temp|authenticated'),
  ('provision_staff(uuid,uuid,text,text,text,text,date,text,text,text,text,text,text,date,date)|app_owner|definer|app, public, pg_temp|authenticated'),
  ('provision_student(uuid,uuid,uuid,date,text,text,text,text,text,text,text,date,text,uuid,text,text)|app_owner|definer|app, public, pg_temp|authenticated'),
  ('reactivate_tenant(uuid,text)|app_owner|definer|app, public, pg_temp|authenticated'),
  ('require_reason(text)|app_owner|invoker|app, public, pg_temp|-'),
  ('resolve_student_login(text,text,text)|app_owner|definer|app, public, pg_temp|service_role'),
  ('set_audit_context(text,text)|app_owner|definer|app, public, pg_temp|-'),
  ('set_guardian_first_login_mode(uuid,text,text)|app_owner|definer|app, public, pg_temp|authenticated'),
  ('set_school_slug(uuid,text,text)|app_owner|definer|app, public, pg_temp|authenticated'),   -- M36
  ('set_role_status(uuid,text,text)|app_owner|definer|app, public, pg_temp|authenticated'),
  ('set_staff_status(uuid,text,text,date)|app_owner|definer|app, public, pg_temp|authenticated'),
  ('staff_in_scope(uuid)|app_owner|definer|app, public, pg_temp|authenticated'),
  ('student_in_scope(uuid)|app_owner|definer|app, public, pg_temp|authenticated'),
  ('student_is_self(uuid)|app_owner|definer|app, public, pg_temp|authenticated'),
  ('student_linked_to_guardian(uuid)|app_owner|definer|app, public, pg_temp|authenticated'),
  ('suspend_tenant(uuid,text)|app_owner|definer|app, public, pg_temp|authenticated'),
  ('system_role_id(text)|app_owner|definer|app, public, pg_temp|-'),
  ('tg_audit()|app_owner|definer|app, public, pg_temp|-'),
  ('tg_academic_year_guard()|app_owner|invoker|app, public, pg_temp|-'),   -- T10 (M33)
  ('tg_authz_integrity()|app_owner|definer|app, public, pg_temp|-'),
  ('tg_create_identity_scope()|app_owner|definer|app, public, pg_temp|-'),
  ('tg_reject_mutation()|app_owner|invoker|app, pg_temp|-'),
  ('tg_stamp()|app_owner|definer|app, pg_temp|-'),
  ('transfer_enrollment(uuid,uuid,date,text,text)|app_owner|definer|app, public, pg_temp|authenticated'),
  ('unlink_guardian(uuid,date,text)|app_owner|definer|app, public, pg_temp|authenticated');

select plan(10 + 4 + 2 + 3 + 5);

-- ---------- القسم 1 ----------
select ok((select v from r where k = 'i3.school_code')  like 'ERR 23514%schools_school_code_chk%', 'I3: school_code format enforced');
select ok((select v from r where k = 'i4.family')       like 'ERR 23514%families_archived_chk%',   'I4: an archived family requires archived_at');
select ok((select v from r where k = 'i4.guardian')     like 'ERR 23514%guardians_archived_chk%',  'I4: an archived guardian requires archived_at');
select ok((select v from r where k = 'i4.student')      like 'ERR 23514%students_archived_chk%',   'I4: an archived student requires archived_at');
select ok((select v from r where k = 'i9.forged_flag')  like 'ERR 23514%identity_scopes_standalone_chk%',
          'I9: the standalone flag cannot be forged to give a grouped school its own scope');
select ok((select v from r where k = 'i11.kind')        like 'ERR 23514%auth_identities_kind_chk%', 'I11: an identity is tenant or platform — nothing else');
select ok((select v from r where k = 'i15.group')       like 'ERR 23503%membership_scopes_group_fk%', 'I15: a scope cannot reference a group of another tenant');
select ok((select v from r where k = 'i15.membership')  like 'ERR 23503%membership_scopes_membership_fk%', 'I15: a scope carries the tenant of its membership');
select ok((select v from r where k = 'i23.guardian')    like 'ERR 23505%guardians_profile_uq%', 'I23: one account ↔ one guardian');
select ok((select v from r where k = 'i27.student')     like 'ERR 23503%student_guardians_student_fk%', 'I27: a guardian link cannot reference a student of another tenant');

-- ---------- السياسات ----------
select is((select count(*)::int from expected_policies), 71, 'the reviewed policy list has 71 policies (61 + 6 for subjects, M39 + 4 for the calendar, M41)');
select set_eq($q$select tablename || '.' || policyname || ':' || cmd from pg_policies where schemaname in ('public', 'app')$q$,
              'select p from expected_policies', 'policies: exactly the reviewed set — none added, none dropped, no command changed');
select is((select count(*)::int from pg_policies where schemaname = 'public' and (roles <> '{authenticated}' or permissive <> 'PERMISSIVE')), 0,
          'every policy is PERMISSIVE and TO authenticated only (no anon, no PUBLIC, no service path)');
select is((select string_agg(c.relname, ',' order by c.relname) from pg_class c where c.relnamespace = 'public'::regnamespace and c.relkind = 'r'
            and not exists (select 1 from pg_policies p where p.schemaname = 'public' and p.tablename = c.relname)),
          'auth_identities,login_challenges,platform_admin_role_permissions,platform_admin_roles',
          'tables with no client policy at all: the four documented service/controlled-only tables');

-- ---------- الـtriggers ----------
select set_eq($q$select c.relname || '.' || t.tgname || ':' || replace(t.tgfoid::regproc::text, 'app.', '') || ':' ||
                        substring(pg_get_triggerdef(t.oid) from 'TRIGGER \S+ (.*?) ON ')
                   from pg_trigger t join pg_class c on c.oid = t.tgrelid
                  where c.relnamespace = 'public'::regnamespace and not t.tgisinternal$q$,
              'select t from expected_triggers', 'triggers: exactly T5 (audit_log), T6 stamp, T7 audit, T8 authz_integrity, T9 identity scope, T10 year guard, T11 term guard, T12 structure guards, T13 subject guards, T14 calendar guards — same tables, same events');
select is((select count(*)::int from pg_trigger t join pg_class c on c.oid = t.tgrelid
            where c.relnamespace = 'public'::regnamespace and not t.tgisinternal and t.tgenabled <> 'O'), 0, 'no trigger is disabled');

-- ---------- عقود الدوال ----------
select is((select count(*)::int from expected_functions), 89, 'the reviewed function list has 89 functions (83 + 6 for the calendar, M41/M42)');
select set_eq($q$select substr(p.oid::regprocedure::text, 5) || '|' || pg_get_userbyid(p.proowner) || '|' ||
                        case when p.prosecdef then 'definer' else 'invoker' end || '|' ||
                        replace(coalesce(array_to_string(p.proconfig, ','), ''), 'search_path=', '') || '|' ||
                        coalesce((select string_agg(a.grantee::regrole::text, '+' order by a.grantee::regrole::text)
                                    from aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
                                   where a.privilege_type = 'EXECUTE' and a.grantee <> p.proowner), '-')
                   from pg_proc p where p.pronamespace = 'app'::regnamespace$q$,
              'select f from expected_functions',
              'functions: signature, owner, SECURITY DEFINER, pinned search_path and EXECUTE grantees — exactly the reviewed contracts');
select is((select count(*)::int from pg_proc p where p.pronamespace = 'app'::regnamespace
            and exists (select 1 from aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a where a.grantee = 0 and a.privilege_type = 'EXECUTE')), 0,
          'no function in app is executable by PUBLIC');

-- ---------- السطح خارج العقود ----------
select is((select count(*)::int from pg_proc p where p.pronamespace = 'public'::regnamespace
            and not exists (select 1 from pg_depend d where d.objid = p.oid and d.deptype = 'e')), 0,
          'no function lives in the exposed schema public (PostgREST RPC surface is empty)');
select is((select count(*)::int from pg_class c where c.relnamespace in ('public'::regnamespace, 'app'::regnamespace) and c.relkind in ('v', 'm', 'f', 'p')
            and not exists (select 1 from pg_depend d where d.objid = c.oid and d.deptype = 'e')), 0,
          'no views, materialized views, foreign or partitioned tables in public/app');
select is((select count(*)::int from pg_class c where c.relnamespace = 'app'::regnamespace and c.relkind = 'r'), 0, 'schema app holds no tables');
-- المواصفة §3.4 (M32/C3): كل FK له فهرس يبدأ بأعمدته (فهرس جزئي يُقبل إن كان شرطه «عمود الـFK IS NOT NULL»)؛
-- الاستثناء الموثق الوحيد: FK الهوية (auth_user_id, identity_kind) — UNIQUE (auth_user_id) يحدد صفاً واحداً
select is((with fk as (select k.conrelid, k.conname, k.conkey from pg_constraint k
                        where k.connamespace = 'public'::regnamespace and k.contype = 'f')
           select coalesce(string_agg(fk.conrelid::regclass::text || '.' || fk.conname, ',' order by fk.conrelid::regclass::text, fk.conname), 'none') from fk
            where not exists (
              select 1 from pg_index i
               where i.indrelid = fk.conrelid
                 and (select array_agg(x order by x) from unnest((string_to_array(i.indkey::text, ' ')::int2[])[1:cardinality(fk.conkey)]) x)
                   = (select array_agg(x order by x) from unnest(fk.conkey) x)
                 and (i.indpred is null
                      or exists (select 1 from unnest(fk.conkey) c(att) join pg_attribute a on a.attrelid = fk.conrelid and a.attnum = c.att
                                  where pg_get_expr(i.indpred, i.indrelid) = '(' || a.attname || ' IS NOT NULL)')))),
          'profiles.profiles_identity_fk,system_users.system_users_identity_fk',
          'every FK has an index leading with its columns — except the documented identity FK covered by UNIQUE (auth_user_id)');
select ok(not has_schema_privilege('anon', 'app', 'USAGE') and not has_schema_privilege('anon', 'app', 'CREATE')
      and not has_schema_privilege('authenticated', 'app', 'CREATE') and not has_schema_privilege('authenticated', 'public', 'CREATE')
      and not has_schema_privilege('anon', 'public', 'CREATE') and not has_schema_privilege('service_role', 'public', 'CREATE'),
          'schemas: anon cannot reach app; no API role can create objects in public or app');

select * from finish();
rollback;
