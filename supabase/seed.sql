-- E5 — Development seed (local / CI only — NEVER production; B8 §8.1)
-- يعمل عند `supabase db reset` محلياً فقط. الاختبارات لا تعتمد عليه (B8 §8.3): تُشغَّل بـ`db reset --no-seed`.
--
-- المبدأ (Gate E، 2026-09-26): الـseed لا يلتف حول المعمارية ولا يمنح نفسه صلاحيات لا يملكها التطبيق.
--   كل صف Foundation يكتبه فاعل مُصادَق بالمسار نفسه الذي يستعمله التطبيق:
--     • صفوف الهوية ← دوال الإنشاء (M22) بـJWT الفاعل: bootstrap_tenant، provision_staff/student/guardian/account
--     • صفوف الإعداد (مجموعة، مدارس، بنية أكاديمية، أدوار ونطاقات) ← CRUD تحت RLS بدور authenticated، وT8 فعّال
--     • انتقالات الحالة ← دوال M21 (تفعيل السنة الدراسية)
--   الاستثناءان الوحيدان — لأن لا مسار تطبيق لهما بالتصميم:
--     1. حسابات auth.users/auth.identities — في Production ينشئها FastAPI عبر Supabase Admin API (§5.4، الخطوة 3)
--     2. إقلاع أول Platform Admin (system_user + إسناد دور platform_admin) — service فقط (B8 «إقلاع»، G8)
--   لا permission ولا role ولا سياسة يُنشئها الـseed: البيانات المرجعية من M23 كما هي.
--   الـseed يتحقق من نفسه في آخره (كتلة DO) — أي انحراف يُفشله، ومنه: لا صف تدقيق لبيانات الـTenant بفاعل system.
--
-- البنية:  Tenant DEV
--            ├── Group GA ── School SA (sa)، School SB (sb)
--            └── School SS (مستقلة)
--          + مستخدم لكل دور من الأدوار العشرة (+ Platform Admin)
-- كلمة المرور لكل حسابات التطوير: DevOnly-Seed-2026 (محلية فقط، ليست سراً)

begin;

-- ------------------------------------------------------------------
-- أدوات الـseed (مؤقتة في الجلسة)
-- ------------------------------------------------------------------
create function pg_temp.dev_auth_user(p_id uuid, p_email text) returns void
language sql as $$
  insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
                          raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
                          confirmation_token, recovery_token, email_change_token_new, email_change)
  values ('00000000-0000-0000-0000-000000000000', p_id, 'authenticated', 'authenticated', p_email,
          extensions.crypt('DevOnly-Seed-2026', extensions.gen_salt('bf')), now(),
          '{"provider":"email","providers":["email"]}', '{}', now(), now(), '', '', '', '');
  insert into auth.identities (provider_id, user_id, identity_data, provider, created_at, updated_at)
  values (p_id::text, p_id, jsonb_build_object('sub', p_id::text, 'email', p_email, 'email_verified', true), 'email', now(), now());
$$;

-- انتحال فاعل: JWT claims كما يرسلها PostgREST
create function pg_temp.act(p_sub uuid) returns void
language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', p_sub, 'role', 'authenticated')::text, true),
         set_config('request.jwt.claim.sub', p_sub::text, true);
$$;

create temp table dev (label text primary key, auth uuid, email text, role_code text, scope text) on commit drop;
insert into dev values
  ('platform',       'a0000000-0000-4000-8000-000000000000', 'platform@dev.smas.test',       null,             null),
  ('tenant_admin',   'a0000000-0000-4000-8000-000000000001', 'tenant.admin@dev.smas.test',   'tenant_admin',   'tenant'),
  ('group_manager',  'a0000000-0000-4000-8000-000000000002', 'group.manager@dev.smas.test',  'group_manager',  'GA'),
  ('school_admin',   'a0000000-0000-4000-8000-000000000003', 'school.admin@dev.smas.test',   'school_admin',   'SA'),
  ('secretary',      'a0000000-0000-4000-8000-000000000004', 'secretary@dev.smas.test',      'secretary',      'SA'),
  ('accountant',     'a0000000-0000-4000-8000-000000000005', 'accountant@dev.smas.test',     'accountant',     'SA'),
  ('teacher',        'a0000000-0000-4000-8000-000000000006', 'teacher@dev.smas.test',        'teacher',        'SA'),
  ('counselor',      'a0000000-0000-4000-8000-000000000007', 'counselor@dev.smas.test',      'counselor',      'SA'),
  ('bus_supervisor', 'a0000000-0000-4000-8000-000000000008', 'bus.supervisor@dev.smas.test', 'bus_supervisor', 'SA'),
  ('guardian',       'a0000000-0000-4000-8000-000000000009', 'guardian@dev.smas.test',       'guardian',       null),
  -- D1 (M24): حساب الطالب = معرّف الطالب وبريده اصطناعي؛ الدخول بالـOfficial ID عبر FastAPI
  ('student',        'e0000000-0000-4000-8000-000000000001', 'e0000000-0000-4000-8000-000000000001@students.smas.invalid', 'student', null);
grant select on dev to authenticated;

