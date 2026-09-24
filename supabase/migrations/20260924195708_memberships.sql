-- M07 — memberships
-- المرجع: docs/DB_IMPLEMENTATION_SPEC_v1.md §B10 (M07)، I12–I16؛ docs/DATA_DICTIONARY_v1.md §2.8، §2.12، §2.13؛
--         docs/RLS_MODEL_v1.md §2.2، §3 (مع تصحيح F1)
-- has_permission() و can_access_tenant/group/school() هنا — اعتمادياتها كلها جاهزة.
-- can_see_membership / can_manage_membership بعد جداول الهوية (M09).

-- ------------------------------------------------------------------
-- memberships — [T] (DD §2.8) — 1:1 مع profile (O1 + D9)
-- ------------------------------------------------------------------
create table public.memberships (
  id                 uuid        not null default gen_random_uuid(),
  platform_tenant_id uuid        not null,
  profile_id         uuid        not null,
  status             text        not null default 'active',
  ended_at           timestamptz,
  created_at         timestamptz not null default now(),
  created_by         uuid,
  updated_at         timestamptz not null default now(),
  updated_by         uuid,
  constraint memberships_pkey             primary key (id),
  constraint memberships_tenant_profile_uq unique (platform_tenant_id, profile_id),
  constraint memberships_profile_uq       unique (profile_id),                                  -- I12
  constraint memberships_id_tenant_uq     unique (id, platform_tenant_id),                      -- §0.6
  constraint memberships_profile_fk       foreign key (profile_id, platform_tenant_id)
                                            references public.profiles (id, platform_tenant_id),
  constraint memberships_status_chk       check (status in ('active', 'suspended', 'ended')),
  constraint memberships_ended_chk        check ((status = 'ended') = (ended_at is not null)),
  constraint memberships_created_by_fk    foreign key (created_by) references public.profiles (id),
  constraint memberships_updated_by_fk    foreign key (updated_by) references public.profiles (id)
);
create index memberships_active_profile_idx on public.memberships (profile_id) where status = 'active';   -- has_permission
create index memberships_created_by_idx     on public.memberships (created_by);
create index memberships_updated_by_idx     on public.memberships (updated_by);

-- ------------------------------------------------------------------
-- membership_roles (DD §2.12) — I16 إعلاني: الدور نظامي أو من Tenant العضوية (يحل محل T1)
--   T8 (M19) يفحص INSERT/DELETE.
-- ------------------------------------------------------------------
create table public.membership_roles (
  membership_id      uuid        not null,
  role_id            uuid        not null,
  platform_tenant_id uuid        not null,
  role_owner_key     uuid        not null,
  granted_at         timestamptz not null default now(),
  granted_by         uuid,
  constraint membership_roles_pkey           primary key (membership_id, role_id),
  constraint membership_roles_membership_fk  foreign key (membership_id, platform_tenant_id)
                                               references public.memberships (id, platform_tenant_id) on delete cascade,
  constraint membership_roles_role_fk        foreign key (role_id, role_owner_key)
                                               references public.roles (id, owner_key),            -- I16
  constraint membership_roles_owner_chk      check (role_owner_key in (platform_tenant_id, '00000000-0000-0000-0000-000000000000'::uuid)),
  constraint membership_roles_granted_by_fk  foreign key (granted_by) references public.profiles (id)
);
create index membership_roles_role_idx        on public.membership_roles (role_id, role_owner_key);     -- FK + T8
create index membership_roles_membership_idx  on public.membership_roles (membership_id, platform_tenant_id);
create index membership_roles_granted_by_idx  on public.membership_roles (granted_by);

-- ------------------------------------------------------------------
-- membership_scopes (DD §2.13) — أين تُستعمل الصلاحية، لا ما هي
--   I13 الشكل؛ I14 NULLS NOT DISTINCT (D8)؛ I15 كل مرجع من Tenant العضوية
-- ------------------------------------------------------------------
create table public.membership_scopes (
  id                 uuid        not null default gen_random_uuid(),
  membership_id      uuid        not null,
  platform_tenant_id uuid        not null,
  scope_type         text        not null,
  group_id           uuid,
  school_id          uuid,
  created_at         timestamptz not null default now(),
  created_by         uuid,
  constraint membership_scopes_pkey          primary key (id),
  constraint membership_scopes_type_chk      check (scope_type in ('tenant', 'group', 'school')),
  constraint membership_scopes_shape_chk     check (                                              -- I13
       (scope_type = 'tenant' and group_id is null     and school_id is null)
    or (scope_type = 'group'  and group_id is not null and school_id is null)
    or (scope_type = 'school' and group_id is null     and school_id is not null)),
  constraint membership_scopes_uq            unique nulls not distinct
                                               (membership_id, scope_type, group_id, school_id),    -- I14
  constraint membership_scopes_membership_fk foreign key (membership_id, platform_tenant_id)
                                               references public.memberships (id, platform_tenant_id) on delete cascade,
  constraint membership_scopes_group_fk      foreign key (group_id, platform_tenant_id)
                                               references public.groups (id, platform_tenant_id),    -- I15
  constraint membership_scopes_school_fk     foreign key (school_id, platform_tenant_id)
                                               references public.schools (id, platform_tenant_id),   -- I15
  constraint membership_scopes_created_by_fk foreign key (created_by) references public.profiles (id)
);
create index membership_scopes_membership_type_idx on public.membership_scopes (membership_id, scope_type);  -- can_access_*
create index membership_scopes_membership_fk_idx   on public.membership_scopes (membership_id, platform_tenant_id);
create index membership_scopes_group_idx           on public.membership_scopes (group_id, platform_tenant_id);
create index membership_scopes_school_idx          on public.membership_scopes (school_id, platform_tenant_id);
create index membership_scopes_created_by_idx      on public.membership_scopes (created_by);

