-- M07 — memberships: I12–I16، has_permission (G10)، can_access_* (F1)
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

create function pg_temp.as_(p_sub uuid) returns void
language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p_sub, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', coalesce(p_sub::text, ''), true);
end $$;

-- ============ Fixture ============
-- T1: group GA (schools SA1, SA2)، group GB (school SB1)، مدرسة مستقلة SS
-- T2: مدرسة مستقلة S2
insert into public.platform_tenants (id, tenant_code, name) values
  ('10000000-0000-0000-0000-000000000001', 'T1', 'T1'),
  ('20000000-0000-0000-0000-000000000002', 'T2', 'T2');
insert into public.groups (id, platform_tenant_id, group_code, name) values
  ('a1000000-0000-0000-0000-00000000000a', '10000000-0000-0000-0000-000000000001', 'GA', 'GA'),
  ('a2000000-0000-0000-0000-00000000000b', '10000000-0000-0000-0000-000000000001', 'GB', 'GB');
insert into public.schools (id, platform_tenant_id, group_id, school_code, name, slug) values
  ('5a100000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', 'a1000000-0000-0000-0000-00000000000a', 'SA1', 'SA1', 'sa1'),
  ('5a200000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001', 'a1000000-0000-0000-0000-00000000000a', 'SA2', 'SA2', 'sa2'),
  ('5b100000-0000-0000-0000-000000000003', '10000000-0000-0000-0000-000000000001', 'a2000000-0000-0000-0000-00000000000b', 'SB1', 'SB1', 'sb1'),
  ('55000000-0000-0000-0000-000000000004', '10000000-0000-0000-0000-000000000001', null,                                   'SS',  'SS',  'ss'),
  ('52000000-0000-0000-0000-000000000005', '20000000-0000-0000-0000-000000000002', null,                                   'S2',  'S2',  's2');

-- المستخدمون: tenantAdmin (نطاق tenant)، groupMgr (نطاق GA)، schoolAdmin (نطاق SA1)،
--             multi (نطاقا SA2 و SS)، ended (عضوية منتهية)، t2user (Tenant 2)، platform
insert into auth.users (id, email) values
  ('c1000000-0000-0000-0000-000000000001', 'ta@m07.invalid'),
  ('c2000000-0000-0000-0000-000000000002', 'gm@m07.invalid'),
  ('c3000000-0000-0000-0000-000000000003', 'sa@m07.invalid'),
  ('c4000000-0000-0000-0000-000000000004', 'multi@m07.invalid'),
  ('c5000000-0000-0000-0000-000000000005', 'ended@m07.invalid'),
  ('c6000000-0000-0000-0000-000000000006', 't2@m07.invalid'),
  ('c7000000-0000-0000-0000-000000000007', 'platform@m07.invalid'),
  ('c8000000-0000-0000-0000-000000000008', 'nomem@m07.invalid');
insert into public.auth_identities values
  ('c1000000-0000-0000-0000-000000000001', 'tenant'), ('c2000000-0000-0000-0000-000000000002', 'tenant'),
  ('c3000000-0000-0000-0000-000000000003', 'tenant'), ('c4000000-0000-0000-0000-000000000004', 'tenant'),
  ('c5000000-0000-0000-0000-000000000005', 'tenant'), ('c6000000-0000-0000-0000-000000000006', 'tenant'),
  ('c7000000-0000-0000-0000-000000000007', 'platform'), ('c8000000-0000-0000-0000-000000000008', 'tenant');
insert into public.profiles (id, platform_tenant_id, auth_user_id, display_name) values
  ('b1000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', 'c1000000-0000-0000-0000-000000000001', 'TA'),
  ('b2000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001', 'c2000000-0000-0000-0000-000000000002', 'GM'),
  ('b3000000-0000-0000-0000-000000000003', '10000000-0000-0000-0000-000000000001', 'c3000000-0000-0000-0000-000000000003', 'SA'),
  ('b4000000-0000-0000-0000-000000000004', '10000000-0000-0000-0000-000000000001', 'c4000000-0000-0000-0000-000000000004', 'MULTI'),
  ('b5000000-0000-0000-0000-000000000005', '10000000-0000-0000-0000-000000000001', 'c5000000-0000-0000-0000-000000000005', 'ENDED'),
  ('b6000000-0000-0000-0000-000000000006', '20000000-0000-0000-0000-000000000002', 'c6000000-0000-0000-0000-000000000006', 'T2'),
  ('b8000000-0000-0000-0000-000000000008', '10000000-0000-0000-0000-000000000001', 'c8000000-0000-0000-0000-000000000008', 'NOMEM');   -- T1 profile without membership
