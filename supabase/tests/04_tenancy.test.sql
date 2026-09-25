-- M04 — tenancy: groups، schools، identity_scopes، T9؛ I1–I9، G3
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

insert into public.platform_tenants (id, tenant_code, name) values
  ('10000000-0000-0000-0000-000000000001', 'T1', 'Tenant One'),
  ('20000000-0000-0000-0000-000000000002', 'T2', 'Tenant Two');

-- مجموعتان في T1، ومجموعة في T2 بنفس الكود (مسموح: الكود فريد داخل Tenant)
insert into public.groups (id, platform_tenant_id, group_code, name) values
  ('a1000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', 'G-A', 'Group A'),
  ('a2000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001', 'G-B', 'Group B'),
  ('a3000000-0000-0000-0000-000000000003', '20000000-0000-0000-0000-000000000002', 'G-A', 'Group A in T2');

insert into public.schools (id, platform_tenant_id, group_id, school_code, name, slug) values
  ('51000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', 'a1000000-0000-0000-0000-000000000001', 'S1', 'In group A', 's1'),
  ('52000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001', null,                                   'S2', 'Standalone', 's2'),
  ('53000000-0000-0000-0000-000000000003', '20000000-0000-0000-0000-000000000002', null,                                   'S1', 'Standalone T2', 's1');

-- I1–I5
select pg_temp.rec('g.dup_code',        $q$insert into public.groups (platform_tenant_id, group_code, name) values ('10000000-0000-0000-0000-000000000001','G-A','x') returning 'ok'$q$);
select pg_temp.rec('g.bad_code',        $q$insert into public.groups (platform_tenant_id, group_code, name) values ('10000000-0000-0000-0000-000000000001','g a','x') returning 'ok'$q$);
select pg_temp.rec('s.cross_tenant_grp',$q$insert into public.schools (platform_tenant_id, group_id, school_code, name, slug) values ('20000000-0000-0000-0000-000000000002','a1000000-0000-0000-0000-000000000001','SX','x','sx') returning 'ok'$q$);
select pg_temp.rec('s.dup_code',        $q$insert into public.schools (platform_tenant_id, school_code, name, slug) values ('10000000-0000-0000-0000-000000000001','S1','x','sx1') returning 'ok'$q$);
select pg_temp.rec('s.dup_slug',        $q$insert into public.schools (platform_tenant_id, school_code, name, slug) values ('10000000-0000-0000-0000-000000000001','SZ','x','s1') returning 'ok'$q$);
select pg_temp.rec('s.bad_slug',        $q$insert into public.schools (platform_tenant_id, school_code, name, slug) values ('10000000-0000-0000-0000-000000000001','SY','x','Bad Slug') returning 'ok'$q$);
select pg_temp.rec('s.archive_no_ts',   $q$update public.schools set status = 'archived' where id = '52000000-0000-0000-0000-000000000002' returning 'ok'$q$);

-- I7–I9
select pg_temp.rec('is.scope_for_grouped_school',
  $q$insert into public.identity_scopes (platform_tenant_id, scope_kind, school_id) values ('10000000-0000-0000-0000-000000000001','school','51000000-0000-0000-0000-000000000001') returning 'ok'$q$);
select pg_temp.rec('is.second_scope_for_group',
  $q$insert into public.identity_scopes (platform_tenant_id, scope_kind, group_id) values ('10000000-0000-0000-0000-000000000001','group','a1000000-0000-0000-0000-000000000001') returning 'ok'$q$);
select pg_temp.rec('is.second_scope_for_school',
  $q$insert into public.identity_scopes (platform_tenant_id, scope_kind, school_id) values ('10000000-0000-0000-0000-000000000001','school','52000000-0000-0000-0000-000000000002') returning 'ok'$q$);
-- عزل قيد الـTenant: نحذف نطاق مدرسة T2 كي لا يسبقه قيد التفرّد، ثم ضابط بالـTenant الصحيح يعيده
delete from public.identity_scopes where school_id = '53000000-0000-0000-0000-000000000003';
select pg_temp.rec('is.cross_tenant_school',
  $q$insert into public.identity_scopes (platform_tenant_id, scope_kind, school_id) values ('10000000-0000-0000-0000-000000000001','school','53000000-0000-0000-0000-000000000003') returning 'ok'$q$);
select pg_temp.rec('is.same_tenant_control',
  $q$insert into public.identity_scopes (platform_tenant_id, scope_kind, school_id) values ('20000000-0000-0000-0000-000000000002','school','53000000-0000-0000-0000-000000000003') returning 'ok'$q$);
select pg_temp.rec('is.bad_shape',
  $q$insert into public.identity_scopes (platform_tenant_id, scope_kind, group_id, school_id) values ('10000000-0000-0000-0000-000000000001','group','a2000000-0000-0000-0000-000000000002','52000000-0000-0000-0000-000000000002') returning 'ok'$q$);
select pg_temp.rec('is.join_group_with_scope',
  $q$update public.schools set group_id = 'a1000000-0000-0000-0000-000000000001' where id = '52000000-0000-0000-0000-000000000002' returning 'ok'$q$);

-- RLS
select set_config('request.jwt.claims', '{"sub":"aaaaaaaa-0000-0000-0000-000000000001","role":"authenticated"}', true);
set local role authenticated;
select pg_temp.rec('rls.groups',  'select count(*)::text from public.groups');
select pg_temp.rec('rls.schools', 'select count(*)::text from public.schools');
select pg_temp.rec('rls.scopes',  'select count(*)::text from public.identity_scopes');
reset role;

