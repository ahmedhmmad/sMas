-- M09 — people
-- المرجع: docs/DB_IMPLEMENTATION_SPEC_v1.md §B10 (M09)، I22–I32، A4، G3، O2، O3، B6؛
--         docs/DATA_DICTIONARY_v1.md §0.4، §0.5، §2.14–§2.19
-- جداول الهوية (staff، families، students، guardians) بلا school_id — الوصول بالعلاقة (§1.1 بند 11).
-- الإنشاء عبر دوال M22 (G4)؛ RLS مفعّل ومفروض من الإنشاء؛ السياسات في M17.
--
-- ⚠️ تنفيذي — قطعة الاسم الرباعي (DD §0.4): صيغة full_name في DD تستعمل concat_ws، وهي STABLE
--    فيرفضها Postgres في عمود محسوب («generation expression is not immutable» — ثبت على PG 17.6).
--    المُنفَّذ: || مع coalesce، ثم regexp_replace و btrim كما في الأصل — الناتج نفسه بدوال IMMUTABLE.

-- ------------------------------------------------------------------
-- staff — [I] (DD §2.14) — لا school_id: وجود الموظف في Tenant لا يعني رؤيته لكل مدارسه
-- ------------------------------------------------------------------
create table public.staff (
  id                 uuid        not null default gen_random_uuid(),
  platform_tenant_id uuid        not null,
  profile_id         uuid,
  employee_code      text        not null,
  first_name         text        not null,
  father_name        text,
  grandfather_name   text,
  family_name        text        not null,
  full_name          text        generated always as (btrim(regexp_replace(
                       first_name || ' ' || coalesce(father_name, '') || ' ' ||
                       coalesce(grandfather_name, '') || ' ' || family_name, '\s+', ' ', 'g'))) stored,
  national_id        text,
  phone_e164         text,
  email              text,
  gender             text,
  birth_date         date,
  hire_date          date,
  status             text        not null default 'active',
  archived_at        timestamptz,
  created_at         timestamptz not null default now(),
  created_by         uuid,
  updated_at         timestamptz not null default now(),
  updated_by         uuid,
  constraint staff_pkey                primary key (id),
  constraint staff_tenant_code_uq      unique (platform_tenant_id, employee_code),              -- I22
  constraint staff_id_tenant_uq        unique (id, platform_tenant_id),                         -- §0.6
  constraint staff_tenant_fk           foreign key (platform_tenant_id) references public.platform_tenants (id),
  constraint staff_profile_fk          foreign key (profile_id, platform_tenant_id) references public.profiles (id, platform_tenant_id),
  constraint staff_employee_code_chk   check (length(btrim(employee_code)) > 0),
  constraint staff_first_name_chk      check (length(btrim(first_name)) > 0),
  constraint staff_family_name_chk     check (length(btrim(family_name)) > 0),
  constraint staff_phone_chk           check (phone_e164 is null or phone_e164 ~ '^\+[1-9][0-9]{7,14}$'),
  constraint staff_gender_chk          check (gender is null or gender in ('male', 'female')),
  constraint staff_status_chk          check (status in ('active', 'on_leave', 'ended', 'archived')),
  constraint staff_archived_chk        check ((status = 'archived') = (archived_at is not null)),
  constraint staff_created_by_fk       foreign key (created_by) references public.profiles (id),
  constraint staff_updated_by_fk       foreign key (updated_by) references public.profiles (id)
);
create unique index staff_profile_uq       on public.staff (profile_id) where profile_id is not null;   -- I23
create index staff_profile_tenant_idx      on public.staff (profile_id, platform_tenant_id);
create index staff_tenant_full_name_idx    on public.staff (platform_tenant_id, full_name);
create index staff_created_by_idx          on public.staff (created_by);
create index staff_updated_by_idx          on public.staff (updated_by);

