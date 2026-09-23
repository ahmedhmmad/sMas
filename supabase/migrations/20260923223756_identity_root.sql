-- M03 — identity_root
-- المرجع: docs/DB_IMPLEMENTATION_SPEC_v1.md §B10 (M03)، §4.4 (G10)؛ docs/DATA_DICTIONARY_v1.md §2.1، §2.7؛
--         docs/RLS_MODEL_v1.md §1.1، §4.5
--
-- ترتيب تنفيذي (لا قرار جديد):
--   • RLS يُفعَّل ويُفرض عند إنشاء كل جدول، لا في M13: صلاحيات Supabase الافتراضية تمنح anon و
--     authenticated صلاحية ALL على جداول public فور إنشائها. المنع الافتراضي يبقى حتى تأتي السياسات.
--   • app.current_profile_id() و app.current_tenant_id() هنا لا في M12: اعتمادياتهما (profiles،
--     app.auth_uid()) موجودة الآن، وT6 تستدعي الأولى عند كل إدراج.

-- ------------------------------------------------------------------
-- auth_identities — G10: حساب Auth واحد = سياق أمني واحد (tenant | platform)
--   المفتاح الأساسي على auth_user_id يجعل الحصرية إعلانية بلا race.
--   profiles و system_users (M05) يرتبطان به بـFK مركّب على (auth_user_id, kind).
-- ------------------------------------------------------------------
create table public.auth_identities (
  auth_user_id uuid        not null references auth.users (id),
  kind         text        not null,
  created_at   timestamptz not null default now(),
  constraint auth_identities_pkey      primary key (auth_user_id),
  constraint auth_identities_kind_chk  check (kind in ('tenant', 'platform')),
  constraint auth_identities_kind_uq   unique (auth_user_id, kind)
);

comment on table public.auth_identities is
  'G10: one security context per Auth user. PK on auth_user_id makes tenant/platform exclusive.';

-- ------------------------------------------------------------------
-- platform_tenants — [P] جذر العزل (DD §2.1)
-- ------------------------------------------------------------------
create table public.platform_tenants (
  id           uuid        not null default gen_random_uuid(),
  tenant_code  text        not null,
  name         text        not null,
  status       text        not null default 'active',
  suspended_at timestamptz,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  constraint platform_tenants_pkey             primary key (id),
  constraint platform_tenants_tenant_code_uq   unique (tenant_code),
  constraint platform_tenants_tenant_code_chk  check (tenant_code ~ '^[A-Z0-9][A-Z0-9_-]{1,31}$'),
  constraint platform_tenants_status_chk       check (status in ('active', 'suspended')),
  constraint platform_tenants_suspended_chk    check ((status = 'suspended') = (suspended_at is not null))
);

-- ------------------------------------------------------------------
-- profiles — [T] (DD §2.7)
--   O1: auth_user_id فريد عالمياً → app.current_tenant_id() حتمية.
--   G10: identity_kind ثابت 'tenant' + FK مركّب إلى auth_identities.
-- ------------------------------------------------------------------
create table public.profiles (
  id                 uuid        not null default gen_random_uuid(),
  platform_tenant_id uuid        not null,
  auth_user_id       uuid        not null,
  identity_kind      text        not null default 'tenant',
  display_name       text        not null,
  status             text        not null default 'active',
  created_at         timestamptz not null default now(),
  created_by         uuid,
  updated_at         timestamptz not null default now(),
  updated_by         uuid,
  constraint profiles_pkey                  primary key (id),
  constraint profiles_auth_user_uq          unique (auth_user_id),                        -- O1
  constraint profiles_tenant_auth_user_uq   unique (platform_tenant_id, auth_user_id),
  constraint profiles_id_tenant_uq          unique (id, platform_tenant_id),              -- §0.6
  constraint profiles_tenant_fk             foreign key (platform_tenant_id) references public.platform_tenants (id),
  constraint profiles_auth_user_fk          foreign key (auth_user_id) references auth.users (id),
  constraint profiles_identity_fk           foreign key (auth_user_id, identity_kind)
                                              references public.auth_identities (auth_user_id, kind),  -- G10
  constraint profiles_identity_kind_chk     check (identity_kind = 'tenant'),
  constraint profiles_status_chk            check (status in ('active', 'suspended', 'disabled')),
  constraint profiles_display_name_chk      check (length(btrim(display_name)) > 0),
  constraint profiles_created_by_fk         foreign key (created_by) references public.profiles (id),
  constraint profiles_updated_by_fk         foreign key (updated_by) references public.profiles (id)
);

create index profiles_created_by_idx on public.profiles (created_by);
create index profiles_updated_by_idx on public.profiles (updated_by);

-- ------------------------------------------------------------------
-- T6 — ختم
-- ------------------------------------------------------------------
create trigger stamp before insert or update on public.auth_identities  for each row execute function app.tg_stamp();
create trigger stamp before insert or update on public.platform_tenants for each row execute function app.tg_stamp();
create trigger stamp before insert or update on public.profiles         for each row execute function app.tg_stamp();

-- ------------------------------------------------------------------
-- RLS — مفعّل ومفروض من الإنشاء؛ لا سياسات بعد = منع كامل لأدوار الـAPI
-- ------------------------------------------------------------------
alter table public.auth_identities  enable row level security;
alter table public.auth_identities  force  row level security;
alter table public.platform_tenants enable row level security;
alter table public.platform_tenants force  row level security;
alter table public.profiles         enable row level security;
alter table public.profiles         force  row level security;

-- ------------------------------------------------------------------
-- دوال الهوية (RLS_MODEL §1.1) — تُنشأ بهوية app_owner وتقرأ الفاعل عبر app.auth_uid()
--   حتمية بقرار O1: profiles_auth_user_uq يضمن صفاً واحداً على الأكثر.
-- ------------------------------------------------------------------
grant select on public.profiles to app_owner;

set local role app_owner;

create function app.current_profile_id()
returns uuid
language sql
stable
security definer
set search_path = app, public, pg_temp
as $$
  select p.id
  from public.profiles p
  where p.auth_user_id = app.auth_uid()
    and p.status = 'active';
$$;

create function app.current_tenant_id()
returns uuid
language sql
stable
security definer
set search_path = app, public, pg_temp
as $$
  select p.platform_tenant_id
  from public.profiles p
  where p.auth_user_id = app.auth_uid()
    and p.status = 'active';
$$;

reset role;
