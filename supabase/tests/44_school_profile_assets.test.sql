-- M45 — ملف المدرسة والأصول (Phase 2B / 2B-4): RLS، T16، الدوال الأربع، الـbucket، الاتساق. E1–E10.
begin;

create temp table r (k text primary key, v text) on commit drop;
grant all on r to public;
create temp table actors (label text primary key, auth uuid) on commit drop;
grant select on actors to public;

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

create function pg_temp.run(p_key text, p_label text, p_sql text) returns void
language plpgsql as $$
declare v_sub uuid := (select auth from actors where label = p_label);
begin
  perform set_config('request.jwt.claims', json_build_object('sub', v_sub, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', v_sub::text, true);
  execute 'set local role authenticated';
  perform pg_temp.rec(p_key, p_sql);
  execute 'reset role';
  insert into r values (p_key || '#ctx', coalesce(current_setting('app.audit_action', true), '') || '|' || coalesce(current_setting('app.audit_reason', true), ''))
    on conflict (k) do update set v = excluded.v;
end $$;

-- ============ Fixture ============
insert into public.platform_tenants (id, tenant_code, host_label, name) values
  ('10000000-0000-0000-0000-000000000001', 'T1', 't1', 'T1'), ('20000000-0000-0000-0000-000000000002', 'T2', 't2', 'T2');
insert into public.groups (id, platform_tenant_id, group_code, name) values ('a1000000-0000-0000-0000-00000000000a', '10000000-0000-0000-0000-000000000001', 'GA', 'GA');
insert into public.schools (id, platform_tenant_id, group_id, school_code, name, slug) values
  ('5a000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', 'a1000000-0000-0000-0000-00000000000a', 'SA', 'SA', 'sa'),
  ('5b000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001', 'a1000000-0000-0000-0000-00000000000a', 'SB', 'SB', 'sb'),
  ('5f000000-0000-0000-0000-000000000004', '10000000-0000-0000-0000-000000000001', 'a1000000-0000-0000-0000-00000000000a', 'SZ', 'SZ', 'sz'),
  ('5c000000-0000-0000-0000-000000000003', '20000000-0000-0000-0000-000000000002', null, 'SX', 'SX', 'sx');
update public.schools set status = 'archived', archived_at = now() where id = '5f000000-0000-0000-0000-000000000004';

create function pg_temp.member(p_label text, p_role text, p_tenant uuid, p_scope text, p_target uuid) returns void
language plpgsql as $$
declare v_a uuid := gen_random_uuid(); v_p uuid; v_m uuid;
begin
  insert into auth.users (id, email) values (v_a, p_label || '@m45.invalid');
  insert into public.auth_identities (auth_user_id, kind) values (v_a, 'tenant');
  insert into public.profiles (platform_tenant_id, auth_user_id, display_name) values (p_tenant, v_a, p_label) returning id into v_p;
  insert into public.memberships (platform_tenant_id, profile_id) values (p_tenant, v_p) returning id into v_m;
  insert into public.membership_roles (membership_id, role_id, platform_tenant_id, role_owner_key)
    values (v_m, (select id from public.roles where code = p_role and platform_tenant_id is null), p_tenant, '00000000-0000-0000-0000-000000000000');
  insert into public.membership_scopes (membership_id, platform_tenant_id, scope_type, group_id, school_id)
    values (v_m, p_tenant, p_scope, case when p_scope = 'group' then p_target end, case when p_scope = 'school' then p_target end);
  insert into actors values (p_label, v_a);
end $$;
select pg_temp.member('sa',  'school_admin',   '10000000-0000-0000-0000-000000000001', 'school', '5a000000-0000-0000-0000-000000000001');
select pg_temp.member('sb',  'school_admin',   '10000000-0000-0000-0000-000000000001', 'school', '5b000000-0000-0000-0000-000000000002');
select pg_temp.member('gm',  'group_manager',  '10000000-0000-0000-0000-000000000001', 'group',  'a1000000-0000-0000-0000-00000000000a');   -- school.update بلا security.manage
select pg_temp.member('sec', 'secretary',      '10000000-0000-0000-0000-000000000001', 'school', '5a000000-0000-0000-0000-000000000001');
select pg_temp.member('bus', 'bus_supervisor', '10000000-0000-0000-0000-000000000001', 'school', '5a000000-0000-0000-0000-000000000001');
select pg_temp.member('ta',  'tenant_admin',   '10000000-0000-0000-0000-000000000001', 'tenant', null);
select pg_temp.member('x',   'school_admin',   '20000000-0000-0000-0000-000000000002', 'school', '5c000000-0000-0000-0000-000000000003');

create function pg_temp.reg(p_id text, p_school text, p_kind text, p_title text default null, p_type text default 'image/png', p_reason text default 'r') returns text language sql as $$
  select format($f$select app.register_school_asset(%L, %L, %L, %L, %L, 1000, 200, 100, %L, %L)$f$,
                p_id, p_school, p_kind, p_title, p_type, repeat('a', 64), p_reason)
$$;
create function pg_temp.st(p_id text) returns text language sql as $$
  select status from public.school_assets where id = p_id::uuid
$$;
-- مدير المدرسة A يعرض الملف أولاً
-- ============ الملف ============
select pg_temp.run('p.insert',  'sa',  $q$insert into public.school_profiles (school_id, address, phone_e164, email, website, principal_display_name)
  values ('5a000000-0000-0000-0000-000000000001', 'Cairo', '+201000000001', 'info@sa.example', 'https://sa.example', 'Mr. A') returning 'ok'$q$);
select pg_temp.run('p.read_sec','sec', $q$select phone_e164 from public.school_profiles$q$);
select pg_temp.run('p.read_bus','bus', $q$select count(*)::text from public.school_profiles$q$);
select pg_temp.run('p.read_sb', 'sb',  $q$select count(*)::text from public.school_profiles$q$);
select pg_temp.run('p.sec_write','sec', $q$update public.school_profiles set address = 'x' returning 'ok'$q$);
select pg_temp.run('p.sec_ins', 'sec', $q$insert into public.school_profiles (school_id) values ('5a000000-0000-0000-0000-000000000001') returning 'ok'$q$);
select pg_temp.run('p.sb_ins',  'sb',  $q$insert into public.school_profiles (school_id) values ('5a000000-0000-0000-0000-000000000001') returning 'ok'$q$);
select pg_temp.run('p.phone',   'sa',  $q$update public.school_profiles set phone_e164 = '0100000000' returning 'ok'$q$);
select pg_temp.run('p.web',     'sa',  $q$update public.school_profiles set website = 'http://sa.example' returning 'ok'$q$);
select pg_temp.run('p.edit',    'sa',  $q$update public.school_profiles set address = 'Giza' returning address$q$);
select pg_temp.run('p.archived','ta',  $q$insert into public.school_profiles (school_id, address) values ('5f000000-0000-0000-0000-000000000004', 'x') returning 'ok'$q$);
select pg_temp.rec('p.blind.before', $q$select md5(to_jsonb(p)::text) from public.school_profiles p where school_id = '5a000000-0000-0000-0000-000000000001'$q$);
select pg_temp.run('p.blind', 'sb', $q$with u as (update public.school_profiles set address = 'hijack') select 'done'$q$);
select pg_temp.rec('p.blind.after',  $q$select md5(to_jsonb(p)::text) from public.school_profiles p where school_id = '5a000000-0000-0000-0000-000000000001'$q$);
select pg_temp.rec('p.su_move', $q$update public.school_profiles set school_id = '5b000000-0000-0000-0000-000000000002' returning 'ok'$q$);

-- ============ الأصول: التسجيل ============
select pg_temp.run('a.logo',     'sa',  pg_temp.reg('e1000000-0000-0000-0000-000000000001', '5a000000-0000-0000-0000-000000000001', 'logo'));
select pg_temp.run('a.gm_logo',  'gm',  pg_temp.reg('e1000000-0000-0000-0000-000000000002', '5a000000-0000-0000-0000-000000000001', 'logo', null, 'image/jpeg'));
select pg_temp.rec('a.logos',    $q$select string_agg(id::text || ':' || status, ',' order by id) from public.school_assets where kind = 'logo'$q$);
select pg_temp.run('a.gm_stamp', 'gm',  pg_temp.reg('e1000000-0000-0000-0000-000000000003', '5a000000-0000-0000-0000-000000000001', 'stamp'));
select pg_temp.run('a.stamp1',   'sa',  pg_temp.reg('e1000000-0000-0000-0000-000000000004', '5a000000-0000-0000-0000-000000000001', 'stamp'));
select pg_temp.run('a.stamp2',   'sa',  pg_temp.reg('e1000000-0000-0000-0000-000000000005', '5a000000-0000-0000-0000-000000000001', 'stamp', null, 'image/png', 'new stamp'));
select pg_temp.rec('a.stamps',   $q$select pg_temp.st('e1000000-0000-0000-0000-000000000004') || '|' || pg_temp.st('e1000000-0000-0000-0000-000000000005')$q$);
select pg_temp.run('a.sec',      'sec', pg_temp.reg('e1000000-0000-0000-0000-000000000006', '5a000000-0000-0000-0000-000000000001', 'logo'));
select pg_temp.run('a.sb',       'sb',  pg_temp.reg('e1000000-0000-0000-0000-000000000007', '5a000000-0000-0000-0000-000000000001', 'logo'));
select pg_temp.run('a.x',        'x',   pg_temp.reg('e1000000-0000-0000-0000-000000000008', '5a000000-0000-0000-0000-000000000001', 'logo'));
select pg_temp.run('a.sig_notitle','sa', pg_temp.reg('e1000000-0000-0000-0000-000000000009', '5a000000-0000-0000-0000-000000000001', 'signature'));
select pg_temp.run('a.logo_title','sa', pg_temp.reg('e1000000-0000-0000-0000-00000000000a', '5a000000-0000-0000-0000-000000000001', 'logo', 'x'));
select pg_temp.run('a.sig1',     'sa',  pg_temp.reg('e1000000-0000-0000-0000-00000000000b', '5a000000-0000-0000-0000-000000000001', 'signature', 'Principal'));
select pg_temp.run('a.sig_deputy','sa', pg_temp.reg('e1000000-0000-0000-0000-00000000000c', '5a000000-0000-0000-0000-000000000001', 'signature', 'Deputy'));
select pg_temp.run('a.sig2',     'sa',  pg_temp.reg('e1000000-0000-0000-0000-00000000000d', '5a000000-0000-0000-0000-000000000001', 'signature', '  principal '));
select pg_temp.rec('a.sigs',     $q$select string_agg(signer_title || ':' || status, ',' order by id) from public.school_assets where kind = 'signature'$q$);
select pg_temp.run('a.svg',      'sa',  pg_temp.reg('e1000000-0000-0000-0000-00000000000e', '5a000000-0000-0000-0000-000000000001', 'logo', null, 'image/svg+xml'));
select pg_temp.run('a.archived', 'ta',  pg_temp.reg('e1000000-0000-0000-0000-00000000000f', '5f000000-0000-0000-0000-000000000004', 'logo'));
select pg_temp.run('a.noreason', 'sa',  pg_temp.reg('e1000000-0000-0000-0000-000000000010', '5a000000-0000-0000-0000-000000000001', 'logo', null, 'image/png', ''));
select pg_temp.run('a.kind',     'sa',  pg_temp.reg('e1000000-0000-0000-0000-000000000011', '5a000000-0000-0000-0000-000000000001', 'photo'));
select pg_temp.run('a.direct_ins','sa', $q$insert into public.school_assets (id, school_id, kind, object_path, content_type, byte_size, width, height, sha256)
  values ('e1000000-0000-0000-0000-000000000012', '5a000000-0000-0000-0000-000000000001', 'logo', '10000000-0000-0000-0000-000000000001/5a000000-0000-0000-0000-000000000001/logo/e1000000-0000-0000-0000-000000000012.png', 'image/png', 1, 1, 1, repeat('a', 64)) returning 'ok'$q$);
select pg_temp.run('a.direct_upd','sa', $q$update public.school_assets set status = 'retired' returning 'ok'$q$);

-- كل مسار: المسار المميّز يمر بالقيود والحارس
create function pg_temp.raw(p_id text, p_school text, p_path text, p_type text default 'image/png') returns text language sql as $$
  select format($f$insert into public.school_assets (id, school_id, kind, object_path, content_type, byte_size, width, height, sha256)
                   values (%L, %L, 'logo', %L, %L, 1, 1, 1, repeat('a', 64)) returning 'ok'$f$, p_id, p_school, p_path, p_type)
$$;
select pg_temp.rec('su.tenant', pg_temp.raw('e2000000-0000-0000-0000-000000000001', '5a000000-0000-0000-0000-000000000001',
  '20000000-0000-0000-0000-000000000002/5a000000-0000-0000-0000-000000000001/logo/e2000000-0000-0000-0000-000000000001.png'));
select pg_temp.rec('su.school', pg_temp.raw('e2000000-0000-0000-0000-000000000002', '5a000000-0000-0000-0000-000000000001',
  '10000000-0000-0000-0000-000000000001/5b000000-0000-0000-0000-000000000002/logo/e2000000-0000-0000-0000-000000000002.png'));
select pg_temp.rec('su.id',     pg_temp.raw('e2000000-0000-0000-0000-000000000003', '5a000000-0000-0000-0000-000000000001',
  '10000000-0000-0000-0000-000000000001/5a000000-0000-0000-0000-000000000001/logo/e1000000-0000-0000-0000-000000000001.png'));
select pg_temp.rec('su.ext',    pg_temp.raw('e2000000-0000-0000-0000-000000000004', '5a000000-0000-0000-0000-000000000001',
  '10000000-0000-0000-0000-000000000001/5a000000-0000-0000-0000-000000000001/logo/e2000000-0000-0000-0000-000000000004.jpg'));
select pg_temp.rec('su.archived', pg_temp.raw('e2000000-0000-0000-0000-000000000005', '5f000000-0000-0000-0000-000000000004',
  '10000000-0000-0000-0000-000000000001/5f000000-0000-0000-0000-000000000004/logo/e2000000-0000-0000-0000-000000000005.png'));
select pg_temp.rec('su.sig_case', $q$insert into public.school_assets (id, school_id, kind, signer_title, object_path, content_type, byte_size, width, height, sha256)
  values ('e2000000-0000-0000-0000-000000000006', '5a000000-0000-0000-0000-000000000001', 'signature', 'DEPUTY',
          '10000000-0000-0000-0000-000000000001/5a000000-0000-0000-0000-000000000001/signature/e2000000-0000-0000-0000-000000000006.png', 'image/png', 1, 1, 1, repeat('a', 64)) returning 'ok'$q$);
select pg_temp.rec('su.change', $q$update public.school_assets set sha256 = repeat('b', 64) where id = 'e1000000-0000-0000-0000-000000000005' returning 'ok'$q$);
select pg_temp.rec('su.reactivate', $q$update public.school_assets set status = 'active', retired_at = null where id = 'e1000000-0000-0000-0000-000000000004' returning 'ok'$q$);

-- ============ التقاعد ============
select pg_temp.run('t.sec',     'sec', $q$select app.retire_school_asset('e1000000-0000-0000-0000-000000000002', 'r')::text$q$);
select pg_temp.run('t.gm_stamp','gm',  $q$select app.retire_school_asset('e1000000-0000-0000-0000-000000000005', 'r')::text$q$);
select pg_temp.run('t.sb',      'sb',  $q$select app.retire_school_asset('e1000000-0000-0000-0000-000000000002', 'r')::text$q$);
select pg_temp.run('t.noreason','sa',  $q$select app.retire_school_asset('e1000000-0000-0000-0000-000000000002', '')::text$q$);
select pg_temp.run('t.logo',    'sa',  $q$select app.retire_school_asset('e1000000-0000-0000-0000-000000000002', 'old logo')::text$q$);
select pg_temp.run('t.again',   'sa',  $q$select app.retire_school_asset('e1000000-0000-0000-0000-000000000002', 'r')::text$q$);

-- ============ الرابط الموقّع (E7، E8) ============
select pg_temp.run('u.sec_logo',  'sec', $q$select app.authorize_asset_url('e1000000-0000-0000-0000-000000000001')$q$);
select pg_temp.run('u.bus_logo',  'bus', $q$select app.authorize_asset_url('e1000000-0000-0000-0000-000000000001')$q$);
select pg_temp.run('u.sec_stamp', 'sec', $q$select app.authorize_asset_url('e1000000-0000-0000-0000-000000000005')$q$);
select pg_temp.run('u.gm_stamp',  'gm',  $q$select app.authorize_asset_url('e1000000-0000-0000-0000-000000000005')$q$);
select pg_temp.run('u.sa_stamp',  'sa',  $q$select app.authorize_asset_url('e1000000-0000-0000-0000-000000000005')$q$);
select pg_temp.run('u.sa_old',    'sa',  $q$select app.authorize_asset_url('e1000000-0000-0000-0000-000000000004')$q$);
select pg_temp.run('u.sb',        'sb',  $q$select app.authorize_asset_url('e1000000-0000-0000-0000-000000000001')$q$);
select pg_temp.run('u.read_sb',   'sb',  $q$select count(*)::text from public.school_assets$q$);

-- ============ الاتساق (E9) ============
select pg_temp.rec('c.before', $q$select count(*) || '|' || count(*) filter (where issue = 'row_without_object') from app.school_asset_consistency()$q$);
insert into storage.objects (bucket_id, name)
select 'school-assets', object_path from public.school_assets where school_id = '5a000000-0000-0000-0000-000000000001';
insert into storage.buckets (id, name) values ('other-bucket-not-checked', 'other-bucket-not-checked');
insert into storage.objects (bucket_id, name) values ('school-assets', 'orphan/without/a/row.png'), ('other-bucket-not-checked', 'x.png');
select pg_temp.rec('c.after',  $q$select string_agg(issue || ':' || object_path, ',') from app.school_asset_consistency()$q$);

-- ============ التدقيق ============
select pg_temp.rec('au.logo',    $q$select action || '|' || reason from public.audit_log where entity_type = 'school_assets' and entity_id = 'e1000000-0000-0000-0000-000000000001' and action = 'insert'$q$);
select pg_temp.rec('au.prev',    $q$select action || '|' || reason || '|' || (new_values ->> 'status') from public.audit_log where entity_type = 'school_assets' and entity_id = 'e1000000-0000-0000-0000-000000000004' and action <> 'insert'$q$);
select pg_temp.rec('au.retire',  $q$select action || '|' || reason from public.audit_log where entity_type = 'school_assets' and entity_id = 'e1000000-0000-0000-0000-000000000002' and action <> 'insert'$q$);
select pg_temp.rec('au.url',     $q$select count(*) || '|' || string_agg(distinct new_values ->> 'kind', ',') || '|' ||
    bool_and(not (new_values ? 'url') and not (new_values::text ~* '(token|signedurl|https?://)')) from public.audit_log where action = 'asset_url'$q$);
select pg_temp.rec('au.url_logo', $q$select count(*)::text from public.audit_log where action = 'asset_url' and entity_id = 'e1000000-0000-0000-0000-000000000001'$q$);
select pg_temp.rec('au.profile', $q$select string_agg(action, ',' order by id) from public.audit_log where entity_type = 'school_profiles'$q$);
select pg_temp.rec('au.ctx',     $q$select coalesce(string_agg(k, ',' order by k), 'none') from r where k like '%#ctx' and v <> '|'$q$);

-- =====================================================================
select plan(74);

-- الملف
select is((select v from r where k = 'p.insert'), 'ok', 'E1: the school admin creates its school''s profile');
select is((select v from r where k = 'p.read_sec'), '+201000000001', 'secretary reads it (school.read)');
select is((select v from r where k = 'p.read_bus'), '1', 'any school.read holder in scope reads it');
select is((select v from r where k = 'p.read_sb'), '0', 'a sibling school''s admin does not (§1.1 rule 5)');
select is((select v from r where k = 'p.sec_write'), '<null>', 'secretary cannot update it (school.update)');
select ok((select v from r where k = 'p.sec_ins') like 'ERR 42501%row-level security%school_profiles%', 'secretary cannot create one');
select ok((select v from r where k = 'p.sb_ins') like 'ERR 42501%row-level security%school_profiles%', 'a sibling school''s admin cannot create SA''s');
select ok((select v from r where k = 'p.phone') like 'ERR 23514%school_profiles_phone_chk%', 'phone in E.164 (constant 12)');
select ok((select v from r where k = 'p.web') like 'ERR 23514%school_profiles_website_chk%', 'website over https only');
select is((select v from r where k = 'p.edit'), 'Giza', 'the profile is edited in place (no version history — E1)');
select ok((select v from r where k = 'p.archived') like 'ERR 23514%school is archived%', 'an archived school''s profile is read-only (T16)');
select ok((select v from r where k = 'p.blind') = 'done' and (select v from r where k = 'p.blind.after') = (select v from r where k = 'p.blind.before'),
          'a blind UPDATE (no WHERE, no RETURNING) by a sibling school''s admin leaves SA''s profile untouched — the UPDATE policy carries the scope');
select ok((select v from r where k = 'p.su_move') like 'ERR 23514%cannot move to another school%', 'every path: a profile keeps its school');

-- التسجيل
select is((select v from r where k = 'a.logo'), '10000000-0000-0000-0000-000000000001/5a000000-0000-0000-0000-000000000001/logo/e1000000-0000-0000-0000-000000000001.png',
          'E4: the database derives {tenant}/{school}/{kind}/{id}.{ext} — the client sends no path');
select is((select v from r where k = 'a.gm_logo'), '10000000-0000-0000-0000-000000000001/5a000000-0000-0000-0000-000000000001/logo/e1000000-0000-0000-0000-000000000002.jpg',
          'B5: school.update is enough for the logo (JPEG → .jpg)');
select is((select v from r where k = 'a.logos'), 'e1000000-0000-0000-0000-000000000001:retired,e1000000-0000-0000-0000-000000000002:active',
          'B3: a new logo retires the previous one in the same operation');
select ok((select v from r where k = 'a.gm_stamp') like 'ERR 42501%forbidden%', 'B5: school.update does not grant the stamp (security.manage)');
select ok((select v from r where k = 'a.stamp1') like '%/stamp/e1000000-0000-0000-0000-000000000004.png', 'security.manage registers the stamp');
select is((select v from r where k = 'a.stamps'), 'retired|active', 'one active stamp: the second retires the first atomically');
select ok((select v from r where k = 'a.sec') like 'ERR 42501%forbidden%', 'secretary cannot register any asset');
select ok((select v from r where k = 'a.sb') like 'ERR P0002%not found%', 'a sibling school''s admin: SA is not found');
select ok((select v from r where k = 'a.x') like 'ERR P0002%not found%', 'another tenant: not found');
select ok((select v from r where k = 'a.sig_notitle') like 'ERR 22023%signer title%', 'E2: a signature needs a signer title');
select ok((select v from r where k = 'a.logo_title') like 'ERR 22023%signer title%', 'E2: … and other assets none');
select is((select v from r where k = 'a.sigs'), 'Principal:retired,Deputy:active,principal:active',
          'E2: one active signature per title (case and spaces normalized); other titles coexist');
select ok((select v from r where k = 'a.svg') like 'ERR 22023%only PNG or JPEG%', 'E6: PNG or JPEG only (no SVG)');
select ok((select v from r where k = 'a.archived') like 'ERR 22023%archived%', 'no assets for an archived school');
select ok((select v from r where k = 'a.noreason') like 'ERR 22023%reason required%', 'a reason is required');
select ok((select v from r where k = 'a.kind') like 'ERR 22023%unknown asset kind%', 'logo, stamp, signature only');
select ok((select v from r where k = 'a.direct_ins') like 'ERR 42501%permission denied%school_assets%', 'no client INSERT on assets — the function only');
select ok((select v from r where k = 'a.direct_upd') like 'ERR 42501%permission denied%school_assets%', 'no client UPDATE on assets — the function only');

-- كل مسار
select ok((select v from r where k = 'su.tenant') like 'ERR 23514%does not belong to its school''s tenant%', 'E4 every path: a path in another tenant is refused');
select ok((select v from r where k = 'su.school') like 'ERR 23514%school_assets_path_chk%', 'E4 every path: a path in another school is refused');
select ok((select v from r where k = 'su.id') like 'ERR 23514%school_assets_path_chk%', 'E4 every path: a path with another asset''s id is refused');
select ok((select v from r where k = 'su.ext') like 'ERR 23514%school_assets_ext_chk%', 'E4 every path: the extension follows the content type');
select ok((select v from r where k = 'su.archived') like 'ERR 23514%school is archived — no new assets%', 'every path: no asset for an archived school (guard)');
select ok((select v from r where k = 'su.sig_case') like 'ERR 23505%school_assets_one_signature_uq%', 'E2 every path: one active signature per title, case-insensitive (index)');
select ok((select v from r where k = 'su.change') like 'ERR 23514%cannot change%', 'B3 every path: an asset never changes — a new version instead');
select ok((select v from r where k = 'su.reactivate') like 'ERR 23514%retired asset is final%', 'E3 every path: retirement is final');

-- التقاعد
select ok((select v from r where k = 't.sec') like 'ERR 42501%forbidden%', 'retire: secretary cannot');
select ok((select v from r where k = 't.gm_stamp') like 'ERR 42501%forbidden%', 'retire: the stamp needs security.manage');
select ok((select v from r where k = 't.sb') like 'ERR P0002%not found%', 'retire: another school''s asset is not found');
select ok((select v from r where k = 't.noreason') like 'ERR 22023%reason required%', 'retire: a reason is required');
select is((select v from r where k = 't.logo'), '', 'retire: the active logo is retired');
select ok((select v from r where k = 't.again') like 'ERR 22023%already retired%', 'retire: once');
select ok(exists (select 1 from public.school_assets where id = 'e1000000-0000-0000-0000-000000000002' and status = 'retired' and retired_at is not null),
          'E3: the row stays, retired with its time');

-- الرابط
select ok((select v from r where k = 'u.sec_logo') like '%/logo/e1000000-0000-0000-0000-000000000001.png', 'E7: the logo link for school.read (secretary)');
select ok((select v from r where k = 'u.bus_logo') like '%/logo/%', 'E7: … any school.read holder in scope');
select ok((select v from r where k = 'u.sec_stamp') like 'ERR 42501%forbidden%', 'E7: no stamp link without security.manage');
select ok((select v from r where k = 'u.gm_stamp') like 'ERR 42501%forbidden%', 'E7: school.update is not enough for a stamp link');
select ok((select v from r where k = 'u.sa_stamp') like '%/stamp/e1000000-0000-0000-0000-000000000005.png', 'E7: security.manage gets the stamp link');
select ok((select v from r where k = 'u.sa_old') like '%/stamp/e1000000-0000-0000-0000-000000000004.png', 'a retired version stays viewable (old certificates)');
select ok((select v from r where k = 'u.sb') like 'ERR P0002%not found%', 'E7: another school''s asset is not found');
select is((select v from r where k = 'u.read_sb'), '0', 'a sibling school''s admin sees no SA asset row');

-- الاتساق
select is((select v from r where k = 'c.before'), '7|7', 'E9: every registered row without its object is reported');
select is((select v from r where k = 'c.after'), 'object_without_row:orphan/without/a/row.png', 'E9: … once the objects exist only the orphan object is reported (other buckets ignored)');
select ok(not has_function_privilege('authenticated', 'app.school_asset_consistency()', 'EXECUTE') and not has_function_privilege('anon', 'app.school_asset_consistency()', 'EXECUTE'),
          'E9: the consistency check is internal');

-- التدقيق
select is((select v from r where k = 'au.logo'), 'insert|r', 'E8: the upload is audited with the reason');
select is((select v from r where k = 'au.prev'), 'register_school_asset|new stamp|retired', 'E8: the replaced version''s retirement is audited by the operation that replaced it');
select is((select v from r where k = 'au.retire'), 'retire_school_asset|old logo', 'E8: retirement is audited with the reason');
select is((select v from r where k = 'au.url'), '2|stamp|true', 'E8: each stamp/signature link issuance is audited — never the link or a token');
select is((select v from r where k = 'au.url_logo'), '0', 'E8: logo links are not audited');
select is((select v from r where k = 'au.profile'), 'insert,update', 'E8: profile edits are audited (T7)');
select is((select v from r where k = 'au.ctx'), 'none', 'the audit context is empty after every call');

-- البنية
select ok(exists (select 1 from storage.buckets where id = 'school-assets' and not public and file_size_limit = 1048576
                   and allowed_mime_types @> array['image/png', 'image/jpeg'] and cardinality(allowed_mime_types) = 2),
          'B4/B6: the bucket is private, PNG/JPEG, 1MiB');
select is((select count(*)::int from pg_policies where schemaname = 'storage' and tablename = 'objects'
             and (roles && array['anon', 'authenticated', 'public']::name[])), 0,
          'no storage.objects policy for any client role: no direct Storage access with a user session');
select ok(not has_table_privilege('authenticated', 'public.school_assets', 'INSERT') and not has_table_privilege('authenticated', 'public.school_assets', 'UPDATE')
      and not has_table_privilege('authenticated', 'public.school_assets', 'DELETE') and not has_table_privilege('authenticated', 'public.school_profiles', 'DELETE'),
          'no client write on assets and no DELETE anywhere (E3)');
select is((select pg_get_function_identity_arguments('app.register_school_asset(uuid,uuid,text,text,text,integer,integer,integer,text,text)'::regprocedure)),
          'p_asset_id uuid, p_school_id uuid, p_kind text, p_signer_title text, p_content_type text, p_byte_size integer, p_width integer, p_height integer, p_sha256 text, p_reason text',
          'E4: no path parameter — the client cannot name a path');
select ok(has_function_privilege('authenticated', 'app.register_school_asset(uuid,uuid,text,text,text,integer,integer,integer,text,text)', 'EXECUTE')
      and not has_function_privilege('anon', 'app.register_school_asset(uuid,uuid,text,text,text,integer,integer,integer,text,text)', 'EXECUTE'), 'register: authenticated only');
select ok(has_function_privilege('authenticated', 'app.retire_school_asset(uuid,text)', 'EXECUTE')
      and not has_function_privilege('anon', 'app.retire_school_asset(uuid,text)', 'EXECUTE'), 'retire: authenticated only');
select ok(has_function_privilege('authenticated', 'app.authorize_asset_url(uuid)', 'EXECUTE')
      and not has_function_privilege('anon', 'app.authorize_asset_url(uuid)', 'EXECUTE'), 'authorize link: authenticated only');
select ok(exists (select 1 from pg_indexes where indexname = 'school_assets_one_active_uq') and exists (select 1 from pg_indexes where indexname = 'school_assets_one_signature_uq'),
          'B3: one active logo/stamp and one active signature per title — unique indexes');
select is((select count(*)::int from public.school_assets where status = 'active' and school_id = '5a000000-0000-0000-0000-000000000001'), 3,
          'SA ends with: one stamp, two signatures (the logo retired)');
select ok((select v from r where k = 'u.sa_stamp#ctx') = '|', 'authorizing a link leaves no audit context behind');

select * from finish();
rollback;
