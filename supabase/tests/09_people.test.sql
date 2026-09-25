-- M09 — people: I22–I32، A4، G3، O2، O3، B6
-- قاعدة (CLAUDE.md، من M08): كل تحقق رفض يطابق اسم القيد المقصود، ومع كل رفض ضابط إيجابي.
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

-- ينشئ حساب Auth + هوية tenant + profile، ويُرجع معرّف الـprofile
create function pg_temp.mk_profile(p_tenant uuid, p_label text) returns uuid
language plpgsql as $$
declare v_auth uuid := gen_random_uuid(); v_profile uuid;
begin
  insert into auth.users (id, email) values (v_auth, p_label || '-' || v_auth || '@m09.invalid');
  insert into public.auth_identities values (v_auth, 'tenant');
  insert into public.profiles (platform_tenant_id, auth_user_id, display_name)
  values (p_tenant, v_auth, p_label) returning id into v_profile;
  return v_profile;
end $$;

create function pg_temp.scope_of_group(p_group uuid)   returns uuid language sql as $$ select id from public.identity_scopes where group_id  = p_group  $$;
create function pg_temp.scope_of_school(p_school uuid) returns uuid language sql as $$ select id from public.identity_scopes where school_id = p_school $$;

-- ============ Fixture ============
insert into public.platform_tenants (id, tenant_code, name) values
  ('10000000-0000-0000-0000-000000000001', 'T1', 'T1'),
  ('20000000-0000-0000-0000-000000000002', 'T2', 'T2');
insert into public.groups (id, platform_tenant_id, group_code, name) values
  ('a1000000-0000-0000-0000-00000000000a', '10000000-0000-0000-0000-000000000001', 'GA', 'GA'),
  ('a2000000-0000-0000-0000-00000000000b', '10000000-0000-0000-0000-000000000001', 'GB', 'GB');
insert into public.schools (id, platform_tenant_id, group_id, school_code, name, slug) values
  ('5a100000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', 'a1000000-0000-0000-0000-00000000000a', 'SA1', 'SA1', 'sa1'),
  ('55000000-0000-0000-0000-000000000004', '10000000-0000-0000-0000-000000000001', null, 'SS', 'SS', 'ss'),
  ('52000000-0000-0000-0000-000000000005', '20000000-0000-0000-0000-000000000002', null, 'S2', 'S2', 's2');

create temp table ids (k text primary key, v uuid) on commit drop;
insert into ids values
  ('scope_ga', pg_temp.scope_of_group('a1000000-0000-0000-0000-00000000000a')),
  ('scope_gb', pg_temp.scope_of_group('a2000000-0000-0000-0000-00000000000b')),
  ('scope_ss', pg_temp.scope_of_school('55000000-0000-0000-0000-000000000004')),
  ('scope_s2', pg_temp.scope_of_school('52000000-0000-0000-0000-000000000005')),
  ('p_staff1', pg_temp.mk_profile('10000000-0000-0000-0000-000000000001', 'staff1')),
  ('p_t2',     pg_temp.mk_profile('20000000-0000-0000-0000-000000000002', 't2')),
  ('p_st1',    pg_temp.mk_profile('10000000-0000-0000-0000-000000000001', 'st1')),
  ('p_st2',    pg_temp.mk_profile('10000000-0000-0000-0000-000000000001', 'st2')),
  ('p_st3',    pg_temp.mk_profile('10000000-0000-0000-0000-000000000001', 'st3')),
  ('p_st4',    pg_temp.mk_profile('10000000-0000-0000-0000-000000000001', 'st4')),
  ('p_st5',    pg_temp.mk_profile('10000000-0000-0000-0000-000000000001', 'st5')),
  ('p_st6',    pg_temp.mk_profile('10000000-0000-0000-0000-000000000001', 'st6')),
  ('p_actor',  pg_temp.mk_profile('10000000-0000-0000-0000-000000000001', 'actor')),
  ('p_free',   pg_temp.mk_profile('10000000-0000-0000-0000-000000000001', 'free'));
grant select on ids to public;
create function pg_temp.id(p text) returns uuid language sql stable as $$ select v from ids where k = p $$;

