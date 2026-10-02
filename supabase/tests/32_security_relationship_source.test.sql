-- M31 — security_relationship_source (مراجعة Stage 1: S1 + S2)
-- S1: صلاحية ربط ولي الأمر ≠ صلاحية إدارة حسابه — ربط مباشر من المدرسة لا يمنح إصدار الكلمة المؤقتة؛ العلاقة
--     الـprovisioned (provision_guardian) وحدها تفعل، وعمود المصدر لا يكتبه العميل. السلسلة كاملة + المسارات المشروعة.
-- S2: students.family_id لا يُسند إلا إلى أسرة في نطاق الفاعل أصلاً؛ تعديل طالب أسرته غير متغيرة يبقى ممكناً.
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

create function pg_temp.run(p_key text, p_sub uuid, p_sql text) returns void
language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p_sub, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', p_sub::text, true);
  execute 'set local role authenticated';
  perform pg_temp.rec(p_key, p_sql);
  execute 'reset role';
end $$;

-- ============ Fixture: Tenant واحد، مجموعة GA بمدرستين SA و SB ============
insert into public.platform_tenants (id, tenant_code, host_label, name) values ('10000000-0000-0000-0000-000000000001', 'T1', 't1', 'T1');
insert into public.groups (id, platform_tenant_id, group_code, name) values ('a1000000-0000-0000-0000-00000000000a', '10000000-0000-0000-0000-000000000001', 'GA', 'GA');
insert into public.schools (id, platform_tenant_id, group_id, school_code, name, slug) values
  ('5a000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', 'a1000000-0000-0000-0000-00000000000a', 'SA', 'SA', 'sa'),
  ('5b000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001', 'a1000000-0000-0000-0000-00000000000a', 'SB', 'SB', 'sb');
create temp table sec (code text primary key, school uuid, year uuid, grade uuid, section uuid) on commit drop;
grant select on sec to public;
do $$
declare s record; v_y uuid; v_st uuid; v_g uuid; v_sec uuid;
begin
  for s in select id, school_code from public.schools where platform_tenant_id = '10000000-0000-0000-0000-000000000001' loop
    insert into public.academic_years (school_id, name, start_date, end_date, status) values (s.id, 'Y', '2026-09-01', '2027-06-30', 'active') returning id into v_y;
    insert into public.stages (school_id, name, sequence_no) values (s.id, 'P', 1) returning id into v_st;
    insert into public.grade_levels (school_id, stage_id, name, sequence_no) values (s.id, v_st, 'G1', 1) returning id into v_g;
    insert into public.sections (school_id, academic_year_id, grade_level_id, name) values (s.id, v_y, v_g, 'A') returning id into v_sec;
    insert into sec values (s.school_code, s.id, v_y, v_g, v_sec);
  end loop;
end $$;

create function pg_temp.account(p_id uuid) returns uuid
language plpgsql as $$
declare v_p uuid;
begin
  insert into auth.users (id, email, updated_at) values (p_id, p_id::text || '@m31.invalid', now());
  insert into public.auth_identities (auth_user_id, kind) values (p_id, 'tenant');
  insert into public.profiles (platform_tenant_id, auth_user_id, display_name) values ('10000000-0000-0000-0000-000000000001', p_id, 'x') returning id into v_p;
  return v_p;
end $$;

insert into public.families (id, platform_tenant_id, family_name) values
  ('f2000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001', 'FamA2'),
  ('f3000000-0000-0000-0000-000000000003', '10000000-0000-0000-0000-000000000001', 'FamB'),
  ('f4000000-0000-0000-0000-000000000004', '10000000-0000-0000-0000-000000000001', 'FamSole'),
  ('f5000000-0000-0000-0000-000000000005', '10000000-0000-0000-0000-000000000001', 'FamEmpty');

-- طالب بحساب، نطاق هوية GA، وتسجيل نشط في مدرسته
create function pg_temp.student(p_id uuid, p_school text, p_official text, p_family uuid) returns void
language plpgsql as $$
declare v_p uuid := pg_temp.account(p_id); x record; v_scope uuid;
begin
  select * into x from sec where code = p_school;
  select i.id into v_scope from public.schools sc join public.identity_scopes i on i.owner_id = sc.scope_owner_id where sc.id = x.school;
  insert into public.students (id, platform_tenant_id, identity_scope_id, student_profile_id, family_id, official_id, official_id_type, first_name, family_name)
    values (p_id, '10000000-0000-0000-0000-000000000001', v_scope, v_p, p_family, p_official, 'national_id', 'S', 'T');
  insert into public.enrollments (school_id, student_id, platform_tenant_id, academic_year_id, grade_level_id, section_id,
                                  identity_scope_id, scope_owner_id, effective_from)
    values (x.school, p_id, '10000000-0000-0000-0000-000000000001', x.year, x.grade, x.section, v_scope,
            'a1000000-0000-0000-0000-00000000000a', '2026-09-01');
