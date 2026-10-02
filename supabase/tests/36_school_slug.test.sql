-- M36 — school_slug (Phase 2A، ف3 + Q6): slug يتغير بـapp.set_school_slug وحدها (school.update + نطاق المدرسة + سبب).
-- الصيغة والتفرد بالقيدين القائمين؛ الفشل لا يترك أثراً؛ الـslug القديم يتحرر فوراً؛
-- وتغيير الـslug يغيّر المعرّف/السياق فقط — لا يمنح ولا يسحب تفويضاً، ولا يمس علاقة المدرسة بالـTenant/Group.
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

create function pg_temp.run(p_key text, p_label text, p_sql text) returns void
language plpgsql as $$
declare v_sub uuid := (select auth from actors where label = p_label);
begin
  perform set_config('request.jwt.claims', json_build_object('sub', v_sub, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', v_sub::text, true);
  execute 'set local role authenticated';
  perform pg_temp.rec(p_key, p_sql);
  insert into r values (p_key || '#ctx', coalesce(current_setting('app.audit_action', true), '') || '|' || coalesce(current_setting('app.audit_reason', true), ''))
    on conflict (k) do update set v = excluded.v;
  execute 'reset role';
end $$;

-- ============ Fixture ============
insert into public.platform_tenants (id, tenant_code, host_label, name) values
  ('10000000-0000-0000-0000-000000000001', 'T1', 't1', 'T1'), ('20000000-0000-0000-0000-000000000002', 'T2', 't2', 'T2');
insert into public.groups (id, platform_tenant_id, group_code, name) values ('a1000000-0000-0000-0000-00000000000a', '10000000-0000-0000-0000-000000000001', 'GA', 'GA');
insert into public.schools (id, platform_tenant_id, group_id, school_code, name, slug, status, archived_at) values
  ('5a000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', 'a1000000-0000-0000-0000-00000000000a', 'SA', 'SA', 'sa',  'active',   null),
  ('5b000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001', 'a1000000-0000-0000-0000-00000000000a', 'SB', 'SB', 'sb',  'active',   null),
  ('55000000-0000-0000-0000-000000000004', '10000000-0000-0000-0000-000000000001', null,                                   'SS', 'SS', 'ss',  'active',   null),
  ('5f000000-0000-0000-0000-000000000005', '10000000-0000-0000-0000-000000000001', null,                                   'SZ', 'SZ', 'old', 'archived', now()),
  ('5c000000-0000-0000-0000-000000000003', '20000000-0000-0000-0000-000000000002', null,                                   'SX', 'SX', 'sx',  'active',   null);
insert into public.academic_years (school_id, name, start_date, end_date) values
  ('5a000000-0000-0000-0000-000000000001', 'Y', '2026-09-01', '2027-06-30'), ('5b000000-0000-0000-0000-000000000002', 'Y', '2026-09-01', '2027-06-30');

create function pg_temp.member(p_label text, p_role text, p_tenant uuid, p_scope text, p_target uuid) returns void
language plpgsql as $$
declare v_a uuid := gen_random_uuid(); v_p uuid; v_m uuid;
begin
  insert into auth.users (id, email) values (v_a, p_label || '@m36.invalid');
  insert into public.auth_identities (auth_user_id, kind) values (v_a, 'tenant');
  insert into public.profiles (platform_tenant_id, auth_user_id, display_name) values (p_tenant, v_a, p_label) returning id into v_p;
  insert into public.memberships (platform_tenant_id, profile_id) values (p_tenant, v_p) returning id into v_m;
  insert into public.membership_roles (membership_id, role_id, platform_tenant_id, role_owner_key)
    values (v_m, (select id from public.roles where code = p_role and platform_tenant_id is null), p_tenant, '00000000-0000-0000-0000-000000000000');
  insert into public.membership_scopes (membership_id, platform_tenant_id, scope_type, group_id, school_id)
    values (v_m, p_tenant, p_scope, case when p_scope = 'group' then p_target end, case when p_scope = 'school' then p_target end);
  insert into actors values (p_label, v_a);
end $$;
select pg_temp.member('sa',  'school_admin',  '10000000-0000-0000-0000-000000000001', 'school', '5a000000-0000-0000-0000-000000000001');
select pg_temp.member('sb',  'school_admin',  '10000000-0000-0000-0000-000000000001', 'school', '5b000000-0000-0000-0000-000000000002');
select pg_temp.member('sec', 'secretary',     '10000000-0000-0000-0000-000000000001', 'school', '5a000000-0000-0000-0000-000000000001');   -- school.read بلا school.update
select pg_temp.member('gm',  'group_manager', '10000000-0000-0000-0000-000000000001', 'group',  'a1000000-0000-0000-0000-00000000000a');
select pg_temp.member('ta',  'tenant_admin',  '10000000-0000-0000-0000-000000000001', 'tenant', null);
select pg_temp.member('x',   'school_admin',  '20000000-0000-0000-0000-000000000002', 'school', '5c000000-0000-0000-0000-000000000003');

-- لقطات: التفويض (كل العضويات والأدوار والنطاقات ونطاقات الهوية)، وصف المدرسة عدا slug والختم
create function pg_temp.authz_snapshot() returns text language sql as $$
  select md5(coalesce((select string_agg(x::text, ';' order by x::text) from public.memberships x), '') || '#' ||
             coalesce((select string_agg(x::text, ';' order by x::text) from public.membership_roles x), '') || '#' ||
             coalesce((select string_agg(x::text, ';' order by x::text) from public.membership_scopes x), '') || '#' ||
             coalesce((select string_agg(x::text, ';' order by x::text) from public.identity_scopes x), ''))
$$;
create function pg_temp.school_row(p_id uuid) returns text language sql as $$
  select (to_jsonb(s) - 'slug' - 'updated_at' - 'updated_by')::text from public.schools s where s.id = p_id
$$;
-- ما يصل إليه كل فاعل: can_access_school على SA و SB، وما يقرؤه من سنوات كل منهما
create function pg_temp.probe(p_key text, p_label text) returns void language sql as $$
  select pg_temp.run(p_key, p_label, $q$select app.can_access_school('5a000000-0000-0000-0000-000000000001')::text || app.can_access_school('5b000000-0000-0000-0000-000000000002')::text
     || '|' || (select count(*) from public.academic_years where school_id = '5a000000-0000-0000-0000-000000000001')
     || (select count(*) from public.academic_years where school_id = '5b000000-0000-0000-0000-000000000002')
     || '|' || (select coalesce(string_agg(school_code, ',' order by school_code), '') from public.schools)$q$)
$$;
create function pg_temp.ctx(p_tenant text, p_slug text) returns text language sql as $$
  select coalesce((select coalesce((select sc.school_code from public.schools sc where sc.id = c.school_id), 'tenant-only') from app.login_context(p_tenant, p_slug) c), 'none')
$$;

select pg_temp.rec('before.authz',  $q$select pg_temp.authz_snapshot()$q$);
select pg_temp.rec('before.row_sa', $q$select pg_temp.school_row('5a000000-0000-0000-0000-000000000001')$q$);
select pg_temp.rec('before.row_sb', $q$select pg_temp.school_row('5b000000-0000-0000-0000-000000000002')$q$);
select pg_temp.probe('before.sa', 'sa');
select pg_temp.probe('before.sb', 'sb');
select pg_temp.probe('before.x',  'x');
select pg_temp.rec('before.ctx', $q$select pg_temp.ctx('t1', 'sa') || ',' || pg_temp.ctx('t1', 'north') || ',' || pg_temp.ctx('t1', null) || ',' || pg_temp.ctx('t2', 'sx')$q$);

-- ============ الرفض — قبل أي نجاح ============
select pg_temp.run('d.direct',    'sa',  $q$update public.schools set slug = 'hack' where id = '5a000000-0000-0000-0000-000000000001' returning 'ok'$q$);
select pg_temp.run('d.direct_ta', 'ta',  $q$update public.schools set slug = 'hack' where id = '5a000000-0000-0000-0000-000000000001' returning 'ok'$q$);
select pg_temp.run('d.name_ok',   'sa',  $q$update public.schools set name = name, timezone = timezone where id = '5a000000-0000-0000-0000-000000000001' returning name$q$);
select pg_temp.run('f.sec',       'sec', $q$select app.set_school_slug('5a000000-0000-0000-0000-000000000001', 'north', 'r')$q$);
select pg_temp.run('f.sibling',   'sb',  $q$select app.set_school_slug('5a000000-0000-0000-0000-000000000001', 'north', 'r')$q$);
select pg_temp.run('f.tenant',    'x',   $q$select app.set_school_slug('5a000000-0000-0000-0000-000000000001', 'north', 'r')$q$);
select pg_temp.run('f.noreason',  'sa',  $q$select app.set_school_slug('5a000000-0000-0000-0000-000000000001', 'north', ' ')$q$);
select pg_temp.run('f.same',      'sa',  $q$select app.set_school_slug('5a000000-0000-0000-0000-000000000001', 'sa', 'r')$q$);
select pg_temp.run('f.null',      'sa',  $q$select app.set_school_slug('5a000000-0000-0000-0000-000000000001', null, 'r')$q$);
select pg_temp.run('f.taken',     'sa',  $q$select app.set_school_slug('5a000000-0000-0000-0000-000000000001', 'sb', 'r')$q$);
select pg_temp.run('f.taken_archived', 'sa', $q$select app.set_school_slug('5a000000-0000-0000-0000-000000000001', 'old', 'r')$q$);
select pg_temp.run('f.upper',     'sa',  $q$select app.set_school_slug('5a000000-0000-0000-0000-000000000001', 'North', 'r')$q$);
select pg_temp.run('f.short',     'sa',  $q$select app.set_school_slug('5a000000-0000-0000-0000-000000000001', 'n', 'r')$q$);
select pg_temp.run('f.trailing',  'sa',  $q$select app.set_school_slug('5a000000-0000-0000-0000-000000000001', 'north-', 'r')$q$);
select pg_temp.run('f.underscore','sa',  $q$select app.set_school_slug('5a000000-0000-0000-0000-000000000001', 'north_a', 'r')$q$);
select pg_temp.run('f.archived',  'ta',  $q$select app.set_school_slug('5f000000-0000-0000-0000-000000000005', 'reborn', 'r')$q$);
select pg_temp.rec('fail.slug',   $q$select slug from public.schools where id = '5a000000-0000-0000-0000-000000000001'$q$);
select pg_temp.rec('fail.audit',  $q$select count(*)::text from public.audit_log where entity_type = 'schools' and entity_id = '5a000000-0000-0000-0000-000000000001' and (action = 'change_slug' or new_values ->> 'slug' <> 'sa')$q$);
select pg_temp.rec('fail.ctx',    $q$select coalesce(string_agg(k, ',' order by k), 'none') from r where k like '%#ctx' and v <> '|'$q$);

-- ============ النجاح ============
select pg_temp.run('ok.sa', 'sa', $q$select app.set_school_slug('5a000000-0000-0000-0000-000000000001', 'north', 'rebrand')$q$);
select pg_temp.rec('after.slug',    $q$select slug from public.schools where id = '5a000000-0000-0000-0000-000000000001'$q$);
select pg_temp.rec('after.row_sa',  $q$select pg_temp.school_row('5a000000-0000-0000-0000-000000000001')$q$);
select pg_temp.rec('after.ctx',     $q$select pg_temp.ctx('t1', 'sa') || ',' || pg_temp.ctx('t1', 'north') || ',' || pg_temp.ctx('t1', null) || ',' || pg_temp.ctx('t2', 'sx')$q$);

-- Q6: الـslug القديم متاح فوراً — المدرسة الشقيقة تأخذه بمديرها، ومدرسة جديدة تأخذ ما تحرر بعدها
select pg_temp.run('free.sb',  'sb', $q$select app.set_school_slug('5b000000-0000-0000-0000-000000000002', 'sa', 'takes the freed slug')$q$);
select pg_temp.run('free.new', 'ta', $q$with i as (insert into public.schools (platform_tenant_id, group_id, school_code, name, slug)
  values ('10000000-0000-0000-0000-000000000001', 'a1000000-0000-0000-0000-00000000000a', 'SN', 'SN', 'sb') returning 1) select count(*)::text from i$q$);
select pg_temp.rec('free.ctx', $q$select pg_temp.ctx('t1', 'sa') || ',' || pg_temp.ctx('t1', 'north') || ',' || pg_temp.ctx('t1', 'sb')$q$);
-- التفرد داخل الـTenant فقط: T2 يستعمل الـslug نفسه
select pg_temp.run('ok.x',  'x',  $q$select app.set_school_slug('5c000000-0000-0000-0000-000000000003', 'north', 'same slug, other tenant')$q$);
-- النطاق بالمجموعة وبالـTenant
select pg_temp.run('ok.gm', 'gm', $q$select app.set_school_slug('5b000000-0000-0000-0000-000000000002', 'south', 'group manager')$q$);
select pg_temp.run('ok.ta', 'ta', $q$select app.set_school_slug('55000000-0000-0000-0000-000000000004', 'solo', 'tenant admin')$q$);
select pg_temp.run('gm.standalone', 'gm', $q$select app.set_school_slug('55000000-0000-0000-0000-000000000004', 'mine', 'r')$q$);

-- التفويض بعد كل التغييرات: لا شيء تغيّر
select pg_temp.rec('after.authz',  $q$select pg_temp.authz_snapshot()$q$);
select pg_temp.rec('after.row_sb', $q$select pg_temp.school_row('5b000000-0000-0000-0000-000000000002')$q$);
select pg_temp.probe('after.sa', 'sa');
select pg_temp.probe('after.sb', 'sb');
select pg_temp.probe('after.x',  'x');

-- ============ التدقيق ============
select pg_temp.rec('audit.row', $q$select actor_type || '|' || action || '|' || reason || '|' || (old_values ->> 'slug') || '>' || (new_values ->> 'slug') || '|' ||
    (actor_id = (select p.id from public.profiles p join actors a on a.auth = p.auth_user_id where a.label = 'sa'))::text || '|' ||
    (platform_tenant_id = '10000000-0000-0000-0000-000000000001')::text || '|' || entity_id
  from public.audit_log where entity_type = 'schools' and entity_id = '5a000000-0000-0000-0000-000000000001' and action = 'change_slug'$q$);
select pg_temp.rec('audit.diff', $q$select string_agg(o.key, ',' order by o.key) from public.audit_log a, jsonb_each(a.old_values) o
   where a.entity_type = 'schools' and a.entity_id = '5a000000-0000-0000-0000-000000000001' and a.action = 'change_slug' and o.value is distinct from a.new_values -> o.key$q$);
select pg_temp.rec('audit.count', $q$select count(*)::text from public.audit_log where entity_type = 'schools' and action = 'change_slug'$q$);
select pg_temp.rec('audit.ctx',   $q$select coalesce(string_agg(k, ',' order by k), 'none') from r where k like '%#ctx' and v <> '|'$q$);

-- =====================================================================
select plan(3 + 14 + 3 + 4 + 7 + 6 + 4 + 5);

-- 4. UPDATE المباشر
select ok((select v from r where k = 'd.direct')    like 'ERR 42501%permission denied%schools%', 'direct UPDATE of slug is refused for a school admin (column grant)');
select ok((select v from r where k = 'd.direct_ta') like 'ERR 42501%permission denied%schools%', 'direct UPDATE of slug is refused even for the tenant admin');
select is((select v from r where k = 'd.name_ok'),  'SA', 'control: the same admin still updates name and timezone directly');

-- 5، 6. الصلاحية والنطاق
select ok((select v from r where k = 'f.sec')     like 'ERR 42501%forbidden%', 'school.read without school.update → forbidden');
select ok((select v from r where k = 'f.sibling') like 'ERR P0002%not found%', 'a sibling school''s admin → not found (no disclosure)');
select ok((select v from r where k = 'f.tenant')  like 'ERR P0002%not found%', 'another tenant → not found');
select ok((select v from r where k = 'gm.standalone') like 'ERR P0002%not found%', 'a group manager cannot rename a school outside its group');
-- المدخلات والحالة
select ok((select v from r where k = 'f.noreason') like 'ERR 22023%reason required%', 'a reason is required');
select ok((select v from r where k = 'f.same')     like 'ERR 22023%must differ from the current one%', 'the same slug is not a change');
select ok((select v from r where k = 'f.null')     like 'ERR 22023%must differ from the current one%', 'a null slug is refused');
select ok((select v from r where k = 'f.archived') like 'ERR 22023%archived school cannot change%', 'an archived school keeps its slug');
-- 2. التفرد
select ok((select v from r where k = 'f.taken')          like 'ERR 23505%schools_tenant_slug_uq%', 'a slug used by another school of the tenant is refused (existing unique constraint)');
select ok((select v from r where k = 'f.taken_archived') like 'ERR 23505%schools_tenant_slug_uq%', '… including the slug still held by an archived school');
-- 3. الصيغة
select ok((select v from r where k = 'f.upper')      like 'ERR 23514%schools_slug_chk%', 'invalid slug: uppercase (existing DNS-label constraint)');
select ok((select v from r where k = 'f.short')      like 'ERR 23514%schools_slug_chk%', 'invalid slug: one character');
select ok((select v from r where k = 'f.trailing')   like 'ERR 23514%schools_slug_chk%', 'invalid slug: trailing hyphen');
select ok((select v from r where k = 'f.underscore') like 'ERR 23514%schools_slug_chk%', 'invalid slug: underscore');

-- 8. الفشل لا يترك أثراً
select is((select v from r where k = 'fail.slug'),  'sa',   'after every refusal the slug is unchanged');
select is((select v from r where k = 'fail.audit'), '0',    'no audit row for a refused change');
select is((select v from r where k = 'fail.ctx'),   'none', 'the audit context is empty after every refusal — including a constraint failure after it was set (it rolls back with the statement)');

-- 1. النجاح
select is((select v from r where k = 'ok.sa'),      'north', 'a school admin changes the slug of its own school');
select is((select v from r where k = 'after.slug'), 'north', 'the new slug is stored');
select is((select v from r where k = 'ok.gm'),      'south', 'a group manager changes the slug of a school of its group');
select is((select v from r where k = 'ok.ta'),      'solo',  'a tenant admin changes the slug of a standalone school');

-- 9، 11. السياق والـslug القديم
select is((select v from r where k = 'before.ctx'), 'SA,none,tenant-only,SX', 'before: host sa.t1 names SA; north.t1 names nothing');
select is((select v from r where k = 'after.ctx'),  'none,SA,tenant-only,SX', 'after: north.t1 names SA, the old host names nothing; the tenant host and the other tenant are untouched');
select is((select v from r where k = 'free.sb'),    'sa', 'Q6: the old slug is available at once — the sibling school takes it');
select is((select v from r where k = 'free.new'),   '1',  'Q6: a new school is created with a freed slug');
select is((select v from r where k = 'free.ctx'),   'SB,SA,SN', 'the host follows the slug: sa.t1 now names SB, north.t1 names SA, sb.t1 names the new school');
select is((select v from r where k = 'ok.x'),       'north', 'uniqueness is per tenant: another tenant uses the same slug');
select is((select count(*)::int from public.schools where slug = 'north'), 2, '… two schools named north, one per tenant');

-- 10. علاقة المدرسة والتفويض لا يتغيران
select is((select v from r where k = 'after.row_sa'), (select v from r where k = 'before.row_sa'), 'the school row is unchanged except its slug: same id, tenant, group, code, scope owner, status');
select is((select v from r where k = 'after.row_sb'), (select v from r where k = 'before.row_sb'), '… and the same for the sibling school after two changes');
select is((select v from r where k = 'after.authz'),  (select v from r where k = 'before.authz'),  'memberships, roles, scopes and identity scopes are byte-identical after five slug changes');
select is((select v from r where k = 'before.sa'), 'truefalse|10|SA', 'before: SA''s admin reaches SA only');
select is((select v from r where k = 'after.sa'),  'truefalse|10|SA', 'after: unchanged — SA''s admin gains nothing on SB although SB now holds SA''s old slug');
select is((select v from r where k = 'after.sb'),  (select v from r where k = 'before.sb'), 'SB''s admin reaches SB only, before and after (taking the slug "sa" grants nothing on SA)');

-- 7. التدقيق
select is((select v from r where k = 'audit.row'),   'tenant_user|change_slug|rebrand|sa>north|true|true|5a000000-0000-0000-0000-000000000001', 'audit: actor, action, reason, old and new slug, tenant, and the school as the entity');
select is((select v from r where k = 'audit.diff'),  'slug', 'audit: the change touched the slug only (same transaction, same actor: the stamp columns do not differ)');
select is((select v from r where k = 'audit.count'), '5', 'one audit row per successful change (five), none for the refused ones');
select is((select v from r where k = 'audit.ctx'),   'none', 'the audit context is empty after every call');

-- البنية
select is((select string_agg(column_name, ',' order by column_name) from information_schema.column_privileges
            where table_schema = 'public' and table_name = 'schools' and grantee = 'authenticated' and privilege_type = 'UPDATE'),
          'name,timezone', 'column register: slug is not client-writable');
select ok(has_function_privilege('authenticated', 'app.set_school_slug(uuid,text,text)', 'EXECUTE')
      and not has_function_privilege('anon', 'app.set_school_slug(uuid,text,text)', 'EXECUTE'), 'set_school_slug: EXECUTE for authenticated only');
select is((select v from r where k = 'after.x'), (select v from r where k = 'before.x'), 'another tenant''s admin reaches nothing of T1, before and after');
select is((select count(*)::int from public.permissions), 73, 'no new permission key: the catalog is still 73');
select is((select count(*)::int from pg_class c where c.relnamespace = 'public'::regnamespace and c.relkind = 'r' and c.relname not like 'pg\_%'
            and not exists (select 1 from pg_depend d where d.objid = c.oid and d.deptype = 'e')), 30, 'no new table: no slug history or reservation (Q6)');

select * from finish();
rollback;