-- ------------------------------------------------------------------
-- 0. استثناء 1: حسابات Auth (Admin API في Production)
-- ------------------------------------------------------------------
-- D3 (M26): حسابات الموظفين وولي الأمر هوية اصطناعية (المعرّف = معرّف الكيان، I2)؛ البريد/الهاتف الحقيقي في staff/guardians
select pg_temp.dev_auth_user(auth, case
         when role_code in ('group_manager','school_admin','secretary','accountant','teacher','counselor','bus_supervisor')
           then auth::text || '@staff.smas.invalid'
         when label = 'guardian' then auth::text || '@guardians.smas.invalid'
         else email end)
  from dev;

-- ------------------------------------------------------------------
-- 0. استثناء 2: إقلاع Platform Admin (service — G8)
-- ------------------------------------------------------------------
insert into public.auth_identities (auth_user_id, kind) values ('a0000000-0000-4000-8000-000000000000', 'platform');
insert into public.system_users (id, auth_user_id, display_name)
  values ('b0000000-0000-4000-8000-000000000000', 'a0000000-0000-4000-8000-000000000000', 'Dev Platform Admin');
insert into public.platform_admin_assignments (system_user_id, platform_admin_role_id)
  select 'b0000000-0000-4000-8000-000000000000', id from public.platform_admin_roles where code = 'platform_admin';

-- ------------------------------------------------------------------
-- 1. Platform Admin ← bootstrap_tenant (M22)
-- ------------------------------------------------------------------
select pg_temp.act('a0000000-0000-4000-8000-000000000000');
set local role authenticated;
select app.bootstrap_tenant('d0000000-0000-4000-8000-000000000001', 'DEV', 'Development Tenant',
                            'a0000000-0000-4000-8000-000000000001', 'Tenant Admin');
reset role;

-- ------------------------------------------------------------------
-- 2. tenant_admin ← البنية تحت RLS
-- ------------------------------------------------------------------
select pg_temp.act('a0000000-0000-4000-8000-000000000001');
set local role authenticated;

insert into public.groups (platform_tenant_id, group_code, name)
  values ('d0000000-0000-4000-8000-000000000001', 'GA', 'Group A');
insert into public.schools (platform_tenant_id, group_id, school_code, name, slug, timezone)
  select 'd0000000-0000-4000-8000-000000000001', g.id, v.code, v.name, v.slug, 'Africa/Cairo'
  from public.groups g,
       (values ('SA', 'School A', 'school-a'), ('SB', 'School B', 'school-b')) v(code, name, slug)
  where g.group_code = 'GA';
insert into public.schools (platform_tenant_id, group_id, school_code, name, slug, timezone)
  values ('d0000000-0000-4000-8000-000000000001', null, 'SS', 'Standalone School', 'standalone', 'Africa/Cairo');

-- البنية الأكاديمية لكل مدرسة: سنة (planned ثم تفعيل بـM21)، مرحلة، صفان، شعبة لكل صف
insert into public.academic_years (school_id, name, start_date, end_date)
  select id, '2026/2027', '2026-09-01', '2027-06-30' from public.schools;
select app.activate_academic_year(y.id, 'development seed') from public.academic_years y;
insert into public.stages (school_id, name, sequence_no) select id, 'Primary', 1 from public.schools;
insert into public.grade_levels (school_id, stage_id, name, sequence_no)
  select s.school_id, s.id, v.name, v.seq from public.stages s, (values ('Grade 1', 1), ('Grade 2', 2)) v(name, seq);
insert into public.sections (school_id, academic_year_id, grade_level_id, name)
  select g.school_id, y.id, g.id, 'A'
  from public.grade_levels g join public.academic_years y on y.school_id = g.school_id;

-- الموظفون السبعة (provision_staff) في School A، ثم حساباتهم (provision_account)
select app.provision_staff(
         d.auth,                                                             -- I2: معرّف الموظف = معرّف حسابه
         (select id from public.schools where school_code = 'SA'),
         upper(d.label), initcap(replace(d.label, '_', ' ')), 'Dev', initcap(replace(d.label, '_', ' ')), '2026-09-01',
         p_email => d.email)
  from dev d where d.role_code in ('group_manager','school_admin','secretary','accountant','teacher','counselor','bus_supervisor');
select app.provision_account('staff', d.auth, d.auth)
  from dev d where d.role_code in ('group_manager','school_admin','secretary','accountant','teacher','counselor','bus_supervisor');

-- الأدوار والنطاقات تحت RLS (role.assign / scope.assign) و T8
insert into public.membership_roles (membership_id, role_id, platform_tenant_id, role_owner_key)
  select m.id, r.id, m.platform_tenant_id, '00000000-0000-0000-0000-000000000000'
  from dev d
  join public.profiles p    on p.auth_user_id = d.auth
  join public.memberships m on m.profile_id = p.id
  join public.roles r       on r.code = d.role_code and r.platform_tenant_id is null
  where d.role_code in ('group_manager','school_admin','secretary','accountant','teacher','counselor','bus_supervisor');