insert into public.memberships (id, platform_tenant_id, profile_id, status, ended_at) values
  ('e1000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', 'b1000000-0000-0000-0000-000000000001', 'active', null),
  ('e2000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001', 'b2000000-0000-0000-0000-000000000002', 'active', null),
  ('e3000000-0000-0000-0000-000000000003', '10000000-0000-0000-0000-000000000001', 'b3000000-0000-0000-0000-000000000003', 'active', null),
  ('e4000000-0000-0000-0000-000000000004', '10000000-0000-0000-0000-000000000001', 'b4000000-0000-0000-0000-000000000004', 'active', null),
  ('e5000000-0000-0000-0000-000000000005', '10000000-0000-0000-0000-000000000001', 'b5000000-0000-0000-0000-000000000005', 'ended',  now()),
  ('e6000000-0000-0000-0000-000000000006', '20000000-0000-0000-0000-000000000002', 'b6000000-0000-0000-0000-000000000006', 'active', null);
insert into public.membership_scopes (membership_id, platform_tenant_id, scope_type, group_id, school_id) values
  ('e1000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', 'tenant', null, null),
  ('e2000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001', 'group',  'a1000000-0000-0000-0000-00000000000a', null),
  ('e3000000-0000-0000-0000-000000000003', '10000000-0000-0000-0000-000000000001', 'school', null, '5a100000-0000-0000-0000-000000000001'),
  ('e4000000-0000-0000-0000-000000000004', '10000000-0000-0000-0000-000000000001', 'school', null, '5a200000-0000-0000-0000-000000000002'),
  ('e4000000-0000-0000-0000-000000000004', '10000000-0000-0000-0000-000000000001', 'school', null, '55000000-0000-0000-0000-000000000004'),
  ('e5000000-0000-0000-0000-000000000005', '10000000-0000-0000-0000-000000000001', 'tenant', null, null),
  ('e6000000-0000-0000-0000-000000000006', '20000000-0000-0000-0000-000000000002', 'tenant', null, null);

-- الأدوار والصلاحيات
insert into public.permissions (id, code, resource, operation, description) values
  ('f1000000-0000-0000-0000-000000000001', 'zt_student.read',   'zt_student', 'read',   'x'),
  ('f2000000-0000-0000-0000-000000000002', 'zt_student.export', 'zt_student', 'export', 'x');
insert into public.roles (id, platform_tenant_id, code, name, is_system, status) values
  ('71000000-0000-0000-0000-000000000001', null,                                   'reader',     'Reader',     true,  'active'),
  ('72000000-0000-0000-0000-000000000002', null,                                   'exporter',   'Exporter',   true,  'inactive'),
  ('73000000-0000-0000-0000-000000000003', '10000000-0000-0000-0000-000000000001', 'custom_t1',  'Custom T1',  false, 'active'),
  ('74000000-0000-0000-0000-000000000004', '20000000-0000-0000-0000-000000000002', 'custom_t2',  'Custom T2',  false, 'active');
insert into public.role_permissions values
  ('71000000-0000-0000-0000-000000000001', 'f1000000-0000-0000-0000-000000000001'),
  ('72000000-0000-0000-0000-000000000002', 'f2000000-0000-0000-0000-000000000002');
insert into public.membership_roles (membership_id, role_id, platform_tenant_id, role_owner_key) values
  ('e3000000-0000-0000-0000-000000000003', '71000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000000'),
  ('e3000000-0000-0000-0000-000000000003', '72000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000000'),
  ('e3000000-0000-0000-0000-000000000003', '73000000-0000-0000-0000-000000000003', '10000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001'),
  ('e5000000-0000-0000-0000-000000000005', '71000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000000');

-- ============ القيود ============
-- I12 = memberships_profile_uq. العضوية الثانية تخرق أيضاً memberships_tenant_profile_uq (مفتاح أوسع يتضمنه)،
-- وأيهما يُبلَّغ أولاً يتبع ترتيب إنشاء الفهارس لا الدلالة: الـmigrations تنشئ tenant_profile_uq أولاً،
-- والاستعادة من pg_dump بترتيب الأسماء (ظهر في E6). لذا يُعزل I12: يُسقط القيد الأوسع داخل الـsubtransaction
-- نفسها (تُلغى مع الرفض)، فلا يرفض الإدراج إلا القيد المقصود.
do $$
begin
  begin
    alter table public.memberships drop constraint memberships_tenant_profile_uq;
    insert into public.memberships (platform_tenant_id, profile_id)
      values ('10000000-0000-0000-0000-000000000001', 'b1000000-0000-0000-0000-000000000001');
    insert into r values ('m.second_membership', 'ok');
    raise exception 'undo' using errcode = 'P0001';
  exception when others then
    if sqlerrm <> 'undo' then
      insert into r values ('m.second_membership', 'ERR ' || sqlstate || ': ' || sqlerrm);
    end if;
  end;
