-- M45 — school_profile_assets (Phase 2B / 2B-4 — B2–B6؛ القرارات E1–E10)
-- المرجع: docs/PHASE2B_4_PROFILE_STORAGE.md؛ docs/DATA_DICTIONARY_v1.md §2.35، §2.36.
--
-- school_profiles [S] ملف المدرسة 1:1 (E1) — بلا تاريخ نسخ؛ CRUD + RLS (school.read / school.update) + T16.
-- school_assets   [S] الشعار والختم والتوقيعات بنسخ لا تُستبدل (B3): رفع جديد = صف جديد والسابق retired؛ التقاعد نهائي؛
--                     لا حذف (E3). **لا منح كتابة للعميل** — الدوال وحدها.
-- المسار (E4): {tenant_id}/{school_id}/{kind}/{asset_id}.{png|jpg} — **تشتقه DB** من صف المدرسة وتتحقق من تطابقه
--              (CHECK للمدرسة والنوع والمعرّف والامتداد، والحارس للـtenant على كل مسار).
-- الصلاحية (B5، E7): الشعار school.update؛ الختم والتوقيعات security.manage؛ الرابط الموقّع للختم/التوقيع security.manage
--              ويُدقَّق إصداره (E8) — **لا رابط ولا token في التدقيق**.
-- Storage: bucket خاص `school-assets` (PNG/JPEG، 1MiB)؛ لا سياسة على storage.objects لأي دور عميل؛ الكائنات يرفعها
--          FastAPI بمفتاح الخدمة بعد أن تقرر DB (E5: DB ← Storage ← commit — ليست معاملة ذرية عبر النظامين).
-- الاتساق (E9): app.school_asset_consistency() — صفوف بلا كائن وكائنات بلا صفوف؛ محتوى الكائنات خارج pg_dump
--               (Production Readiness Gate — B6). لا مفتاح جديد: الكتالوج 75.