-- ============ staff ============
insert into public.staff (id, platform_tenant_id, profile_id, employee_code, first_name, father_name, grandfather_name, family_name) values
  ('51000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', pg_temp.id('p_staff1'), 'E-001', 'Ahmad', 'Mohammad', null, 'Hammad'),
  ('52000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001', null,                   'E-002', '  Sara ', null, '  Ali', ' Omar  ');
select pg_temp.rec('st.same_code_other_tenant', $q$insert into public.staff (platform_tenant_id, employee_code, first_name, family_name) values ('20000000-0000-0000-0000-000000000002','E-001','X','Y') returning 'ok'$q$);
select pg_temp.rec('st.dup_code',          $q$insert into public.staff (platform_tenant_id, employee_code, first_name, family_name) values ('10000000-0000-0000-0000-000000000001','E-001','X','Y') returning 'ok'$q$);
select pg_temp.rec('st.profile_other_tenant', format($q$insert into public.staff (platform_tenant_id, profile_id, employee_code, first_name, family_name) values ('10000000-0000-0000-0000-000000000001',%L,'E-010','X','Y') returning 'ok'$q$, pg_temp.id('p_t2')));
select pg_temp.rec('st.profile_twice',        format($q$insert into public.staff (platform_tenant_id, profile_id, employee_code, first_name, family_name) values ('10000000-0000-0000-0000-000000000001',%L,'E-011','X','Y') returning 'ok'$q$, pg_temp.id('p_staff1')));
select pg_temp.rec('st.bad_phone',         $q$insert into public.staff (platform_tenant_id, employee_code, first_name, family_name, phone_e164) values ('10000000-0000-0000-0000-000000000001','E-012','X','Y','0100123456') returning 'ok'$q$);
select pg_temp.rec('st.blank_first',       $q$insert into public.staff (platform_tenant_id, employee_code, first_name, family_name) values ('10000000-0000-0000-0000-000000000001','E-013','   ','Y') returning 'ok'$q$);
select pg_temp.rec('st.archive_no_ts',     $q$update public.staff set status = 'archived' where id = '52000000-0000-0000-0000-000000000002' returning 'ok'$q$);

-- ============ staff_school_assignments ============
insert into public.staff_school_assignments (id, staff_id, school_id, platform_tenant_id, job_title, is_primary, effective_from) values
  ('61000000-0000-0000-0000-000000000001', '51000000-0000-0000-0000-000000000001', '5a100000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', 'Teacher', true, '2026-09-01');
select pg_temp.rec('ssa.second_school_nonprimary', $q$insert into public.staff_school_assignments (staff_id, school_id, platform_tenant_id, job_title, effective_from) values ('51000000-0000-0000-0000-000000000001','55000000-0000-0000-0000-000000000004','10000000-0000-0000-0000-000000000001','Teacher','2026-09-01') returning 'ok'$q$);
select pg_temp.rec('ssa.second_primary',  $q$insert into public.staff_school_assignments (staff_id, school_id, platform_tenant_id, job_title, is_primary, effective_from) values ('51000000-0000-0000-0000-000000000001','55000000-0000-0000-0000-000000000004','10000000-0000-0000-0000-000000000001','Coordinator',true,'2026-10-01') returning 'ok'$q$);
select pg_temp.rec('ssa.school_other_tenant', $q$insert into public.staff_school_assignments (staff_id, school_id, platform_tenant_id, job_title, effective_from) values ('51000000-0000-0000-0000-000000000001','52000000-0000-0000-0000-000000000005','10000000-0000-0000-0000-000000000001','Teacher','2026-09-01') returning 'ok'$q$);
select pg_temp.rec('ssa.active_with_end', $q$insert into public.staff_school_assignments (staff_id, school_id, platform_tenant_id, job_title, effective_from, effective_to) values ('52000000-0000-0000-0000-000000000002','5a100000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000001','Clerk','2026-09-01','2027-01-01') returning 'ok'$q$);
select pg_temp.rec('ssa.zero_period',     $q$insert into public.staff_school_assignments (staff_id, school_id, platform_tenant_id, job_title, status, effective_from, effective_to) values ('52000000-0000-0000-0000-000000000002','5a100000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000001','Clerk','ended','2026-09-01','2026-09-01') returning 'ok'$q$);
-- إنهاء المدرسة الأساسية ثم تعيين أساسية جديدة: مسموح
update public.staff_school_assignments set status = 'ended', effective_to = '2027-01-01' where id = '61000000-0000-0000-0000-000000000001';
select pg_temp.rec('ssa.new_primary_after_end', $q$insert into public.staff_school_assignments (staff_id, school_id, platform_tenant_id, job_title, is_primary, effective_from) values ('51000000-0000-0000-0000-000000000001','5a100000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000001','Teacher',true,'2027-01-01') returning 'ok'$q$);