select plan(32);

-- البنية
select has_table('public', 'groups', 'groups exists');
select has_table('public', 'schools', 'schools exists');
select has_table('public', 'identity_scopes', 'identity_scopes exists');
select ok((select bool_and(relrowsecurity and relforcerowsecurity) from pg_class
           where oid in ('public.groups'::regclass, 'public.schools'::regclass, 'public.identity_scopes'::regclass)),
          'RLS enabled and forced on all three tables');

-- I1–I5
select ok((select v from r where k = 'g.dup_code') like 'ERR 23505%groups_tenant_code_uq%',  'group_code unique within tenant');
select is((select count(*)::int from public.groups where group_code = 'G-A'), 2, 'same group_code allowed across tenants');
select ok((select v from r where k = 'g.bad_code') like 'ERR 23514%groups_group_code_chk%',  'group_code format enforced');
select ok((select v from r where k = 's.cross_tenant_grp') like 'ERR 23503%schools_group_fk%', 'I5: school cannot join a group of another tenant');
select ok((select v from r where k = 's.dup_code') like 'ERR 23505%schools_tenant_code_uq%',  'school_code unique within tenant');
select is((select count(*)::int from public.schools where school_code = 'S1'), 2, 'same school_code allowed across tenants');
select ok((select v from r where k = 's.dup_slug') like 'ERR 23505%schools_tenant_slug_uq%',  'slug unique within tenant');
select ok((select v from r where k = 's.bad_slug') like 'ERR 23514%schools_slug_chk%',  'slug format enforced');
select ok((select v from r where k = 's.archive_no_ts') like 'ERR 23514%schools_archived_chk%', 'archived status requires archived_at');

-- الأعمدة المشتقة
select is((select is_standalone from public.schools where id = '51000000-0000-0000-0000-000000000001'), false, 'is_standalone false for grouped school');
select is((select is_standalone from public.schools where id = '52000000-0000-0000-0000-000000000002'), true,  'is_standalone true for standalone school');
select is((select scope_owner_id::text from public.schools where id = '51000000-0000-0000-0000-000000000001'), 'a1000000-0000-0000-0000-000000000001', 'G3: grouped school scope owner = its group');
select is((select scope_owner_id::text from public.schools where id = '52000000-0000-0000-0000-000000000002'), '52000000-0000-0000-0000-000000000002', 'G3: standalone school scope owner = itself');

-- T9 (G9، I8)
select is((select count(*)::int from public.identity_scopes where scope_kind = 'group'), 3,  'T9: one group scope per group (3 groups)');
select is((select count(*)::int from public.identity_scopes where scope_kind = 'school'), 2, 'T9: one school scope per standalone school (2)');
select is((select count(*)::int from public.identity_scopes where school_id = '51000000-0000-0000-0000-000000000001'), 0, 'T9: grouped school gets no scope of its own');
select is((select owner_id::text from public.identity_scopes where group_id = 'a1000000-0000-0000-0000-000000000001'), 'a1000000-0000-0000-0000-000000000001', 'G3: group scope owner_id = group');
select ok((select bool_and(s.scope_owner_id = i.owner_id) from public.schools s
           join public.identity_scopes i on i.owner_id = s.scope_owner_id),
          'G3: every school matches its identity scope through the owner key');
select ok(exists (select 1 from public.identity_scopes where group_id = 'a3000000-0000-0000-0000-000000000003' and platform_tenant_id = '20000000-0000-0000-0000-000000000002'),
          'T9: scope inherits the tenant of its group');

-- I7–I9
select ok((select v from r where k = 'is.scope_for_grouped_school') like 'ERR 23503%identity_scopes_school_standalone_fk%', 'I9: grouped school cannot own a scope');
select ok((select v from r where k = 'is.second_scope_for_group')   like 'ERR 23505%identity_scopes_group_uq%', 'I7: at most one scope per group');
select ok((select v from r where k = 'is.second_scope_for_school')  like 'ERR 23505%identity_scopes_school_uq%', 'I7: at most one scope per standalone school');
select ok((select v from r where k = 'is.cross_tenant_school')      like 'ERR 23503%identity_scopes_school_tenant_fk%', 'scope cannot reference a school of another tenant (added tenant FK)');
select is((select v from r where k = 'is.same_tenant_control'), 'ok', 'control: the same insert with the correct tenant succeeds');
select ok((select v from r where k = 'is.bad_shape')                like 'ERR 23514%identity_scopes_shape_chk%', 'scope shape: group xor school');
select ok((select v from r where k = 'is.join_group_with_scope')    like 'ERR 23503%identity_scopes_school_standalone_fk%', 'standalone school with a scope cannot silently join a group (merge procedure required)');

-- RLS
select ok((select v from r where k = 'rls.groups') = '0' and (select v from r where k = 'rls.schools') = '0' and (select v from r where k = 'rls.scopes') = '0',
          'RLS: authenticated sees nothing before policies');
select ok(not has_function_privilege('anon', 'app.tg_create_identity_scope()', 'EXECUTE')
      and (select pg_get_userbyid(proowner) = 'app_owner' and prosecdef from pg_proc where oid = 'app.tg_create_identity_scope()'::regprocedure),
          'T9: SECURITY DEFINER owned by app_owner, no EXECUTE for anon');

select * from finish();
rollback;