end $$;
select pg_temp.student('e1000000-0000-0000-0000-000000000001', 'SA', 'N1', null);                                     -- stA
select pg_temp.student('e2000000-0000-0000-0000-000000000002', 'SA', 'N2', 'f2000000-0000-0000-0000-000000000002');   -- stA2 ∈ FamA2
select pg_temp.student('e3000000-0000-0000-0000-000000000003', 'SB', 'N3', 'f3000000-0000-0000-0000-000000000003');   -- stB ∈ FamB
select pg_temp.student('e4000000-0000-0000-0000-000000000004', 'SA', 'N4', 'f4000000-0000-0000-0000-000000000004');   -- stSole: العضو الوحيد في FamSole

-- الفاعلون: school_admin المبذور (M23) بنطاق مدرسة
create function pg_temp.member(p_auth uuid, p_school text) returns void
language plpgsql as $$
declare v_p uuid := pg_temp.account(p_auth); v_m uuid;
begin
  insert into public.memberships (platform_tenant_id, profile_id) values ('10000000-0000-0000-0000-000000000001', v_p) returning id into v_m;
  insert into public.membership_roles (membership_id, role_id, platform_tenant_id, role_owner_key)
    values (v_m, (select id from public.roles where code = 'school_admin' and platform_tenant_id is null),
            '10000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000000');
  insert into public.membership_scopes (membership_id, platform_tenant_id, scope_type, school_id)
    values (v_m, '10000000-0000-0000-0000-000000000001', 'school', (select school from sec where code = p_school));
end $$;
select pg_temp.member('c1000000-0000-0000-0000-000000000001', 'SA');   -- adminSA
select pg_temp.member('c2000000-0000-0000-0000-000000000002', 'SB');   -- adminSB

-- ولي أمر gX: سجّلته SB لطالبها stB (provisioned) وحسابه pending — المسار الحقيقي: provision_guardian ← Auth ← provision_account
select pg_temp.run('fx.gx_provision', 'c2000000-0000-0000-0000-000000000002',
  $q$select app.provision_guardian('91000000-0000-0000-0000-000000000001', 'e3000000-0000-0000-0000-000000000003', 'mother',
                                   '+201000000001', 'G', 'X', '2026-09-01')::text$q$);
reset role;
insert into auth.users (id, email, updated_at) values ('91000000-0000-0000-0000-000000000001', 'gx@m31.invalid', now());
select pg_temp.run('fx.gx_account', 'c2000000-0000-0000-0000-000000000002',
  $q$select (app.provision_account('guardian', '91000000-0000-0000-0000-000000000001', '91000000-0000-0000-0000-000000000001') is not null)::text$q$);

-- ============ S1 — ربط مباشر من SA لا يمنح إدارة الحساب ============
select pg_temp.run('s1.see_before',   'c1000000-0000-0000-0000-000000000001', $q$select count(*)::text from public.guardians where id = '91000000-0000-0000-0000-000000000001'$q$);
select pg_temp.run('s1.issue_before', 'c1000000-0000-0000-0000-000000000001', $q$select app.begin_guardian_temporary_password('91000000-0000-0000-0000-000000000001')::text$q$);
-- §10.5: الربط المباشر مشروع ويبقى ممكناً
select pg_temp.run('s1.direct_link',  'c1000000-0000-0000-0000-000000000001', $q$insert into public.student_guardians (student_id, guardian_id, platform_tenant_id, relationship_type)
  values ('e1000000-0000-0000-0000-000000000001', '91000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', 'other') returning 'ok'$q$);
select pg_temp.rec('s1.link_source', $q$select relationship_source from public.student_guardians
  where student_id = 'e1000000-0000-0000-0000-000000000001' and guardian_id = '91000000-0000-0000-0000-000000000001'$q$);