-- ============ families ============
insert into public.families (id, platform_tenant_id, family_code, family_name) values
  ('f1000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', 'F-1', 'Hammad'),
  ('f2000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001', null,  'Omar'),
  ('f3000000-0000-0000-0000-000000000003', '10000000-0000-0000-0000-000000000001', null,  'Ali'),
  ('f9000000-0000-0000-0000-000000000009', '20000000-0000-0000-0000-000000000002', 'F-1', 'Other tenant');
select pg_temp.rec('fam.dup_code', $q$insert into public.families (platform_tenant_id, family_code, family_name) values ('10000000-0000-0000-0000-000000000001','F-1','x') returning 'ok'$q$);

-- ============ students (A4، G3، O2، O3) ============
-- نفس الرقم الرسمي N-100 في ثلاثة نطاقات مختلفة: مسموح (I28 داخل النطاق فقط)
select set_config('request.jwt.claims', json_build_object('sub', (select auth_user_id from public.profiles where id = pg_temp.id('p_actor')), 'role', 'authenticated')::text, true);
insert into public.students (id, platform_tenant_id, identity_scope_id, student_profile_id, family_id, official_id, official_id_type, first_name, family_name) values
  ('71000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', pg_temp.id('scope_ga'), pg_temp.id('p_st1'), 'f1000000-0000-0000-0000-000000000001', 'N-100', 'national_id', 'Omar', 'Hammad'),
  ('72000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001', pg_temp.id('scope_gb'), pg_temp.id('p_st2'), null, 'N-100', 'national_id', 'Lina', 'Saleh'),
  ('73000000-0000-0000-0000-000000000003', '10000000-0000-0000-0000-000000000001', pg_temp.id('scope_ss'), pg_temp.id('p_st3'), null, 'N-100', 'national_id', 'Yousef', 'Nasser');
select set_config('request.jwt.claims', '', true);
-- طالب بمعرف مؤقت مولَّد (O3) وبلا جنس ولا تاريخ ميلاد (O2)
insert into public.students (id, platform_tenant_id, identity_scope_id, student_profile_id, temporary_id, first_name, family_name) values
  ('74000000-0000-0000-0000-000000000004', '10000000-0000-0000-0000-000000000001', pg_temp.id('scope_ga'), pg_temp.id('p_st4'), app.next_temporary_id(), 'Maryam', 'Khaled');

