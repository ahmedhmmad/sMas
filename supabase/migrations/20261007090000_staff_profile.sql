-- M46 — staff_profile (Phase 3A / 3-1 — P12)
-- المرجع: docs/PHASE3_SCOPE.md §1، P12؛ docs/DATA_DICTIONARY_v1.md §2.37، §2.38.
--
-- staff_specialties     [I]  تخصصات الموظف — نص حر (لا ربط بمادة مدرسة: المادة كتالوج مدرسي والموظف عبر المدارس)
-- staff_qualifications  [I]  مؤهلاته (الدرجة، المجال، الجهة، سنة التخرج)
--
-- كلاهما يتبع الشخص لا المدرسة (ثابت 3): بلا school_id، ويُرى **بالعلاقة** كـstaff نفسه (§1.1 بند 11):
--   platform_tenant_id = current_tenant_id() ∧ المفتاح ∧ app.staff_in_scope(staff_id) (تكليف نشط في نطاق الفاعل — H2).
-- القراءة staff.read؛ الكتابة staff.update (P12). لا DELETE: الخطأ يُعطَّل بالحالة (inactive) ويبقى في التدقيق.
-- staff_id و platform_tenant_id ثابتان (خارج منح UPDATE)؛ FK مركّب بالـTenant (§0.6).
-- PD1 (Q1): أعمدة مهنية فقط — لا عمود شخصي جديد تحت staff.read.
-- لا دالة جديدة ولا مفتاح ولا trigger حارس: القائم (RLS + المنح + القيود) يكفي.

-- ------------------------------------------------------------------
-- staff_specialties
-- ------------------------------------------------------------------
create table public.staff_specialties (
  id                 uuid        not null default gen_random_uuid(),
  platform_tenant_id uuid        not null,
  staff_id           uuid        not null,
  name               text        not null,
  status             text        not null default 'active',
  created_at         timestamptz not null default now(),
  created_by         uuid,
  updated_at         timestamptz not null default now(),
  updated_by         uuid,
  constraint staff_specialties_pkey          primary key (id),
  constraint staff_specialties_staff_fk      foreign key (staff_id, platform_tenant_id) references public.staff (id, platform_tenant_id),
  constraint staff_specialties_tenant_fk     foreign key (platform_tenant_id) references public.platform_tenants (id),
  constraint staff_specialties_name_uq       unique (staff_id, name),
  constraint staff_specialties_name_chk      check (length(btrim(name)) > 0 and name = btrim(name) and length(name) <= 120),
  constraint staff_specialties_status_chk    check (status in ('active', 'inactive')),
  constraint staff_specialties_created_by_fk foreign key (created_by) references public.profiles (id),
  constraint staff_specialties_updated_by_fk foreign key (updated_by) references public.profiles (id)
);
create index staff_specialties_staff_idx      on public.staff_specialties (staff_id, platform_tenant_id);
create index staff_specialties_tenant_idx     on public.staff_specialties (platform_tenant_id);
create index staff_specialties_created_by_idx on public.staff_specialties (created_by);
create index staff_specialties_updated_by_idx on public.staff_specialties (updated_by);

-- ------------------------------------------------------------------
-- staff_qualifications
-- ------------------------------------------------------------------
create table public.staff_qualifications (
  id                 uuid        not null default gen_random_uuid(),
  platform_tenant_id uuid        not null,
  staff_id           uuid        not null,
  degree             text        not null,
  field              text        not null,
  institution        text,
  graduation_year    smallint,
  notes              text,
  status             text        not null default 'active',
  created_at         timestamptz not null default now(),
  created_by         uuid,
  updated_at         timestamptz not null default now(),
  updated_by         uuid,
  constraint staff_qualifications_pkey          primary key (id),
  constraint staff_qualifications_staff_fk      foreign key (staff_id, platform_tenant_id) references public.staff (id, platform_tenant_id),
  constraint staff_qualifications_tenant_fk     foreign key (platform_tenant_id) references public.platform_tenants (id),
  constraint staff_qualifications_degree_chk    check (degree in ('diploma', 'bachelor', 'higher_diploma', 'master', 'doctorate', 'other')),
  constraint staff_qualifications_field_chk     check (length(btrim(field)) > 0 and length(field) <= 200),
  constraint staff_qualifications_institution_chk check (institution is null or (length(btrim(institution)) > 0 and length(institution) <= 200)),
  constraint staff_qualifications_year_chk      check (graduation_year is null or (graduation_year >= 1900 and graduation_year <= 2100)),
  constraint staff_qualifications_notes_chk     check (notes is null or (length(btrim(notes)) > 0 and length(notes) <= 1000)),
  constraint staff_qualifications_status_chk    check (status in ('active', 'inactive')),
  constraint staff_qualifications_created_by_fk foreign key (created_by) references public.profiles (id),
  constraint staff_qualifications_updated_by_fk foreign key (updated_by) references public.profiles (id)
);
create index staff_qualifications_staff_idx      on public.staff_qualifications (staff_id, platform_tenant_id);
create index staff_qualifications_tenant_idx     on public.staff_qualifications (platform_tenant_id);
create index staff_qualifications_created_by_idx on public.staff_qualifications (created_by);
create index staff_qualifications_updated_by_idx on public.staff_qualifications (updated_by);