-- §10.5: القراءة بعد الربط تبقى كما هي، وولي الأمر صار في النطاق
select pg_temp.run('s1.see_after',    'c1000000-0000-0000-0000-000000000001', $q$select phone_e164 from public.guardians where id = '91000000-0000-0000-0000-000000000001'$q$);
select pg_temp.run('s1.in_scope',     'c1000000-0000-0000-0000-000000000001', $q$select app.guardian_in_scope('91000000-0000-0000-0000-000000000001')::text$q$);
-- الإصلاح: إدارة الحساب تفشل
select pg_temp.run('s1.issue_direct', 'c1000000-0000-0000-0000-000000000001', $q$select app.begin_guardian_temporary_password('91000000-0000-0000-0000-000000000001')::text$q$);
select pg_temp.run('s1.arm_direct',   'c1000000-0000-0000-0000-000000000001', $q$select app.arm_guardian_temporary_password('91000000-0000-0000-0000-000000000001')$q$);
-- لا تزوير للمصدر من العميل
select pg_temp.run('s1.forge_insert', 'c1000000-0000-0000-0000-000000000001', $q$insert into public.student_guardians (student_id, guardian_id, platform_tenant_id, relationship_type, relationship_source)
  values ('e2000000-0000-0000-0000-000000000002', '91000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', 'other', 'provisioned') returning 'ok'$q$);
select pg_temp.run('s1.forge_update', 'c1000000-0000-0000-0000-000000000001', $q$update public.student_guardians set relationship_source = 'provisioned'
  where student_id = 'e1000000-0000-0000-0000-000000000001' and guardian_id = '91000000-0000-0000-0000-000000000001' returning 'ok'$q$);
-- ولا تحويل direct ← provisioned عبر فرع الـidempotency في provision_guardian
select pg_temp.run('s1.launder',      'c1000000-0000-0000-0000-000000000001', $q$select app.provision_guardian('91000000-0000-0000-0000-000000000001', 'e1000000-0000-0000-0000-000000000001', 'other',
                                   '+201000000001', 'G', 'X', '2026-09-01')::text$q$);
select pg_temp.rec('s1.launder_source', $q$select relationship_source from public.student_guardians
  where student_id = 'e1000000-0000-0000-0000-000000000001' and guardian_id = '91000000-0000-0000-0000-000000000001'$q$);
select pg_temp.run('s1.issue_after_launder', 'c1000000-0000-0000-0000-000000000001', $q$select app.begin_guardian_temporary_password('91000000-0000-0000-0000-000000000001')::text$q$);
-- المدرسة التي سجّلته (علاقة provisioned بطالب في نطاقها) تبقى قادرة
select pg_temp.run('s1.owner_issue',  'c2000000-0000-0000-0000-000000000002', $q$select app.begin_guardian_temporary_password('91000000-0000-0000-0000-000000000001')::text$q$);
select pg_temp.run('s1.owner_arm',    'c2000000-0000-0000-0000-000000000002', $q$select app.arm_guardian_temporary_password('91000000-0000-0000-0000-000000000001')$q$);

-- ============ S1 — المسار المشروع لـSA: provision_guardian ← حساب ← إصدار ============
select pg_temp.run('s1.legit_provision', 'c1000000-0000-0000-0000-000000000001', $q$select app.provision_guardian('92000000-0000-0000-0000-000000000002', 'e1000000-0000-0000-0000-000000000001', 'father',
                                   '+201000000002', 'P', 'Q', '2026-09-01')::text$q$);
select pg_temp.rec('s1.legit_source', $q$select relationship_source from public.student_guardians
  where student_id = 'e1000000-0000-0000-0000-000000000001' and guardian_id = '92000000-0000-0000-0000-000000000002'$q$);
reset role;
insert into auth.users (id, email, updated_at) values ('92000000-0000-0000-0000-000000000002', 'gp@m31.invalid', now());
select pg_temp.run('s1.legit_account', 'c1000000-0000-0000-0000-000000000001',
  $q$select (app.provision_account('guardian', '92000000-0000-0000-0000-000000000002', '92000000-0000-0000-0000-000000000002') is not null)::text$q$);
select pg_temp.rec('s1.legit_state', $q$select credential_state from public.auth_identities where auth_user_id = '92000000-0000-0000-0000-000000000002'$q$);
select pg_temp.run('s1.legit_issue',  'c1000000-0000-0000-0000-000000000001', $q$select app.begin_guardian_temporary_password('92000000-0000-0000-0000-000000000002')::text$q$);
select pg_temp.run('s1.legit_arm',    'c1000000-0000-0000-0000-000000000001', $q$select app.arm_guardian_temporary_password('92000000-0000-0000-0000-000000000002')$q$);