-- ------------------------------------------------------------------
-- school_profiles
-- ------------------------------------------------------------------
create table public.school_profiles (
  id                     uuid        not null default gen_random_uuid(),   -- T7 يسجّل entity_id من id
  school_id              uuid        not null,
  address                text,
  phone_e164             text,
  email                  text,
  website                text,
  principal_display_name text,
  created_at             timestamptz not null default now(),
  created_by             uuid,
  updated_at             timestamptz not null default now(),
  updated_by             uuid,
  constraint school_profiles_pkey          primary key (id),
  constraint school_profiles_school_uq     unique (school_id),                -- 1:1 (B2)
  constraint school_profiles_school_fk     foreign key (school_id) references public.schools (id),
  constraint school_profiles_address_chk   check (address is null or length(btrim(address)) > 0),
  constraint school_profiles_phone_chk     check (phone_e164 is null or phone_e164 ~ '^\+[1-9][0-9]{7,14}$'),
  constraint school_profiles_email_chk     check (email is null or email ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$'),
  constraint school_profiles_website_chk   check (website is null or website ~ '^https://[^\s]+$'),
  constraint school_profiles_principal_chk check (principal_display_name is null or length(btrim(principal_display_name)) > 0),
  constraint school_profiles_created_by_fk foreign key (created_by) references public.profiles (id),
  constraint school_profiles_updated_by_fk foreign key (updated_by) references public.profiles (id)
);
create index school_profiles_created_by_idx on public.school_profiles (created_by);
create index school_profiles_updated_by_idx on public.school_profiles (updated_by);

-- ------------------------------------------------------------------
-- school_assets
-- ------------------------------------------------------------------
create table public.school_assets (
  id           uuid        not null,
  school_id    uuid        not null,
  kind         text        not null,
  signer_title text,
  object_path  text        not null,
  content_type text        not null,
  byte_size    integer     not null,
  width        integer     not null,
  height       integer     not null,
  sha256       text        not null,
  status       text        not null default 'active',
  retired_at   timestamptz,
  created_at   timestamptz not null default now(),
  created_by   uuid,
  updated_at   timestamptz not null default now(),
  updated_by   uuid,
  constraint school_assets_pkey          primary key (id),
  constraint school_assets_school_fk     foreign key (school_id) references public.schools (id),
  constraint school_assets_path_uq       unique (object_path),
  constraint school_assets_kind_chk      check (kind in ('logo', 'stamp', 'signature')),
  constraint school_assets_signer_chk    check ((kind = 'signature') = (signer_title is not null) and (signer_title is null or length(btrim(signer_title)) > 0)),
  -- E4: {tenant}/{school}/{kind}/{id}.{ext} — المدرسة والنوع والمعرّف والامتداد من الصف نفسه؛ الـtenant في الحارس
  constraint school_assets_path_chk      check (object_path ~ '^[0-9a-f-]{36}/[0-9a-f-]{36}/(logo|stamp|signature)/[0-9a-f-]{36}\.(png|jpg)$'
                                                and split_part(object_path, '/', 2) = school_id::text
                                                and split_part(object_path, '/', 3) = kind
                                                and split_part(split_part(object_path, '/', 4), '.', 1) = id::text),
  constraint school_assets_ext_chk       check ((content_type = 'image/png' and object_path like '%.png') or (content_type = 'image/jpeg' and object_path like '%.jpg')),
  constraint school_assets_type_chk      check (content_type in ('image/png', 'image/jpeg')),
  constraint school_assets_size_chk      check (byte_size between 1 and 1048576),
  constraint school_assets_dims_chk      check (width >= 1 and width <= 4000 and height >= 1 and height <= 4000),   -- مسطّحة: تعود كما هي بعد dump/restore
  constraint school_assets_sha_chk       check (sha256 ~ '^[0-9a-f]{64}$'),
  constraint school_assets_status_chk    check (status in ('active', 'retired')),
  constraint school_assets_retired_chk   check ((status = 'retired') = (retired_at is not null)),
  constraint school_assets_created_by_fk foreign key (created_by) references public.profiles (id),
  constraint school_assets_updated_by_fk foreign key (updated_by) references public.profiles (id)
);
create unique index school_assets_one_active_uq    on public.school_assets (school_id, kind)
  where status = 'active' and kind <> 'signature';
create unique index school_assets_one_signature_uq on public.school_assets (school_id, lower(btrim(signer_title)))
  where status = 'active' and kind = 'signature';
create index school_assets_school_idx     on public.school_assets (school_id);
create index school_assets_created_by_idx on public.school_assets (created_by);
create index school_assets_updated_by_idx on public.school_assets (updated_by);

-- ------------------------------------------------------------------
-- T6 ختم، T7 تدقيق، RLS مفعّل ومفروض من الإنشاء
-- ------------------------------------------------------------------
create trigger stamp before insert or update on public.school_profiles for each row execute function app.tg_stamp();
create trigger stamp before insert or update on public.school_assets   for each row execute function app.tg_stamp();
create trigger audit after insert or update or delete on public.school_profiles for each row execute function app.tg_audit();
create trigger audit after insert or update or delete on public.school_assets   for each row execute function app.tg_audit();

alter table public.school_profiles enable row level security;
alter table public.school_profiles force  row level security;
alter table public.school_assets   enable row level security;
alter table public.school_assets   force  row level security;

-- ------------------------------------------------------------------
-- السياسات — School-level، TO authenticated، لا DELETE؛ الأصول بلا سياسة كتابة (لا منح)
-- ------------------------------------------------------------------
create policy school_profiles_select on public.school_profiles for select to authenticated
  using (app.can_access_school(school_id) and app.has_permission('school.read'));
create policy school_profiles_insert on public.school_profiles for insert to authenticated
  with check (app.can_access_school(school_id) and app.has_permission('school.update'));
create policy school_profiles_update on public.school_profiles for update to authenticated
  using      (app.can_access_school(school_id) and app.has_permission('school.update'))
  with check (app.can_access_school(school_id) and app.has_permission('school.update'));

create policy school_assets_select on public.school_assets for select to authenticated
  using (app.can_access_school(school_id) and app.has_permission('school.read'));

-- ------------------------------------------------------------------
-- الامتيازات — منح صريح فقط (secure-by-default، M20)
-- ------------------------------------------------------------------
grant select on public.school_profiles, public.school_assets to authenticated;
grant insert (school_id, address, phone_e164, email, website, principal_display_name) on public.school_profiles to authenticated;
grant update (address, phone_e164, email, website, principal_display_name)            on public.school_profiles to authenticated;

grant select, insert, update (status, retired_at) on public.school_assets to app_owner;
grant usage on schema storage to app_owner;      -- فحص الاتساق وحده (E9): قراءة storage.objects، لا كتابة
grant select on storage.objects to app_owner;

-- ------------------------------------------------------------------
-- Storage — bucket خاص؛ طبقة ثانية خلف تحقق FastAPI (النوع والحجم)
-- ------------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('school-assets', 'school-assets', false, 1048576, array['image/png', 'image/jpeg']);

set local role app_owner;

-- T16 — school_profiles: المدرسة المؤرشفة للقراءة فقط؛ school_id ثابت
create function app.tg_school_profile_guard()
returns trigger
language plpgsql
security definer
set search_path = app, public, pg_temp
as $$
begin
  if tg_op = 'UPDATE' and new.school_id is distinct from old.school_id then
    raise exception 'invariant: a school profile cannot move to another school' using errcode = '23514';
  end if;
  if (select s.status from public.schools s where s.id = new.school_id) <> 'active' then
    raise exception 'invariant: the school is archived — its profile is read-only' using errcode = '23514';
  end if;
  return new;
end;
$$;

-- T16 — school_assets: الـtenant في المسار (E4) والمدرسة نشطة عند الإنشاء؛ لا تغيير عدا التقاعد، والتقاعد نهائي (E3)
create function app.tg_school_asset_guard()
returns trigger
language plpgsql
security definer
set search_path = app, public, pg_temp
as $$
declare v_tenant uuid; v_status text;
begin
  if tg_op = 'INSERT' then
    select s.platform_tenant_id, s.status into v_tenant, v_status from public.schools s where s.id = new.school_id;
    if split_part(new.object_path, '/', 1) <> v_tenant::text then
      raise exception 'invariant: the asset path does not belong to its school''s tenant' using errcode = '23514';
    end if;
    if v_status <> 'active' then
      raise exception 'invariant: the school is archived — no new assets' using errcode = '23514';
    end if;
    if new.status <> 'active' then
      raise exception 'invariant: an asset is created active' using errcode = '23514';
    end if;
    return new;
  end if;
  if old.status = 'retired' then
    raise exception 'invariant: a retired asset is final' using errcode = '23514';
  end if;
  if (new.id, new.school_id, new.kind, new.signer_title, new.object_path, new.content_type, new.byte_size, new.width, new.height, new.sha256)
     is distinct from (old.id, old.school_id, old.kind, old.signer_title, old.object_path, old.content_type, old.byte_size, old.width, old.height, old.sha256) then
    raise exception 'invariant: an asset cannot change — upload a new version instead' using errcode = '23514';
  end if;
  return new;
end;
$$;

-- تسجيل نسخة أصل جديدة (B3، E4، E5): التفويض والصف في DB قبل أي رفع؛ المسار مشتق هنا لا من العميل.
-- تعيد object_path ليرفع FastAPI الكائن إليه ثم يُكمل المعاملة (commit).
create function app.register_school_asset(p_asset_id uuid, p_school_id uuid, p_kind text, p_signer_title text, p_content_type text,
                                          p_byte_size integer, p_width integer, p_height integer, p_sha256 text, p_reason text)
returns text
language plpgsql security definer set search_path = app, public, pg_temp
as $$
declare
  v_school public.schools%rowtype;
  v_path text; v_title text := nullif(btrim(p_signer_title), '');
begin
  if p_kind not in ('logo', 'stamp', 'signature') or p_kind is null then
    raise exception 'invalid: unknown asset kind' using errcode = '22023';
  end if;
  if not app.has_permission(case when p_kind = 'logo' then 'school.update' else 'security.manage' end) then
    raise exception 'forbidden' using errcode = '42501';                                       -- B5
  end if;
  perform app.require_reason(p_reason);
  if p_content_type is null or p_content_type not in ('image/png', 'image/jpeg') then
    raise exception 'invalid: only PNG or JPEG' using errcode = '22023';                         -- E6 (الخادم حدده من البايتات)
  end if;
  if (p_kind = 'signature') <> (v_title is not null) then
    raise exception 'invalid: a signature needs a signer title, other assets none' using errcode = '22023';
  end if;

  select s.* into v_school from public.schools s where s.id = p_school_id and app.can_access_school(s.id) for share;
  if not found then raise exception 'not found' using errcode = 'P0002'; end if;
  if v_school.status <> 'active' then
    raise exception 'invalid: the school is archived' using errcode = '22023';
  end if;

  v_path := format('%s/%s/%s/%s.%s', v_school.platform_tenant_id, v_school.id, p_kind, p_asset_id,
                   case p_content_type when 'image/png' then 'png' when 'image/jpeg' then 'jpg' else 'invalid' end);

  perform app.set_audit_context('register_school_asset', p_reason);
  update public.school_assets a set status = 'retired', retired_at = now()                     -- B3: النشط السابق يُحال في العملية نفسها
   where a.school_id = v_school.id and a.status = 'active' and a.kind = p_kind
     and (p_kind <> 'signature' or lower(btrim(a.signer_title)) = lower(v_title));
  insert into public.school_assets (id, school_id, kind, signer_title, object_path, content_type, byte_size, width, height, sha256)
  values (p_asset_id, v_school.id, p_kind, v_title, v_path, p_content_type, p_byte_size, p_width, p_height, p_sha256);
  perform app.set_audit_context(null, null);
  return v_path;
end;
$$;

-- تقاعد نسخة (E3): نهائي؛ الكائن لا يُمس
create function app.retire_school_asset(p_asset_id uuid, p_reason text)
returns void
language plpgsql security definer set search_path = app, public, pg_temp
as $$
declare v_asset public.school_assets%rowtype;
begin
  perform app.require_reason(p_reason);
  select a.* into v_asset from public.school_assets a
   where a.id = p_asset_id and app.can_access_school(a.school_id) and app.has_permission('school.read') for update;
  if not found then raise exception 'not found' using errcode = 'P0002'; end if;
  if not app.has_permission(case when v_asset.kind = 'logo' then 'school.update' else 'security.manage' end) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if v_asset.status <> 'active' then
    raise exception 'invalid: the asset is already retired' using errcode = '22023';
  end if;
  perform app.set_audit_context('retire_school_asset', p_reason);
  update public.school_assets set status = 'retired', retired_at = now() where id = v_asset.id;
  perform app.set_audit_context(null, null);
end;
$$;

-- قبل إصدار رابط موقّع (E7، E8): الصف مرئي + صلاحية الرابط حسب النوع؛ للختم/التوقيع صف تدقيق لعملية الإصدار
-- في المعاملة نفسها (fail closed) — **بلا الرابط ولا الـtoken**. تعيد object_path.
create function app.authorize_asset_url(p_asset_id uuid)
returns text
language plpgsql security definer set search_path = app, public, pg_temp
as $$
declare v_asset public.school_assets%rowtype; v_tenant uuid; v_source text;
begin
  select a.* into v_asset from public.school_assets a
   where a.id = p_asset_id and app.can_access_school(a.school_id) and app.has_permission('school.read');
  if not found then raise exception 'not found' using errcode = 'P0002'; end if;
  if v_asset.kind <> 'logo' then
    if not app.has_permission('security.manage') then
      raise exception 'forbidden' using errcode = '42501';
    end if;
    select s.platform_tenant_id into v_tenant from public.schools s where s.id = v_asset.school_id;
    v_source := coalesce(nullif(current_setting('app.request_source', true), ''), 'api');
    if v_source not in ('web', 'mobile', 'api', 'system') then v_source := 'api'; end if;
    insert into public.audit_log (platform_tenant_id, school_id, actor_type, actor_id, action, entity_type, entity_id, new_values, source)
    values (v_tenant, v_asset.school_id, 'tenant_user', app.current_profile_id(), 'asset_url', 'school_assets', v_asset.id::text,
            jsonb_build_object('kind', v_asset.kind, 'signer_title', v_asset.signer_title, 'status', v_asset.status), v_source);
  end if;
  return v_asset.object_path;
end;
$$;

-- E9: الافتراق بين الصفوف والكائنات — داخلية، بلا EXECUTE لأدوار الـAPI
create function app.school_asset_consistency()
returns table (issue text, object_path text)
language sql
stable
security definer
set search_path = app, public, pg_temp
as $$
  select 'row_without_object', a.object_path from public.school_assets a
   where not exists (select 1 from storage.objects o where o.bucket_id = 'school-assets' and o.name = a.object_path)
  union all
  select 'object_without_row', o.name from storage.objects o
   where o.bucket_id = 'school-assets' and not exists (select 1 from public.school_assets a where a.object_path = o.name)
  order by 1, 2
$$;

reset role;

create trigger guard before insert or update on public.school_profiles
  for each row execute function app.tg_school_profile_guard();
create trigger guard before insert or update on public.school_assets
  for each row execute function app.tg_school_asset_guard();

grant execute on function app.register_school_asset(uuid, uuid, text, text, text, integer, integer, integer, text, text) to authenticated;
grant execute on function app.retire_school_asset(uuid, text) to authenticated;
grant execute on function app.authorize_asset_url(uuid) to authenticated;
