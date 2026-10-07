-- M47 — staff_membership_grant (Phase 3A / 3-2، P13، Q3): `can_manage_membership` + فرع الموظف لأول منح.
-- عضوية بلا نطاقات لموظف له تكليف مدرسة **نشط** ضمن نطاق الفاعل تُدار؛ وكل ما عداه كما في M12/M15/M19:
-- لا إدارة ذاتية، عزل الـTenant، «كل نطاقات الهدف ⊆ نطاقات الفاعل» بعد أول نطاق، سياسة النطاق، T8، مسار tenant_admin،
-- وفرعا الطالب وولي الأمر. الإثبات الأخير: نص M12 (بلا الفرع) يُعاد داخل المعاملة فيفشل مسار مدير المدرسة وحده.
begin;

create temp table r (k text primary key, v text) on commit drop;
grant all on r to public;

create function pg_temp.rec(p_key text, p_sql text) returns void
language plpgsql as $$
declare x text;
begin
  begin
    execute p_sql into x;
    x := coalesce(x, '<null>');
  exception when others then
    x := 'ERR ' || sqlstate || ': ' || sqlerrm;
  end;
  insert into r values (p_key, x) on conflict (k) do update set v = excluded.v;
end $$;

create temp table actors (label text primary key, auth uuid) on commit drop;
grant select on actors to public;
create temp table mem (label text primary key, id uuid) on commit drop;     -- عضويات الأهداف بأسمائها
grant select on mem to public;