-- ------------------------------------------------------------------
-- staff_school_assignments — [S] (DD §2.15) — الفترات نصف مفتوحة [from, to) (B6)
-- ------------------------------------------------------------------
create table public.staff_school_assignments (
  id                 uuid        not null default gen_random_uuid(),
  staff_id           uuid        not null,
  school_id          uuid        not null,
  platform_tenant_id uuid        not null,
  job_title          text        not null,
  is_primary         boolean     not null default false,
  status             text        not null default 'active',
  effective_from     date        not null,
  effective_to       date,
  created_at         timestamptz not null default now(),
  created_by         uuid,
  updated_at         timestamptz not null default now(),
  updated_by         uuid,
  constraint staff_school_assignments_pkey          primary key (id),
  constraint staff_school_assignments_staff_fk      foreign key (staff_id, platform_tenant_id)  references public.staff (id, platform_tenant_id),
  constraint staff_school_assignments_school_fk     foreign key (school_id, platform_tenant_id) references public.schools (id, platform_tenant_id),
  constraint staff_school_assignments_period_uq     unique (staff_id, school_id, effective_from),
  constraint staff_school_assignments_dates_chk     check (effective_to is null or effective_to > effective_from),
  constraint staff_school_assignments_active_chk    check ((status = 'active') = (effective_to is null)),
  constraint staff_school_assignments_status_chk    check (status in ('active', 'ended')),
  constraint staff_school_assignments_job_title_chk check (length(btrim(job_title)) > 0),
  constraint staff_school_assignments_created_by_fk foreign key (created_by) references public.profiles (id),
  constraint staff_school_assignments_updated_by_fk foreign key (updated_by) references public.profiles (id)
);
create unique index staff_school_assignments_primary_uq on public.staff_school_assignments (staff_id)
  where is_primary and status = 'active';                                                          -- I24
create index staff_school_assignments_school_status_idx on public.staff_school_assignments (school_id, status);
create index staff_school_assignments_staff_idx         on public.staff_school_assignments (staff_id, platform_tenant_id);
create index staff_school_assignments_school_idx        on public.staff_school_assignments (school_id, platform_tenant_id);
create index staff_school_assignments_created_by_idx    on public.staff_school_assignments (created_by);
create index staff_school_assignments_updated_by_idx    on public.staff_school_assignments (updated_by);

-- ------------------------------------------------------------------
-- families — [I] (DD §2.16) — تُنشأ داخل دوال الإنشاء فقط (G4، G8)
-- ------------------------------------------------------------------
create table public.families (
  id                 uuid        not null default gen_random_uuid(),
  platform_tenant_id uuid        not null,
  family_code        text,
  family_name        text        not null,
  address            text,
  status             text        not null default 'active',
  archived_at        timestamptz,
  created_at         timestamptz not null default now(),
  created_by         uuid,
  updated_at         timestamptz not null default now(),
  updated_by         uuid,
  constraint families_pkey             primary key (id),
  constraint families_id_tenant_uq     unique (id, platform_tenant_id),
  constraint families_tenant_fk        foreign key (platform_tenant_id) references public.platform_tenants (id),
  constraint families_name_chk         check (length(btrim(family_name)) > 0),
  constraint families_status_chk       check (status in ('active', 'archived')),
  constraint families_archived_chk     check ((status = 'archived') = (archived_at is not null)),
  constraint families_created_by_fk    foreign key (created_by) references public.profiles (id),
  constraint families_updated_by_fk    foreign key (updated_by) references public.profiles (id)
);
create unique index families_tenant_code_uq on public.families (platform_tenant_id, family_code) where family_code is not null;
create index families_created_by_idx on public.families (created_by);
create index families_updated_by_idx on public.families (updated_by);