-- ============ S2 — الأسرة ضمن النطاق أصلاً ============
select pg_temp.run('s2.see_before',   'c1000000-0000-0000-0000-000000000001', $q$select count(*)::text from public.families where id = 'f3000000-0000-0000-0000-000000000003'$q$);
select pg_temp.run('s2.move_out',     'c1000000-0000-0000-0000-000000000001', $q$update public.students set family_id = 'f3000000-0000-0000-0000-000000000003'
  where id = 'e1000000-0000-0000-0000-000000000001' returning 'ok'$q$);
select pg_temp.run('s2.move_empty',   'c1000000-0000-0000-0000-000000000001', $q$update public.students set family_id = 'f5000000-0000-0000-0000-000000000005'
  where id = 'e1000000-0000-0000-0000-000000000001' returning 'ok'$q$);
select pg_temp.run('s2.move_two',     'c1000000-0000-0000-0000-000000000001', $q$with u as (update public.students set family_id = 'f3000000-0000-0000-0000-000000000003'
  where id in ('e1000000-0000-0000-0000-000000000001', 'e2000000-0000-0000-0000-000000000002') returning 1) select count(*)::text from u$q$);
select pg_temp.run('s2.see_after',    'c1000000-0000-0000-0000-000000000001', $q$select count(*)::text from public.families where id = 'f3000000-0000-0000-0000-000000000003'$q$);
select pg_temp.run('s2.move_in',      'c1000000-0000-0000-0000-000000000001', $q$update public.students set family_id = 'f2000000-0000-0000-0000-000000000002'
  where id = 'e1000000-0000-0000-0000-000000000001' returning 'ok'$q$);
select pg_temp.run('s2.unset',        'c1000000-0000-0000-0000-000000000001', $q$update public.students set family_id = null
  where id = 'e1000000-0000-0000-0000-000000000001' returning 'ok'$q$);
-- لا تراجع: طالب هو العضو الوحيد في أسرته يبقى قابلاً للتعديل (الأسرة غير متغيرة)
select pg_temp.run('s2.sole_member',  'c1000000-0000-0000-0000-000000000001', $q$update public.students set nationality = 'EG'
  where id = 'e4000000-0000-0000-0000-000000000004' returning family_id::text$q$);
-- SB يعدّل طالبه في FamB كالمعتاد
select pg_temp.run('s2.owner_edit',   'c2000000-0000-0000-0000-000000000002', $q$update public.students set nationality = 'EG'
  where id = 'e3000000-0000-0000-0000-000000000003' returning 'ok'$q$);

-- ============ البنية ============
select pg_temp.rec('st.bad_value', $q$update public.student_guardians set relationship_source = 'manual'
  where guardian_id = '92000000-0000-0000-0000-000000000002' returning 'ok'$q$);

select plan(5 + 21 + 9 + 5);

-- ---------- Fixture (المسار الحقيقي) ----------
select is((select v from r where k = 'fx.gx_provision'), '91000000-0000-0000-0000-000000000001', 'fixture: SB provisions guardian gX for its student');
select is((select v from r where k = 'fx.gx_account'),   'true', 'fixture: SB provisions the guardian account');
select is((select relationship_source from public.student_guardians where guardian_id = '91000000-0000-0000-0000-000000000001'
            and student_id = 'e3000000-0000-0000-0000-000000000003'), 'provisioned', 'provision_guardian marks its link provisioned');
select is((select credential_state from public.auth_identities where auth_user_id = '91000000-0000-0000-0000-000000000001'), 'pending',
          'fixture: the guardian account is pending (not onboarded)');
select is((select count(*)::int from public.student_guardians where guardian_id = '91000000-0000-0000-0000-000000000001'), 2,
          'fixture: gX ends with two links — SB provisioned, SA direct');