select pg_temp.rec('s.dup_official_same_scope', format($q$insert into public.students (platform_tenant_id, identity_scope_id, student_profile_id, official_id, official_id_type, first_name, family_name) values ('10000000-0000-0000-0000-000000000001',%L,%L,'N-100','passport','X','Y') returning 'ok'$q$, pg_temp.id('scope_ga'), pg_temp.id('p_st5')));
select pg_temp.rec('s.no_scope',         format($q$insert into public.students (platform_tenant_id, student_profile_id, official_id, official_id_type, first_name, family_name) values ('10000000-0000-0000-0000-000000000001',%L,'N-200','national_id','X','Y') returning 'ok'$q$, pg_temp.id('p_st5')));
select pg_temp.rec('s.no_profile',       format($q$insert into public.students (platform_tenant_id, identity_scope_id, official_id, official_id_type, first_name, family_name) values ('10000000-0000-0000-0000-000000000001',%L,'N-201','national_id','X','Y') returning 'ok'$q$, pg_temp.id('scope_ga')));
select pg_temp.rec('s.profile_twice',    format($q$insert into public.students (platform_tenant_id, identity_scope_id, student_profile_id, official_id, official_id_type, first_name, family_name) values ('10000000-0000-0000-0000-000000000001',%L,%L,'N-202','national_id','X','Y') returning 'ok'$q$, pg_temp.id('scope_ga'), pg_temp.id('p_st1')));
select pg_temp.rec('s.profile_other_tenant', format($q$insert into public.students (platform_tenant_id, identity_scope_id, student_profile_id, official_id, official_id_type, first_name, family_name) values ('10000000-0000-0000-0000-000000000001',%L,%L,'N-203','national_id','X','Y') returning 'ok'$q$, pg_temp.id('scope_ga'), pg_temp.id('p_t2')));
select pg_temp.rec('s.scope_other_tenant',   format($q$insert into public.students (platform_tenant_id, identity_scope_id, student_profile_id, official_id, official_id_type, first_name, family_name) values ('10000000-0000-0000-0000-000000000001',%L,%L,'N-204','national_id','X','Y') returning 'ok'$q$, pg_temp.id('scope_s2'), pg_temp.id('p_st5')));
select pg_temp.rec('s.family_other_tenant',  format($q$insert into public.students (platform_tenant_id, identity_scope_id, student_profile_id, family_id, official_id, official_id_type, first_name, family_name) values ('10000000-0000-0000-0000-000000000001',%L,%L,'f9000000-0000-0000-0000-000000000009','N-205','national_id','X','Y') returning 'ok'$q$, pg_temp.id('scope_ga'), pg_temp.id('p_st5')));
select pg_temp.rec('s.no_identifier',        format($q$insert into public.students (platform_tenant_id, identity_scope_id, student_profile_id, first_name, family_name) values ('10000000-0000-0000-0000-000000000001',%L,%L,'X','Y') returning 'ok'$q$, pg_temp.id('scope_ga'), pg_temp.id('p_st5')));
select pg_temp.rec('s.official_no_type',     format($q$insert into public.students (platform_tenant_id, identity_scope_id, student_profile_id, official_id, first_name, family_name) values ('10000000-0000-0000-0000-000000000001',%L,%L,'N-206','X','Y') returning 'ok'$q$, pg_temp.id('scope_ga'), pg_temp.id('p_st5')));
select pg_temp.rec('s.bad_temp_format',      format($q$insert into public.students (platform_tenant_id, identity_scope_id, student_profile_id, temporary_id, first_name, family_name) values ('10000000-0000-0000-0000-000000000001',%L,%L,'TEMP-1','X','Y') returning 'ok'$q$, pg_temp.id('scope_ga'), pg_temp.id('p_st5')));
select pg_temp.rec('s.dup_temp',             format($q$insert into public.students (platform_tenant_id, identity_scope_id, student_profile_id, temporary_id, first_name, family_name) values ('10000000-0000-0000-0000-000000000001',%L,%L,%L,'X','Y') returning 'ok'$q$,
                                                 pg_temp.id('scope_ss'), pg_temp.id('p_st5'), (select temporary_id from public.students where id = '74000000-0000-0000-0000-000000000004')));
select pg_temp.rec('s.valid_after_failures', format($q$insert into public.students (platform_tenant_id, identity_scope_id, student_profile_id, official_id, official_id_type, first_name, family_name) values ('10000000-0000-0000-0000-000000000001',%L,%L,'N-300','passport','Zaid','Adel') returning 'ok'$q$, pg_temp.id('scope_ga'), pg_temp.id('p_st5')));

-- ============ guardians ============
insert into public.guardians (id, platform_tenant_id, first_name, family_name, phone_e164) values
  ('81000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', 'Khaled', 'Hammad', '+201001234567'),
  ('82000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001', 'Huda',   'Hammad', '+970599123456'),
  ('89000000-0000-0000-0000-000000000009', '20000000-0000-0000-0000-000000000002', 'Other',  'Tenant', '+201001234567');   -- نفس الهاتف في T2
select pg_temp.rec('g.dup_phone',       $q$insert into public.guardians (platform_tenant_id, first_name, family_name, phone_e164) values ('10000000-0000-0000-0000-000000000001','X','Y','+201001234567') returning 'ok'$q$);
select pg_temp.rec('g.bad_phone',       $q$insert into public.guardians (platform_tenant_id, first_name, family_name, phone_e164) values ('10000000-0000-0000-0000-000000000001','X','Y','01001234567') returning 'ok'$q$);
select pg_temp.rec('g.bad_alt_phone',   $q$insert into public.guardians (platform_tenant_id, first_name, family_name, phone_e164, alt_phone_e164) values ('10000000-0000-0000-0000-000000000001','X','Y','+972501234567','+0123') returning 'ok'$q$);
select pg_temp.rec('g.negative_logins', $q$update public.guardians set failed_login_count = -1 where id = '81000000-0000-0000-0000-000000000001' returning 'ok'$q$);
select pg_temp.rec('g.profile_other_tenant', format($q$update public.guardians set profile_id = %L where id = '81000000-0000-0000-0000-000000000001' returning 'ok'$q$, pg_temp.id('p_t2')));
select pg_temp.rec('g.profile_ok',           format($q$update public.guardians set profile_id = %L where id = '81000000-0000-0000-0000-000000000001' returning 'ok'$q$, pg_temp.id('p_free')));