-- ------------------------------------------------------------------
-- T6 — ختم (granted_* في membership_roles، created_* في membership_scopes)
-- ------------------------------------------------------------------
create trigger stamp before insert or update on public.memberships       for each row execute function app.tg_stamp();
create trigger stamp before insert or update on public.membership_roles  for each row execute function app.tg_stamp();
create trigger stamp before insert or update on public.membership_scopes for each row execute function app.tg_stamp();

-- ------------------------------------------------------------------
-- RLS — مفعّل ومفروض من الإنشاء
-- ------------------------------------------------------------------
alter table public.memberships       enable row level security;
alter table public.memberships       force  row level security;
alter table public.membership_roles  enable row level security;
alter table public.membership_roles  force  row level security;
alter table public.membership_scopes enable row level security;
alter table public.membership_scopes force  row level security;

-- ------------------------------------------------------------------
-- دوال الصلاحية والنطاق — بهوية app_owner
-- ------------------------------------------------------------------
grant select on public.memberships, public.membership_roles, public.membership_scopes,
                public.roles, public.role_permissions, public.groups, public.schools to app_owner;

set local role app_owner;

-- سياق Tenant حصراً (G10، RLS_MODEL §2.2) — «هل يملك الصلاحية؟» لا «أين؟»
create function app.has_permission(p_code text)
returns boolean
language sql
stable
security definer
set search_path = app, public, pg_temp
as $$
  select app.current_security_context() = 'tenant'
     and exists (
       select 1
       from public.memberships m
       join public.membership_roles mr on mr.membership_id = m.id
       join public.roles r              on r.id = mr.role_id
       join public.role_permissions rp  on rp.role_id = mr.role_id
       join public.permissions perm     on perm.id = rp.permission_id
       where m.profile_id = app.current_profile_id()
         and m.status = 'active'
         and r.status = 'active'
         and perm.code = p_code
     );
$$;

-- F1: نطاق Tenant — لا مجرد عضوية في الـTenant.
--     العزل المجرد في السياسات = platform_tenant_id = (select app.current_tenant_id())
create function app.can_access_tenant(p_tenant_id uuid)
returns boolean
language sql
stable
security definer
set search_path = app, public, pg_temp
as $$
  select p_tenant_id is not null
     and p_tenant_id = app.current_tenant_id()
     and exists (
       select 1
       from public.memberships m
       join public.membership_scopes ms on ms.membership_id = m.id
       where m.profile_id = app.current_profile_id()
         and m.platform_tenant_id = p_tenant_id
         and m.status = 'active'
         and ms.scope_type = 'tenant'
     );
$$;

create function app.can_access_group(p_group_id uuid)
returns boolean
language sql
stable
security definer
set search_path = app, public, pg_temp
as $$
  select exists (
    select 1
    from public.memberships m
    join public.membership_scopes ms on ms.membership_id = m.id
    join public.groups g on g.id = p_group_id
    where m.profile_id = app.current_profile_id()
      and m.status = 'active'
      and g.platform_tenant_id = m.platform_tenant_id          -- عزل Tenant داخل الدالة
      and (   ms.scope_type = 'tenant'
           or (ms.scope_type = 'group' and ms.group_id = g.id))
  );
$$;

create function app.can_access_school(p_school_id uuid)
returns boolean
language sql
stable
security definer
set search_path = app, public, pg_temp
as $$
  select exists (
    select 1
    from public.memberships m
    join public.membership_scopes ms on ms.membership_id = m.id
    join public.schools s on s.id = p_school_id
    where m.profile_id = app.current_profile_id()
      and m.status = 'active'
      and s.platform_tenant_id = m.platform_tenant_id          -- عزل Tenant داخل الدالة
      and (   ms.scope_type = 'tenant'
           or (ms.scope_type = 'group'  and s.group_id is not null and ms.group_id = s.group_id)
           or (ms.scope_type = 'school' and ms.school_id = s.id))
  );
$$;

reset role;
