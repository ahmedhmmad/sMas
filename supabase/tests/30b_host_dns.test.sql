-- M30b — host_dns_labels: host_label و slug مدرسة = labels DNS صالحة (لا شرطة في البداية ولا النهاية، ≤ 63)
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

insert into public.platform_tenants (id, tenant_code, host_label, name) values ('10000000-0000-0000-0000-000000000001', 'T1', 't1', 'T1');
insert into public.schools (id, platform_tenant_id, school_code, name, slug) values
  ('5a000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', 'SA', 'SA', 'school-a');

-- tenant_admin لـT1 (يملك UPDATE (slug) على schools — سجل §4.6)
insert into auth.users (id, email) values ('c1000000-0000-0000-0000-000000000001', 'ta@m30b.invalid');
insert into public.auth_identities (auth_user_id, kind) values ('c1000000-0000-0000-0000-000000000001', 'tenant');
with p as (insert into public.profiles (platform_tenant_id, auth_user_id, display_name)
           values ('10000000-0000-0000-0000-000000000001', 'c1000000-0000-0000-0000-000000000001', 'ta') returning id),
     m as (insert into public.memberships (platform_tenant_id, profile_id) select '10000000-0000-0000-0000-000000000001', id from p returning id),
     s as (insert into public.membership_scopes (membership_id, platform_tenant_id, scope_type) select id, '10000000-0000-0000-0000-000000000001', 'tenant' from m)
insert into public.membership_roles (membership_id, role_id, platform_tenant_id, role_owner_key)
  select m.id, r.id, '10000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000000'
  from m, public.roles r where r.code = 'tenant_admin' and r.platform_tenant_id is null;

create function pg_temp.label(p_key text, p_label text) returns void language sql as $$
  select pg_temp.rec(p_key, format($f$insert into public.platform_tenants (tenant_code, host_label, name)
    values ('X' || upper(substr(md5(%L), 1, 8)), %L, 'x') returning 'ok'$f$, p_key, p_label)) $$;
create function pg_temp.slug(p_key text, p_slug text) returns void language sql as $$
  select pg_temp.rec(p_key, format($f$insert into public.schools (platform_tenant_id, school_code, name, slug)
    values ('10000000-0000-0000-0000-000000000001', 'S' || upper(substr(md5(%L), 1, 8)), 'x', %L) returning 'ok'$f$, p_key, p_slug)) $$;

-- host_label
select pg_temp.label('l.trailing',  'tenant-');
select pg_temp.label('l.leading',   '-tenant');
select pg_temp.label('l.dash',      '-');
select pg_temp.label('l.too_long',  repeat('a', 64));
select pg_temp.label('l.one',       'a');
select pg_temp.label('l.word',      'tenant');
select pg_temp.label('l.hyphen',    'tenant-a');
select pg_temp.label('l.alnum',     'abc123');
select pg_temp.label('l.max',       repeat('a', 62) || '1');
-- slug
select pg_temp.slug('s.trailing',   'school-');
select pg_temp.slug('s.leading',    '-school');
select pg_temp.slug('s.dash',       '--');
select pg_temp.slug('s.one',        'a');                     -- الحد الأدنى القائم (2) يبقى
select pg_temp.slug('s.too_long',   repeat('a', 64));
select pg_temp.slug('s.two',        'ab');
select pg_temp.slug('s.hyphen',     'school-b');
select pg_temp.slug('s.max',        repeat('b', 62) || '1');
-- مسار العميل: tenant_admin يملك UPDATE (slug) — القيد يحكمه أيضاً
select set_config('request.jwt.claims', '{"sub":"c1000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select set_config('request.jwt.claim.sub', 'c1000000-0000-0000-0000-000000000001', true);
set local role authenticated;
select pg_temp.rec('u.trailing', $q$update public.schools set slug = 'school-' where id = '5a000000-0000-0000-0000-000000000001' returning 'ok'$q$);
select pg_temp.rec('u.ok',       $q$update public.schools set slug = 'school-z' where id = '5a000000-0000-0000-0000-000000000001' returning 'ok'$q$);
reset role;

select plan(22);

select ok((select v from r where k = 'l.trailing') like 'ERR 23514%platform_tenants_host_label_chk%', 'host_label: trailing hyphen refused (tenant-)');
select ok((select v from r where k = 'l.leading')  like 'ERR 23514%platform_tenants_host_label_chk%', 'host_label: leading hyphen refused');
select ok((select v from r where k = 'l.dash')     like 'ERR 23514%platform_tenants_host_label_chk%', 'host_label: a lone hyphen refused');
select ok((select v from r where k = 'l.too_long') like 'ERR 23514%platform_tenants_host_label_chk%', 'host_label: 64 characters refused');
select is((select v from r where k = 'l.one'),    'ok', 'host_label: a');
select is((select v from r where k = 'l.word'),   'ok', 'host_label: tenant');
select is((select v from r where k = 'l.hyphen'), 'ok', 'host_label: tenant-a');
select is((select v from r where k = 'l.alnum'),  'ok', 'host_label: abc123');
select is((select v from r where k = 'l.max'),    'ok', 'host_label: 63 characters');
select ok((select v from r where k = 's.trailing') like 'ERR 23514%schools_slug_chk%', 'slug: trailing hyphen refused (school-)');
select ok((select v from r where k = 's.leading')  like 'ERR 23514%schools_slug_chk%', 'slug: leading hyphen refused');
select ok((select v from r where k = 's.dash')     like 'ERR 23514%schools_slug_chk%', 'slug: hyphens only refused');
select ok((select v from r where k = 's.one')      like 'ERR 23514%schools_slug_chk%', 'slug: one character still refused (M04 minimum kept)');
select ok((select v from r where k = 's.too_long') like 'ERR 23514%schools_slug_chk%', 'slug: 64 characters refused');
select is((select v from r where k = 's.two'),    'ok', 'slug: ab');
select is((select v from r where k = 's.hyphen'), 'ok', 'slug: school-b');
select is((select v from r where k = 's.max'),    'ok', 'slug: 63 characters');
select ok((select v from r where k = 'u.trailing') like 'ERR 23514%schools_slug_chk%', 'client path: a tenant admin cannot rename a school to a non-DNS slug');
select is((select v from r where k = 'u.ok'),     'ok', 'client path: a DNS-safe rename still works');
select is((select pg_get_constraintdef(oid) from pg_constraint where conname = 'platform_tenants_host_label_chk'),
          'CHECK ((host_label ~ ''^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$''::text))', 'host_label constraint text (RFC 1123 label)');
select is((select pg_get_constraintdef(oid) from pg_constraint where conname = 'schools_slug_chk'),
          'CHECK ((slug ~ ''^[a-z0-9][a-z0-9-]{0,61}[a-z0-9]$''::text))', 'slug constraint text (RFC 1123 label, 2–63)');
select is((select count(*)::int from pg_constraint where conname in ('platform_tenants_host_label_chk', 'schools_slug_chk')), 2,
          'each rule is a single constraint (replaced, not stacked)');

select * from finish();
rollback;
