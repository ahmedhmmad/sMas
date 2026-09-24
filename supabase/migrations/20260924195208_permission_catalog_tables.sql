-- M06 — permission_catalog_tables
-- المرجع: docs/DB_IMPLEMENTATION_SPEC_v1.md §B10 (M06)، I16–I18، C3، G10؛
--         docs/DATA_DICTIONARY_v1.md §2.5.1، §2.9–§2.11؛ docs/RLS_MODEL_v1.md §2.3
-- الجداول فقط؛ البيانات المرجعية (73 مفتاحاً، 10 أدوار، الخرائط) في M23.
-- has_permission() (سياق Tenant) في M07 — تحتاج memberships.

-- ------------------------------------------------------------------
-- permissions — [P] كتالوج عالمي (DD §2.10). يكتبه migrations فقط → بلا *_by.
-- ------------------------------------------------------------------
create table public.permissions (
  id           uuid        not null default gen_random_uuid(),
  code         text        not null,
  resource     text        not null,
  operation    text        not null,
  description  text        not null,
  is_sensitive boolean     not null default false,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  constraint permissions_pkey            primary key (id),
  constraint permissions_code_uq         unique (code),
  constraint permissions_code_parts_chk  check (code = resource || '.' || operation),             -- I18
  constraint permissions_code_format_chk check (code ~ '^[a-z][a-z0-9_]*\.[a-z][a-z0-9_]*$'),
  constraint permissions_description_chk check (length(btrim(description)) > 0)
);

-- ------------------------------------------------------------------
-- roles — [T / P] (DD §2.9)
--   platform_tenant_id NULL = دور نظام (قالب)؛ NOT NULL = دور مخصص للـTenant.
--   owner_key (I16): يحوّل NULL إلى مفتاح صفري قابل للمطابقة — هدف FK من membership_roles (M07).
-- ------------------------------------------------------------------
create table public.roles (
  id                 uuid        not null default gen_random_uuid(),
  platform_tenant_id uuid,
  code               text        not null,
  name               text        not null,
  description        text,
  is_system          boolean     not null default false,
  status             text        not null default 'active',
  owner_key          uuid        generated always as
                       (coalesce(platform_tenant_id, '00000000-0000-0000-0000-000000000000'::uuid)) stored,
  created_at         timestamptz not null default now(),
  created_by         uuid,
  updated_at         timestamptz not null default now(),
  updated_by         uuid,
  constraint roles_pkey             primary key (id),
  constraint roles_id_tenant_uq     unique (id, platform_tenant_id),                              -- §0.6
  constraint roles_id_owner_uq      unique (id, owner_key),                                       -- I16
  constraint roles_tenant_fk        foreign key (platform_tenant_id) references public.platform_tenants (id),
  constraint roles_is_system_chk    check (is_system = (platform_tenant_id is null)),             -- I17
  constraint roles_status_chk       check (status in ('active', 'inactive')),
  constraint roles_code_chk         check (code ~ '^[a-z][a-z0-9_]*$'),
  constraint roles_name_chk         check (length(btrim(name)) > 0),
  constraint roles_created_by_fk    foreign key (created_by) references public.profiles (id),
  constraint roles_updated_by_fk    foreign key (updated_by) references public.profiles (id)
);
create unique index roles_system_code_uq on public.roles (code)                     where platform_tenant_id is null;
create unique index roles_tenant_code_uq on public.roles (platform_tenant_id, code) where platform_tenant_id is not null;
create index roles_created_by_idx on public.roles (created_by);
create index roles_updated_by_idx on public.roles (updated_by);

-- ------------------------------------------------------------------
-- role_permissions (DD §2.11) — ربط صرف: CASCADE من الدور، RESTRICT من الصلاحية
--   T8 (M19) يفحص INSERT/DELETE هنا (F5).
-- ------------------------------------------------------------------
create table public.role_permissions (
  role_id       uuid not null,
  permission_id uuid not null,
  constraint role_permissions_pkey          primary key (role_id, permission_id),
  constraint role_permissions_role_fk       foreign key (role_id)       references public.roles (id)       on delete cascade,
  constraint role_permissions_permission_fk foreign key (permission_id) references public.permissions (id) on delete restrict
);
create index role_permissions_permission_idx on public.role_permissions (permission_id);

-- ------------------------------------------------------------------
-- platform_admin_role_permissions (DD §2.5.1، قرار C3) — نفس الكتالوج لسياق Platform
-- ------------------------------------------------------------------
create table public.platform_admin_role_permissions (
  platform_admin_role_id uuid not null,
  permission_id          uuid not null,
  constraint platform_admin_role_permissions_pkey          primary key (platform_admin_role_id, permission_id),
  constraint platform_admin_role_permissions_role_fk       foreign key (platform_admin_role_id)
                                                             references public.platform_admin_roles (id) on delete cascade,
  constraint platform_admin_role_permissions_permission_fk foreign key (permission_id)
                                                             references public.permissions (id) on delete restrict
);
create index platform_admin_role_permissions_permission_idx on public.platform_admin_role_permissions (permission_id);

-- ------------------------------------------------------------------
-- T6 — ختم (جداول الربط بلا أعمدة ختم)
-- ------------------------------------------------------------------
create trigger stamp before insert or update on public.permissions for each row execute function app.tg_stamp();
create trigger stamp before insert or update on public.roles       for each row execute function app.tg_stamp();

-- ------------------------------------------------------------------
-- RLS — مفعّل ومفروض من الإنشاء
-- ------------------------------------------------------------------
alter table public.permissions                     enable row level security;
alter table public.permissions                     force  row level security;
alter table public.roles                           enable row level security;
alter table public.roles                           force  row level security;
alter table public.role_permissions                enable row level security;
alter table public.role_permissions                force  row level security;
alter table public.platform_admin_role_permissions enable row level security;
alter table public.platform_admin_role_permissions force  row level security;

-- ------------------------------------------------------------------
-- has_platform_permission() — سياق Platform حصراً (G10، RLS_MODEL §2.3)
--   تفحص السياق أولاً: صلاحية Tenant لا تُرضي سياسة Platform بأي حال.
-- ------------------------------------------------------------------
grant select on public.permissions, public.platform_admin_role_permissions to app_owner;

set local role app_owner;

create function app.has_platform_permission(p_code text)
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
       join public.platform_admin_role_permissions parp
            on parp.platform_admin_role_id = paa.platform_admin_role_id
       join public.permissions perm on perm.id = parp.permission_id
       where paa.system_user_id = app.current_system_user_id()
         and paa.status = 'active'
         and perm.code = p_code
     );
$$;

reset role;
