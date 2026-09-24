-- M08 — academic_structure
-- المرجع: docs/DB_IMPLEMENTATION_SPEC_v1.md §B10 (M08)، I33–I37، §3.2 (T4 → إعلاني)، B6؛
--         docs/DATA_DICTIONARY_v1.md §2.21–§2.25؛ M00 V6
-- جداول School-level: school_id NOT NULL + فهرس (PLAN_v3 §3.3 بند 1). عدد الفصول/المراحل/الشعب
-- غير مثبّت في الكود — كله بيانات (ERD §9).
-- الأعمدة المشتركة على الجداول الخمسة (DD §0.3: «ما لم يُذكر خلاف ذلك»).
-- التواريخ التقويمية: start_date/end_date شاملة للطرفين '[]' (B6 §6.1).

-- ------------------------------------------------------------------
-- academic_years — (DD §2.21)
--   I33 سنة نشطة واحدة لكل مدرسة؛ I34 لا تداخل؛ (id, school_id, start_date, end_date) هدف FK الفصول
-- ------------------------------------------------------------------
create table public.academic_years (
  id         uuid        not null default gen_random_uuid(),
  school_id  uuid        not null,
  name       text        not null,
  start_date date        not null,
  end_date   date        not null,
  status     text        not null default 'planned',
  created_at timestamptz not null default now(),
  created_by uuid,
  updated_at timestamptz not null default now(),
  updated_by uuid,
  constraint academic_years_pkey            primary key (id),
  constraint academic_years_id_school_uq    unique (id, school_id),
  constraint academic_years_bounds_uq       unique (id, school_id, start_date, end_date),       -- هدف FK من terms
  constraint academic_years_school_name_uq  unique (school_id, name),
  constraint academic_years_school_fk       foreign key (school_id) references public.schools (id),
  constraint academic_years_dates_chk       check (end_date > start_date),
  constraint academic_years_status_chk      check (status in ('planned', 'active', 'closed')),
  constraint academic_years_name_chk        check (length(btrim(name)) > 0),
  constraint academic_years_no_overlap      exclude using gist (
                                              school_id with =,
                                              daterange(start_date, end_date, '[]') with &&),      -- I34
  constraint academic_years_created_by_fk   foreign key (created_by) references public.profiles (id),
  constraint academic_years_updated_by_fk   foreign key (updated_by) references public.profiles (id)
);
create unique index academic_years_active_uq on public.academic_years (school_id) where status = 'active';   -- I33
create index academic_years_school_status_idx on public.academic_years (school_id, status);                 -- ERD §8
create index academic_years_created_by_idx    on public.academic_years (created_by);
create index academic_years_updated_by_idx    on public.academic_years (updated_by);

-- ------------------------------------------------------------------
-- terms — (DD §2.22)
--   I35: الفصل داخل السنة — FK يحمل حدود السنة ON UPDATE CASCADE + CHECK (يحل محل T4؛ مُثبت M00 V6)
--   I36: لا تداخل بين فصول السنة
-- ------------------------------------------------------------------
create table public.terms (
  id               uuid        not null default gen_random_uuid(),
  academic_year_id uuid        not null,
  school_id        uuid        not null,
  name             text        not null,
  sequence_no      integer     not null,
  start_date       date        not null,
  end_date         date        not null,
  year_start_date  date        not null,
  year_end_date    date        not null,
  status           text        not null default 'planned',
  created_at       timestamptz not null default now(),
  created_by       uuid,
  updated_at       timestamptz not null default now(),
  updated_by       uuid,
  constraint terms_pkey               primary key (id),
  constraint terms_year_fk            foreign key (academic_year_id, school_id, year_start_date, year_end_date)
                                        references public.academic_years (id, school_id, start_date, end_date)
                                        on update cascade,
  constraint terms_within_year_chk    check (start_date >= year_start_date and end_date <= year_end_date),   -- I35
  constraint terms_dates_chk          check (end_date > start_date),
  constraint terms_sequence_chk       check (sequence_no > 0),
  constraint terms_status_chk         check (status in ('planned', 'active', 'closed')),
  constraint terms_name_chk           check (length(btrim(name)) > 0),
  constraint terms_year_sequence_uq   unique (academic_year_id, sequence_no),
  constraint terms_year_name_uq       unique (academic_year_id, name),
  constraint terms_no_overlap         exclude using gist (
                                        academic_year_id with =,
                                        daterange(start_date, end_date, '[]') with &&),            -- I36
  constraint terms_created_by_fk      foreign key (created_by) references public.profiles (id),
  constraint terms_updated_by_fk      foreign key (updated_by) references public.profiles (id)
);
create index terms_year_fk_idx     on public.terms (academic_year_id, school_id, year_start_date, year_end_date);
create index terms_school_idx      on public.terms (school_id);
create index terms_created_by_idx  on public.terms (created_by);
create index terms_updated_by_idx  on public.terms (updated_by);