end $$;
-- profile بلا عضوية (فلا يسبق قيدُ التفرد الـFK) من T1 في عضوية داخل T2
select pg_temp.rec('m.cross_tenant',      $q$insert into public.memberships (platform_tenant_id, profile_id) values ('20000000-0000-0000-0000-000000000002','b8000000-0000-0000-0000-000000000008') returning 'ok'$q$);
select pg_temp.rec('m.end_no_ts',         $q$update public.memberships set status = 'ended' where id = 'e2000000-0000-0000-0000-000000000002' returning 'ok'$q$);

select pg_temp.rec('mr.foreign_honest', $q$insert into public.membership_roles (membership_id, role_id, platform_tenant_id, role_owner_key) values ('e3000000-0000-0000-0000-000000000003','74000000-0000-0000-0000-000000000004','10000000-0000-0000-0000-000000000001','20000000-0000-0000-0000-000000000002') returning 'ok'$q$);
select pg_temp.rec('mr.foreign_forged', $q$insert into public.membership_roles (membership_id, role_id, platform_tenant_id, role_owner_key) values ('e3000000-0000-0000-0000-000000000003','74000000-0000-0000-0000-000000000004','10000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000001') returning 'ok'$q$);
select pg_temp.rec('mr.wrong_tenant',   $q$insert into public.membership_roles (membership_id, role_id, platform_tenant_id, role_owner_key) values ('e3000000-0000-0000-0000-000000000003','74000000-0000-0000-0000-000000000004','20000000-0000-0000-0000-000000000002','20000000-0000-0000-0000-000000000002') returning 'ok'$q$);
select pg_temp.rec('mr.granted_by',     $q$select coalesce(granted_by::text,'<null>') from public.membership_roles where membership_id = 'e3000000-0000-0000-0000-000000000003' limit 1$q$);

select pg_temp.rec('ms.bad_shape',       $q$insert into public.membership_scopes (membership_id, platform_tenant_id, scope_type, school_id) values ('e2000000-0000-0000-0000-000000000002','10000000-0000-0000-0000-000000000001','tenant','5a100000-0000-0000-0000-000000000001') returning 'ok'$q$);
select pg_temp.rec('ms.dup_tenant',      $q$insert into public.membership_scopes (membership_id, platform_tenant_id, scope_type) values ('e1000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000001','tenant') returning 'ok'$q$);
select pg_temp.rec('ms.dup_group',       $q$insert into public.membership_scopes (membership_id, platform_tenant_id, scope_type, group_id) values ('e2000000-0000-0000-0000-000000000002','10000000-0000-0000-0000-000000000001','group','a1000000-0000-0000-0000-00000000000a') returning 'ok'$q$);
select pg_temp.rec('ms.cross_tenant_school', $q$insert into public.membership_scopes (membership_id, platform_tenant_id, scope_type, school_id) values ('e3000000-0000-0000-0000-000000000003','10000000-0000-0000-0000-000000000001','school','52000000-0000-0000-0000-000000000005') returning 'ok'$q$);

-- ============ has_permission (G10) ============
select pg_temp.as_('c3000000-0000-0000-0000-000000000003');
select pg_temp.rec('hp.sa_read',     $q$select app.has_permission('zt_student.read')::text$q$);
select pg_temp.rec('hp.sa_export',   $q$select app.has_permission('zt_student.export')::text$q$);   -- الدور غير نشط
select pg_temp.rec('hp.sa_unknown',  $q$select app.has_permission('no.such')::text$q$);
select pg_temp.as_('c5000000-0000-0000-0000-000000000005');
select pg_temp.rec('hp.ended_read',  $q$select app.has_permission('zt_student.read')::text$q$);
select pg_temp.as_('c7000000-0000-0000-0000-000000000007');
select pg_temp.rec('hp.platform_read', $q$select app.has_permission('zt_student.read')::text$q$);
select pg_temp.as_(null);
select pg_temp.rec('hp.service_read',  $q$select app.has_permission('zt_student.read')::text$q$);