-- ============ student_guardians ============
insert into public.student_guardians (student_id, guardian_id, platform_tenant_id, relationship_type, is_primary) values
  ('71000000-0000-0000-0000-000000000001', '81000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', 'father', true),
  ('71000000-0000-0000-0000-000000000001', '82000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001', 'mother', false),
  ('72000000-0000-0000-0000-000000000002', '81000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', 'father', true);   -- ولي أمر واحد لطفلين (نطاقان مختلفان)
select pg_temp.rec('sg.second_primary', $q$update public.student_guardians set is_primary = true where student_id = '71000000-0000-0000-0000-000000000001' and guardian_id = '82000000-0000-0000-0000-000000000002' returning 'ok'$q$);
select pg_temp.rec('sg.dup_pair',       $q$insert into public.student_guardians (student_id, guardian_id, platform_tenant_id, relationship_type) values ('71000000-0000-0000-0000-000000000001','81000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000001','father') returning 'ok'$q$);
select pg_temp.rec('sg.cross_tenant',   $q$insert into public.student_guardians (student_id, guardian_id, platform_tenant_id, relationship_type) values ('71000000-0000-0000-0000-000000000001','89000000-0000-0000-0000-000000000009','10000000-0000-0000-0000-000000000001','other') returning 'ok'$q$);
select pg_temp.rec('sg.bad_relation',   $q$insert into public.student_guardians (student_id, guardian_id, platform_tenant_id, relationship_type) values ('73000000-0000-0000-0000-000000000003','82000000-0000-0000-0000-000000000002','10000000-0000-0000-0000-000000000001','uncle') returning 'ok'$q$);
select pg_temp.rec('sg.active_with_end', $q$insert into public.student_guardians (student_id, guardian_id, platform_tenant_id, relationship_type, effective_to) values ('73000000-0000-0000-0000-000000000003','82000000-0000-0000-0000-000000000002','10000000-0000-0000-0000-000000000001','other','2030-01-01') returning 'ok'$q$);
-- إنهاء الأساسي ثم تعيين آخر: مسموح
update public.student_guardians set status = 'ended', effective_to = current_date + 1
 where student_id = '71000000-0000-0000-0000-000000000001' and guardian_id = '81000000-0000-0000-0000-000000000001';
select pg_temp.rec('sg.new_primary_after_end', $q$update public.student_guardians set is_primary = true where student_id = '71000000-0000-0000-0000-000000000001' and guardian_id = '82000000-0000-0000-0000-000000000002' returning 'ok'$q$);

-- ============ RLS ============
select set_config('request.jwt.claims', json_build_object('sub', (select auth_user_id from public.profiles where id = pg_temp.id('p_staff1')), 'role', 'authenticated')::text, true);
set local role authenticated;
select pg_temp.rec('rls.rows', $q$select ((select count(*) from public.staff) + (select count(*) from public.staff_school_assignments) + (select count(*) from public.families)
                                  + (select count(*) from public.students) + (select count(*) from public.guardians) + (select count(*) from public.student_guardians))::text$q$);
reset role;

select plan(61);

-- البنية
select ok((select bool_and(relrowsecurity and relforcerowsecurity) from pg_class
           where oid in ('public.staff'::regclass, 'public.staff_school_assignments'::regclass, 'public.families'::regclass,
                         'public.students'::regclass, 'public.guardians'::regclass, 'public.student_guardians'::regclass)),
          'RLS enabled and forced on the six people tables');