insert into public.membership_scopes (membership_id, platform_tenant_id, scope_type, group_id, school_id)
  select m.id, m.platform_tenant_id,
         case when d.scope like 'G%' then 'group' else 'school' end,
         (select id from public.groups  where group_code  = d.scope),
         (select id from public.schools where school_code = d.scope)
  from dev d
  join public.profiles p    on p.auth_user_id = d.auth
  join public.memberships m on m.profile_id = p.id
  where d.role_code in ('group_manager','school_admin','secretary','accountant','teacher','counselor','bus_supervisor');
reset role;

-- ------------------------------------------------------------------
-- 3. secretary ← الطالب وولي أمره (H1: سكرتير مدرسة ضمن مجموعة، النطاق من المدرسة)
-- ------------------------------------------------------------------
select pg_temp.act('a0000000-0000-4000-8000-000000000004');
set local role authenticated;
select app.provision_student('e0000000-0000-4000-8000-000000000001', 'e0000000-0000-4000-8000-000000000001',
         (select s.id from public.sections s join public.grade_levels g on g.id = s.grade_level_id
          join public.schools sc on sc.id = s.school_id where sc.school_code = 'SA' and g.sequence_no = 1),
         '2026-09-01', 'Omar', 'Hassan', p_father_name => 'Ahmad', p_grandfather_name => 'Mahmoud',
         p_official_id => '30101010100000', p_official_id_type => 'national_id', p_gender => 'male',
         p_new_family_name => 'Hassan');
select app.provision_guardian('a0000000-0000-4000-8000-000000000009', 'e0000000-0000-4000-8000-000000000001',
         'father', '+201000000001', 'Ahmad', 'Hassan', '2026-09-01', p_father_name => 'Mahmoud', p_is_primary => true);
reset role;

-- ------------------------------------------------------------------
-- 4. tenant_admin ← حساب ولي الأمر (provision_account يتطلب membership.create)
-- ------------------------------------------------------------------
select pg_temp.act('a0000000-0000-4000-8000-000000000001');
set local role authenticated;
select app.provision_account('guardian', 'a0000000-0000-4000-8000-000000000009', 'a0000000-0000-4000-8000-000000000009');
reset role;

select set_config('request.jwt.claims', '', true), set_config('request.jwt.claim.sub', '', true);

-- ------------------------------------------------------------------
-- 5. تحقق ذاتي — أي انحراف يُفشل الـseed
-- ------------------------------------------------------------------
do $$
declare v_bad text; v_n int;
begin
  -- البنية
  if (select count(*) from public.platform_tenants where tenant_code = 'DEV') <> 1
     or (select count(*) from public.schools where platform_tenant_id = 'd0000000-0000-4000-8000-000000000001' and group_id is not null) <> 2
     or (select count(*) from public.schools where platform_tenant_id = 'd0000000-0000-4000-8000-000000000001' and group_id is null) <> 1
     or (select count(*) from public.academic_years where status = 'active') <> 3 then
    raise exception 'seed: structure is not Tenant + Group(2 schools) + standalone school with active years';
  end if;

  -- مستخدم لكل دور من العشرة، بدوره ونطاقه بالضبط
  select string_agg(d.label, ', ') into v_bad
  from dev d
  where d.role_code is not null
    and not exists (
      select 1 from public.profiles p
      join public.memberships m       on m.profile_id = p.id and m.status = 'active'
      join public.membership_roles mr on mr.membership_id = m.id
      join public.roles r             on r.id = mr.role_id and r.code = d.role_code and r.platform_tenant_id is null
      where p.auth_user_id = d.auth
        and (select count(*) from public.membership_roles x where x.membership_id = m.id) = 1
        and case
              when d.scope is null     then not exists (select 1 from public.membership_scopes s where s.membership_id = m.id)
              when d.scope = 'tenant'  then exists (select 1 from public.membership_scopes s where s.membership_id = m.id and s.scope_type = 'tenant')
              when d.scope like 'G%'   then exists (select 1 from public.membership_scopes s join public.groups g on g.id = s.group_id where s.membership_id = m.id and g.group_code = d.scope)
              else                          exists (select 1 from public.membership_scopes s join public.schools sc on sc.id = s.school_id where s.membership_id = m.id and sc.school_code = d.scope)
            end);
  if v_bad is not null then
    raise exception 'seed: users without exactly their role/scope: %', v_bad;
  end if;

  -- لا بيانات مرجعية من الـseed: الكتالوج والأدوار كما بذرتها M23
  if (select count(*) from public.permissions) <> 73 or (select count(*) from public.roles) <> 10
     or (select count(*) from public.role_permissions) <> 255 or (select count(*) from public.platform_admin_roles) <> 1 then
    raise exception 'seed: reference data changed — the seed must not create permissions or roles';
  end if;

  -- لا استثناءات: كل صف في الـTenant كتبه فاعل مُصادَق (tenant_user / platform_admin)، لا system
  select count(*) into v_n from public.audit_log
   where platform_tenant_id = 'd0000000-0000-4000-8000-000000000001' and actor_type = 'system';
  if v_n <> 0 then
    raise exception 'seed: % tenant rows were written in service context (bypassing the application path)', v_n;
  end if;
end $$;

commit;