-- ------------------------------------------------------------------
-- students — [I] (DD §2.17، قرارا A4 و N1)
--   بلا school_id ولا group_id. نطاق الهوية identity_scope_id NOT NULL؛ الحساب student_profile_id NOT NULL 1:1.
--   I28: official_id فريد داخل نطاق الهوية — قيد إعلاني واحد يغطي Group والمدرسة المستقلة (T2 ملغى).
--   G3: (id, identity_scope_id) هدف FK من enrollments (M10) — التسجيل داخل نطاق هوية الطالب.
--   temporary_id: يولّده app.next_temporary_id() داخل دوال الإنشاء (O3)؛ الصيغة هنا تحقق فقط.
-- ------------------------------------------------------------------
create table public.students (
  id                 uuid        not null default gen_random_uuid(),
  platform_tenant_id uuid        not null,
  identity_scope_id  uuid        not null,
  student_profile_id uuid        not null,
  family_id          uuid,
  official_id        text,
  official_id_type   text,
  temporary_id       text,
  first_name         text        not null,
  father_name        text,
  grandfather_name   text,
  family_name        text        not null,
  full_name          text        generated always as (btrim(regexp_replace(
                       first_name || ' ' || coalesce(father_name, '') || ' ' ||
                       coalesce(grandfather_name, '') || ' ' || family_name, '\s+', ' ', 'g'))) stored,
  gender             text,                                                                     -- O2
  birth_date         date,                                                                     -- O2
  nationality        text,
  status             text        not null default 'active',
  archived_at        timestamptz,
  created_at         timestamptz not null default now(),
  created_by         uuid,
  updated_at         timestamptz not null default now(),
  updated_by         uuid,
  constraint students_pkey                primary key (id),
  constraint students_id_tenant_uq        unique (id, platform_tenant_id),                    -- §0.6
  constraint students_id_scope_uq         unique (id, identity_scope_id),                     -- G3
  constraint students_profile_uq          unique (student_profile_id),                        -- I30
  constraint students_tenant_fk           foreign key (platform_tenant_id) references public.platform_tenants (id),
  constraint students_scope_fk            foreign key (identity_scope_id, platform_tenant_id)
                                            references public.identity_scopes (id, platform_tenant_id),   -- I27
  constraint students_profile_fk          foreign key (student_profile_id, platform_tenant_id)
                                            references public.profiles (id, platform_tenant_id),
  constraint students_family_fk           foreign key (family_id, platform_tenant_id)
                                            references public.families (id, platform_tenant_id),
  constraint students_identifier_chk      check (official_id is not null or temporary_id is not null),   -- I29
  constraint students_official_type_chk   check ((official_id is null) = (official_id_type is null)),
  constraint students_official_kind_chk   check (official_id_type is null or official_id_type in ('national_id', 'passport')),
  constraint students_official_blank_chk  check (official_id is null or length(btrim(official_id)) > 0),
  constraint students_temporary_id_chk    check (temporary_id is null or temporary_id ~ '^TMP-[0-9]{4}-[0-9]{6,}$'),   -- I31
  constraint students_first_name_chk      check (length(btrim(first_name)) > 0),
  constraint students_family_name_chk     check (length(btrim(family_name)) > 0),
  constraint students_gender_chk          check (gender is null or gender in ('male', 'female')),
  constraint students_status_chk          check (status in ('active', 'withdrawn', 'archived')),
  constraint students_archived_chk        check ((status = 'archived') = (archived_at is not null)),
  constraint students_created_by_fk       foreign key (created_by) references public.profiles (id),
  constraint students_updated_by_fk       foreign key (updated_by) references public.profiles (id)
);
create unique index students_scope_official_id_uq on public.students (identity_scope_id, official_id)
  where official_id is not null;                                                                   -- I28
create unique index students_tenant_temporary_id_uq on public.students (platform_tenant_id, temporary_id)
  where temporary_id is not null;
create index students_scope_tenant_idx     on public.students (identity_scope_id, platform_tenant_id);
create index students_profile_tenant_idx   on public.students (student_profile_id, platform_tenant_id);
create index students_family_idx           on public.students (family_id, platform_tenant_id);
create index students_tenant_full_name_idx on public.students (platform_tenant_id, full_name);
create index students_created_by_idx       on public.students (created_by);
create index students_updated_by_idx       on public.students (updated_by);

-- ------------------------------------------------------------------
-- guardians — [I] (DD §2.18)
--   phone_e164 فريد داخل Tenant (I25)؛ يتغير عبر مسار OTP في FastAPI فقط (GRANT في M20)
-- ------------------------------------------------------------------
create table public.guardians (
  id                 uuid        not null default gen_random_uuid(),
  platform_tenant_id uuid        not null,
  profile_id         uuid,
  first_name         text        not null,
  father_name        text,
  grandfather_name   text,
  family_name        text        not null,
  full_name          text        generated always as (btrim(regexp_replace(
                       first_name || ' ' || coalesce(father_name, '') || ' ' ||
                       coalesce(grandfather_name, '') || ' ' || family_name, '\s+', ' ', 'g'))) stored,
  phone_e164         text        not null,
  alt_phone_e164     text,
  email              text,
  national_id        text,
  residence_country  text,
  status             text        not null default 'active',
  locked_until       timestamptz,
  failed_login_count integer     not null default 0,
  last_login_at      timestamptz,
  archived_at        timestamptz,
  created_at         timestamptz not null default now(),
  created_by         uuid,
  updated_at         timestamptz not null default now(),
  updated_by         uuid,
  constraint guardians_pkey                primary key (id),
  constraint guardians_tenant_phone_uq     unique (platform_tenant_id, phone_e164),            -- I25
  constraint guardians_id_tenant_uq        unique (id, platform_tenant_id),
  constraint guardians_tenant_fk           foreign key (platform_tenant_id) references public.platform_tenants (id),
  constraint guardians_profile_fk          foreign key (profile_id, platform_tenant_id) references public.profiles (id, platform_tenant_id),
  constraint guardians_phone_chk           check (phone_e164 ~ '^\+[1-9][0-9]{7,14}$'),
  constraint guardians_alt_phone_chk       check (alt_phone_e164 is null or alt_phone_e164 ~ '^\+[1-9][0-9]{7,14}$'),
  constraint guardians_failed_login_chk    check (failed_login_count >= 0),
  constraint guardians_first_name_chk      check (length(btrim(first_name)) > 0),
  constraint guardians_family_name_chk     check (length(btrim(family_name)) > 0),
  constraint guardians_status_chk          check (status in ('active', 'archived')),
  constraint guardians_archived_chk        check ((status = 'archived') = (archived_at is not null)),
  constraint guardians_created_by_fk       foreign key (created_by) references public.profiles (id),
  constraint guardians_updated_by_fk       foreign key (updated_by) references public.profiles (id)
);
create unique index guardians_profile_uq      on public.guardians (profile_id) where profile_id is not null;   -- I23
create index guardians_profile_tenant_idx     on public.guardians (profile_id, platform_tenant_id);
create index guardians_tenant_full_name_idx   on public.guardians (platform_tenant_id, full_name);
create index guardians_created_by_idx         on public.guardians (created_by);
create index guardians_updated_by_idx         on public.guardians (updated_by);