-- ---------- S1 ----------
select is((select v from r where k = 's1.see_before'),   '0', 'S1: before any link, SA does not see the SB guardian');
select ok((select v from r where k = 's1.issue_before')  like 'ERR P0002%', 'S1: before any link, SA cannot issue a temporary password');
select is((select v from r where k = 's1.direct_link'),  'ok', 'S1: §10.5 — SA may still link the guardian to its own student directly');
select is((select v from r where k = 's1.link_source'),  'direct', 'S1: a client-created link is direct (column default)');
select is((select v from r where k = 's1.see_after'),    '+201000000001', 'S1: §10.5 — reading the guardian after linking is unchanged');
select is((select v from r where k = 's1.in_scope'),     'true', 'S1: the direct link places the guardian in SA scope (guardian_in_scope alone would allow)');
select ok((select v from r where k = 's1.issue_direct')  like 'ERR P0002%', 'S1 FIX: a direct link does not grant issuing a temporary password');
select ok((select v from r where k = 's1.arm_direct')    like 'ERR P0002%', 'S1 FIX: … nor arming it');
select ok((select v from r where k = 's1.forge_insert')  like 'ERR 42501%permission denied%student_guardians%', 'S1: the client cannot insert relationship_source');
select ok((select v from r where k = 's1.forge_update')  like 'ERR 42501%permission denied%student_guardians%', 'S1: the client cannot update relationship_source');
select is((select v from r where k = 's1.launder'),      '91000000-0000-0000-0000-000000000001', 'S1: provision_guardian on an existing direct link returns idempotently …');
select is((select v from r where k = 's1.launder_source'), 'direct', '… without converting the link to provisioned');
select ok((select v from r where k = 's1.issue_after_launder') like 'ERR P0002%', '… so issuing still fails');
select is((select v from r where k = 's1.owner_issue'),  '91000000-0000-0000-0000-000000000001', 'S1: the registering school (provisioned link in its scope) can still issue');
select is((select v from r where k = 's1.owner_arm'),    'pending', '… and arm');
select is((select v from r where k = 's1.legit_provision'), '92000000-0000-0000-0000-000000000002', 'S1 legit: SA provisions its own guardian');
select is((select v from r where k = 's1.legit_source'), 'provisioned', 'S1 legit: the provisioned link');
select is((select v from r where k = 's1.legit_account'), 'true', 'S1 legit: SA provisions the account');
select is((select v from r where k = 's1.legit_state'),  'pending', 'S1 legit: account pending');
select is((select v from r where k = 's1.legit_issue'),  '92000000-0000-0000-0000-000000000002', 'S1 legit: SA issues the temporary password for its provisioned guardian');
select is((select v from r where k = 's1.legit_arm'),    'pending', 'S1 legit: … and arms it');

-- ---------- S2 ----------
select is((select v from r where k = 's2.see_before'),   '0', 'S2: SA does not see FamB (its only student is in SB)');
select ok((select v from r where k = 's2.move_out')      like 'ERR 42501%row-level security%students%', 'S2 FIX: SA cannot attach its student to a family outside its scope');
select ok((select v from r where k = 's2.move_empty')    like 'ERR 42501%row-level security%students%', 'S2 FIX: … nor to a family with no student in its scope');
select ok((select v from r where k = 's2.move_two')      like 'ERR 42501%row-level security%students%', 'S2 FIX: … nor by moving two students in one statement');
select is((select v from r where k = 's2.see_after'),    '0', 'S2: FamB stays invisible to SA');
select is((select v from r where k = 's2.move_in'),      'ok', 'S2 legit: SA attaches its student to a family already in its scope');
select is((select v from r where k = 's2.unset'),        'ok', 'S2 legit: SA clears a student family');
select is((select v from r where k = 's2.sole_member'),  'f4000000-0000-0000-0000-000000000004', 'S2 no regression: the sole member of a family stays editable (family unchanged)');
select is((select v from r where k = 's2.owner_edit'),   'ok', 'S2 no regression: SB edits its own student in FamB');

-- ---------- البنية ----------
select is((select format('%s|%s|%s', data_type, is_nullable, column_default) from information_schema.columns
            where table_schema = 'public' and table_name = 'student_guardians' and column_name = 'relationship_source'),
          'text|NO|''direct''::text', 'relationship_source: text NOT NULL DEFAULT direct');
select ok((select v from r where k = 'st.bad_value') like 'ERR 23514%student_guardians_relationship_source_chk%', 'relationship_source: direct or provisioned only');
select ok(not has_column_privilege('authenticated', 'public.student_guardians', 'relationship_source', 'INSERT')
      and not has_column_privilege('authenticated', 'public.student_guardians', 'relationship_source', 'UPDATE'),
          'relationship_source is not client-writable (no column grant)');
select ok((select with_check from pg_policies where schemaname = 'public' and tablename = 'students' and policyname = 'students_update')
          like '%family_in_scope(family_id)%', 'students_update WITH CHECK requires the family to be in scope');
select is((select string_agg(proname, ',' order by proname) from pg_proc where pronamespace = 'app'::regnamespace and prosrc ~ 'relationship_source'),
          'guardian_account_for_issue,provision_guardian', 'only provision_guardian writes and only the issue gate reads relationship_source');

select * from finish();
rollback;
