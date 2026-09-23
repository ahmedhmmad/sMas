-- M04 — tenancy
-- المرجع: docs/DB_IMPLEMENTATION_SPEC_v1.md §B10 (M04)، §3.1 (I1–I9)، G3، G9؛
--         docs/DATA_DICTIONARY_v1.md §2.2، §2.3، §2.16.1، §2.16.2
-- RLS مفعّل ومفروض عند الإنشاء (انظر M03)؛ السياسات في M14.

-- ------------------------------------------------------------------
-- groups — [T] (DD §2.2)
-- ------------------------------------------------------------------
create table public.groups (
  id                 uuid        not null default gen_random_uuid(),
  platform_tenant_id uuid        not null,
  group_code         text        not null,
  name               text        not null,
  status             text        not null default 'active',
  created_at         timestamptz not null default now(),
  created_by         uuid,
  updated_at         timestamptz not null default now(),
  updated_by         uuid,
  constraint groups_pkey             primary key (id),
  constraint groups_tenant_code_uq   unique (platform_tenant_id, group_code),
  constraint groups_id_tenant_uq     unique (id, platform_tenant_id),                     -- §0.6
  constraint groups_tenant_fk        foreign key (platform_tenant_id) references public.platform_tenants (id),
  constraint groups_status_chk       check (status in ('active', 'inactive')),
  constraint groups_group_code_chk   check (group_code ~ '^[A-Z0-9][A-Z0-9_-]{1,31}$'),
  constraint groups_name_chk         check (length(btrim(name)) > 0),
  constraint groups_created_by_fk    foreign key (created_by) references public.profiles (id),
  constraint groups_updated_by_fk    foreign key (updated_by) references public.profiles (id)
);
create index groups_created_by_idx on public.groups (created_by);
create index groups_updated_by_idx on public.groups (updated_by);

-- ------------------------------------------------------------------
-- schools — [T] (DD §2.3)
--   is_standalone  (I9): هدف FK من identity_scopes — مدرسة داخل Group لا تملك نطاقاً خاصاً
--   scope_owner_id (G3): مالك نطاق الهوية الذي تنتمي إليه المدرسة — هدف FK من enrollments (M10)
-- ------------------------------------------------------------------
create table public.schools (
  id                 uuid        not null default gen_random_uuid(),
  platform_tenant_id uuid        not null,
  group_id           uuid,
  school_code        text        not null,
  name               text        not null,
  slug               text        not null,
  status             text        not null default 'active',
  timezone           text        not null default 'Africa/Cairo',
  is_standalone      boolean     generated always as (group_id is null) stored,
  scope_owner_id     uuid        generated always as (coalesce(group_id, id)) stored,
  archived_at        timestamptz,
  created_at         timestamptz not null default now(),
  created_by         uuid,
  updated_at         timestamptz not null default now(),
  updated_by         uuid,
  constraint schools_pkey               primary key (id),
  constraint schools_tenant_code_uq     unique (platform_tenant_id, school_code),
  constraint schools_tenant_slug_uq     unique (platform_tenant_id, slug),
  constraint schools_id_tenant_uq       unique (id, platform_tenant_id),                   -- §0.6
  constraint schools_id_standalone_uq   unique (id, is_standalone),                        -- I9
  constraint schools_id_scope_owner_uq  unique (id, scope_owner_id),                       -- G3
  constraint schools_tenant_fk          foreign key (platform_tenant_id) references public.platform_tenants (id),
  constraint schools_group_fk           foreign key (group_id, platform_tenant_id)
                                          references public.groups (id, platform_tenant_id),  -- I5
  constraint schools_status_chk         check (status in ('active', 'archived')),
  constraint schools_archived_chk       check ((status = 'archived') = (archived_at is not null)),
  constraint schools_slug_chk           check (slug ~ '^[a-z0-9][a-z0-9-]{1,62}$'),
  constraint schools_school_code_chk    check (school_code ~ '^[A-Z0-9][A-Z0-9_-]{1,31}$'),
  constraint schools_name_chk           check (length(btrim(name)) > 0),
  constraint schools_created_by_fk      foreign key (created_by) references public.profiles (id),
  constraint schools_updated_by_fk      foreign key (updated_by) references public.profiles (id)
);
create index schools_tenant_group_idx on public.schools (platform_tenant_id, group_id);      -- ERD §8
create index schools_group_idx        on public.schools (group_id, platform_tenant_id);       -- FK
create index schools_created_by_idx   on public.schools (created_by);
create index schools_updated_by_idx   on public.schools (updated_by);