-- ============ can_access_* (F1) ============
create function pg_temp.scope_matrix(p_key text, p_sub uuid) returns void
language plpgsql as $$
begin
  perform pg_temp.as_(p_sub);
  perform pg_temp.rec(p_key || '.tenant_T1', $q$select app.can_access_tenant('10000000-0000-0000-0000-000000000001')::text$q$);
  perform pg_temp.rec(p_key || '.tenant_T2', $q$select app.can_access_tenant('20000000-0000-0000-0000-000000000002')::text$q$);
  perform pg_temp.rec(p_key || '.group_GA',  $q$select app.can_access_group('a1000000-0000-0000-0000-00000000000a')::text$q$);
  perform pg_temp.rec(p_key || '.group_GB',  $q$select app.can_access_group('a2000000-0000-0000-0000-00000000000b')::text$q$);
  perform pg_temp.rec(p_key || '.schools', $q$
    select string_agg(s.school_code, ',' order by s.school_code) filter (where app.can_access_school(s.id))
    from public.schools s$q$);
end $$;

select pg_temp.scope_matrix('ta',    'c1000000-0000-0000-0000-000000000001');
select pg_temp.scope_matrix('gm',    'c2000000-0000-0000-0000-000000000002');
select pg_temp.scope_matrix('sa',    'c3000000-0000-0000-0000-000000000003');
select pg_temp.scope_matrix('multi', 'c4000000-0000-0000-0000-000000000004');
select pg_temp.scope_matrix('ended', 'c5000000-0000-0000-0000-000000000005');
select pg_temp.scope_matrix('t2',    'c6000000-0000-0000-0000-000000000006');
select pg_temp.scope_matrix('plat',  'c7000000-0000-0000-0000-000000000007');
select pg_temp.as_(null);

-- RLS
select pg_temp.as_('c1000000-0000-0000-0000-000000000001');
set local role authenticated;
select pg_temp.rec('rls.memberships', 'select count(*)::text from public.memberships');
select pg_temp.rec('rls.scopes',      'select count(*)::text from public.membership_scopes');
reset role;

select plan(46);

select ok((select bool_and(relrowsecurity and relforcerowsecurity) from pg_class
           where oid in ('public.memberships'::regclass, 'public.membership_roles'::regclass, 'public.membership_scopes'::regclass)),
          'RLS enabled and forced on the three membership tables');

-- القيود
select ok((select v from r where k = 'm.second_membership') like 'ERR 23505%memberships_profile_uq%', 'I12: one membership per profile');
select ok((select v from r where k = 'm.cross_tenant') like 'ERR 23503%memberships_profile_fk%', 'membership cannot bind a profile to another tenant (composite tenant FK)');
select ok((select v from r where k = 'm.end_no_ts')         like 'ERR 23514%memberships_ended_chk%', 'ended status requires ended_at');
select ok((select v from r where k = 'mr.foreign_honest')   like 'ERR 23514%membership_roles_owner_chk%', 'I16: other-tenant custom role rejected (CHECK)');
select ok((select v from r where k = 'mr.foreign_forged')   like 'ERR 23503%membership_roles_role_fk%', 'I16: other-tenant custom role with forged key rejected (FK)');
select ok((select v from r where k = 'mr.wrong_tenant')     like 'ERR 23503%membership_roles_membership_fk%', 'membership_roles tenant must match the membership');
select is((select v from r where k = 'mr.granted_by'), '<null>', 'T6: granted_by NULL in service context');
select ok((select v from r where k = 'ms.bad_shape')        like 'ERR 23514%membership_scopes_shape_chk%', 'I13: scope shape enforced');
select ok((select v from r where k = 'ms.dup_tenant')       like 'ERR 23505%membership_scopes_uq%', 'I14: duplicate tenant scope rejected (NULLS NOT DISTINCT)');
select ok((select v from r where k = 'ms.dup_group')        like 'ERR 23505%membership_scopes_uq%', 'I14: duplicate group scope rejected');
select ok((select v from r where k = 'ms.cross_tenant_school') like 'ERR 23503%membership_scopes_school_fk%', 'I15: scope cannot reference a school of another tenant');

-- has_permission
select is((select v from r where k = 'hp.sa_read'),       'true',  'has_permission: granted via active role');
select is((select v from r where k = 'hp.sa_export'),     'false', 'has_permission: inactive role grants nothing');
select is((select v from r where k = 'hp.sa_unknown'),    'false', 'has_permission: unknown code');
select is((select v from r where k = 'hp.ended_read'),    'false', 'has_permission: ended membership grants nothing');
select is((select v from r where k = 'hp.platform_read'), 'false', 'G10: platform context never satisfies a tenant permission');
select is((select v from r where k = 'hp.service_read'),  'false', 'has_permission: service context');

