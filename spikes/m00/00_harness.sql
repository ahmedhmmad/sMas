-- M00 harness — يُلحَق قبل كل ملف V. كل تشغيل داخل BEGIN ... ROLLBACK: لا أثر يبقى.
-- النمط: العمليات بهوية منتحَلة تُسجَّل نتائجها في m00_res، ثم تُفحص بـpgTAP بهوية postgres.
\set ON_ERROR_STOP 1
\pset format unaligned
\pset tuples_only on
\pset pager off

begin;

create extension if not exists pgtap with schema extensions;
set local search_path = extensions, public;

create schema m00;
grant usage on schema m00 to anon, authenticated, service_role;

create temp table m00_res (k text primary key, v text) on commit drop;
grant all on m00_res to public;

-- ينفذ SQL بالدور الحالي ويُرجع أول قيمة نصياً، أو 'ERR <sqlstate>: <message>'
create function m00.val(p_sql text) returns text
language plpgsql as $$
declare r text;
begin
  execute p_sql into r;
  return coalesce(r, '<null>');
exception when others then
  return 'ERR ' || sqlstate || ': ' || sqlerrm;
end $$;

create function m00.rec(p_key text, p_sql text) returns void
language plpgsql as $$
begin
  insert into m00_res values (p_key, m00.val(p_sql))
  on conflict (k) do update set v = excluded.v;
end $$;

-- ثلاثة مستخدمين وهميين؛ الانتحال عبر JWT claims كما تفعل PostgREST
\set uid_a '''aaaaaaaa-0000-0000-0000-000000000001'''
\set uid_b '''bbbbbbbb-0000-0000-0000-000000000002'''
\set uid_c '''cccccccc-0000-0000-0000-000000000003'''

create function m00.claims(p_sub uuid, p_role text default 'authenticated') returns void
language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_sub, 'role', p_role)::text, true);
  perform set_config('request.jwt.claim.sub', coalesce(p_sub::text, ''), true);
  perform set_config('request.jwt.claim.role', p_role, true);
end $$;