select hasnt_column('public', 'students', 'school_id', 'A4: students has no school_id');
select hasnt_column('public', 'students', 'group_id',  'A4: students has no group_id (derived from identity_scopes)');
select hasnt_column('public', 'staff',     'school_id', 'identity table staff has no school_id');
select hasnt_column('public', 'guardians', 'school_id', 'identity table guardians has no school_id');
select hasnt_column('public', 'families',  'school_id', 'identity table families has no school_id');
select col_not_null('public', 'students', 'identity_scope_id',  'A4: identity_scope_id NOT NULL');
select col_not_null('public', 'students', 'student_profile_id', 'N1: student_profile_id NOT NULL');
select col_is_null('public', 'students', 'gender',     'O2: gender nullable');
select col_is_null('public', 'students', 'birth_date', 'O2: birth_date nullable');
select col_is_unique('public', 'students', array['id', 'identity_scope_id'], 'G3: (id, identity_scope_id) unique — FK target for enrollments');

-- الاسم الرباعي
select is((select full_name from public.staff where id = '51000000-0000-0000-0000-000000000001'), 'Ahmad Mohammad Hammad', 'full_name skips a missing middle name');
select is((select full_name from public.staff where id = '52000000-0000-0000-0000-000000000002'), 'Sara Ali Omar',          'full_name collapses and trims spaces');
select ok((select bool_and(full_name = btrim(regexp_replace(concat_ws(' ', first_name, father_name, grandfather_name, family_name), '\s+', ' ', 'g')))
             from (select first_name, father_name, grandfather_name, family_name, full_name from public.staff
                   union all select first_name, father_name, grandfather_name, family_name, full_name from public.students
                   union all select first_name, father_name, grandfather_name, family_name, full_name from public.guardians) x),
          'full_name equals the DD §0.4 concat_ws expression on every row (same result, IMMUTABLE functions)');

-- staff
select is((select v from r where k = 'st.same_code_other_tenant'), 'ok',                            'I22 positive: same employee_code in another tenant');
select ok((select v from r where k = 'st.dup_code')            like 'ERR 23505%staff_tenant_code_uq%', 'I22: employee_code unique within tenant');
select ok((select v from r where k = 'st.profile_other_tenant') like 'ERR 23503%staff_profile_fk%',   'staff profile must be in the same tenant');
select ok((select v from r where k = 'st.profile_twice')       like 'ERR 23505%staff_profile_uq%',     'I23: one account cannot be two staff members');
select ok((select v from r where k = 'st.bad_phone')           like 'ERR 23514%staff_phone_chk%',      'staff phone must be E.164');
select ok((select v from r where k = 'st.blank_first')         like 'ERR 23514%staff_first_name_chk%', 'first name cannot be blank');
select ok((select v from r where k = 'st.archive_no_ts')       like 'ERR 23514%staff_archived_chk%',   'archived status requires archived_at');

-- staff_school_assignments
select is((select v from r where k = 'ssa.second_school_nonprimary'), 'ok', 'positive: staff can be assigned to a second school');
select ok((select v from r where k = 'ssa.second_primary')        like 'ERR 23505%staff_school_assignments_primary_uq%', 'I24: one active primary school per staff member');
select ok((select v from r where k = 'ssa.school_other_tenant')   like 'ERR 23503%staff_school_assignments_school_fk%',  'assignment school must be in the staff tenant');
select ok((select v from r where k = 'ssa.active_with_end')       like 'ERR 23514%staff_school_assignments_active_chk%', 'B6: active assignment has no effective_to');
select ok((select v from r where k = 'ssa.zero_period')           like 'ERR 23514%staff_school_assignments_dates_chk%',  'B6: half-open period cannot be empty');
select is((select v from r where k = 'ssa.new_primary_after_end'), 'ok', 'positive: new primary after the previous one ended');

-- families
select ok((select v from r where k = 'fam.dup_code') like 'ERR 23505%families_tenant_code_uq%', 'family_code unique within tenant');
select is((select count(*)::int from public.families where family_code is null), 2, 'positive: several families without a code');
select is((select count(*)::int from public.families where family_code = 'F-1'), 2, 'positive: same family_code in another tenant');