-- F1 — can_access_tenant يعني نطاق Tenant
select is((select v from r where k = 'ta.tenant_T1'),    'true',  'F1: tenant-scoped member has tenant scope');
select is((select v from r where k = 'gm.tenant_T1'),    'false', 'F1: group-scoped member of the tenant has NO tenant scope');
select is((select v from r where k = 'sa.tenant_T1'),    'false', 'F1: school-scoped member of the tenant has NO tenant scope (the escalation that A3 allowed)');
select is((select v from r where k = 'multi.tenant_T1'), 'false', 'F1: multi-school member has NO tenant scope');
select is((select v from r where k = 'ta.tenant_T2'),    'false', 'tenant scope never crosses tenants');
select is((select v from r where k = 'ended.tenant_T1'), 'false', 'ended membership: no tenant scope even with a tenant scope row');

-- can_access_group
select is((select v from r where k = 'ta.group_GA'), 'true',  'tenant scope covers every group');
select is((select v from r where k = 'ta.group_GB'), 'true',  'tenant scope covers every group (GB)');
select is((select v from r where k = 'gm.group_GA'), 'true',  'group scope covers its group');
select is((select v from r where k = 'gm.group_GB'), 'false', 'group scope does not cover another group');
select is((select v from r where k = 'sa.group_GA'), 'false', 'school scope does not grant the group');
select is((select v from r where k = 't2.group_GA'), 'false', 'tenant scope in T2 does not reach a T1 group');

-- can_access_school — القائمة الكاملة لكل مستخدم
select is((select v from r where k = 'ta.schools'),    'SA1,SA2,SB1,SS', 'tenant scope: every school of T1, none of T2');
select is((select v from r where k = 'gm.schools'),    'SA1,SA2',        'group scope: only the group schools — not GB, not the standalone school');
select is((select v from r where k = 'sa.schools'),    'SA1',            'school scope: only its school (§1.1 rule 5)');
select is((select v from r where k = 'multi.schools'), 'SA2,SS',         'multiple school scopes work together');
select is((select v from r where k = 'ended.schools'), '<null>',         'ended membership: no school');
select is((select v from r where k = 't2.schools'),    'S2',             'T2 tenant scope: only T2 school (same code S* across tenants irrelevant)');
select is((select v from r where k = 'plat.schools'),  '<null>',         'C3: platform admin has no tenant school scope');
select is((select v from r where k = 'plat.tenant_T1'),'false',          'C3: platform admin has no tenant scope');

-- الدوال والملكية
select ok((select bool_and(pg_get_userbyid(proowner) = 'app_owner' and prosecdef) from pg_proc
           where oid in ('app.has_permission(text)'::regprocedure, 'app.can_access_tenant(uuid)'::regprocedure,
                         'app.can_access_group(uuid)'::regprocedure, 'app.can_access_school(uuid)'::regprocedure)),
          'permission and scope functions: SECURITY DEFINER owned by app_owner');
select is((select count(*)::int from pg_proc p where p.pronamespace = 'app'::regnamespace
             and has_function_privilege('anon', p.oid, 'EXECUTE')), 0,
          'no function in schema app is executable by anon');
select ok((select bool_and(array_to_string(proconfig, ',') like 'search_path=%') from pg_proc p
           where p.pronamespace = 'app'::regnamespace and p.prosecdef),
          'every SECURITY DEFINER function in app pins search_path');

-- RLS
select is((select v from r where k = 'rls.memberships'), '1', 'RLS (M15 self branch): without membership.read only its own membership is visible');
select is((select v from r where k = 'rls.scopes'),      '1', 'RLS (M15 self branch): without membership.read only its own scope rows are visible');

-- الـCASCADE: حذف العضوية يحذف أدوارها ونطاقاتها — عملية إدارية بسياق service (claims ممسوحة؛ T8 مُعفى — G7)
select pg_temp.as_(null);
delete from public.memberships where id = 'e5000000-0000-0000-0000-000000000005';
select is((select count(*)::int from public.membership_roles  where membership_id = 'e5000000-0000-0000-0000-000000000005'), 0, 'CASCADE: membership_roles removed with the membership');
select is((select count(*)::int from public.membership_scopes where membership_id = 'e5000000-0000-0000-0000-000000000005'), 0, 'CASCADE: membership_scopes removed with the membership');
select ok((select count(*) from public.role_permissions where role_id = '71000000-0000-0000-0000-000000000001') = 1, 'RESTRICT side intact: the role and its permissions survive');

select * from finish();
rollback;
