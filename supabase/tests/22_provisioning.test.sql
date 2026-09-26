-- M22 — provisioning_functions: إنشاء الهوية مع علاقتها (§5.1، §5.2، §5.4) + bootstrap_tenant (قرار 2026-09-26)
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

create temp table ids (label text primary key, auth uuid) on commit drop;
grant all on ids to public;

create function pg_temp.run(p_key text, p_label text, p_sql text) returns void
language plpgsql as $$
declare v_sub uuid := (select auth from ids where label = p_label);
begin
  perform set_config('request.jwt.claims', json_build_object('sub', v_sub, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', coalesce(v_sub::text, ''), true);
  execute 'set local role authenticated';
  perform pg_temp.rec(p_key, p_sql);
  insert into r values (p_key || '#ctx', coalesce(current_setting('app.audit_action', true), '') || '|' || coalesce(current_setting('app.audit_reason', true), ''))
    on conflict (k) do update set v = excluded.v;
  execute 'reset role';
end $$;

-- حساب Auth جاهز (الخطوة 3 من الـSaga — ينشئه FastAPI عبر Admin API)
create function pg_temp.auth(p_label text) returns uuid language plpgsql as $$
declare v uuid := gen_random_uuid();
begin
  insert into auth.users (id, email) values (v, p_label || '@m22.invalid');
  insert into ids values (p_label, v) on conflict (label) do update set auth = excluded.auth;
  return v;
end $$;
create function pg_temp.a(p_label text) returns uuid language sql as $$ select auth from ids where label = p_label $$;

-- ============ Fixture ============
insert into public.platform_tenants (id, tenant_code, name) values
  ('10000000-0000-0000-0000-000000000001', 'T1', 'T1'), ('20000000-0000-0000-0000-000000000002', 'T2', 'T2');
insert into public.groups (id, platform_tenant_id, group_code, name) values
  ('a1000000-0000-0000-0000-00000000000a', '10000000-0000-0000-0000-000000000001', 'GA', 'GA'),
  ('a2000000-0000-0000-0000-00000000000b', '10000000-0000-0000-0000-000000000001', 'GB', 'GB');
insert into public.schools (id, platform_tenant_id, group_id, school_code, name, slug) values
  ('5a100000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', 'a1000000-0000-0000-0000-00000000000a', 'SA1', 'SA1', 'sa1'),
  ('5b100000-0000-0000-0000-000000000003', '10000000-0000-0000-0000-000000000001', 'a2000000-0000-0000-0000-00000000000b', 'SB1', 'SB1', 'sb1'),
  ('55000000-0000-0000-0000-000000000004', '10000000-0000-0000-0000-000000000001', null,                                   'SS',  'SS',  'ss');
create temp table sec (code text primary key, id uuid) on commit drop;
grant select on sec to public;
do $$
declare s record; v_y uuid; v_st uuid; v_g uuid; v_sec uuid;
begin
  for s in select id, school_code from public.schools loop
    insert into public.academic_years (school_id, name, start_date, end_date, status) values (s.id, 'Y', '2026-09-01', '2027-06-30', 'active') returning id into v_y;
    insert into public.stages (school_id, name, sequence_no) values (s.id, 'P', 1) returning id into v_st;
    insert into public.grade_levels (school_id, stage_id, name, sequence_no) values (s.id, v_st, 'G1', 1) returning id into v_g;
    insert into public.sections (school_id, academic_year_id, grade_level_id, name) values (s.id, v_y, v_g, 'A') returning id into v_sec;
    insert into sec values (s.school_code, v_sec);
  end loop;
end $$;
create function pg_temp.sec(p text) returns uuid language sql as $$ select id from sec where code = p $$;

insert into public.permissions (code, resource, operation, description)
  select c, split_part(c, '.', 1), split_part(c, '.', 2), 'test' from unnest(array[
    'student.create','student.read','enrollment.create','enrollment.read','staff.create','staff.assign','staff.read',
    'guardian.create','guardian.link','guardian.read','family.read','membership.create','tenant.read','tenant.create']) c on conflict (code) do nothing;
create function pg_temp.perm(c text) returns uuid language sql as $$ select id from public.permissions where code = c $$;

-- أدوار النظام التي تسندها الدوال (tenant_admin، student، guardian) مبذورة فعلاً في M23 — تُستعمل كما هي.
-- دورا الفاعلين: zt_secretary (كل الصلاحيات عدا tenant.*؛ يغطي أدوار student و guardian المبذورة لـT8)، weak (بلا صلاحيات دور student)
insert into public.roles (id, platform_tenant_id, code, name, is_system) values
  ('70000000-0000-0000-0000-000000000004', null, 'zt_secretary', 'Secretary', true),
  ('70000000-0000-0000-0000-000000000005', null, 'weak',         'Weak',      true);
insert into public.role_permissions (role_id, permission_id)
            select '70000000-0000-0000-0000-000000000004'::uuid, id from public.permissions where code not like 'tenant.%'
  union all select '70000000-0000-0000-0000-000000000005'::uuid, pg_temp.perm(c) from unnest(array['student.create','enrollment.create']) c;   -- بلا صلاحيات دور student

create function pg_temp.member(p_label text, p_role uuid, p_scope text) returns void
language plpgsql as $$
declare v_auth uuid := pg_temp.auth(p_label); v_p uuid; v_m uuid;
begin
  insert into public.auth_identities values (v_auth, 'tenant');
  insert into public.profiles (platform_tenant_id, auth_user_id, display_name) values ('10000000-0000-0000-0000-000000000001', v_auth, p_label) returning id into v_p;
  insert into public.memberships (platform_tenant_id, profile_id) values ('10000000-0000-0000-0000-000000000001', v_p) returning id into v_m;
  if p_role is not null then
    insert into public.membership_roles (membership_id, role_id, platform_tenant_id, role_owner_key) values (v_m, p_role, '10000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000000');
  end if;
  insert into public.membership_scopes (membership_id, platform_tenant_id, scope_type, school_id) values (v_m, '10000000-0000-0000-0000-000000000001', 'school', (select id from public.schools where school_code = p_scope));
end $$;
select pg_temp.member('sec',  '70000000-0000-0000-0000-000000000004', 'SA1');   -- سكرتير مدرسة ضمن مجموعة (H1)
select pg_temp.member('secs', '70000000-0000-0000-0000-000000000004', 'SS');    -- سكرتير مدرسة مستقلة
select pg_temp.member('sb',   '70000000-0000-0000-0000-000000000004', 'SB1');
select pg_temp.member('weak', '70000000-0000-0000-0000-000000000005', 'SA1');
select pg_temp.member('nop',  null,                                   'SA1');

-- Platform Admins
insert into public.platform_admin_roles (id, code, name) values ('81000000-0000-0000-0000-000000000001', 'ops', 'Ops'), ('82000000-0000-0000-0000-000000000002', 'none', 'None');
insert into public.platform_admin_role_permissions values ('81000000-0000-0000-0000-000000000001', pg_temp.perm('tenant.create'));
do $$
declare l text; v_auth uuid; v_su uuid;
begin
  foreach l in array array['pa','pa0'] loop
    v_auth := pg_temp.auth(l);
    insert into public.auth_identities values (v_auth, 'platform');
    insert into public.system_users (auth_user_id, display_name) values (v_auth, l) returning id into v_su;
    insert into public.platform_admin_assignments (system_user_id, platform_admin_role_id)
      values (v_su, case l when 'pa' then '81000000-0000-0000-0000-000000000001'::uuid else '82000000-0000-0000-0000-000000000002'::uuid end);
  end loop;
end $$;

-- عائلة موجودة في T1 بلا طالب ضمن النطاق
insert into public.families (id, platform_tenant_id, family_name) values ('f0000000-0000-0000-0000-00000000000f', '10000000-0000-0000-0000-000000000001', 'hidden');

-- حسابات Auth للكيانات الجديدة
select pg_temp.auth(l) from unnest(array['st1','st2','st3','stw','stx','gacc','facc','adm3','dup']) l;

-- D1 (M24): حساب الطالب معرّفه = معرّف الطالب. 'self' ⇒ حساب Auth بمعرّف الطالب وبريد D1 الاصطناعي
create function pg_temp.sa(p uuid) returns uuid language plpgsql as $$
begin
  insert into auth.users (id, email) values (p, p::text || '@students.smas.invalid') on conflict (id) do nothing;
  return p;
end $$;
create function pg_temp.ps(p_student uuid, p_auth text, p_sec text, p_extra text default '') returns text language sql as $$
  select format($f$select app.provision_student(%L, %L, %L, '2026-09-01', 'Ali', 'Hasan'%s)::text$f$, p_student,
                case when p_auth = 'self' then pg_temp.sa(p_student) else pg_temp.a(p_auth) end, pg_temp.sec(p_sec), p_extra) $$;

-- ============ provision_student ============
select pg_temp.run('ps.ok',       'sec',  pg_temp.ps('e1000000-0000-0000-0000-000000000001', 'self', 'SA1', ', p_new_family_name => ''Hasan'''));
select pg_temp.run('ps.again',    'sec',  pg_temp.ps('e1000000-0000-0000-0000-000000000001', 'self', 'SA1', ', p_new_family_name => ''Hasan'''));
-- المعرّف نفسه لمدرسة أخرى (سكرتير SS) = بيانات مختلفة
select pg_temp.run('ps.conflict', 'secs', pg_temp.ps('e1000000-0000-0000-0000-000000000001', 'self', 'SS'));
-- D1: حساب بمعرّف آخر مرفوض قبل أي كتابة
select pg_temp.run('ps.d1',       'sec',  pg_temp.ps('e8000000-0000-0000-0000-000000000008', 'st2', 'SA1'));
select pg_temp.rec('ps.d1_trace', $q$select count(*)::text from public.students where id = 'e8000000-0000-0000-0000-000000000008'$q$);
select pg_temp.run('ps.visible',  'sec',  $q$select count(*)::text from public.students where id = 'e1000000-0000-0000-0000-000000000001'$q$);
select pg_temp.rec('ps.shape', $q$select (st.identity_scope_id = (select id from public.identity_scopes where group_id = 'a1000000-0000-0000-0000-00000000000a'))::text
  || '|' || (st.temporary_id ~ '^TMP-[0-9]{4}-[0-9]{6,}$')::text
  || '|' || (select string_agg(e.status || ':' || sc.school_code, ',') from public.enrollments e join public.schools sc on sc.id = e.school_id where e.student_id = st.id)
  || '|' || (select string_agg(r.code, ',') from public.memberships m join public.membership_roles mr on mr.membership_id = m.id join public.roles r on r.id = mr.role_id where m.profile_id = st.student_profile_id)
  || '|' || (select family_name from public.families f where f.id = st.family_id)
  || '|' || (select count(*) from public.profiles p where p.auth_user_id = 'e1000000-0000-0000-0000-000000000001')
  from public.students st where st.id = 'e1000000-0000-0000-0000-000000000001'$q$);
select pg_temp.run('ps.standalone','secs', pg_temp.ps('e2000000-0000-0000-0000-000000000002', 'self', 'SS'));
select pg_temp.rec('ps.standalone_scope', $q$select (identity_scope_id = (select id from public.identity_scopes where school_id = '55000000-0000-0000-0000-000000000004'))::text from public.students where id = 'e2000000-0000-0000-0000-000000000002'$q$);
select pg_temp.run('ps.sb',       'sb',   pg_temp.ps('e3000000-0000-0000-0000-000000000003', 'self', 'SA1'));
select pg_temp.run('ps.nop',      'nop',  pg_temp.ps('e3000000-0000-0000-0000-000000000003', 'self', 'SA1'));
select pg_temp.run('ps.weak',     'weak', pg_temp.ps('e4000000-0000-0000-0000-000000000004', 'self', 'SA1'));   -- T8 داخل الإنشاء
select pg_temp.rec('ps.weak_trace', $q$select (select count(*) from public.profiles where auth_user_id = 'e4000000-0000-0000-0000-000000000004')
  || '/' || (select count(*) from public.auth_identities where auth_user_id = 'e4000000-0000-0000-0000-000000000004')
  || '/' || (select count(*) from public.students where id = 'e4000000-0000-0000-0000-000000000004')$q$);
-- حساب Auth مستعمل (O1/G10): معرّف الطالب = حساب السكرتير القائم، فيمر D1 ويصطدم بحصرية الهوية
select pg_temp.run('ps.reused_auth','sec', pg_temp.ps(pg_temp.a('sec'), 'self', 'SA1'));
select pg_temp.rec('ps.reused_trace', format($q$select count(*)::text from public.students where id = %L$q$, pg_temp.a('sec')));
select pg_temp.run('ps.hidden_family','sec', pg_temp.ps('e6000000-0000-0000-0000-000000000006', 'self', 'SA1', ', p_family_id => ''f0000000-0000-0000-0000-00000000000f'''));
select pg_temp.run('ps.direct',   'sec',  format($q$insert into public.students (platform_tenant_id, identity_scope_id, student_profile_id, first_name, family_name, official_id, official_id_type)
  values ('10000000-0000-0000-0000-000000000001', (select id from public.identity_scopes limit 1), gen_random_uuid(), 'x', 'x', 'X1', 'national_id') returning 'ok'$q$));

-- ============ provision_staff ============
create function pg_temp.pf(p_staff uuid, p_school text, p_code text) returns text language sql as $$
  select format($f$select app.provision_staff(%L, %L, %L, 'Omar', 'Said', 'Teacher', '2026-09-01')::text$f$, p_staff, (select id from public.schools where school_code = p_school), p_code) $$;
select pg_temp.run('pf.ok',      'sec', pg_temp.pf('c1000000-0000-0000-0000-000000000001', 'SA1', 'E1'));
select pg_temp.run('pf.again',   'sec', pg_temp.pf('c1000000-0000-0000-0000-000000000001', 'SA1', 'E1'));
select pg_temp.run('pf.conflict','sec', pg_temp.pf('c1000000-0000-0000-0000-000000000001', 'SA1', 'E9'));
select pg_temp.run('pf.visible', 'sec', $q$select count(*)::text from public.staff where id = 'c1000000-0000-0000-0000-000000000001'$q$);
select pg_temp.run('pf.sb',      'sb',  pg_temp.pf('c2000000-0000-0000-0000-000000000002', 'SA1', 'E2'));

-- ============ provision_guardian ============
create function pg_temp.pg(p_guardian uuid, p_student uuid, p_phone text) returns text language sql as $$
  select format($f$select app.provision_guardian(%L, %L, 'father', %L, 'Hasan', 'Ali', '2026-09-01')::text$f$, p_guardian, p_student, p_phone) $$;
select pg_temp.run('pg.ok',      'sec', pg_temp.pg('d1000000-0000-0000-0000-000000000001', 'e1000000-0000-0000-0000-000000000001', '+201000000001'));
select pg_temp.run('pg.again',   'sec', pg_temp.pg('d1000000-0000-0000-0000-000000000001', 'e1000000-0000-0000-0000-000000000001', '+201000000001'));
select pg_temp.run('pg.visible', 'sec', $q$select count(*)::text from public.guardians where id = 'd1000000-0000-0000-0000-000000000001'$q$);
select pg_temp.run('pg.sb',      'sb',  pg_temp.pg('d2000000-0000-0000-0000-000000000002', 'e1000000-0000-0000-0000-000000000001', '+201000000002'));
select pg_temp.run('pg.phone',   'sec', pg_temp.pg('d3000000-0000-0000-0000-000000000003', 'e1000000-0000-0000-0000-000000000001', '+201000000001'));

-- ============ provision_account ============
select pg_temp.run('pa.guardian', 'sec', format($q$select (app.provision_account('guardian', 'd1000000-0000-0000-0000-000000000001', %L) is not null)::text$q$, pg_temp.a('gacc')));
select pg_temp.run('pa.again',    'sec', format($q$select (app.provision_account('guardian', 'd1000000-0000-0000-0000-000000000001', %L) is not null)::text$q$, pg_temp.a('gacc')));
select pg_temp.run('pa.conflict', 'sec', format($q$select app.provision_account('guardian', 'd1000000-0000-0000-0000-000000000001', %L)::text$q$, pg_temp.a('dup')));
select pg_temp.run('pa.staff',    'sec', format($q$select (app.provision_account('staff', 'c1000000-0000-0000-0000-000000000001', %L) is not null)::text$q$, pg_temp.a('facc')));
select pg_temp.run('pa.sb',       'sb',  format($q$select app.provision_account('guardian', 'd1000000-0000-0000-0000-000000000001', %L)::text$q$, pg_temp.a('dup')));
select pg_temp.run('pa.kind',     'sec', format($q$select app.provision_account('student', 'e1000000-0000-0000-0000-000000000001', %L)::text$q$, pg_temp.a('dup')));
select pg_temp.rec('pa.shape', $q$select
     (select g.profile_id = p.id from public.guardians g join public.profiles p on p.auth_user_id = (select auth from ids where label = 'gacc') where g.id = 'd1000000-0000-0000-0000-000000000001')::text
  || '|' || (select string_agg(r.code, ',') from public.profiles p join public.memberships m on m.profile_id = p.id join public.membership_roles mr on mr.membership_id = m.id join public.roles r on r.id = mr.role_id
             where p.auth_user_id = (select auth from ids where label = 'gacc'))
  || '|' || (select count(*) from public.profiles p join public.memberships m on m.profile_id = p.id join public.membership_roles mr on mr.membership_id = m.id
             where p.auth_user_id = (select auth from ids where label = 'facc'))
  || '|' || (select count(*) from public.profiles p join public.memberships m on m.profile_id = p.id join public.membership_scopes ms on ms.membership_id = m.id
             where p.auth_user_id = (select auth from ids where label = 'facc'))$q$);

-- ============ bootstrap_tenant ============
create function pg_temp.bt(p_id uuid, p_code text, p_auth text) returns text language sql as $$
  select format($f$select app.bootstrap_tenant(%L, %L, 'New Tenant', %L, 'Admin')::text$f$, p_id, p_code, pg_temp.a(p_auth)) $$;
select pg_temp.run('bt.pa0',     'pa0', pg_temp.bt('30000000-0000-0000-0000-000000000003', 'T3', 'adm3'));
select pg_temp.run('bt.tenant',  'sec', pg_temp.bt('30000000-0000-0000-0000-000000000003', 'T3', 'adm3'));
select pg_temp.run('bt.ok',      'pa',  pg_temp.bt('30000000-0000-0000-0000-000000000003', 'T3', 'adm3'));
select pg_temp.run('bt.again',   'pa',  pg_temp.bt('30000000-0000-0000-0000-000000000003', 'T3', 'adm3'));
select pg_temp.run('bt.conflict','pa',  pg_temp.bt('30000000-0000-0000-0000-000000000003', 'T9', 'adm3'));
select pg_temp.run('bt.admin_sees', 'adm3', $q$select string_agg(tenant_code, ',') from public.platform_tenants$q$);
select pg_temp.rec('bt.shape', $q$select string_agg(r.code, ',') || '|' || (select string_agg(ms.scope_type, ',') from public.membership_scopes ms where ms.membership_id = m.id)
  from public.profiles p join public.memberships m on m.profile_id = p.id join public.membership_roles mr on mr.membership_id = m.id join public.roles r on r.id = mr.role_id
  where p.auth_user_id = (select auth from ids where label = 'adm3') group by m.id$q$);
select pg_temp.rec('bt.audit', $q$select actor_type from public.audit_log where entity_type = 'platform_tenants' and entity_id = '30000000-0000-0000-0000-000000000003' and action = 'insert'$q$);
-- الإعفاء ضيق: Platform Admin لا يكتب membership_roles مباشرة
select pg_temp.run('bt.pa_direct', 'pa', format($q$insert into public.membership_roles (membership_id, role_id, platform_tenant_id, role_owner_key)
  values (%L, '70000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000000') returning 'ok'$q$,
  (select m.id from public.memberships m join public.profiles p on p.id = m.profile_id where p.auth_user_id = pg_temp.a('sec'))));

-- ============ إيقاف الـTenant (M21b) ============
update public.platform_tenants set status = 'suspended', suspended_at = now() where id = '10000000-0000-0000-0000-000000000001';
select pg_temp.run('susp.ps', 'sec', pg_temp.ps('e7000000-0000-0000-0000-000000000007', 'self', 'SA1'));
update public.platform_tenants set status = 'active', suspended_at = null where id = '10000000-0000-0000-0000-000000000001';

-- ============ البنية ============
create temp table fn (f regprocedure) on commit drop;
insert into fn values
  ('app.bootstrap_tenant(uuid,text,text,uuid,text)'),
  ('app.provision_student(uuid,uuid,uuid,date,text,text,text,text,text,text,text,date,text,uuid,text,text)'),
  ('app.provision_staff(uuid,uuid,text,text,text,text,date,text,text,text,text,text,text,date,date)'),
  ('app.provision_guardian(uuid,uuid,text,text,text,text,date,text,text,text,text,text,boolean)'),
  ('app.provision_account(text,uuid,uuid)');

select plan(54);

-- ---------- provision_student ----------
select is((select v from r where k = 'ps.ok'),       'e1000000-0000-0000-0000-000000000001', 'provision_student: a school-scoped secretary in a grouped school (H1)');
select is((select v from r where k = 'ps.again'),    'e1000000-0000-0000-0000-000000000001', 'idempotency: the same request returns the existing student');
select ok((select v from r where k = 'ps.conflict')  like 'ERR 23505%conflict: student%', 'idempotency: the same id with different data is a conflict');
select ok((select v from r where k = 'ps.d1')        like 'ERR 22023%invariant: student account id must equal student id (D1)%', 'D1 (M24): the account id must be the student id');
select is((select v from r where k = 'ps.d1_trace'),  '0', 'D1: rejected before anything is written');
select is((select v from r where k = 'ps.visible'),  '1', '§5.1: the created student is visible to its creator (the enrollment was created with it)');
select is((select v from r where k = 'ps.shape'),    'true|true|active:SA1|student|Hasan|1',
          'H1 + shape: identity scope = the target school''s group; temporary_id generated (O3); active enrollment; student role; new family; exactly one profile');
select is((select v from r where k = 'ps.standalone'), 'e2000000-0000-0000-0000-000000000002', 'provision_student: standalone school');
select is((select v from r where k = 'ps.standalone_scope'), 'true', 'H1: a standalone school''s own identity scope');
select ok((select v from r where k = 'ps.sb')        like 'ERR P0002%not found%', 'provision_student: a section outside the actor''s scope → not found');
select ok((select v from r where k = 'ps.nop')       like 'ERR 42501%forbidden%', 'provision_student: without student.create/enrollment.create');
select ok((select v from r where k = 'ps.weak')      like 'ERR 42501%T8: role grants permissions the actor does not hold: enrollment.read, profile.read, school.read, student.read%', 'T8 inside provisioning: assigning the student role needs its permissions');
select is((select v from r where k = 'ps.weak_trace'), '0/0/0', 'saga atomicity: a failed provisioning leaves no profile, identity or student (FastAPI then compensates the Auth user)');
select ok((select v from r where k = 'ps.reused_auth') like 'ERR 23505%auth_identities%', 'O1/G10: an Auth user already bound elsewhere cannot receive a second profile');
select is((select v from r where k = 'ps.reused_trace'), '0', '… and nothing is left behind');
select ok((select v from r where k = 'ps.hidden_family') like 'ERR P0002%not found%', 'provision_student: a family outside the actor''s scope → not found');
select ok((select v from r where k = 'ps.direct')    like 'ERR 42501%permission denied%students%', 'no bypass: direct INSERT into students is denied (G4, M20)');

-- ---------- provision_staff ----------
select is((select v from r where k = 'pf.ok'),       'c1000000-0000-0000-0000-000000000001', 'provision_staff: staff + first assignment');
select is((select v from r where k = 'pf.again'),    'c1000000-0000-0000-0000-000000000001', 'provision_staff: idempotent');
select ok((select v from r where k = 'pf.conflict')  like 'ERR 23505%conflict: staff%', 'provision_staff: same id, different data → conflict');
select is((select v from r where k = 'pf.visible'),  '1', 'provision_staff: visible to its creator (active assignment)');
select ok((select v from r where k = 'pf.sb')        like 'ERR P0002%not found%', 'provision_staff: a school outside the scope → not found');

-- ---------- provision_guardian ----------
select is((select v from r where k = 'pg.ok'),       'd1000000-0000-0000-0000-000000000001', 'provision_guardian: guardian + link to a current student');
select is((select v from r where k = 'pg.again'),    'd1000000-0000-0000-0000-000000000001', 'provision_guardian: idempotent');
select is((select v from r where k = 'pg.visible'),  '1', 'provision_guardian: visible to its creator (active link)');
select ok((select v from r where k = 'pg.sb')        like 'ERR P0002%not found%', 'provision_guardian: a student outside the scope → not found');
select ok((select v from r where k = 'pg.phone')     like 'ERR 23505%guardians_tenant_phone_uq%', 'provision_guardian: the phone is unique within the tenant (I25)');

-- ---------- provision_account ----------
select is((select v from r where k = 'pa.guardian'), 'true', 'provision_account: guardian account');
select is((select v from r where k = 'pa.again'),    'true', 'provision_account: idempotent for the same Auth user');
select ok((select v from r where k = 'pa.conflict')  like 'ERR 23505%already has an account%', 'provision_account: a second account for the same guardian → conflict');
select is((select v from r where k = 'pa.staff'),    'true', 'provision_account: staff account');
select ok((select v from r where k = 'pa.sb')        like 'ERR P0002%not found%', 'provision_account: a guardian outside the scope → not found');
select ok((select v from r where k = 'pa.kind')      like 'ERR 22023%kind must be staff or guardian%', 'provision_account: students get their account only through provision_student');
select is((select v from r where k = 'pa.shape'),    'true|guardian|0|0', 'shape: guardian linked to its profile with the guardian role; staff account with no role and no scope (granted later under T8)');

-- ---------- bootstrap_tenant ----------
select ok((select v from r where k = 'bt.pa0')       like 'ERR 42501%forbidden%', 'bootstrap_tenant: platform identity without tenant.create');
select ok((select v from r where k = 'bt.tenant')    like 'ERR 42501%forbidden%', 'bootstrap_tenant: a tenant user (G10)');
select is((select v from r where k = 'bt.ok'),       '30000000-0000-0000-0000-000000000003', 'bootstrap_tenant: platform admin with tenant.create (the only client path to create a tenant)');
select is((select v from r where k = 'bt.again'),    '30000000-0000-0000-0000-000000000003', 'bootstrap_tenant: idempotent');
select ok((select v from r where k = 'bt.conflict')  like 'ERR 23505%conflict: tenant%', 'bootstrap_tenant: same id, different data → conflict');
select is((select v from r where k = 'bt.shape'),    'tenant_admin|tenant', 'the new admin holds tenant_admin with a tenant scope');
select is((select v from r where k = 'bt.admin_sees'),'T3', 'the new admin works immediately — and sees only its own tenant');
select is((select v from r where k = 'bt.audit'),    'platform_admin', 'audit: the tenant creation is attributed to the platform admin (actor verified in DB)');
select ok((select v from r where k = 'bt.pa_direct') like 'ERR 42501%row-level security%membership_roles%', 'the T8 exemption is narrow: a platform admin cannot write membership_roles directly');

-- ---------- M21b / التدقيق / البنية ----------
select ok((select v from r where k = 'susp.ps')      like 'ERR 42501%forbidden%', 'tenant suspension stops provisioning (root security context, M21b)');
select is((select count(*)::int from r where k like '%#ctx' and v <> '|'), 0, 'audit context is empty after every call');
select is((select count(*)::int from fn f join pg_proc p on p.oid = f.f
            where pg_get_userbyid(p.proowner) = 'app_owner' and p.prosecdef and array_to_string(p.proconfig, ',') like 'search_path=%'), 5,
          'all 5: SECURITY DEFINER, owner app_owner, pinned search_path');
select is((select count(*)::int from fn where has_function_privilege('authenticated', f, 'EXECUTE')), 5, 'EXECUTE for authenticated on all 5 (M20 allowlist)');
select is((select count(*)::int from fn, unnest(array['anon','public']) g where has_function_privilege(g, f, 'EXECUTE')), 0, 'no EXECUTE for anon or PUBLIC');
select is((select count(*)::int from unnest(array['anon','authenticated','public']) g,
             unnest(array['app.system_role_id(text)','app.new_tenant_account(uuid,uuid,text)']::regprocedure[]) f
            where has_function_privilege(g, f, 'EXECUTE')), 0, 'internal helpers are executable by no client');
select is((select count(*)::int from fn f join pg_proc p on p.oid = f.f where p.prosrc ~* 'p_actor|auth\.uid\(\)|execute\s'), 0, 'no p_actor, no direct auth.uid(), no dynamic SQL');
select is((select count(*)::int from pg_proc where oid = 'app.provision_student(uuid,uuid,uuid,date,text,text,text,text,text,text,text,date,text,uuid,text,text)'::regprocedure
            and array_to_string(proargnames, ',') like '%scope%'), 0, 'H1: provision_student has no identity-scope parameter');
select is((select count(*)::int from fn f join pg_proc p on p.oid = f.f where p.prorettype <> 'uuid'::regtype), 0,
          'every provisioning function returns an id only — no identity-scope data');
select ok(not has_table_privilege('authenticated', 'public.platform_tenants', 'INSERT'), 'bootstrap_tenant remains the only client path to create a tenant (M20b)');
select ok((select prosrc ~ 'tenant.create' and prosrc ~ 'membership_roles'', ''membership_scopes' from pg_proc where oid = 'app.tg_authz_integrity()'::regprocedure),
          'T8 carries the narrow exemption (platform context + tenant.create, membership_roles/_scopes only)');

select * from finish();
rollback;