-- students — A4 / I28
select is((select count(*)::int from public.students where official_id = 'N-100'), 3, 'I28 positive: same official id in three different identity scopes');
select ok((select v from r where k = 's.dup_official_same_scope') like 'ERR 23505%students_scope_official_id_uq%', 'I28: official id unique within an identity scope');
select ok((select v from r where k = 's.no_scope')      like 'ERR 23502%identity_scope_id%',  'A4: student without identity scope rejected');
select ok((select v from r where k = 's.no_profile')    like 'ERR 23502%student_profile_id%', 'N1: student without an account rejected');
select ok((select v from r where k = 's.profile_twice') like 'ERR 23505%students_profile_uq%', 'I30: one account cannot be two students');
select ok((select v from r where k = 's.profile_other_tenant') like 'ERR 23503%students_profile_fk%', 'student account must be in the same tenant');
select ok((select v from r where k = 's.scope_other_tenant')   like 'ERR 23503%students_scope_fk%',   'identity scope must be in the same tenant');
select ok((select v from r where k = 's.family_other_tenant')  like 'ERR 23503%students_family_fk%',  'family must be in the same tenant');
select ok((select v from r where k = 's.no_identifier')    like 'ERR 23514%students_identifier_chk%',   'I29: student needs an official or a temporary id');
select ok((select v from r where k = 's.official_no_type') like 'ERR 23514%students_official_type_chk%', 'official id requires its type');
select ok((select v from r where k = 's.bad_temp_format')  like 'ERR 23514%students_temporary_id_chk%',  'I31: temporary id must match TMP-{YEAR}-{SEQ}');
select ok((select v from r where k = 's.dup_temp')         like 'ERR 23505%students_tenant_temporary_id_uq%', 'temporary id unique within tenant');
select is((select v from r where k = 's.valid_after_failures'), 'ok', 'positive: a correct student is still accepted after the rejections');
select ok((select temporary_id ~ '^TMP-[0-9]{4}-[0-9]{6,}$' and gender is null and birth_date is null from public.students where id = '74000000-0000-0000-0000-000000000004'),
          'O3 + O2: generated temporary id, no gender, no birth date');
select is((select created_by from public.students where id = '71000000-0000-0000-0000-000000000001'), pg_temp.id('p_actor'),
          'T6: created_by stamped with the acting profile');

-- guardians
select is((select count(*)::int from public.guardians where phone_e164 = '+201001234567'), 2, 'I25 positive: same phone in another tenant');
select ok((select v from r where k = 'g.dup_phone')       like 'ERR 23505%guardians_tenant_phone_uq%',  'I25: guardian phone unique within tenant');
select ok((select v from r where k = 'g.bad_phone')       like 'ERR 23514%guardians_phone_chk%',        'guardian phone must be E.164');
select ok((select v from r where k = 'g.bad_alt_phone')   like 'ERR 23514%guardians_alt_phone_chk%',    'alternate phone must be E.164');
select ok((select v from r where k = 'g.negative_logins') like 'ERR 23514%guardians_failed_login_chk%', 'failed login count cannot be negative');
select ok((select v from r where k = 'g.profile_other_tenant') like 'ERR 23503%guardians_profile_fk%',  'guardian account must be in the same tenant');
select is((select v from r where k = 'g.profile_ok'), 'ok', 'positive: guardian linked to an account in its tenant');

-- student_guardians
select is((select count(*)::int from public.student_guardians where guardian_id = '81000000-0000-0000-0000-000000000001'), 2,
          'positive: one guardian account for two children in different identity scopes');
select is((select count(*)::int from public.student_guardians where student_id = '71000000-0000-0000-0000-000000000001'), 2,
          'positive: several guardians per student');
select ok((select v from r where k = 'sg.second_primary')   like 'ERR 23505%student_guardians_primary_uq%',  'I26: one active primary guardian per student');
select ok((select v from r where k = 'sg.dup_pair')         like 'ERR 23505%student_guardians_pair_uq%',     'a guardian is linked to a student once');
select ok((select v from r where k = 'sg.cross_tenant')     like 'ERR 23503%student_guardians_guardian_fk%', 'I27: student and guardian in the same tenant');
select ok((select v from r where k = 'sg.bad_relation')     like 'ERR 23514%student_guardians_relationship_chk%', 'relationship type restricted');
select ok((select v from r where k = 'sg.active_with_end')  like 'ERR 23514%student_guardians_active_chk%',  'B6: active link has no effective_to');
select is((select v from r where k = 'sg.new_primary_after_end'), 'ok', 'positive: new primary guardian after the previous one ended');

-- RLS
select is((select v from r where k = 'rls.rows'), '1', 'RLS (M17 self path): a staff member without permissions sees only its own staff row across the six tables');

select * from finish();
rollback;