-- ------------------------------------------------------------------
-- student_guardians — (DD §2.19) — Many-to-Many؛ الطرفان في نفس Tenant (I27)
-- ------------------------------------------------------------------
create table public.student_guardians (
  id                 uuid        not null default gen_random_uuid(),
  student_id         uuid        not null,
  guardian_id        uuid        not null,
  platform_tenant_id uuid        not null,
  relationship_type  text        not null,
  is_primary         boolean     not null default false,
  receives_whatsapp  boolean     not null default true,
  can_pickup         boolean     not null default false,
  status             text        not null default 'active',
  effective_from     date        not null default current_date,
  effective_to       date,
  created_at         timestamptz not null default now(),
  created_by         uuid,
  updated_at         timestamptz not null default now(),
  updated_by         uuid,
  constraint student_guardians_pkey            primary key (id),
  constraint student_guardians_pair_uq         unique (student_id, guardian_id),
  constraint student_guardians_student_fk      foreign key (student_id, platform_tenant_id)  references public.students (id, platform_tenant_id),
  constraint student_guardians_guardian_fk     foreign key (guardian_id, platform_tenant_id) references public.guardians (id, platform_tenant_id),
  constraint student_guardians_relationship_chk check (relationship_type in ('father', 'mother', 'grandparent', 'sibling', 'legal_guardian', 'other')),
  constraint student_guardians_status_chk      check (status in ('active', 'ended')),
  constraint student_guardians_dates_chk       check (effective_to is null or effective_to > effective_from),
  constraint student_guardians_active_chk      check ((status = 'active') = (effective_to is null)),
  constraint student_guardians_created_by_fk   foreign key (created_by) references public.profiles (id),
  constraint student_guardians_updated_by_fk   foreign key (updated_by) references public.profiles (id)
);
create unique index student_guardians_primary_uq on public.student_guardians (student_id)
  where is_primary and status = 'active';                                                           -- I26
create index student_guardians_guardian_student_idx on public.student_guardians (guardian_id, student_id);   -- ERD §8
create index student_guardians_student_fk_idx       on public.student_guardians (student_id, platform_tenant_id);
create index student_guardians_guardian_fk_idx      on public.student_guardians (guardian_id, platform_tenant_id);
create index student_guardians_created_by_idx       on public.student_guardians (created_by);
create index student_guardians_updated_by_idx       on public.student_guardians (updated_by);

-- ------------------------------------------------------------------
-- T6 — ختم
-- ------------------------------------------------------------------
create trigger stamp before insert or update on public.staff                    for each row execute function app.tg_stamp();
create trigger stamp before insert or update on public.staff_school_assignments for each row execute function app.tg_stamp();
create trigger stamp before insert or update on public.families                 for each row execute function app.tg_stamp();
create trigger stamp before insert or update on public.students                 for each row execute function app.tg_stamp();
create trigger stamp before insert or update on public.guardians                for each row execute function app.tg_stamp();
create trigger stamp before insert or update on public.student_guardians        for each row execute function app.tg_stamp();

-- ------------------------------------------------------------------
-- RLS — مفعّل ومفروض من الإنشاء
-- ------------------------------------------------------------------
alter table public.staff                    enable row level security;
alter table public.staff                    force  row level security;
alter table public.staff_school_assignments enable row level security;
alter table public.staff_school_assignments force  row level security;
alter table public.families                 enable row level security;
alter table public.families                 force  row level security;
alter table public.students                 enable row level security;
alter table public.students                 force  row level security;
alter table public.guardians                enable row level security;
alter table public.guardians                force  row level security;
alter table public.student_guardians        enable row level security;
alter table public.student_guardians        force  row level security;