-- ------------------------------------------------------------------
-- identity_scopes — [T] (DD §2.16.1، قرار A4)
--   نطاق تفرد هوية الطالب: Group أو مدرسة مستقلة. لا يكتبه أحد مباشرة — T9 وحده.
--   ⚠️ إضافة على DD: FK (school_id, platform_tenant_id) — قيد is_standalone وحده لا يضمن
--      أن المدرسة من نفس Tenant النطاق (نمط §0.6).
-- ------------------------------------------------------------------
create table public.identity_scopes (
  id                   uuid        not null default gen_random_uuid(),
  platform_tenant_id   uuid        not null,
  scope_kind           text        not null,
  group_id             uuid,
  school_id            uuid,
  school_is_standalone boolean     not null default true,
  owner_id             uuid        generated always as (coalesce(group_id, school_id)) stored,  -- G3
  created_at           timestamptz not null default now(),
  created_by           uuid,
  updated_at           timestamptz not null default now(),
  updated_by           uuid,
  constraint identity_scopes_pkey              primary key (id),
  constraint identity_scopes_id_tenant_uq      unique (id, platform_tenant_id),         -- §0.6
  constraint identity_scopes_id_owner_uq       unique (id, owner_id),                   -- G3
  constraint identity_scopes_kind_chk          check (scope_kind in ('group', 'school')),
  constraint identity_scopes_shape_chk         check (
       (scope_kind = 'group'  and group_id is not null and school_id is null)
    or (scope_kind = 'school' and school_id is not null and group_id is null)),
  constraint identity_scopes_standalone_chk    check (school_is_standalone),
  constraint identity_scopes_tenant_fk         foreign key (platform_tenant_id) references public.platform_tenants (id),
  constraint identity_scopes_group_fk          foreign key (group_id, platform_tenant_id)
                                                 references public.groups (id, platform_tenant_id),
  constraint identity_scopes_school_tenant_fk  foreign key (school_id, platform_tenant_id)
                                                 references public.schools (id, platform_tenant_id),
  constraint identity_scopes_school_standalone_fk foreign key (school_id, school_is_standalone)
                                                 references public.schools (id, is_standalone),   -- I9
  constraint identity_scopes_created_by_fk     foreign key (created_by) references public.profiles (id),
  constraint identity_scopes_updated_by_fk     foreign key (updated_by) references public.profiles (id)
);
-- I7: نطاق واحد على الأكثر لكل Group ولكل مدرسة مستقلة
create unique index identity_scopes_group_uq  on public.identity_scopes (group_id)  where group_id  is not null;
create unique index identity_scopes_school_uq on public.identity_scopes (school_id) where school_id is not null;
create index identity_scopes_group_tenant_idx      on public.identity_scopes (group_id, platform_tenant_id);
create index identity_scopes_school_tenant_idx     on public.identity_scopes (school_id, platform_tenant_id);
create index identity_scopes_school_standalone_idx on public.identity_scopes (school_id, school_is_standalone);
create index identity_scopes_tenant_idx            on public.identity_scopes (platform_tenant_id);
create index identity_scopes_created_by_idx        on public.identity_scopes (created_by);
create index identity_scopes_updated_by_idx        on public.identity_scopes (updated_by);

-- ------------------------------------------------------------------
-- T6 — ختم
-- ------------------------------------------------------------------
create trigger stamp before insert or update on public.groups          for each row execute function app.tg_stamp();
create trigger stamp before insert or update on public.schools         for each row execute function app.tg_stamp();
create trigger stamp before insert or update on public.identity_scopes for each row execute function app.tg_stamp();

-- ------------------------------------------------------------------
-- T9 — إنشاء نطاق الهوية تلقائياً (G9، I8)
--   AFTER INSERT on groups                     → نطاق group
--   AFTER INSERT on schools WHEN standalone    → نطاق school
--   الـinvariant «لكل Group ومدرسة مستقلة نطاق» لا يعتمد على مسار الإنشاء.
-- ------------------------------------------------------------------
grant insert on public.identity_scopes to app_owner;

set local role app_owner;

create function app.tg_create_identity_scope()
returns trigger
language plpgsql
security definer
set search_path = app, public, pg_temp
as $$
begin
  if tg_table_name = 'groups' then
    insert into public.identity_scopes (platform_tenant_id, scope_kind, group_id)
    values (new.platform_tenant_id, 'group', new.id);
  elsif tg_table_name = 'schools' then
    insert into public.identity_scopes (platform_tenant_id, scope_kind, school_id)
    values (new.platform_tenant_id, 'school', new.id);
  end if;
  return null;
end;
$$;

reset role;

create trigger create_identity_scope after insert on public.groups
  for each row execute function app.tg_create_identity_scope();
create trigger create_identity_scope after insert on public.schools
  for each row when (new.group_id is null) execute function app.tg_create_identity_scope();

-- ------------------------------------------------------------------
-- RLS — مفعّل ومفروض من الإنشاء
-- ------------------------------------------------------------------
alter table public.groups          enable row level security;
alter table public.groups          force  row level security;
alter table public.schools         enable row level security;
alter table public.schools         force  row level security;
alter table public.identity_scopes enable row level security;
alter table public.identity_scopes force  row level security;
