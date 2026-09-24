-- M05 — platform_admin_identity
-- المرجع: docs/DB_IMPLEMENTATION_SPEC_v1.md §B10 (M05)، G8، G10؛ docs/DATA_DICTIONARY_v1.md §2.4–§2.6؛
--         docs/RLS_MODEL_v1.md §1.2، §2.1
--
-- ملاحظات تنفيذية:
--   • لا created_by/updated_by هنا (خلافاً لنص DD §2.4): T6 يكتبها من app.current_profile_id() — معرّف
--     profile في Tenant — بينما DD يربطها بـsystem_users. والكتابة هنا service role فقط (G8) حيث لا فاعل.
--     عمود دائم الفراغ يوحي بنسبة غير موجودة؛ الفاعل الموثوق في audit_log (T7). أعمدة الوقت باقية.
--   • current_security_context / current_system_user_id / is_platform_admin هنا (اعتمادياتها جاهزة)؛
--     has_platform_permission في M06 (تحتاج permissions).

-- ------------------------------------------------------------------
-- system_users — [P] (DD §2.4) — هوية مشغّل المنصة، ليست profile ولا ترتبط بأي Tenant
--   G10: identity_kind ثابت 'platform' + FK مركّب إلى auth_identities.
-- ------------------------------------------------------------------
create table public.system_users (
  id            uuid        not null default gen_random_uuid(),
  auth_user_id  uuid        not null,
  identity_kind text        not null default 'platform',
  display_name  text        not null,
  status        text        not null default 'active',
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  constraint system_users_pkey               primary key (id),
  constraint system_users_auth_user_uq       unique (auth_user_id),
  constraint system_users_auth_user_fk       foreign key (auth_user_id) references auth.users (id),
  constraint system_users_identity_fk        foreign key (auth_user_id, identity_kind)
                                               references public.auth_identities (auth_user_id, kind),   -- G10
  constraint system_users_identity_kind_chk  check (identity_kind = 'platform'),
  constraint system_users_status_chk         check (status in ('active', 'suspended')),
  constraint system_users_display_name_chk   check (length(btrim(display_name)) > 0)
);

-- ------------------------------------------------------------------
-- platform_admin_roles — [P] (DD §2.5)
-- ------------------------------------------------------------------
create table public.platform_admin_roles (
  id          uuid        not null default gen_random_uuid(),
  code        text        not null,
  name        text        not null,
  description text,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  constraint platform_admin_roles_pkey      primary key (id),
  constraint platform_admin_roles_code_uq   unique (code),
  constraint platform_admin_roles_code_chk  check (code ~ '^[a-z][a-z0-9_]*$'),
  constraint platform_admin_roles_name_chk  check (length(btrim(name)) > 0)
);

-- ------------------------------------------------------------------
-- platform_admin_assignments — [P] (DD §2.6)
-- ------------------------------------------------------------------
create table public.platform_admin_assignments (
  id                     uuid        not null default gen_random_uuid(),
  system_user_id         uuid        not null,
  platform_admin_role_id uuid        not null,
  status                 text        not null default 'active',
  granted_at             timestamptz not null default now(),
  revoked_at             timestamptz,
  created_at             timestamptz not null default now(),
  updated_at             timestamptz not null default now(),
  constraint platform_admin_assignments_pkey        primary key (id),
  constraint platform_admin_assignments_uq          unique (system_user_id, platform_admin_role_id),
  constraint platform_admin_assignments_user_fk     foreign key (system_user_id) references public.system_users (id),
  constraint platform_admin_assignments_role_fk     foreign key (platform_admin_role_id) references public.platform_admin_roles (id),
  constraint platform_admin_assignments_status_chk  check (status in ('active', 'revoked')),
  constraint platform_admin_assignments_revoked_chk check ((status = 'revoked') = (revoked_at is not null))
);
create index platform_admin_assignments_role_idx on public.platform_admin_assignments (platform_admin_role_id);

-- ------------------------------------------------------------------
-- T6 — ختم (أعمدة الوقت فقط؛ granted_at ثابت بعد الإدراج)
-- ------------------------------------------------------------------
create trigger stamp before insert or update on public.system_users               for each row execute function app.tg_stamp();
create trigger stamp before insert or update on public.platform_admin_roles       for each row execute function app.tg_stamp();
create trigger stamp before insert or update on public.platform_admin_assignments for each row execute function app.tg_stamp();

-- ------------------------------------------------------------------
-- RLS — مفعّل ومفروض من الإنشاء؛ الكتابة service role فقط (G8)
-- ------------------------------------------------------------------
alter table public.system_users               enable row level security;
alter table public.system_users               force  row level security;
alter table public.platform_admin_roles       enable row level security;
alter table public.platform_admin_roles       force  row level security;
alter table public.platform_admin_assignments enable row level security;
alter table public.platform_admin_assignments force  row level security;

-- ------------------------------------------------------------------
-- دوال الهوية للسياق الأمني (RLS_MODEL §1.2، §2.1) — بهوية app_owner، الفاعل عبر app.auth_uid()
-- ------------------------------------------------------------------
grant select on public.auth_identities, public.system_users, public.platform_admin_assignments to app_owner;

set local role app_owner;

-- 'tenant' | 'platform' | NULL — حصري بحكم PK في auth_identities (G10)
create function app.current_security_context()
returns text
language sql
stable
security definer
set search_path = app, public, pg_temp
as $$
  select ai.kind from public.auth_identities ai where ai.auth_user_id = app.auth_uid();
$$;

create function app.current_system_user_id()
returns uuid
language sql
stable
security definer
set search_path = app, public, pg_temp
as $$
  select su.id
  from public.system_users su
  where su.auth_user_id = app.auth_uid()
    and su.status = 'active';
$$;

-- اختبار هوية فقط — لا يمنح أي صلاحية (C3). يُقرن دائماً بـhas_platform_permission().
create function app.is_platform_admin()
returns boolean
language sql
stable
security definer
set search_path = app, public, pg_temp
as $$
  select app.current_security_context() = 'platform'
     and exists (
       select 1
       from public.platform_admin_assignments paa
       join public.system_users su on su.id = paa.system_user_id
       where su.auth_user_id = app.auth_uid()
         and su.status  = 'active'
         and paa.status = 'active'
     );
$$;

reset role;
