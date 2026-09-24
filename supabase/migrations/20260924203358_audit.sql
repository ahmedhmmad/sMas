-- M11 — audit
-- المرجع: docs/DB_IMPLEMENTATION_SPEC_v1.md §B7، §3.3 (T5، T7)، I44، I45؛ docs/DATA_DICTIONARY_v1.md §2.26
--
-- المبدأ: audit_log سجل مستقل للفاعل والحدث — لا بديل عن created_by/updated_by، ولا يعتمد عليها.
--   الفاعل يُحدَّد هنا مستقلاً: profile (tenant_user) ← system_user (platform_admin) ← system.
--   لذلك يُسجَّل Platform Admin بهويته الحقيقية حيث لا يستطيع created_by تمثيله (M05).
--
-- ملاحظات تنفيذية:
--   • source قيمة يؤثر فيها العميل وعليها CHECK: أي قيمة غير معروفة تصبح 'api' — كي لا تستطيع قيمة
--     مرسلة إفشال التدقيق ومعه الكتابة الأصلية.
--   • app.audit_action يُطبَّق على UPDATE فقط (تضبطه دوال انتقال الحالة قبل الكتابة، §5.3).
--   • T7 على 28 جدولاً: كل جداول Foundation عدا audit_log (auth_identities مشمول).

-- ------------------------------------------------------------------
-- audit_log — [A] (DD §2.26) — بلا FK عمداً: السجل يبقى صالحاً بعد أرشفة الكيان أو غيابه
-- ------------------------------------------------------------------
create table public.audit_log (
  id                 bigint      generated always as identity,
  platform_tenant_id uuid,
  school_id          uuid,
  actor_type         text        not null,
  actor_id           uuid,
  action             text        not null,
  entity_type        text        not null,
  entity_id          text        not null,
  old_values         jsonb,
  new_values         jsonb,
  reason             text,
  source             text        not null default 'api',
  ip_address         inet,
  created_at         timestamptz not null default now(),
  constraint audit_log_pkey            primary key (id),
  constraint audit_log_actor_type_chk  check (actor_type in ('tenant_user', 'platform_admin', 'system')),
  constraint audit_log_source_chk      check (source in ('web', 'mobile', 'api', 'system')),
  constraint audit_log_actor_chk       check (actor_type = 'system' or actor_id is not null)
);
create index audit_log_tenant_created_idx on public.audit_log (platform_tenant_id, created_at desc);   -- ERD §8
create index audit_log_entity_idx         on public.audit_log (entity_type, entity_id);                -- ERD §8
create index audit_log_actor_created_idx  on public.audit_log (actor_id, created_at desc);
create index audit_log_school_idx         on public.audit_log (school_id);

-- ------------------------------------------------------------------
-- الثبات (I44): الصلاحيات + T5. الصلاحيات وحدها لا تمنع مالك الجدول.
-- لا INSERT لـanon/authenticated: الكتابة عبر T7 (SECURITY DEFINER) أو FastAPI بـservice role (§7.4).
-- ------------------------------------------------------------------
revoke all on public.audit_log from anon, authenticated;
revoke update, delete, truncate on public.audit_log from service_role;

create trigger audit_log_immutable
  before update or delete on public.audit_log
  for each row execute function app.tg_reject_mutation();
create trigger audit_log_no_truncate
  before truncate on public.audit_log
  for each statement execute function app.tg_reject_mutation();

alter table public.audit_log enable row level security;
alter table public.audit_log force  row level security;

-- ------------------------------------------------------------------
-- T7 — التقاط التدقيق (I45)
-- ------------------------------------------------------------------
grant insert on public.audit_log to app_owner;

set local role app_owner;

create function app.tg_audit()
returns trigger
language plpgsql
security definer
set search_path = app, public, pg_temp
as $$
declare
  v_row        jsonb := case when tg_op = 'DELETE' then to_jsonb(old) else to_jsonb(new) end;
  v_profile    uuid  := app.current_profile_id();
  v_sysuser    uuid;
  v_actor_type text;
  v_actor_id   uuid;
  v_tenant     uuid;
  v_school     uuid;
  v_entity_id  text;
  v_action     text;
  v_source     text;
  v_ip         inet;
