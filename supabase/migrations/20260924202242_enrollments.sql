-- M10 — enrollments
-- المرجع: docs/DB_IMPLEMENTATION_SPEC_v1.md §B10 (M10)، I38–I42، G3، G6، §3.2 (T3 → إعلاني)، §5.5، B6؛
--         docs/DATA_DICTIONARY_v1.md §2.20
-- الجسر بين هوية الطالب (بلا school_id) والمدرسة — مصدر حقيقة RLS للوصول إلى الطالب (M17).
-- الفترات نصف مفتوحة [effective_from, effective_to) (B6 §6.1).
--
-- ملاحظات تنفيذية:
--   • قيود G3 الثلاثة DEFERRABLE INITIALLY IMMEDIATE: فورية في كل عملية عادية، وقابلة للتأجيل داخل
--     إجراء الدمج الإداري لاحقاً (§5.5) دون تعديل هذه الـmigration.
--   • I38 محتوى بالكامل في G6: التسجيل النشط فترته [from, ∞)، فأي نشطَين لنفس الطالب يتداخلان دائماً.
--     يبقى القيد (المواصفة + فهرس بحث مفيد)، لكن لا حالة تخرقه وحده.

create table public.enrollments (
  id                 uuid        not null default gen_random_uuid(),
  school_id          uuid        not null,
  student_id         uuid        not null,
  platform_tenant_id uuid        not null,
  academic_year_id   uuid        not null,
  grade_level_id     uuid        not null,
  section_id         uuid        not null,
  identity_scope_id  uuid        not null,                                                     -- G3
  scope_owner_id     uuid        not null,                                                     -- G3
  enrollment_no      text,
  status             text        not null default 'active',
  effective_from     date        not null,
  effective_to       date,
  withdrawal_reason  text,
  created_at         timestamptz not null default now(),
  created_by         uuid,
  updated_at         timestamptz not null default now(),
  updated_by         uuid,
  constraint enrollments_pkey             primary key (id),
  -- عزل Tenant
  constraint enrollments_student_fk       foreign key (student_id, platform_tenant_id) references public.students (id, platform_tenant_id),
  constraint enrollments_school_fk        foreign key (school_id, platform_tenant_id)  references public.schools (id, platform_tenant_id),
  -- I39: السنة والصف والشعبة من المدرسة نفسها ومتسقة — FK واحد (يحل محل T3)
  constraint enrollments_section_fk       foreign key (section_id, school_id, academic_year_id, grade_level_id)
                                            references public.sections (id, school_id, academic_year_id, grade_level_id),
  -- I40 / G3: المدرسة داخل نطاق هوية الطالب
  constraint enrollments_student_scope_fk foreign key (student_id, identity_scope_id)
                                            references public.students (id, identity_scope_id)
                                            deferrable initially immediate,
  constraint enrollments_school_owner_fk  foreign key (school_id, scope_owner_id)
                                            references public.schools (id, scope_owner_id)
                                            deferrable initially immediate,
  constraint enrollments_scope_owner_fk   foreign key (identity_scope_id, scope_owner_id)
                                            references public.identity_scopes (id, owner_id)
                                            deferrable initially immediate,
  -- I42 / B6
  constraint enrollments_status_chk       check (status in ('active', 'withdrawn', 'transferred', 'completed')),
  constraint enrollments_dates_chk        check (effective_to is null or effective_to > effective_from),
  constraint enrollments_active_chk       check ((status = 'active') = (effective_to is null)),
  constraint enrollments_no_blank_chk     check (enrollment_no is null or length(btrim(enrollment_no)) > 0),
  -- I41 / G6: لا تداخل زمني بين تسجيلات الطالب عبر الـTenant
  constraint enrollments_no_overlap       exclude using gist (
                                            student_id with =,
                                            daterange(effective_from, effective_to, '[)') with &&),
  constraint enrollments_created_by_fk    foreign key (created_by) references public.profiles (id),
  constraint enrollments_updated_by_fk    foreign key (updated_by) references public.profiles (id)
);

-- I38 (محتوى في G6 — انظر الرأس)
create unique index enrollments_active_uq on public.enrollments (student_id, school_id, academic_year_id)
  where status = 'active';
create unique index enrollments_school_year_no_uq on public.enrollments (school_id, academic_year_id, enrollment_no)
  where enrollment_no is not null;

-- الفهارس: ERD §8 + كل FK
create index enrollments_school_year_student_idx on public.enrollments (school_id, academic_year_id, student_id);
create index enrollments_school_year_section_idx on public.enrollments (school_id, academic_year_id, section_id);
create index enrollments_student_idx             on public.enrollments (student_id);                     -- حرج: RLS على students
create index enrollments_student_tenant_idx      on public.enrollments (student_id, platform_tenant_id);
create index enrollments_school_tenant_idx       on public.enrollments (school_id, platform_tenant_id);
create index enrollments_section_fk_idx          on public.enrollments (section_id, school_id, academic_year_id, grade_level_id);
create index enrollments_student_scope_idx       on public.enrollments (student_id, identity_scope_id);
create index enrollments_school_owner_idx        on public.enrollments (school_id, scope_owner_id);
create index enrollments_scope_owner_idx         on public.enrollments (identity_scope_id, scope_owner_id);
create index enrollments_created_by_idx          on public.enrollments (created_by);
create index enrollments_updated_by_idx          on public.enrollments (updated_by);

create trigger stamp before insert or update on public.enrollments for each row execute function app.tg_stamp();

alter table public.enrollments enable row level security;
alter table public.enrollments force  row level security;