-- ------------------------------------------------------------------
-- T6 ختم، T7 تدقيق، RLS مفعّل ومفروض من الإنشاء
-- ------------------------------------------------------------------
create trigger stamp before insert or update on public.staff_specialties    for each row execute function app.tg_stamp();
create trigger stamp before insert or update on public.staff_qualifications for each row execute function app.tg_stamp();
create trigger audit after insert or update or delete on public.staff_specialties    for each row execute function app.tg_audit();
create trigger audit after insert or update or delete on public.staff_qualifications for each row execute function app.tg_audit();

alter table public.staff_specialties    enable row level security;
alter table public.staff_specialties    force  row level security;
alter table public.staff_qualifications enable row level security;
alter table public.staff_qualifications force  row level security;

-- ------------------------------------------------------------------
-- السياسات — Identity attachment: Tenant + المفتاح + العلاقة (staff_in_scope)، TO authenticated، لا DELETE
-- ------------------------------------------------------------------
create policy staff_specialties_select on public.staff_specialties
  for select to authenticated
  using (    platform_tenant_id = (select app.current_tenant_id())
         and app.has_permission('staff.read') and app.staff_in_scope(staff_id));
create policy staff_specialties_insert on public.staff_specialties
  for insert to authenticated
  with check (    platform_tenant_id = (select app.current_tenant_id())
              and app.has_permission('staff.update') and app.staff_in_scope(staff_id));
create policy staff_specialties_update on public.staff_specialties
  for update to authenticated
  using      (    platform_tenant_id = (select app.current_tenant_id())
              and app.has_permission('staff.update') and app.staff_in_scope(staff_id))
  with check (    platform_tenant_id = (select app.current_tenant_id())
              and app.has_permission('staff.update') and app.staff_in_scope(staff_id));

create policy staff_qualifications_select on public.staff_qualifications
  for select to authenticated
  using (    platform_tenant_id = (select app.current_tenant_id())
         and app.has_permission('staff.read') and app.staff_in_scope(staff_id));
create policy staff_qualifications_insert on public.staff_qualifications
  for insert to authenticated
  with check (    platform_tenant_id = (select app.current_tenant_id())
              and app.has_permission('staff.update') and app.staff_in_scope(staff_id));
create policy staff_qualifications_update on public.staff_qualifications
  for update to authenticated
  using      (    platform_tenant_id = (select app.current_tenant_id())
              and app.has_permission('staff.update') and app.staff_in_scope(staff_id))
  with check (    platform_tenant_id = (select app.current_tenant_id())
              and app.has_permission('staff.update') and app.staff_in_scope(staff_id));

-- ------------------------------------------------------------------
-- الامتيازات — منح صريح فقط (secure-by-default، M20)
--   staff_id و platform_tenant_id ثابتان (خارج UPDATE)؛ الصف يولد active (status خارج INSERT)
-- ------------------------------------------------------------------
grant insert (platform_tenant_id, staff_id, name)                                          on public.staff_specialties    to authenticated;
grant update (name, status)                                                                on public.staff_specialties    to authenticated;
grant insert (platform_tenant_id, staff_id, degree, field, institution, graduation_year, notes) on public.staff_qualifications to authenticated;
grant update (degree, field, institution, graduation_year, notes, status)                  on public.staff_qualifications to authenticated;