begin
  -- الفاعل — مستقل عن created_by
  if v_profile is not null then
    v_actor_type := 'tenant_user';    v_actor_id := v_profile;
  else
    v_sysuser := app.current_system_user_id();
    if v_sysuser is not null then
      v_actor_type := 'platform_admin'; v_actor_id := v_sysuser;
    else
      v_actor_type := 'system';         v_actor_id := null;
    end if;
  end if;

  -- الكيان
  v_entity_id := coalesce(
    v_row ->> 'id',
    v_row ->> 'auth_user_id',                                                        -- auth_identities
    case tg_table_name
      when 'role_permissions'                then (v_row ->> 'role_id') || ':' || (v_row ->> 'permission_id')
      when 'platform_admin_role_permissions' then (v_row ->> 'platform_admin_role_id') || ':' || (v_row ->> 'permission_id')
      when 'membership_roles'                then (v_row ->> 'membership_id') || ':' || (v_row ->> 'role_id')
    end);

  -- النطاق: من أعمدة الصف؛ ثم الاشتقاق حيث لا عمود
  v_school := (v_row ->> 'school_id')::uuid;
  v_tenant := case tg_table_name
                when 'platform_tenants' then (v_row ->> 'id')::uuid
                else (v_row ->> 'platform_tenant_id')::uuid
              end;
  if v_tenant is null and v_school is not null then
    select s.platform_tenant_id into v_tenant from public.schools s where s.id = v_school;
  end if;
  if v_tenant is null and tg_table_name = 'role_permissions' then
    select r.platform_tenant_id into v_tenant from public.roles r where r.id = (v_row ->> 'role_id')::uuid;
  end if;

  -- الحدث والسياق (بيانات وصفية غير موثوقة — لا يُبنى عليها قرار أمني)
  v_action := case
                when tg_op = 'UPDATE' and nullif(current_setting('app.audit_action', true), '') is not null
                  then current_setting('app.audit_action', true)
                else lower(tg_op)
              end;
  v_source := nullif(current_setting('app.request_source', true), '');
  if v_source is null or v_source not in ('web', 'mobile', 'api', 'system') then
    v_source := 'api';
  end if;
  begin
    v_ip := nullif(btrim(split_part(
              (nullif(current_setting('request.headers', true), '')::jsonb) ->> 'x-forwarded-for', ',', 1)), '')::inet;
  exception when others then
    v_ip := null;
  end;

  insert into public.audit_log (platform_tenant_id, school_id, actor_type, actor_id, action,
                                entity_type, entity_id, old_values, new_values, reason, source, ip_address)
  values (v_tenant, v_school, v_actor_type, v_actor_id, v_action,
          tg_table_name, v_entity_id,
          case when tg_op in ('UPDATE', 'DELETE') then to_jsonb(old) end,
          case when tg_op in ('INSERT', 'UPDATE') then to_jsonb(new) end,
          nullif(current_setting('app.audit_reason', true), ''),
          v_source, v_ip);
  return null;
end;
$$;

reset role;

-- ------------------------------------------------------------------
-- ربط T7 بكل جداول Foundation (28)
-- ------------------------------------------------------------------
do $$
declare t text;
begin
  foreach t in array array[
    'auth_identities', 'platform_tenants', 'profiles',
    'groups', 'schools', 'identity_scopes',
    'system_users', 'platform_admin_roles', 'platform_admin_assignments',
    'permissions', 'roles', 'role_permissions', 'platform_admin_role_permissions',
    'memberships', 'membership_roles', 'membership_scopes',
    'academic_years', 'terms', 'stages', 'grade_levels', 'sections',
    'staff', 'staff_school_assignments', 'families', 'students', 'guardians', 'student_guardians',
    'enrollments'
  ] loop
    execute format('create trigger audit after insert or update or delete on public.%I for each row execute function app.tg_audit()', t);
  end loop;
end $$;
