-- M15 — policies_authz: منع التصعيد (RLS_MODEL §15.4) + F1–F5
-- المغطى هنا: E3، E6 (جداول M15)، E8، E9 (F1)، E11 (F2)، E12 (F3)، E13 (F4)، E14 الخطوة 1 (F5)،
--             وقرارا 2026-09-25 (can_manage على منح النطاق، membership_id_of).
-- المؤجل بقصد: E1، E2، E7 → M17 (جداولها بلا سياسات بعد)؛ E4، E14 الخطوة 2 → M19 (T8)؛ E5 → M23 (البذر)؛
--             E15، E16 → M18؛ E10، E17 → مثبتان في 14_isolation.
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

create temp table ids (label text primary key, auth uuid, profile uuid, membership uuid) on commit drop;
grant all on ids to public;

create function pg_temp.run(p_key text, p_label text, p_sql text) returns void
language plpgsql as $$
declare v_sub uuid := (select auth from ids where label = p_label);
begin
  perform set_config('request.jwt.claims', json_build_object('sub', v_sub, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', coalesce(v_sub::text, ''), true);
  if p_label = 'anon' then execute 'set local role anon'; else execute 'set local role authenticated'; end if;
  perform pg_temp.rec(p_key, p_sql);
  execute 'reset role';
end $$;

create function pg_temp.mid(p_label text) returns uuid language sql as $$ select membership from ids where label = p_label $$;

-- ============ Fixture ============
insert into public.platform_tenants (id, tenant_code, name) values
  ('10000000-0000-0000-0000-000000000001', 'T1', 'T1'), ('20000000-0000-0000-0000-000000000002', 'T2', 'T2');
insert into public.groups (id, platform_tenant_id, group_code, name) values
  ('a1000000-0000-0000-0000-00000000000a', '10000000-0000-0000-0000-000000000001', 'GA', 'GA'),
  ('a2000000-0000-0000-0000-00000000000b', '10000000-0000-0000-0000-000000000001', 'GB', 'GB');
insert into public.schools (id, platform_tenant_id, group_id, school_code, name, slug) values
  ('5a100000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', 'a1000000-0000-0000-0000-00000000000a', 'SA1', 'SA1', 'sa1'),
  ('5a200000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001', 'a1000000-0000-0000-0000-00000000000a', 'SA2', 'SA2', 'sa2'),
  ('5b100000-0000-0000-0000-000000000003', '10000000-0000-0000-0000-000000000001', 'a2000000-0000-0000-0000-00000000000b', 'SB1', 'SB1', 'sb1'),
  ('52000000-0000-0000-0000-000000000005', '20000000-0000-0000-0000-000000000002', null,                                   'S2',  'S2',  's2');

-- الصلاحيات المستعملة هنا (البذر الحقيقي في M23)
insert into public.permissions (code, resource, operation, description)
  select c, split_part(c, '.', 1), split_part(c, '.', 2), 'test' from unnest(array[
    'profile.read','profile.update','membership.read','role.assign','scope.assign',
    'role.read','role.create','role.update','permission.read','student.read']) c;
create function pg_temp.perm(c text) returns uuid language sql as $$ select id from public.permissions where code = c $$;

-- أدوار النظام: tadmin (كل ما سبق)، sadmin (إدارة عضويات)، teacher (profile.read فقط)، acct (student.read)، rolemgr (إدارة الأدوار)
insert into public.roles (id, platform_tenant_id, code, name, is_system) values
  ('71000000-0000-0000-0000-000000000001', null, 'tadmin',  'TA',      true),
  ('72000000-0000-0000-0000-000000000002', null, 'sadmin',  'SA',      true),
  ('73000000-0000-0000-0000-000000000003', null, 'teacher', 'Teacher', true),
  ('74000000-0000-0000-0000-000000000004', null, 'acct',    'Acct',    true),
  ('75000000-0000-0000-0000-000000000005', null, 'rolemgr', 'RoleMgr', true);
insert into public.role_permissions (role_id, permission_id)
  select '71000000-0000-0000-0000-000000000001'::uuid, id from public.permissions
  union all select '72000000-0000-0000-0000-000000000002'::uuid, pg_temp.perm(c)
    from unnest(array['profile.read','profile.update','membership.read','role.assign','scope.assign','role.read','permission.read']) c
  union all select '73000000-0000-0000-0000-000000000003'::uuid, pg_temp.perm('profile.read')
  union all select '74000000-0000-0000-0000-000000000004'::uuid, pg_temp.perm('student.read')
  union all select '75000000-0000-0000-0000-000000000005'::uuid, pg_temp.perm(c) from unnest(array['role.read','role.create','role.update']) c;
-- أدوار مخصصة: c1 (T1)، c2 (T2)
insert into public.roles (id, platform_tenant_id, code, name) values
  ('7c100000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', 'c1', 'C1'),
  ('7c200000-0000-0000-0000-000000000002', '20000000-0000-0000-0000-000000000002', 'c2', 'C2');
insert into public.role_permissions values
  ('7c100000-0000-0000-0000-000000000001', pg_temp.perm('role.read')),
  ('7c200000-0000-0000-0000-000000000002', pg_temp.perm('role.read'));

create function pg_temp.member(p_label text, p_tenant uuid, p_role uuid, p_scopes text[]) returns void
language plpgsql as $$
declare v_auth uuid := gen_random_uuid(); v_profile uuid; v_m uuid; s text;
begin
  insert into auth.users (id, email) values (v_auth, p_label || '@m15.invalid');
  insert into public.auth_identities values (v_auth, 'tenant');
  insert into public.profiles (platform_tenant_id, auth_user_id, display_name) values (p_tenant, v_auth, p_label) returning id into v_profile;
  insert into public.memberships (platform_tenant_id, profile_id) values (p_tenant, v_profile) returning id into v_m;
  if p_role is not null then
    insert into public.membership_roles (membership_id, role_id, platform_tenant_id, role_owner_key)
      values (v_m, p_role, p_tenant, coalesce((select owner_key from public.roles where id = p_role), '00000000-0000-0000-0000-000000000000'));
  end if;
  foreach s in array coalesce(p_scopes, '{}') loop
    if s = 'tenant' then
      insert into public.membership_scopes (membership_id, platform_tenant_id, scope_type) values (v_m, p_tenant, 'tenant');
    elsif s like 'G%' then
      insert into public.membership_scopes (membership_id, platform_tenant_id, scope_type, group_id)
        values (v_m, p_tenant, 'group', (select id from public.groups where group_code = s));
    else
      insert into public.membership_scopes (membership_id, platform_tenant_id, scope_type, school_id)
        values (v_m, p_tenant, 'school', (select id from public.schools where school_code = s));
    end if;
  end loop;
  insert into ids values (p_label, v_auth, v_profile, v_m);
end $$;

-- T1: ta (tenant)، gm (GA)، gb (GB)، sa1 (SA1)، sb1 (SB1) — مدراء؛ tch معلم SA1 (profile.read فقط)؛
--     multi معلم بنطاقين SA1+SB1؛ acc محاسب SB1؛ fresh عضو SA1 بلا دور؛ rc مدير أدوار بنطاق مدرسة SA1؛
--     grd ولي أمر وst طالب (بلا نطاقات)
select pg_temp.member('ta',    '10000000-0000-0000-0000-000000000001', '71000000-0000-0000-0000-000000000001', array['tenant']);
select pg_temp.member('gm',    '10000000-0000-0000-0000-000000000001', '72000000-0000-0000-0000-000000000002', array['GA']);
select pg_temp.member('gb',    '10000000-0000-0000-0000-000000000001', '72000000-0000-0000-0000-000000000002', array['GB']);
select pg_temp.member('sa1',   '10000000-0000-0000-0000-000000000001', '72000000-0000-0000-0000-000000000002', array['SA1']);
select pg_temp.member('sb1',   '10000000-0000-0000-0000-000000000001', '72000000-0000-0000-0000-000000000002', array['SB1']);
select pg_temp.member('tch',   '10000000-0000-0000-0000-000000000001', '73000000-0000-0000-0000-000000000003', array['SA1']);
select pg_temp.member('multi', '10000000-0000-0000-0000-000000000001', '73000000-0000-0000-0000-000000000003', array['SA1','SB1']);
select pg_temp.member('acc',   '10000000-0000-0000-0000-000000000001', '74000000-0000-0000-0000-000000000004', array['SB1']);
select pg_temp.member('fresh', '10000000-0000-0000-0000-000000000001', null,                                   array['SA1']);
select pg_temp.member('rc',    '10000000-0000-0000-0000-000000000001', '75000000-0000-0000-0000-000000000005', array['SA1']);
select pg_temp.member('grd',   '10000000-0000-0000-0000-000000000001', '73000000-0000-0000-0000-000000000003', null);
select pg_temp.member('st',    '10000000-0000-0000-0000-000000000001', null,                                   null);
select pg_temp.member('t2a',   '20000000-0000-0000-0000-000000000002', '71000000-0000-0000-0000-000000000001', array['tenant']);

-- st طالب مسجل في SA1، و grd ولي أمره (ارتباط نشط)
do $$
declare v_year uuid; v_stage uuid; v_grade uuid; v_sec uuid; v_st uuid; v_g uuid;
  v_school uuid := '5a100000-0000-0000-0000-000000000001';
  v_scope uuid := (select id from public.identity_scopes where group_id = 'a1000000-0000-0000-0000-00000000000a');
begin
  insert into public.academic_years (school_id, name, start_date, end_date, status) values (v_school, 'Y', '2026-09-01', '2027-06-30', 'active') returning id into v_year;
  insert into public.stages (school_id, name, sequence_no) values (v_school, 'P', 1) returning id into v_stage;
  insert into public.grade_levels (school_id, stage_id, name, sequence_no) values (v_school, v_stage, 'G1', 1) returning id into v_grade;
  insert into public.sections (school_id, academic_year_id, grade_level_id, name) values (v_school, v_year, v_grade, 'A') returning id into v_sec;
  insert into public.students (platform_tenant_id, identity_scope_id, student_profile_id, official_id, official_id_type, first_name, family_name)
    values ('10000000-0000-0000-0000-000000000001', v_scope, (select profile from ids where label = 'st'), 'N1', 'national_id', 'S', 'S') returning id into v_st;
  insert into public.enrollments (school_id, student_id, platform_tenant_id, academic_year_id, grade_level_id, section_id, identity_scope_id, scope_owner_id, status, effective_from)
    values (v_school, v_st, '10000000-0000-0000-0000-000000000001', v_year, v_grade, v_sec, v_scope, 'a1000000-0000-0000-0000-00000000000a', 'active', '2026-09-01');
  insert into public.guardians (platform_tenant_id, profile_id, first_name, family_name, phone_e164)
    values ('10000000-0000-0000-0000-000000000001', (select profile from ids where label = 'grd'), 'G', 'G', '+201000000001') returning id into v_g;
  insert into public.student_guardians (student_id, guardian_id, platform_tenant_id, relationship_type) values (v_st, v_g, '10000000-0000-0000-0000-000000000001', 'father');
end $$;

-- Platform Admin بكل الصلاحيات المتاحة في سياق المنصة (E8)
insert into public.platform_admin_roles (id, code, name) values ('81000000-0000-0000-0000-000000000001', 'pa_all', 'All');
insert into public.platform_admin_role_permissions select '81000000-0000-0000-0000-000000000001', id from public.permissions;
insert into auth.users (id, email) values ('c7000000-0000-0000-0000-000000000007', 'pa@m15.invalid');
insert into public.auth_identities values ('c7000000-0000-0000-0000-000000000007', 'platform');
insert into public.system_users (id, auth_user_id, display_name) values ('d7000000-0000-0000-0000-000000000007', 'c7000000-0000-0000-0000-000000000007', 'pa');
insert into public.platform_admin_assignments (system_user_id, platform_admin_role_id) values ('d7000000-0000-0000-0000-000000000007', '81000000-0000-0000-0000-000000000001');
insert into ids values ('pa', 'c7000000-0000-0000-0000-000000000007', null, null);

-- تسميات تُقرأ بلا RLS
create temp table lbl_m on commit drop as select membership as id, label from ids where membership is not null;
create temp table lbl_r on commit drop as select id, code as label from public.roles;
grant select on lbl_m, lbl_r to public;

-- ============ القراءة ============
create function pg_temp.lists(p_label text) returns void
language plpgsql as $$
begin
  perform pg_temp.run('profiles.' || p_label, p_label, $q$select string_agg(display_name, ',' order by display_name collate "C") from public.profiles$q$);
  perform pg_temp.run('members.'  || p_label, p_label, $q$select string_agg(l.label, ',' order by l.label collate "C") from public.memberships m join lbl_m l using (id)$q$);
  perform pg_temp.run('mroles.'   || p_label, p_label, $q$select string_agg(distinct (l.label collate "C"), ',' order by (l.label collate "C")) from public.membership_roles x join lbl_m l on l.id = x.membership_id$q$);
  perform pg_temp.run('mscopes.'  || p_label, p_label, $q$select string_agg(distinct (l.label collate "C"), ',' order by (l.label collate "C")) from public.membership_scopes x join lbl_m l on l.id = x.membership_id$q$);
  perform pg_temp.run('roles.'    || p_label, p_label, $q$select string_agg(code, ',' order by code collate "C") from public.roles$q$);
  perform pg_temp.run('rperms.'   || p_label, p_label, $q$select string_agg(distinct (l.label collate "C"), ',' order by (l.label collate "C")) from public.role_permissions x join lbl_r l on l.id = x.role_id$q$);
  perform pg_temp.run('perms.'    || p_label, p_label, $q$select count(*)::text from public.permissions$q$);
end $$;
select pg_temp.lists(l) from unnest(array['ta','gm','sa1','sb1','tch','grd','st','t2a','pa','anon']) l;

-- ============ الكتابة ============
create function pg_temp.assign_sql(p_target text, p_role uuid) returns text language sql as $$
  select format($f$insert into public.membership_roles (membership_id, role_id, platform_tenant_id, role_owner_key)
                   values (%L, %L, '10000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000000') returning 'ok'$f$,
                pg_temp.mid(p_target), p_role) $$;
create function pg_temp.scope_sql(p_target text, p_type text, p_ref text) returns text language sql as $$
  select format($f$insert into public.membership_scopes (membership_id, platform_tenant_id, scope_type, group_id, school_id)
                   values (%L, '10000000-0000-0000-0000-000000000001', %L, %L, %L) returning 'ok'$f$,
                pg_temp.mid(p_target), p_type,
                case when p_type = 'group'  then (select id from public.groups  where group_code  = p_ref) end,
                case when p_type = 'school' then (select id from public.schools where school_code = p_ref) end) $$;

-- membership_roles — F4، F5 (الخطوة 1)
select pg_temp.run('w.sa1_assign_fresh', 'sa1', pg_temp.assign_sql('fresh', '73000000-0000-0000-0000-000000000003'));
select pg_temp.run('w.sa1_assign_multi', 'sa1', pg_temp.assign_sql('multi', '74000000-0000-0000-0000-000000000004'));
select pg_temp.run('w.sa1_assign_self',  'sa1', pg_temp.assign_sql('sa1',   '73000000-0000-0000-0000-000000000003'));
select pg_temp.run('w.sa1_assign_empty_self', 'sa1', pg_temp.assign_sql('sa1', '7c100000-0000-0000-0000-000000000001'));
select pg_temp.run('w.sa1_assign_gm',    'sa1', pg_temp.assign_sql('gm',    '73000000-0000-0000-0000-000000000003'));
select pg_temp.run('w.tch_assign_fresh', 'tch', pg_temp.assign_sql('fresh', '74000000-0000-0000-0000-000000000004'));
select pg_temp.run('w.gm_assign_multi',  'gm',  pg_temp.assign_sql('multi', '74000000-0000-0000-0000-000000000004'));
select pg_temp.run('w.ta_assign_multi',  'ta',  pg_temp.assign_sql('multi', '74000000-0000-0000-0000-000000000004'));
select pg_temp.run('w.sa1_assign_grd',   'sa1', pg_temp.assign_sql('grd',   '74000000-0000-0000-0000-000000000004'));

-- membership_scopes — F1، E3، ومنح النطاق لعضوية لا يديرها الفاعل (قرار 2026-09-25)
select pg_temp.run('w.sa1_scope_tenant_fresh', 'sa1', pg_temp.scope_sql('fresh', 'tenant', null));
select pg_temp.run('w.sa1_scope_tenant_self',  'sa1', pg_temp.scope_sql('sa1',   'tenant', null));
select pg_temp.run('w.gm_scope_tenant_fresh',  'gm',  pg_temp.scope_sql('fresh', 'tenant', null));
select pg_temp.run('w.sa1_scope_group_fresh',  'sa1', pg_temp.scope_sql('fresh', 'group',  'GA'));
select pg_temp.run('w.sa1_scope_SB1_fresh',    'sa1', pg_temp.scope_sql('fresh', 'school', 'SB1'));
select pg_temp.run('w.sa1_scope_SA1_acc',      'sa1', pg_temp.scope_sql('acc',   'school', 'SA1'));
select pg_temp.run('w.gm_scope_SA2_fresh',     'gm',  pg_temp.scope_sql('fresh', 'school', 'SA2'));
select pg_temp.run('w.ta_scope_tenant_fresh',  'ta',  pg_temp.scope_sql('fresh', 'tenant', null));
select pg_temp.run('w.sa1_scope_SA1_self_dup', 'sa1', pg_temp.scope_sql('sa1',   'school', 'SA2'));

-- profiles — G1، F2
select pg_temp.run('u.sa1_profile_tch',  'sa1', $q$with u as (update public.profiles set display_name = 'tch' where display_name = 'tch' returning 1) select count(*)::text from u$q$);
select pg_temp.run('u.sa1_profile_gm',   'sa1', $q$with u as (update public.profiles set display_name = 'gm' where display_name = 'gm' returning 1) select count(*)::text from u$q$);
select pg_temp.run('u.sa1_profile_self', 'sa1', $q$with u as (update public.profiles set display_name = 'sa1' where display_name = 'sa1' returning 1) select count(*)::text from u$q$);
select pg_temp.run('u.tch_profile_self', 'tch', $q$with u as (update public.profiles set display_name = 'tch' where display_name = 'tch' returning 1) select count(*)::text from u$q$);
select pg_temp.run('u.ta_profile_t2a',   'ta',  $q$with u as (update public.profiles set display_name = 't2a' where display_name = 't2a' returning 1) select count(*)::text from u$q$);
select pg_temp.run('u.ta_profile_move',  'ta',  $q$update public.profiles set platform_tenant_id = '20000000-0000-0000-0000-000000000002' where display_name = 'fresh' returning 'ok'$q$);

-- الحذف (G2)
select pg_temp.run('d.sa1_role_fresh',   'sa1', format($q$with u as (delete from public.membership_roles where membership_id = %L returning 1) select count(*)::text from u$q$, pg_temp.mid('fresh')));
select pg_temp.run('d.sa1_role_tch',     'sa1', format($q$with u as (delete from public.membership_roles where membership_id = %L returning 1) select count(*)::text from u$q$, pg_temp.mid('tch')));
select pg_temp.run('d.sb1_role_multi',   'sb1', format($q$with u as (delete from public.membership_roles where membership_id = %L returning 1) select count(*)::text from u$q$, pg_temp.mid('multi')));
select pg_temp.run('d.sb1_scope_multi',  'sb1', format($q$with u as (delete from public.membership_scopes where membership_id = %L returning 1) select count(*)::text from u$q$, pg_temp.mid('multi')));
select pg_temp.run('d.sa1_scope_tch',    'sa1', format($q$with u as (delete from public.membership_scopes where membership_id = %L returning 1) select count(*)::text from u$q$, pg_temp.mid('tch')));
select pg_temp.run('d.sa1_scope_self',   'sa1', format($q$with u as (delete from public.membership_scopes where membership_id = %L returning 1) select count(*)::text from u$q$, pg_temp.mid('sa1')));

-- memberships — لا كتابة مباشرة
select pg_temp.run('w.ta_membership_insert', 'ta', format($q$insert into public.memberships (platform_tenant_id, profile_id) values ('10000000-0000-0000-0000-000000000001', %L) returning 'ok'$q$,
  (select id from public.profiles where display_name = 'ta')));
select pg_temp.run('u.ta_membership_status', 'ta', $q$with u as (update public.memberships set status = status returning 1) select count(*)::text from u$q$);

-- roles
select pg_temp.run('w.ta_role_T1',   'ta', $q$insert into public.roles (platform_tenant_id, code, name) values ('10000000-0000-0000-0000-000000000001','c9','C9') returning 'ok'$q$);
select pg_temp.run('w.ta_role_T2',   'ta', $q$insert into public.roles (platform_tenant_id, code, name) values ('20000000-0000-0000-0000-000000000002','c8','C8') returning 'ok'$q$);
select pg_temp.run('w.ta_role_sys',  'ta', $q$insert into public.roles (platform_tenant_id, code, name, is_system) values (null,'s9','S9',true) returning 'ok'$q$);
select pg_temp.run('w.rc_role_T1',   'rc', $q$insert into public.roles (platform_tenant_id, code, name) values ('10000000-0000-0000-0000-000000000001','c7','C7') returning 'ok'$q$);
select pg_temp.run('w.sa1_role_T1',  'sa1',$q$insert into public.roles (platform_tenant_id, code, name) values ('10000000-0000-0000-0000-000000000001','c6','C6') returning 'ok'$q$);
select pg_temp.run('u.ta_role_c1',   'ta', $q$with u as (update public.roles set name = 'C1x' where code = 'c1' returning 1) select count(*)::text from u$q$);
select pg_temp.run('u.ta_role_sys',  'ta', $q$with u as (update public.roles set name = 'x' where code = 'teacher' returning 1) select count(*)::text from u$q$);
select pg_temp.run('u.ta_role_c2',   'ta', $q$with u as (update public.roles set name = 'x' where code = 'c2' returning 1) select count(*)::text from u$q$);
select pg_temp.run('u.ta_role_to_sys','ta',$q$update public.roles set platform_tenant_id = null, is_system = true where code = 'c1' returning 'ok'$q$);
select pg_temp.run('u.rc_role_c1',   'rc', $q$with u as (update public.roles set name = 'x' where code = 'c1' returning 1) select count(*)::text from u$q$);

-- role_permissions
select pg_temp.run('w.ta_rp_c1',     'ta', format($q$insert into public.role_permissions values ('7c100000-0000-0000-0000-000000000001', %L) returning 'ok'$q$, pg_temp.perm('student.read')));
select pg_temp.run('w.ta_rp_c2',     'ta', format($q$insert into public.role_permissions values ('7c200000-0000-0000-0000-000000000002', %L) returning 'ok'$q$, pg_temp.perm('student.read')));
select pg_temp.run('w.ta_rp_sys',    'ta', format($q$insert into public.role_permissions values ('73000000-0000-0000-0000-000000000003', %L) returning 'ok'$q$, pg_temp.perm('student.read')));
select pg_temp.run('w.rc_rp_c1',     'rc', format($q$insert into public.role_permissions values ('7c100000-0000-0000-0000-000000000001', %L) returning 'ok'$q$, pg_temp.perm('profile.read')));
select pg_temp.run('d.ta_rp_c1',     'ta', $q$with u as (delete from public.role_permissions where role_id = '7c100000-0000-0000-0000-000000000001' returning 1) select count(*)::text from u$q$);
select pg_temp.run('d.ta_rp_sys',    'ta', $q$with u as (delete from public.role_permissions where role_id = '73000000-0000-0000-0000-000000000003' returning 1) select count(*)::text from u$q$);

-- E6: DELETE على جداول M15 التي بلا استثناء G2
select pg_temp.run('d.profiles',    'ta', $q$with u as (delete from public.profiles returning 1) select count(*)::text from u$q$);
select pg_temp.run('d.memberships', 'ta', $q$with u as (delete from public.memberships returning 1) select count(*)::text from u$q$);
select pg_temp.run('d.roles',       'ta', $q$with u as (delete from public.roles returning 1) select count(*)::text from u$q$);
select pg_temp.run('d.permissions', 'ta', $q$with u as (delete from public.permissions returning 1) select count(*)::text from u$q$);

-- membership_id_of لا يكشف عبر Tenant
select pg_temp.run('mid.cross', 'ta', format($q$select coalesce(app.membership_id_of(%L)::text, '<null>')$q$, (select profile from ids where label = 't2a')));
select pg_temp.run('mid.own',   'ta', format($q$select (app.membership_id_of(%L) = %L)::text$q$, (select profile from ids where label = 'tch'), pg_temp.mid('tch')));

-- الدوال والسياسات
select pg_temp.rec('exec.anon', $q$select count(*)::text from pg_proc p where p.pronamespace = 'app'::regnamespace and has_function_privilege('anon', p.oid, 'EXECUTE')$q$);
select pg_temp.rec('exec.auth', $q$select bool_and(has_function_privilege('authenticated', f, 'EXECUTE'))::text
  from unnest(array['app.current_profile_id()','app.membership_id_of(uuid)','app.can_see_membership(uuid)','app.can_manage_membership(uuid)']::regprocedure[]) f$q$);
-- «EXECUTE فقط حيث تحتاجه سياسة» (قرار 2026-09-25): كل دالة ينفذها authenticated تستدعيها سياسة واحدة على الأقل
select pg_temp.rec('exec.unused', $q$select coalesce(string_agg(p.proname, ','), 'none') from pg_proc p
  where p.pronamespace = 'app'::regnamespace and has_function_privilege('authenticated', p.oid, 'EXECUTE')
    and not exists (select 1 from pg_policies pol where pol.schemaname = 'public'
                     and coalesce(pol.qual, '') || coalesce(pol.with_check, '') ~ ('app\.' || p.proname || '\('))$q$);
select pg_temp.rec('mid.meta', $q$select (pg_get_userbyid(proowner) = 'app_owner' and prosecdef and array_to_string(proconfig, ',') like 'search_path=%')::text from pg_proc where oid = 'app.membership_id_of(uuid)'::regprocedure$q$);

select plan(104);

-- ---------- profiles (F2، قرار membership_id_of) ----------
select is((select v from r where k = 'profiles.ta'),  'acc,fresh,gb,gm,grd,multi,rc,sa1,sb1,st,ta,tch', 'profiles: tenant scope sees every T1 profile reachable by scope or relationship; not T2');
select is((select v from r where k = 'profiles.gm'),  'fresh,gm,grd,multi,rc,sa1,st,tch',              'profiles: group scope → GA members and GA-related identities; not ta, gb, sb1, acc');
select is((select v from r where k = 'profiles.sa1'), 'fresh,grd,multi,rc,sa1,st,tch',                 'profiles: school scope → SA1 only; not the group manager above it');
select is((select v from r where k = 'profiles.sb1'), 'acc,multi,sb1',                                 'profiles: SB1 sees its members; multi by intersection (E12/F3 analogue)');
select is((select v from r where k = 'profiles.tch'), 'fresh,grd,multi,rc,sa1,st,tch',                 'profiles: a teacher with profile.read but WITHOUT membership.read sees SA1 profiles (membership_id_of)');
select is((select v from r where k = 'profiles.grd'), 'grd',                                           'profiles: a guardian sees only itself (E11/F2)');
select is((select v from r where k = 'profiles.st'),  'st',                                            'profiles: a student sees only itself');
select is((select v from r where k = 'profiles.t2a'), 't2a',                                           'profiles: never across tenants');
select is((select v from r where k = 'profiles.pa'),  '<null>',                                        'profiles: a platform admin holding every platform permission sees nothing (E8)');
select is((select v from r where k = 'profiles.anon'),'<null>',                                        'profiles: anon');

-- ---------- memberships (F3) ----------
select is((select v from r where k = 'members.ta'),  'acc,fresh,gb,gm,grd,multi,rc,sa1,sb1,st,ta,tch', 'memberships: tenant scope + membership.read');
select is((select v from r where k = 'members.gm'),  'fresh,gm,grd,multi,rc,sa1,st,tch',              'memberships: group manager does not see another group (E12/F3)');
select is((select v from r where k = 'members.sa1'), 'fresh,grd,multi,rc,sa1,st,tch',                 'memberships: school scope');
select is((select v from r where k = 'members.sb1'), 'acc,multi,sb1',                                 'memberships: SB1');
select is((select v from r where k = 'members.tch'), 'tch',                                           'memberships: without membership.read → only its own');
select is((select v from r where k = 'members.grd'), 'grd',                                           'memberships: guardian → only its own');
select is((select v from r where k = 'members.t2a'), 't2a',                                           'memberships: never across tenants');
select is((select v from r where k = 'members.pa'),  '<null>',                                        'memberships: platform admin sees nothing (E8)');

-- ---------- membership_roles / membership_scopes ----------
select is((select v from r where k = 'mroles.sa1'),  'grd,multi,rc,sa1,tch',                          'membership_roles: SA1 admin sees roles of visible memberships (fresh, st have none)');
select is((select v from r where k = 'mroles.tch'),  'tch',                                           'membership_roles: without membership.read → own roles only');
select is((select v from r where k = 'mroles.sb1'),  'acc,multi,sb1',                                 'membership_roles: SB1');
select is((select v from r where k = 'mroles.pa'),   '<null>',                                        'membership_roles: platform admin sees nothing');
select is((select v from r where k = 'mscopes.sa1'), 'fresh,multi,rc,sa1,tch',                        'membership_scopes: SA1 admin sees scopes of visible memberships');
select is((select v from r where k = 'mscopes.tch'), 'tch',                                           'membership_scopes: own scopes only');
select is((select v from r where k = 'mscopes.grd'), '<null>',                                        'membership_scopes: a guardian has none and sees none');

-- ---------- roles / role_permissions / permissions ----------
select is((select v from r where k = 'roles.ta'),   'acct,c1,rolemgr,sadmin,tadmin,teacher', 'roles: system roles + own tenant custom roles; not c2 (T2)');
select is((select v from r where k = 'roles.t2a'),  'acct,c2,rolemgr,sadmin,tadmin,teacher', 'roles: T2 sees system roles + c2 only');
select is((select v from r where k = 'roles.tch'),  '<null>',                                'roles: without role.read → nothing');
select is((select v from r where k = 'roles.pa'),   '<null>',                                'roles: platform admin sees nothing (E8)');
select is((select v from r where k = 'rperms.ta'),  'acct,c1,rolemgr,sadmin,tadmin,teacher', 'role_permissions: follow roles visibility');
select is((select v from r where k = 'rperms.t2a'), 'acct,c2,rolemgr,sadmin,tadmin,teacher', 'role_permissions: T2 never sees c1 mappings');
select is((select v from r where k = 'rperms.tch'), '<null>',                                'role_permissions: nothing without role.read');
select is((select v from r where k = 'perms.ta'),   '10',                                    'permissions: whole catalog with permission.read');
select is((select v from r where k = 'perms.tch'),  '0',                                     'permissions: nothing without permission.read');
select is((select v from r where k = 'perms.pa'),   '0',                                     'permissions: platform context has no policy here (E8)');

-- ---------- membership_roles: F4، F5 ----------
select is((select v from r where k = 'w.sa1_assign_fresh'), 'ok', 'assign: SA1 admin → a membership wholly inside SA1 (control)');
select ok((select v from r where k = 'w.sa1_assign_multi') like 'ERR 42501%row-level security%membership_roles%', 'E13/F4: SA1 admin cannot assign a role to a membership that also spans SB1');
select ok((select v from r where k = 'w.sa1_assign_self')  like 'ERR 42501%row-level security%membership_roles%', 'F5: no self-assignment');
select ok((select v from r where k = 'w.sa1_assign_empty_self') like 'ERR 42501%row-level security%membership_roles%', 'E14 step 1 (F5): an empty custom role cannot be self-assigned');
select ok((select v from r where k = 'w.sa1_assign_gm')    like 'ERR 42501%row-level security%membership_roles%', 'assign: a school admin cannot act on the group manager above it');
select ok((select v from r where k = 'w.tch_assign_fresh') like 'ERR 42501%row-level security%membership_roles%', 'assign: scope without role.assign (P2)');
select ok((select v from r where k = 'w.gm_assign_multi')  like 'ERR 42501%row-level security%membership_roles%', 'F4: group manager GA cannot assign to a membership spanning SB1 (GB)');
select is((select v from r where k = 'w.ta_assign_multi'), 'ok', 'assign: tenant scope contains every scope (control)');
select is((select v from r where k = 'w.sa1_assign_grd'),  'ok', 'assign: scope-less guardian membership managed through its child in SA1 (§10.0)');

-- ---------- membership_scopes: F1، E3، قرار 2026-09-25 ----------
select ok((select v from r where k = 'w.sa1_scope_tenant_fresh') like 'ERR 42501%row-level security%membership_scopes%', 'E9/F1: school admin cannot grant tenant scope to another');
select ok((select v from r where k = 'w.sa1_scope_tenant_self')  like 'ERR 42501%row-level security%membership_scopes%', 'E9/F1: school admin cannot grant tenant scope to itself');
select ok((select v from r where k = 'w.gm_scope_tenant_fresh')  like 'ERR 42501%row-level security%membership_scopes%', 'F1: group manager cannot grant tenant scope');
select ok((select v from r where k = 'w.sa1_scope_group_fresh')  like 'ERR 42501%row-level security%membership_scopes%', 'F1: school admin cannot grant its group scope');
select ok((select v from r where k = 'w.sa1_scope_SB1_fresh')    like 'ERR 42501%row-level security%membership_scopes%', 'E3: school admin cannot grant another school');
select ok((select v from r where k = 'w.sa1_scope_SA1_acc')      like 'ERR 42501%row-level security%membership_scopes%', '2026-09-25: own school cannot be granted to a membership the actor does not manage (SB1 accountant)');
select is((select v from r where k = 'w.gm_scope_SA2_fresh'), 'ok', 'scope grant: group manager adds a school of its group to a membership it manages (control)');
select is((select v from r where k = 'w.ta_scope_tenant_fresh'), 'ok', 'scope grant: tenant scope grants tenant scope (control)');
select ok((select v from r where k = 'w.sa1_scope_SA1_self_dup') like 'ERR 42501%row-level security%membership_scopes%', 'F5: no self-management of scopes');

-- ---------- الحذف (G2) ----------
select is((select v from r where k = 'd.sa1_role_fresh'),  '0', 'revoke role: fresh gained SA2 and tenant scopes above → no longer wholly inside SA1, so SA1 admin cannot touch it (F4 containment)');
select is((select v from r where k = 'd.sa1_role_tch'),    '1', 'revoke role: SA1 admin on a membership it manages');
select is((select v from r where k = 'd.sb1_role_multi'),  '0', 'revoke role: SB1 admin cannot touch a membership spanning SA1 (F4)');
select is((select v from r where k = 'd.sb1_scope_multi'), '0', 'revoke scope: SB1 admin cannot touch a membership it does not wholly manage');
select is((select v from r where k = 'd.sa1_scope_tch'),   '1', 'revoke scope: SA1 admin on a membership it manages');
select is((select v from r where k = 'd.sa1_scope_self'),  '0', 'revoke scope: no self-management');

-- ---------- profiles: G1 ----------
select is((select v from r where k = 'u.sa1_profile_tch'),  '1', 'profile update: SA1 admin on a managed member');
select is((select v from r where k = 'u.sa1_profile_gm'),   '0', 'profile update: not the group manager above');
select is((select v from r where k = 'u.sa1_profile_self'), '0', 'G1: no self-update of the profile');
select is((select v from r where k = 'u.tch_profile_self'), '0', 'G1: a teacher cannot update its own profile');
select is((select v from r where k = 'u.ta_profile_t2a'),   '0', 'profile update: never across tenants');
select ok((select v from r where k = 'u.ta_profile_move') like 'ERR 42501%row-level security%profiles%', 'profile update: cannot move a profile to another tenant');

-- ---------- memberships ----------
select ok((select v from r where k = 'w.ta_membership_insert') like 'ERR 42501%row-level security%memberships%', 'memberships insert: no client path (provisioning functions only)');
select is((select v from r where k = 'u.ta_membership_status'), '0', 'memberships update: no client path (state functions only)');

-- ---------- roles ----------
select is((select v from r where k = 'w.ta_role_T1'), 'ok', 'roles insert: tenant scope + role.create');
select ok((select v from r where k = 'w.ta_role_T2')  like 'ERR 42501%row-level security%roles%', 'roles insert: never into another tenant');
select ok((select v from r where k = 'w.ta_role_sys') like 'ERR 42501%row-level security%roles%', 'roles insert: no system role from the client');
select ok((select v from r where k = 'w.rc_role_T1')  like 'ERR 42501%row-level security%roles%', 'roles insert: role.create with school scope only → rejected (Gate B: custom roles are tenant-level)');
select ok((select v from r where k = 'w.sa1_role_T1') like 'ERR 42501%row-level security%roles%', 'roles insert: without role.create');
select is((select v from r where k = 'u.ta_role_c1'),  '1', 'roles update: own custom role');
select is((select v from r where k = 'u.ta_role_sys'), '0', 'roles update: system roles are untouchable');
select is((select v from r where k = 'u.ta_role_c2'),  '0', 'roles update: never another tenant''s role');
select ok((select v from r where k = 'u.ta_role_to_sys') like 'ERR 42501%row-level security%roles%', 'roles update: cannot turn a custom role into a system role');
select is((select v from r where k = 'u.rc_role_c1'),  '0', 'roles update: school-scoped role manager cannot edit tenant roles');

-- ---------- role_permissions ----------
select is((select v from r where k = 'w.ta_rp_c1'), 'ok', 'role_permissions insert: own custom role (T8 ⊆ check arrives in M19)');
select ok((select v from r where k = 'w.ta_rp_c2')  like 'ERR 42501%row-level security%role_permissions%', 'role_permissions insert: never another tenant''s role');
select ok((select v from r where k = 'w.ta_rp_sys') like 'ERR 42501%row-level security%role_permissions%', 'role_permissions insert: never a system role');
select ok((select v from r where k = 'w.rc_rp_c1')  like 'ERR 42501%row-level security%role_permissions%', 'role_permissions insert: school-scoped role manager rejected');
select is((select v from r where k = 'd.ta_rp_c1'),  '2', 'role_permissions delete: own custom role (G2)');
select is((select v from r where k = 'd.ta_rp_sys'), '0', 'role_permissions delete: never a system role');

-- ---------- E6 ----------
select is((select v from r where k = 'd.profiles'),    '0', 'E6: DELETE profiles → nothing');
select is((select v from r where k = 'd.memberships'), '0', 'E6: DELETE memberships → nothing');
select is((select v from r where k = 'd.roles'),       '0', 'E6: DELETE roles → nothing');
select is((select v from r where k = 'd.permissions'), '0', 'E6: DELETE permissions → nothing');
select is((select count(*)::int from pg_policies where schemaname = 'public' and cmd in ('DELETE','ALL')
            and tablename not in ('membership_roles','membership_scopes','role_permissions')), 0,
          'E6: DELETE policies exist only on the three G2 tables');

-- ---------- membership_id_of ----------
select is((select v from r where k = 'mid.cross'), '<null>', 'membership_id_of: no lookup across tenants');
select is((select v from r where k = 'mid.own'),   'true',   'membership_id_of: resolves within the tenant');
select is((select v from r where k = 'mid.meta'),  'true',   'membership_id_of: SECURITY DEFINER, owner app_owner, pinned search_path');

-- ---------- الدوال والسياسات ----------
select is((select v from r where k = 'exec.anon'), '0', 'anon executes no function in schema app');
select is((select v from r where k = 'exec.auth'),   'true', 'authenticated executes every helper the M15 policies call');
select is((select v from r where k = 'exec.unused'), 'none', 'EXECUTE only where a policy needs it: every function authenticated can execute is called by a policy');
select is((select count(*)::int from pg_policies where schemaname = 'public'
            and tablename in ('profiles','memberships','membership_roles','membership_scopes','roles','permissions','role_permissions')
            and not ('authenticated' = any(roles) and cardinality(roles) = 1)), 0, 'every M15 policy is TO authenticated only');
select policies_are('public', 'profiles',          array['profiles_select','profiles_update'], 'profiles: exactly the M15 policies');
select policies_are('public', 'memberships',       array['memberships_select'], 'memberships: read only');
select policies_are('public', 'membership_roles',  array['membership_roles_select','membership_roles_insert','membership_roles_delete'], 'membership_roles: exactly the M15 policies');
select policies_are('public', 'membership_scopes', array['membership_scopes_select','membership_scopes_insert','membership_scopes_delete'], 'membership_scopes: exactly the M15 policies');
select policies_are('public', 'roles',             array['roles_select','roles_insert','roles_update'], 'roles: exactly the M15 policies');
select policies_are('public', 'permissions',       array['permissions_select'], 'permissions: read only');
select policies_are('public', 'role_permissions',  array['role_permissions_select','role_permissions_insert','role_permissions_delete'], 'role_permissions: exactly the M15 policies');
select is((select count(*)::int from pg_policies where schemaname = 'public'
            and (coalesce(qual, '') || coalesce(with_check, '')) ~ 'from\s+(public\.)?memberships'), 0,
          '§1.1 rule 6: no policy queries memberships directly');
select is((select count(*)::int from pg_policies where schemaname = 'public'
            and coalesce(qual, '') || coalesce(with_check, '') like '%has_permission(%'
            and coalesce(qual, '') || coalesce(with_check, '') like '%has_platform_permission(%'), 0,
          'G10: no policy mixes tenant and platform permissions');

select * from finish();
rollback;