-- ------------------------------------------------------------------
-- stages — (DD §2.23)
-- ------------------------------------------------------------------
create table public.stages (
  id          uuid        not null default gen_random_uuid(),
  school_id   uuid        not null,
  name        text        not null,
  sequence_no integer     not null,
  status      text        not null default 'active',
  created_at  timestamptz not null default now(),
  created_by  uuid,
  updated_at  timestamptz not null default now(),
  updated_by  uuid,
  constraint stages_pkey             primary key (id),
  constraint stages_id_school_uq     unique (id, school_id),
  constraint stages_school_name_uq   unique (school_id, name),
  constraint stages_school_seq_uq    unique (school_id, sequence_no),
  constraint stages_school_fk        foreign key (school_id) references public.schools (id),
  constraint stages_sequence_chk     check (sequence_no > 0),
  constraint stages_status_chk       check (status in ('active', 'inactive')),
  constraint stages_name_chk         check (length(btrim(name)) > 0),
  constraint stages_created_by_fk    foreign key (created_by) references public.profiles (id),
  constraint stages_updated_by_fk    foreign key (updated_by) references public.profiles (id)
);
create index stages_created_by_idx on public.stages (created_by);
create index stages_updated_by_idx on public.stages (updated_by);

-- ------------------------------------------------------------------
-- grade_levels — (DD §2.24) — I37: المرحلة من نفس المدرسة
-- ------------------------------------------------------------------
create table public.grade_levels (
  id          uuid        not null default gen_random_uuid(),
  school_id   uuid        not null,
  stage_id    uuid        not null,
  name        text        not null,
  sequence_no integer     not null,
  status      text        not null default 'active',
  created_at  timestamptz not null default now(),
  created_by  uuid,
  updated_at  timestamptz not null default now(),
  updated_by  uuid,
  constraint grade_levels_pkey            primary key (id),
  constraint grade_levels_id_school_uq    unique (id, school_id),
  constraint grade_levels_school_name_uq  unique (school_id, name),
  constraint grade_levels_school_seq_uq   unique (school_id, sequence_no),
  constraint grade_levels_stage_fk        foreign key (stage_id, school_id) references public.stages (id, school_id),   -- I37
  constraint grade_levels_sequence_chk    check (sequence_no > 0),
  constraint grade_levels_status_chk      check (status in ('active', 'inactive')),
  constraint grade_levels_name_chk        check (length(btrim(name)) > 0),
  constraint grade_levels_created_by_fk   foreign key (created_by) references public.profiles (id),
  constraint grade_levels_updated_by_fk   foreign key (updated_by) references public.profiles (id)
);
create index grade_levels_stage_idx       on public.grade_levels (stage_id, school_id);
create index grade_levels_created_by_idx  on public.grade_levels (created_by);
create index grade_levels_updated_by_idx  on public.grade_levels (updated_by);

-- ------------------------------------------------------------------
-- sections — (DD §2.25)
--   I37: السنة والصف من نفس المدرسة
--   (id, school_id, academic_year_id, grade_level_id): هدف FK واحد من enrollments (يحل محل T3)
--   السعة وسياسة الجنس قاعدتا أعمال عند التسجيل (المرحلة 4) — لا قيد صف.
-- ------------------------------------------------------------------
create table public.sections (
  id               uuid        not null default gen_random_uuid(),
  school_id        uuid        not null,
  academic_year_id uuid        not null,
  grade_level_id   uuid        not null,
  name             text        not null,
  capacity         integer,
  gender_policy    text        not null default 'mixed',
  status           text        not null default 'active',
  created_at       timestamptz not null default now(),
  created_by       uuid,
  updated_at       timestamptz not null default now(),
  updated_by       uuid,
  constraint sections_pkey             primary key (id),
  constraint sections_id_school_uq     unique (id, school_id),
  constraint sections_context_uq       unique (id, school_id, academic_year_id, grade_level_id),   -- هدف FK من enrollments
  constraint sections_name_uq          unique (school_id, academic_year_id, grade_level_id, name),
  constraint sections_year_fk          foreign key (academic_year_id, school_id) references public.academic_years (id, school_id),
  constraint sections_grade_level_fk   foreign key (grade_level_id, school_id)   references public.grade_levels (id, school_id),
  constraint sections_capacity_chk     check (capacity is null or capacity > 0),
  constraint sections_gender_chk       check (gender_policy in ('mixed', 'male_only', 'female_only')),
  constraint sections_status_chk       check (status in ('active', 'inactive')),
  constraint sections_name_chk         check (length(btrim(name)) > 0),
  constraint sections_created_by_fk    foreign key (created_by) references public.profiles (id),
  constraint sections_updated_by_fk    foreign key (updated_by) references public.profiles (id)
);
create index sections_year_idx         on public.sections (academic_year_id, school_id);
create index sections_grade_level_idx  on public.sections (grade_level_id, school_id);
create index sections_created_by_idx   on public.sections (created_by);
create index sections_updated_by_idx   on public.sections (updated_by);

-- ------------------------------------------------------------------
-- T6 — ختم
-- ------------------------------------------------------------------
create trigger stamp before insert or update on public.academic_years for each row execute function app.tg_stamp();
create trigger stamp before insert or update on public.terms          for each row execute function app.tg_stamp();
create trigger stamp before insert or update on public.stages         for each row execute function app.tg_stamp();
create trigger stamp before insert or update on public.grade_levels   for each row execute function app.tg_stamp();
create trigger stamp before insert or update on public.sections       for each row execute function app.tg_stamp();

-- ------------------------------------------------------------------
-- RLS — مفعّل ومفروض من الإنشاء
-- ------------------------------------------------------------------
alter table public.academic_years enable row level security;
alter table public.academic_years force  row level security;
alter table public.terms          enable row level security;
alter table public.terms          force  row level security;
alter table public.stages         enable row level security;
alter table public.stages         force  row level security;
alter table public.grade_levels   enable row level security;
alter table public.grade_levels   force  row level security;
alter table public.sections       enable row level security;
alter table public.sections       force  row level security;