create function pg_temp.run(p_key text, p_label text, p_sql text) returns void
language plpgsql as $$
declare v_sub uuid := (select auth from actors where label = p_label);
begin
  perform set_config('request.jwt.claims', json_build_object('sub', v_sub, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', v_sub::text, true);
  execute 'set local role authenticated';
  perform pg_temp.rec(p_key, p_sql);
  execute 'reset role';
end $$;

-- ============ Fixture ============
insert into public.platform_tenants (id, tenant_code, host_label, name) values
  ('10000000-0000-0000-0000-000000000001', 'T1', 't1', 'T1'), ('20000000-0000-0000-0000-000000000002', 'T2', 't2', 'T2');
insert into public.groups (id, platform_tenant_id, group_code, name) values ('a1000000-0000-0000-0000-00000000000a', '10000000-0000-0000-0000-000000000001', 'GA', 'GA');
insert into public.schools (id, platform_tenant_id, group_id, school_code, name, slug) values
  ('5a000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', 'a1000000-0000-0000-0000-00000000000a', 'SA', 'SA', 'sa'),
  ('5b000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001', 'a1000000-0000-0000-0000-00000000000a', 'SB', 'SB', 'sb'),
  ('5c000000-0000-0000-0000-000000000003', '20000000-0000-0000-0000-000000000002', null,                                   'SX', 'SX', 'sx');

create function pg_temp.member(p_label text, p_role text, p_tenant uuid, p_scope text, p_target uuid) returns void
language plpgsql as $$
declare v_a uuid := gen_random_uuid(); v_p uuid; v_m uuid;
begin
  insert into auth.users (id, email) values (v_a, p_label || '@m47.invalid');
  insert into public.auth_identities (auth_user_id, kind) values (v_a, 'tenant');
  insert into public.profiles (platform_tenant_id, auth_user_id, display_name) values (p_tenant, v_a, p_label) returning id into v_p;
  insert into public.memberships (platform_tenant_id, profile_id) values (p_tenant, v_p) returning id into v_m;
  insert into public.membership_roles (membership_id, role_id, platform_tenant_id, role_owner_key)
    values (v_m, (select id from public.roles where code = p_role and platform_tenant_id is null), p_tenant, '00000000-0000-0000-0000-000000000000');
  insert into public.membership_scopes (membership_id, platform_tenant_id, scope_type, school_id)
    values (v_m, p_tenant, p_scope, case when p_scope = 'school' then p_target end);
  insert into actors values (p_label, v_a);
  insert into mem values (p_label, v_m);
end $$;
select pg_temp.member('sa', 'school_admin', '10000000-0000-0000-0000-000000000001', 'school', '5a000000-0000-0000-0000-000000000001');
select pg_temp.member('sb', 'school_admin', '10000000-0000-0000-0000-000000000001', 'school', '5b000000-0000-0000-0000-000000000002');
select pg_temp.member('ta', 'tenant_admin', '10000000-0000-0000-0000-000000000001', 'tenant', null);
select pg_temp.member('x',  'school_admin', '20000000-0000-0000-0000-000000000002', 'school', '5c000000-0000-0000-0000-000000000003');

-- موظف بحساب جديد: profile + عضوية **بلا دور ولا نطاق** (ناتج provision_account)، وتكليف مدرسة بالحالة المطلوبة
create function pg_temp.staff_acct(p_label text, p_tenant uuid, p_school uuid, p_active boolean default true) returns void
language plpgsql as $$
declare v_s uuid := gen_random_uuid(); v_p uuid; v_m uuid;
begin
  insert into auth.users (id, email) values (v_s, v_s || '@staff.smas.invalid');
  insert into public.auth_identities (auth_user_id, kind) values (v_s, 'tenant');
  insert into public.profiles (platform_tenant_id, auth_user_id, display_name) values (p_tenant, v_s, p_label) returning id into v_p;
  insert into public.memberships (platform_tenant_id, profile_id) values (p_tenant, v_p) returning id into v_m;
  insert into public.staff (id, platform_tenant_id, profile_id, employee_code, first_name, family_name) values (v_s, p_tenant, v_p, p_label, 'S', p_label);
  if p_school is not null then
    if p_active then
      insert into public.staff_school_assignments (staff_id, school_id, platform_tenant_id, job_title, effective_from) values (v_s, p_school, p_tenant, 'Teacher', '2026-09-01');
    else
      insert into public.staff_school_assignments (staff_id, school_id, platform_tenant_id, job_title, effective_from, status, effective_to)
        values (v_s, p_school, p_tenant, 'Teacher', '2025-09-01', 'ended', '2026-06-30');
    end if;
  end if;
  insert into actors values (p_label, v_s);
  insert into mem values (p_label, v_m);
end $$;
select pg_temp.staff_acct('n_sa',      '10000000-0000-0000-0000-000000000001', '5a000000-0000-0000-0000-000000000001');          -- SA: النطاق أولاً
select pg_temp.staff_acct('n_sa_role', '10000000-0000-0000-0000-000000000001', '5a000000-0000-0000-0000-000000000001');          -- SA: الدور أولاً
select pg_temp.staff_acct('n_sa_esc',  '10000000-0000-0000-0000-000000000001', '5a000000-0000-0000-0000-000000000001');          -- SA: محاولات التصعيد
select pg_temp.staff_acct('n_sa_ta',   '10000000-0000-0000-0000-000000000001', '5a000000-0000-0000-0000-000000000001');          -- SA: يمنحه tenant_admin
select pg_temp.staff_acct('n_sa_nc',   '10000000-0000-0000-0000-000000000001', '5a000000-0000-0000-0000-000000000001');          -- SA: للضابط السلبي
select pg_temp.staff_acct('n_sb',      '10000000-0000-0000-0000-000000000001', '5b000000-0000-0000-0000-000000000002');          -- مدرسة أخرى
select pg_temp.staff_acct('n_ended',   '10000000-0000-0000-0000-000000000001', '5a000000-0000-0000-0000-000000000001', false);   -- تكليف منتهٍ
select pg_temp.staff_acct('n_none',    '10000000-0000-0000-0000-000000000001', null);                                            -- بلا تكليف
select pg_temp.staff_acct('n_x',       '20000000-0000-0000-0000-000000000002', '5c000000-0000-0000-0000-000000000003');          -- Tenant آخر
select pg_temp.staff_acct('n_sa_sb',   '10000000-0000-0000-0000-000000000001', '5a000000-0000-0000-0000-000000000001');          -- مكلَّف في SA وله نطاق SB أصلاً
insert into public.membership_scopes (membership_id, platform_tenant_id, scope_type, school_id)
  select id, '10000000-0000-0000-0000-000000000001', 'school', '5b000000-0000-0000-0000-000000000002' from mem where label = 'n_sa_sb';
-- الفاعل sa نفسه موظف مكلَّف في SA (لاختبار «لا إدارة ذاتية» مع فرع الموظف)
insert into public.staff (id, platform_tenant_id, profile_id, employee_code, first_name, family_name)
  select gen_random_uuid(), '10000000-0000-0000-0000-000000000001', m.profile_id, 'SELF', 'S', 'A' from public.memberships m join mem on mem.id = m.id where mem.label = 'sa';
insert into public.staff_school_assignments (staff_id, school_id, platform_tenant_id, job_title, effective_from)
  select id, '5a000000-0000-0000-0000-000000000001', platform_tenant_id, 'Principal', '2026-09-01' from public.staff where employee_code = 'SELF';

-- ولي أمر بحساب بلا نطاقات، ابنه مسجَّل في SA (فرع M12 القائم — يجب ألا يتغير)
do $$
declare v_t uuid := '10000000-0000-0000-0000-000000000001'; v_sa uuid := '5a000000-0000-0000-0000-000000000001';
  v_year uuid; v_stage uuid; v_grade uuid; v_sec uuid; v_st uuid; v_g uuid := gen_random_uuid(); v_a uuid := gen_random_uuid(); v_p uuid; v_gp uuid; v_gm uuid;
  v_scope uuid := (select scope_owner_id from public.schools where id = '5a000000-0000-0000-0000-000000000001');
  v_iscope uuid := (select i.id from public.identity_scopes i join public.schools s on s.scope_owner_id = i.owner_id where s.id = '5a000000-0000-0000-0000-000000000001');
begin
  insert into public.academic_years (school_id, name, start_date, end_date) values (v_sa, '2026', '2026-09-01', '2027-06-30') returning id into v_year;
  insert into public.stages (school_id, name, sequence_no) values (v_sa, 'P', 1) returning id into v_stage;
  insert into public.grade_levels (school_id, stage_id, name, sequence_no) values (v_sa, v_stage, 'G1', 1) returning id into v_grade;
  insert into public.sections (school_id, academic_year_id, grade_level_id, name) values (v_sa, v_year, v_grade, 'A') returning id into v_sec;
  insert into auth.users (id, email) values (v_a, 'st@m47.invalid');
  insert into public.auth_identities values (v_a, 'tenant');
  insert into public.profiles (platform_tenant_id, auth_user_id, display_name) values (v_t, v_a, 'st') returning id into v_p;
  insert into public.students (platform_tenant_id, identity_scope_id, student_profile_id, official_id, official_id_type, first_name, family_name)
    values (v_t, v_iscope, v_p, 'N-47', 'national_id', 'S', 'S') returning id into v_st;
  insert into public.enrollments (school_id, student_id, platform_tenant_id, academic_year_id, grade_level_id, section_id, identity_scope_id, scope_owner_id, status, effective_from)
    values (v_sa, v_st, v_t, v_year, v_grade, v_sec, v_iscope, v_scope, 'active', '2026-09-01');
  insert into auth.users (id, email) values (v_g, v_g || '@guardians.smas.invalid');
  insert into public.auth_identities values (v_g, 'tenant');
  insert into public.profiles (platform_tenant_id, auth_user_id, display_name) values (v_t, v_g, 'g') returning id into v_gp;
  insert into public.memberships (platform_tenant_id, profile_id) values (v_t, v_gp) returning id into v_gm;
  insert into public.guardians (id, platform_tenant_id, profile_id, first_name, family_name, phone_e164) values (v_g, v_t, v_gp, 'G', 'G', '+201000004700');
  insert into public.student_guardians (student_id, guardian_id, platform_tenant_id, relationship_type) values (v_st, v_g, v_t, 'father');
  insert into mem values ('guardian', v_gm);
end $$;

-- ============ can_manage_membership: مصفوفة الفاعل × الهدف ============
create function pg_temp.matrix(p_actor text) returns void language plpgsql as $$
begin
  perform pg_temp.run('cm.' || p_actor, p_actor,
    $q$select string_agg(label || '=' || case when app.can_manage_membership(id) then 'Y' else 'n' end, ' ' order by label)
         from mem where label in ('n_sa','n_sb','n_ended','n_none','n_x','n_sa_sb','guardian','sa','sb','ta')$q$);
end $$;
select pg_temp.matrix(a) from unnest(array['sa','sb','ta','x']) a;

-- ============ السلوك تحت RLS و T8 ============
create function pg_temp.scope_sql(p_target text, p_school text) returns text language sql as $$
  select format($f$insert into public.membership_scopes (membership_id, platform_tenant_id, scope_type, school_id)
                   select m.id, m.platform_tenant_id, 'school', %L from public.memberships m where m.id = %L returning 'ok'$f$,
                p_school, (select id from mem where label = p_target))
$$;
create function pg_temp.role_sql(p_target text, p_role text) returns text language sql as $$
  select format($f$insert into public.membership_roles (membership_id, role_id, platform_tenant_id, role_owner_key)
                   select m.id, %L, m.platform_tenant_id, '00000000-0000-0000-0000-000000000000' from public.memberships m where m.id = %L returning 'ok'$f$,
                (select id from public.roles where code = p_role and platform_tenant_id is null), (select id from mem where label = p_target))
$$;
-- ملاحظة: `select … from memberships where id =` يمر بسياسة SELECT للعضويات؛ العضوية غير المرئية ← لا صف يُدرج ← '<null>'

-- (2) مدير المدرسة: أول منح لموظف مدرسته — النطاق أولاً ثم الدور، والدور أولاً ثم النطاق
select pg_temp.run('g.sa_scope',       'sa', pg_temp.scope_sql('n_sa', '5a000000-0000-0000-0000-000000000001'));
select pg_temp.run('g.sa_role',        'sa', pg_temp.role_sql('n_sa', 'teacher'));
select pg_temp.run('g.sa_role_first',  'sa', pg_temp.role_sql('n_sa_role', 'teacher'));
select pg_temp.run('g.sa_scope_after', 'sa', pg_temp.scope_sql('n_sa_role', '5a000000-0000-0000-0000-000000000001'));
-- الممنوح صار فعّالاً: المعلم الجديد يملك مفاتيح المعلم داخل SA
select pg_temp.run('g.effective', 'n_sa', $q$select (app.has_permission('staff.read') and app.can_access_school('5a000000-0000-0000-0000-000000000001')
                                                    and not app.can_access_school('5b000000-0000-0000-0000-000000000002') and not app.has_permission('staff.update'))::text$q$);
-- (3) موظف مدرسة أخرى · (4) بلا تكليف نشط · (10) Tenant آخر
select pg_temp.run('d.other_school_scope', 'sa', pg_temp.scope_sql('n_sb', '5a000000-0000-0000-0000-000000000001'));
select pg_temp.run('d.other_school_role',  'sa', pg_temp.role_sql('n_sb', 'teacher'));
select pg_temp.run('d.ended_scope',        'sa', pg_temp.scope_sql('n_ended', '5a000000-0000-0000-0000-000000000001'));
select pg_temp.run('d.ended_role',         'sa', pg_temp.role_sql('n_ended', 'teacher'));
select pg_temp.run('d.none_role',          'sa', pg_temp.role_sql('n_none', 'teacher'));
select pg_temp.run('d.cross_tenant_role',  'sa', pg_temp.role_sql('n_x', 'teacher'));
select pg_temp.run('d.cross_tenant_raw',   'sa', format($f$insert into public.membership_roles (membership_id, role_id, platform_tenant_id, role_owner_key)
  values (%L, %L, '20000000-0000-0000-0000-000000000002', '00000000-0000-0000-0000-000000000000') returning 'ok'$f$,
  (select id from mem where label = 'n_x'), (select id from public.roles where code = 'teacher' and platform_tenant_id is null)));
select pg_temp.run('d.x_into_t1',          'x',  format($f$insert into public.membership_roles (membership_id, role_id, platform_tenant_id, role_owner_key)
  values (%L, %L, '10000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000000') returning 'ok'$f$,
  (select id from mem where label = 'n_sa_esc'), (select id from public.roles where code = 'teacher' and platform_tenant_id is null)));
-- (5) T8 سقف الدور · (6) نطاق خارج نطاق الفاعل
select pg_temp.run('e.tenant_admin_role', 'sa', pg_temp.role_sql('n_sa_ta', 'tenant_admin'));
select pg_temp.run('e.scope_sb',          'sa', pg_temp.scope_sql('n_sa_esc', '5b000000-0000-0000-0000-000000000002'));
select pg_temp.run('e.scope_tenant',      'sa', format($f$insert into public.membership_scopes (membership_id, platform_tenant_id, scope_type)
  values (%L, '10000000-0000-0000-0000-000000000001', 'tenant') returning 'ok'$f$, (select id from mem where label = 'n_sa_esc')));
-- (7) بعد وجود نطاق: القاعدة القائمة تحكم — نطاق SB يُخرج العضوية من إدارة SA ولو كان الموظف مكلَّفاً في SA
select pg_temp.run('f.scoped_elsewhere_role', 'sa', pg_temp.role_sql('n_sa_sb', 'teacher'));
select pg_temp.run('f.ta_adds_sb',            'ta', pg_temp.scope_sql('n_sa', '5b000000-0000-0000-0000-000000000002'));
select pg_temp.run('f.sa_after_ta',           'sa', format($f$select app.can_manage_membership(%L)::text$f$, (select id from mem where label = 'n_sa')));
select pg_temp.run('f.sa_revoke_after_ta',    'sa', format($f$with d as (delete from public.membership_roles where membership_id = %L returning 1) select count(*)::text from d$f$, (select id from mem where label = 'n_sa')));
-- السحب (G2) ضمن الإدارة: sa يسحب دور موظفه ونطاقه
select pg_temp.run('f.sa_revoke_role',  'sa', format($f$with d as (delete from public.membership_roles  where membership_id = %L returning 1) select count(*)::text from d$f$, (select id from mem where label = 'n_sa_role')));
select pg_temp.run('f.sa_revoke_scope', 'sa', format($f$with d as (delete from public.membership_scopes where membership_id = %L returning 1) select count(*)::text from d$f$, (select id from mem where label = 'n_sa_role')));
-- (8) لا إدارة ذاتية — والفاعل نفسه موظف مكلَّف في مدرسته
select pg_temp.run('s.self_role', 'sa', pg_temp.role_sql('sa', 'teacher'));
-- (1) مسار tenant_admin كما كان: يمنح من لا تصله مدرسة (منتهٍ، بلا تكليف)
--     إدراج مباشر بالقيم: can_see_membership (M12، لم تُمس) لا تُظهر عضوية بلا نطاقات لموظف بلا تكليف نشط حتى لنطاق الـTenant،
--     فالقراءة المسبقة للعضوية تخفي الصف؛ الإدارة (can_manage) قائمة — وهذا ما يُختبر
select pg_temp.run('t.ta_ended', 'ta', format($f$insert into public.membership_roles (membership_id, role_id, platform_tenant_id, role_owner_key)
  values (%L, %L, '10000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000000') returning 'ok'$f$,
  (select id from mem where label = 'n_ended'), (select id from public.roles where code = 'teacher' and platform_tenant_id is null)));
select pg_temp.run('t.ta_none',  'ta', format($f$with i as (insert into public.membership_scopes (membership_id, platform_tenant_id, scope_type, school_id)
  values (%L, '10000000-0000-0000-0000-000000000001', 'school', '5a000000-0000-0000-0000-000000000001') returning 1) select 'ok' from i$f$,
  (select id from mem where label = 'n_none')));
select pg_temp.run('t.ta_sees_unreachable', 'ta', format($f$select count(*)::text from public.memberships where id = %L$f$, (select id from mem where label = 'n_ended')));
-- (9) ولي الأمر: كما كان
select pg_temp.run('u.guardian_sa', 'sa', format($f$select app.can_manage_membership(%L)::text$f$, (select id from mem where label = 'guardian')));
select pg_temp.run('u.guardian_sb', 'sb', format($f$select app.can_manage_membership(%L)::text$f$, (select id from mem where label = 'guardian')));

-- انتهاء التكليف يسحب نقطة الدخول فوراً (H2)
update public.staff_school_assignments a set status = 'ended', effective_to = '2026-12-31'
  from public.staff s where s.id = a.staff_id and s.employee_code = 'n_sa_esc';
select pg_temp.run('h.after_end', 'sa', pg_temp.role_sql('n_sa_esc', 'teacher'));

-- ============ الضابط السلبي داخل الحزمة: نص M12 (بلا فرع الموظف) ⇒ مسار مدير المدرسة يفشل وحده ============
set local role app_owner;
create or replace function app.can_manage_membership(p_membership_id uuid)
returns boolean language sql stable security definer set search_path = app, public, pg_temp
as $$
  select exists (
    select 1 from public.memberships m
    where m.id = p_membership_id
      and m.platform_tenant_id = app.current_tenant_id()
      and m.profile_id <> app.current_profile_id()
      and not exists (
        select 1 from public.membership_scopes ms
        where ms.membership_id = m.id
          and not (   (ms.scope_type = 'tenant' and app.can_access_tenant(ms.platform_tenant_id))
                   or (ms.scope_type = 'group'  and app.can_access_group(ms.group_id))
                   or (ms.scope_type = 'school' and app.can_access_school(ms.school_id)))
      )
      and (
            exists (select 1 from public.membership_scopes ms where ms.membership_id = m.id)
         or app.can_access_tenant(m.platform_tenant_id)
         or exists (select 1 from public.students s  where s.student_profile_id = m.profile_id and app.student_in_scope(s.id))
         or exists (select 1 from public.guardians g where g.profile_id = m.profile_id and app.guardian_in_scope(g.id))
      )
  );
$$;
reset role;
select pg_temp.run('nc.sa_scope',   'sa', pg_temp.scope_sql('n_sa_nc', '5a000000-0000-0000-0000-000000000001'));
select pg_temp.run('nc.sa_role',    'sa', pg_temp.role_sql('n_sa_nc', 'teacher'));
select pg_temp.run('nc.ta_role',    'ta', pg_temp.role_sql('n_sa_nc', 'teacher'));
select pg_temp.run('nc.guardian',   'sa', format($f$select app.can_manage_membership(%L)::text$f$, (select id from mem where label = 'guardian')));

select plan(4 + 5 + 8 + 3 + 6 + 1 + 3 + 2 + 1 + 4 + 3);

-- المصفوفة
select is((select v from r where k = 'cm.sa'), 'guardian=Y n_ended=n n_none=n n_sa=Y n_sa_sb=n n_sb=n n_x=n sa=n sb=n ta=n',
          'school admin SA manages: its own school''s new staff account and its guardian — nothing else (other school, ended, unassigned, other tenant, scoped elsewhere, self, peers, tenant admin)');
select is((select v from r where k = 'cm.sb'), 'guardian=n n_ended=n n_none=n n_sa=n n_sa_sb=Y n_sb=Y n_x=n sa=n sb=n ta=n',
          'school admin SB manages SB''s new staff account and the membership scoped to SB only');
select is((select v from r where k = 'cm.ta'), 'guardian=Y n_ended=Y n_none=Y n_sa=Y n_sa_sb=Y n_sb=Y n_x=n sa=Y sb=Y ta=n',
          'tenant admin: unchanged — every membership of its tenant except its own, none of another tenant');
select is((select v from r where k = 'cm.x'),  'guardian=n n_ended=n n_none=n n_sa=n n_sa_sb=n n_sb=n n_x=Y sa=n sb=n ta=n',
          'T2 admin manages its own staff account only — never a T1 membership');

-- (2) أول منح
select is((select v from r where k = 'g.sa_scope'),       'ok', 'school admin grants the first scope (its school) to its new staff account');
select is((select v from r where k = 'g.sa_role'),        'ok', '…then the teacher role');
select is((select v from r where k = 'g.sa_role_first'),  'ok', 'the other order works too: role first on a scope-less staff membership');
select is((select v from r where k = 'g.sa_scope_after'), 'ok', '…then the scope');
select is((select v from r where k = 'g.effective'),      'true', 'the grant is effective: teacher keys inside SA, nothing in SB, no staff.update');

-- (3) (4) (10) الرفض بالعلاقة
select is((select v from r where k = 'd.other_school_scope'), '<null>', 'another school''s staff: the membership is not even visible — no scope inserted');
select is((select v from r where k = 'd.other_school_role'),  '<null>', 'another school''s staff: no role inserted');
select is((select v from r where k = 'd.ended_scope'),        '<null>', 'staff whose assignment ended: no scope inserted (H2)');
select is((select v from r where k = 'd.ended_role'),         '<null>', 'staff whose assignment ended: no role inserted');
select is((select v from r where k = 'd.none_role'),          '<null>', 'staff with no assignment: no role inserted');
select is((select v from r where k = 'd.cross_tenant_role'),  '<null>', 'another tenant''s staff: no role inserted');
select ok((select v from r where k = 'd.cross_tenant_raw') like 'ERR 42501%row-level security%membership_roles%', 'cross-tenant with a raw insert (no visibility dependence): rejected by RLS');
select ok((select v from r where k = 'd.x_into_t1')        like 'ERR 42501%row-level security%membership_roles%', 'a T2 admin cannot grant into a T1 staff membership');

-- (5) (6) التصعيد
select ok((select v from r where k = 'e.tenant_admin_role') like 'ERR 42501%T8: role grants permissions the actor does not hold%', 'T8 unchanged: school admin cannot give tenant_admin to its own new staff');
select ok((select v from r where k = 'e.scope_sb')     like 'ERR 42501%row-level security%membership_scopes%', 'scope policy unchanged: no scope outside the actor''s scope (SB)');
select ok((select v from r where k = 'e.scope_tenant') like 'ERR 42501%row-level security%membership_scopes%', 'scope policy unchanged: no tenant scope from a school admin');

-- (7) بعد أول نطاق + السحب
select ok((select v from r where k = 'f.scoped_elsewhere_role') like 'ERR 42501%row-level security%membership_roles%', 'a staff member assigned in SA but already scoped to SB is visible to SA yet not SA''s to manage — the staff branch is the first-grant door only');
select is((select v from r where k = 'f.ta_adds_sb'),         'ok',    'tenant admin adds an SB scope to the SA teacher');
select is((select v from r where k = 'f.sa_after_ta'),        'false', '…after which SA can no longer manage that membership (all scopes ⊆ actor — F4)');
select is((select v from r where k = 'f.sa_revoke_after_ta'), '0',     '…nor revoke its role');
select is((select v from r where k = 'f.sa_revoke_role'),     '1',     'within its authority SA revokes the role it granted (G2)');
select is((select v from r where k = 'f.sa_revoke_scope'),    '1',     '…and the scope');

-- (8) الذات
select ok((select v from r where k = 's.self_role') like 'ERR 42501%row-level security%membership_roles%', 'no self-management, even when the actor is itself staff assigned in its school (F5)');

-- (1) tenant_admin
select is((select v from r where k = 't.ta_ended'), 'ok', 'tenant admin path unchanged: grants a staff member no school reaches');
select is((select v from r where k = 't.ta_none'),  'ok', 'tenant admin path unchanged: scopes a staff member with no assignment');
select is((select v from r where k = 't.ta_sees_unreachable'), '0', 'recorded as-is (M12 can_see_membership, untouched): a scope-less membership of staff with no active assignment is not listed even for the tenant admin');

-- (9) ولي الأمر
select is((select v from r where k = 'u.guardian_sa'), 'true',  'guardian branch unchanged: SA manages the guardian of its student');
select is((select v from r where k = 'u.guardian_sb'), 'false', 'guardian branch unchanged: SB does not');

-- H2
select is((select v from r where k = 'h.after_end'), '<null>', 'ending the school assignment closes the first-grant door at once');

-- الضابط السلبي
select ok((select v from r where k = 'nc.sa_scope') like 'ERR 42501%row-level security%membership_scopes%', 'negative control: without the staff branch SA cannot grant the first scope');
select ok((select v from r where k = 'nc.sa_role')  like 'ERR 42501%row-level security%membership_roles%',  'negative control: without the staff branch SA cannot grant the first role');
select is((select v from r where k = 'nc.ta_role'),  'ok',   'negative control: the tenant admin path does not depend on the branch');
select is((select v from r where k = 'nc.guardian'), 'true', 'negative control: the guardian branch does not depend on it either');

-- العقد: التوقيع والمالك والمنح كما هي
select is((select pg_get_userbyid(proowner) || '|' || prosecdef || '|' || array_to_string(proconfig, ',') from pg_proc where oid = 'app.can_manage_membership(uuid)'::regprocedure),
          'app_owner|true|search_path=app, public, pg_temp', 'contract unchanged: owner, SECURITY DEFINER, pinned search_path');
select ok(has_function_privilege('authenticated', 'app.can_manage_membership(uuid)', 'EXECUTE') and not has_function_privilege('anon', 'app.can_manage_membership(uuid)', 'EXECUTE'),
          'EXECUTE unchanged: authenticated yes, anon no');
select is((select count(*)::int from public.permissions), 75, 'no permission key added');

select * from finish();
rollback;
