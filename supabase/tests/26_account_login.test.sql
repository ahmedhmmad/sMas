-- M26 — tenant_account_login (F2/D3): OTP وكلمة المرور لحسابات Tenant (ولي الأمر، الموظف) قبل JWT
-- الجلسة نفسها يصدرها Supabase Auth عبر FastAPI (pytest)؛ هنا ما تقرره قاعدة البيانات: أي حساب، ومتى يُقبل الرمز.
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

-- كما يستدعيها FastAPI: دور service_role
create function pg_temp.svc(p_key text, p_sql text) returns void
language plpgsql as $$
begin
  execute 'set local role service_role';
  perform pg_temp.rec(p_key, p_sql);
  execute 'reset role';
end $$;

-- ============ Fixture: الهاتف نفسه والبريد نفسه في T1 و T2 ============
insert into public.platform_tenants (id, tenant_code, name) values
  ('10000000-0000-0000-0000-000000000001', 'T1', 'T1'), ('20000000-0000-0000-0000-000000000002', 'T2', 'T2');

create function pg_temp.account(p_id uuid, p_tenant uuid) returns void
language plpgsql as $$
begin
  insert into auth.users (id, email) values (p_id, p_id::text || '@accounts.m26.invalid');
  insert into public.auth_identities (auth_user_id, kind) values (p_id, 'tenant');
  insert into public.profiles (platform_tenant_id, auth_user_id, display_name) values (p_tenant, p_id, 'x');
end $$;
create function pg_temp.guardian(p_id uuid, p_tenant uuid, p_phone text, p_status text default 'active') returns void
language plpgsql as $$
begin
  perform pg_temp.account(p_id, p_tenant);
  insert into public.guardians (id, platform_tenant_id, first_name, family_name, phone_e164, status, archived_at, profile_id)
    values (p_id, p_tenant, 'G', 'X', p_phone, p_status, case when p_status = 'archived' then now() end,
            (select id from public.profiles where auth_user_id = p_id));
end $$;
create function pg_temp.staff(p_id uuid, p_tenant uuid, p_email text, p_code text, p_status text default 'active') returns void
language plpgsql as $$
begin
  perform pg_temp.account(p_id, p_tenant);
  insert into public.staff (id, platform_tenant_id, employee_code, first_name, family_name, email, status, archived_at, profile_id)
    values (p_id, p_tenant, p_code, 'S', 'X', p_email, p_status, case when p_status = 'archived' then now() end,
            (select id from public.profiles where auth_user_id = p_id));
end $$;

select pg_temp.guardian('91000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', '+201000000001');   -- gA
select pg_temp.guardian('92000000-0000-0000-0000-000000000002', '20000000-0000-0000-0000-000000000002', '+201000000001');   -- gB: الهاتف نفسه
select pg_temp.guardian('93000000-0000-0000-0000-000000000003', '20000000-0000-0000-0000-000000000002', '+201000000003');   -- في T2 فقط
select pg_temp.guardian('94000000-0000-0000-0000-000000000004', '10000000-0000-0000-0000-000000000001', '+201000000004');   -- profile موقوف
update public.profiles set status = 'suspended' where auth_user_id = '94000000-0000-0000-0000-000000000004';
select pg_temp.guardian('95000000-0000-0000-0000-000000000005', '10000000-0000-0000-0000-000000000001', '+201000000005', 'archived');
select pg_temp.staff('a1000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', 'Teacher@School.test', 'E1');     -- sA
select pg_temp.staff('a2000000-0000-0000-0000-000000000002', '20000000-0000-0000-0000-000000000002', 'teacher@school.test', 'E1');     -- sB: البريد نفسه
select pg_temp.staff('a3000000-0000-0000-0000-000000000003', '10000000-0000-0000-0000-000000000001', 'ended@school.test', 'E3', 'ended');

-- ============ 1. البنية ============
select pg_temp.rec('s.dup_email', $q$insert into public.staff (platform_tenant_id, employee_code, first_name, family_name, email)
  values ('10000000-0000-0000-0000-000000000001', 'E9', 'S', 'X', '  TEACHER@school.TEST ') returning 'ok'$q$);
select pg_temp.rec('s.neg_failed', $q$update public.staff set failed_login_count = -1 where id = 'a1000000-0000-0000-0000-000000000001' returning 'ok'$q$);
select pg_temp.rec('c.bad_kind', $q$insert into public.login_challenges (platform_tenant_id, account_id, kind, code_hash, expires_at)
  values ('10000000-0000-0000-0000-000000000001', 'a1000000-0000-0000-0000-000000000001', 'student', 'x', now()) returning 'ok'$q$);
select pg_temp.rec('c.bad_attempts', $q$insert into public.login_challenges (platform_tenant_id, account_id, kind, code_hash, expires_at, attempts)
  values ('10000000-0000-0000-0000-000000000001', 'a1000000-0000-0000-0000-000000000001', 'staff', 'x', now(), 6) returning 'ok'$q$);

-- ============ 2. الإصدار ============
select pg_temp.svc('i.gA',          $q$select app.otp_issue('T1', 'guardian', '+201000000001')$q$);
select pg_temp.svc('i.gB',          $q$select app.otp_issue('t2', 'guardian', ' +201000000001 ')$q$);
select pg_temp.svc('i.only_in_T2',  $q$select app.otp_issue('T1', 'guardian', '+201000000003')$q$);
select pg_temp.svc('i.unknown',     $q$select app.otp_issue('T1', 'guardian', '+201099999999')$q$);
select pg_temp.svc('i.suspended',   $q$select app.otp_issue('T1', 'guardian', '+201000000004')$q$);
select pg_temp.svc('i.archived',    $q$select app.otp_issue('T1', 'guardian', '+201000000005')$q$);
select pg_temp.svc('i.wrong_kind',  $q$select app.otp_issue('T1', 'staff', '+201000000001')$q$);
select pg_temp.svc('i.sA',          $q$select app.otp_issue('T1', 'staff', 'teacher@SCHOOL.test')$q$);
select pg_temp.svc('i.staff_ended', $q$select app.otp_issue('T1', 'staff', 'ended@school.test')$q$);
select pg_temp.rec('i.stored', $q$select count(*) || '|' || bool_and(code_hash like '$2a$08$%') || '|' || bool_and(expires_at between now() + interval '4 minutes' and now() + interval '6 minutes')
  from public.login_challenges
  where account_id in ('91000000-0000-0000-0000-000000000001', '92000000-0000-0000-0000-000000000002', 'a1000000-0000-0000-0000-000000000001')$q$);
select pg_temp.rec('i.hash_not_code', format($q$select (code_hash <> %L)::text from public.login_challenges where account_id = '91000000-0000-0000-0000-000000000001'$q$, (select v from r where k = 'i.gA')));
update public.platform_tenants set status = 'suspended', suspended_at = now() where tenant_code = 'T2';
select pg_temp.svc('i.tenant_suspended', $q$select app.otp_issue('T2', 'guardian', '+201000000001')$q$);
update public.platform_tenants set status = 'active', suspended_at = null where tenant_code = 'T2';

-- ============ 3. التحقق ============
create function pg_temp.code(k text) returns text language sql as $$ select v from r where k = $1 $$;
select pg_temp.svc('v.A_code_on_B', format($q$select app.otp_verify('T2', 'guardian', '+201000000001', %L)$q$, pg_temp.code('i.gA')));
select pg_temp.svc('v.wrong',       $q$select app.otp_verify('T1', 'guardian', '+201000000001', 'nope')$q$);
select pg_temp.rec('v.attempts',    $q$select attempts::text from public.login_challenges where account_id = '91000000-0000-0000-0000-000000000001' and consumed_at is null$q$);
select pg_temp.svc('v.ok',          format($q$select app.otp_verify('T1', 'guardian', '+201000000001', %L)$q$, pg_temp.code('i.gA')));
select pg_temp.svc('v.reuse',       format($q$select app.otp_verify('T1', 'guardian', '+201000000001', %L)$q$, pg_temp.code('i.gA')));
select pg_temp.svc('v.B_ok',        format($q$select app.otp_verify('T2', 'guardian', '+201000000001', %L)$q$, pg_temp.code('i.gB')));
select pg_temp.svc('v.staff_ok',    format($q$select app.otp_verify('T1', 'staff', 'TEACHER@school.test', %L)$q$, pg_temp.code('i.sA')));
select pg_temp.rec('v.last_login',  $q$select (last_login_at is not null)::text from public.guardians where id = '91000000-0000-0000-0000-000000000001'$q$);
-- رمز سابق يُبطَل بإصدار جديد
select pg_temp.svc('i.old',  $q$select app.otp_issue('T1', 'guardian', '+201000000001')$q$);
select pg_temp.svc('i.new',  $q$select app.otp_issue('T1', 'guardian', '+201000000001')$q$);
select pg_temp.svc('v.old',  format($q$select app.otp_verify('T1', 'guardian', '+201000000001', %L)$q$, pg_temp.code('i.old')));
-- 5 محاولات خاطئة تُسقط التحدي: الرمز الصحيح بعدها مرفوض
do $$ begin for i in 1..5 loop
  perform pg_temp.svc('v.burn' || i, $q$select app.otp_verify('T1', 'guardian', '+201000000001', 'bad')$q$);
end loop; end $$;
select pg_temp.svc('v.after_burn', format($q$select app.otp_verify('T1', 'guardian', '+201000000001', %L)$q$, pg_temp.code('i.new')));
-- منتهي الصلاحية
select pg_temp.svc('i.exp', $q$select app.otp_issue('T1', 'guardian', '+201000000001')$q$);
update public.login_challenges set expires_at = now() - interval '1 second' where account_id = '91000000-0000-0000-0000-000000000001' and consumed_at is null;
select pg_temp.svc('v.expired', format($q$select app.otp_verify('T1', 'guardian', '+201000000001', %L)$q$, pg_temp.code('i.exp')));
-- I1: رمز صدر ثم عُلّق الـprofile ⇒ لا حساب
select pg_temp.svc('i.before_suspend', $q$select app.otp_issue('T1', 'staff', 'teacher@school.test')$q$);
update public.profiles set status = 'suspended' where auth_user_id = 'a1000000-0000-0000-0000-000000000001';
select pg_temp.svc('v.after_suspend', format($q$select app.otp_verify('T1', 'staff', 'teacher@school.test', %L)$q$, pg_temp.code('i.before_suspend')));
select pg_temp.svc('p.suspended',     $q$select app.password_login_account('T1', 'staff', 'teacher@school.test')$q$);
update public.profiles set status = 'active' where auth_user_id = 'a1000000-0000-0000-0000-000000000001';

-- ============ 4. كلمة المرور: الإخفاقات والقفل وفكه بـOTP ============
select pg_temp.svc('p.account', $q$select app.password_login_account('T1', 'staff', 'teacher@school.test')$q$);
select pg_temp.svc('p.other_tenant', $q$select app.password_login_account('T2', 'staff', 'teacher@school.test')$q$);
do $$ begin for i in 1..5 loop
  perform pg_temp.svc('p.fail' || i, $q$select app.password_login_result('T1', 'staff', 'teacher@school.test', false)::text$q$);
end loop; end $$;
select pg_temp.rec('p.locked_row', $q$select failed_login_count || '|' || (locked_until > now()) from public.staff where id = 'a1000000-0000-0000-0000-000000000001'$q$);
select pg_temp.svc('p.locked', $q$select app.password_login_account('T1', 'staff', 'teacher@school.test')$q$);
select pg_temp.rec('p.audit', $q$select string_agg(distinct action, ',') from public.audit_log where entity_type = 'staff' and entity_id = 'a1000000-0000-0000-0000-000000000001' and action <> 'insert'$q$);
select pg_temp.svc('i.unlock', $q$select app.otp_issue('T1', 'staff', 'teacher@school.test')$q$);
select pg_temp.svc('v.unlock', format($q$select app.otp_verify('T1', 'staff', 'teacher@school.test', %L)$q$, pg_temp.code('i.unlock')));
select pg_temp.rec('p.unlocked_row', $q$select failed_login_count || '|' || coalesce(locked_until::text, 'null') from public.staff where id = 'a1000000-0000-0000-0000-000000000001'$q$);
select pg_temp.svc('p.after_unlock', $q$select app.password_login_account('T1', 'staff', 'teacher@school.test')$q$);

-- ============ 5. الامتيازات ============
create function pg_temp.as_role(p_key text, p_role text, p_sql text) returns void
language plpgsql as $$
begin
  execute format('set local role %I', p_role);
  perform pg_temp.rec(p_key, p_sql);
  execute 'reset role';
end $$;
select pg_temp.as_role('x.auth_issue',  'authenticated', $q$select app.otp_issue('T1', 'guardian', '+201000000001')$q$);
select pg_temp.as_role('x.auth_table',  'authenticated', $q$select count(*)::text from public.login_challenges$q$);
select pg_temp.as_role('x.svc_table',   'service_role',  $q$select count(*)::text from public.login_challenges$q$);
select pg_temp.as_role('x.svc_resolve', 'service_role',  $q$select count(*)::text from app.login_account('T1', 'guardian', '+201000000001')$q$);

select plan(46);

select ok((select v from r where k = 's.dup_email')   like 'ERR 23505%staff_tenant_email_uq%', 'staff email is unique inside a tenant, case- and space-insensitively');
select ok((select v from r where k = 's.neg_failed')  like 'ERR 23514%staff_failed_login_chk%', 'staff failed_login_count ≥ 0');
select ok((select v from r where k = 'c.bad_kind')    like 'ERR 23514%login_challenges_kind_chk%', 'challenge kind is guardian|staff');
select ok((select v from r where k = 'c.bad_attempts') like 'ERR 23514%login_challenges_attempts_chk%', 'challenge attempts are 0..5');

select ok((select v from r where k = 'i.gA') ~ '^[0-9]{6}$', 'issue: a 6-digit code for the T1 guardian');
select ok((select v from r where k = 'i.gB') ~ '^[0-9]{6}$', 'issue: the same phone in T2 is its own account (tenant code and phone normalized)');
select is((select v from r where k = 'i.only_in_T2'),  '<null>', 'a phone that exists only in T2 resolves to nothing in T1');
select is((select v from r where k = 'i.unknown'),     '<null>', 'unknown phone → nothing');
select is((select v from r where k = 'i.suspended'),   '<null>', 'I1: a suspended profile cannot start authentication');
select is((select v from r where k = 'i.archived'),    '<null>', 'I1: an archived guardian cannot start authentication');
select is((select v from r where k = 'i.wrong_kind'),  '<null>', 'a guardian phone is not a staff contact');
select ok((select v from r where k = 'i.sA') ~ '^[0-9]{6}$', 'issue: staff by email, case-insensitive');
select is((select v from r where k = 'i.staff_ended'), '<null>', 'I1: ended staff cannot start authentication');
select is((select v from r where k = 'i.stored'), '3|true|true', 'three challenges stored as bcrypt (cost 8), valid for about five minutes');
select is((select v from r where k = 'i.hash_not_code'), 'true', 'the code itself is never stored');
select is((select v from r where k = 'i.tenant_suspended'), '<null>', 'suspended tenant → nothing (M21b)');

select is((select v from r where k = 'v.A_code_on_B'), '<null>', 'the T1 code does not verify in T2');
select is((select v from r where k = 'v.wrong'),       '<null>', 'wrong code → nothing');
select is((select v from r where k = 'v.attempts'),    '1', 'a wrong code counts an attempt');
select is((select v from r where k = 'v.ok'),          '91000000-0000-0000-0000-000000000001', 'the right code → the T1 account (I2: account id = guardian id)');
select is((select v from r where k = 'v.reuse'),       '<null>', 'a code is single-use');
select is((select v from r where k = 'v.B_ok'),        '92000000-0000-0000-0000-000000000002', 'the T2 code → the T2 account');
select is((select v from r where k = 'v.staff_ok'),    'a1000000-0000-0000-0000-000000000001', 'staff code → the staff account (I2: account id = staff id)');
select is((select v from r where k = 'v.last_login'),  'true', 'a successful login stamps last_login_at');
select is((select v from r where k = 'v.old'),         '<null>', 'issuing a new code invalidates the previous one');
select is((select v from r where k = 'v.after_burn'),  '<null>', 'five wrong attempts kill the challenge — the right code no longer works');
select is((select v from r where k = 'v.expired'),     '<null>', 'an expired code does not verify');
select is((select v from r where k = 'v.after_suspend'), '<null>', 'I1: a code issued before suspension is useless after it');
select is((select v from r where k = 'p.suspended'),   '<null>', 'I1: no password login for a suspended profile');

select is((select v from r where k = 'p.account'),     'a1000000-0000-0000-0000-000000000001', 'password login resolves the staff account');
select is((select v from r where k = 'p.other_tenant'),'a2000000-0000-0000-0000-000000000002', 'the same email in T2 is the T2 account');
select is((select v from r where k = 'p.locked_row'),  '5|true', 'five failures lock the account');
select is((select v from r where k = 'p.locked'),      '<null>', 'a locked account gets no password login');
select is((select v from r where k = 'p.audit'),       'otp_login,password_login_failed', 'login outcomes are audited by their action (T7 on staff)');
select ok((select v from r where k = 'v.unlock') = 'a1000000-0000-0000-0000-000000000001', 'OTP still works while locked (PLAN §7.8: self-unlock via OTP)');
select is((select v from r where k = 'p.unlocked_row'),'0|null', 'a successful OTP clears the lock');
select is((select v from r where k = 'p.after_unlock'),'a1000000-0000-0000-0000-000000000001', 'password login is available again');

select ok((select v from r where k = 'x.auth_issue')  like 'ERR 42501%permission denied for function otp_issue%', 'authenticated cannot issue codes');
select ok((select v from r where k = 'x.auth_table')  like 'ERR 42501%permission denied for table login_challenges%', 'authenticated cannot read challenges');
select ok((select v from r where k = 'x.svc_table')   like 'ERR 42501%permission denied for table login_challenges%', 'even service_role cannot read challenges — only the functions');
select ok((select v from r where k = 'x.svc_resolve') like 'ERR 42501%permission denied for function login_account%', 'the internal resolver is not executable');
select is((select string_agg(p.proname || ':' || coalesce((select string_agg(g.rolname, '+' order by g.rolname) from aclexplode(p.proacl) a join pg_roles g on g.oid = a.grantee where a.privilege_type = 'EXECUTE'), '-'), ',' order by p.proname)
            from pg_proc p where p.pronamespace = 'app'::regnamespace
             and p.proname in ('otp_issue','otp_verify','password_login_account','password_login_result','login_account','login_outcome')),
          'login_account:app_owner,login_outcome:app_owner,otp_issue:app_owner+service_role,otp_verify:app_owner+service_role,password_login_account:app_owner+service_role,password_login_result:app_owner+service_role',
          'EXECUTE: the four pre-JWT functions for service_role only; the two internals for no one');
select ok(not exists (select 1 from pg_trigger t where t.tgrelid = 'public.login_challenges'::regclass and not t.tgisinternal),
          'no trigger on login_challenges — no T7 copying OTP hashes into audit_log');
select ok((select relrowsecurity and relforcerowsecurity from pg_class where oid = 'public.login_challenges'::regclass), 'login_challenges: RLS enabled and forced');
select ok(has_column_privilege('authenticated', 'public.staff', 'locked_until', 'select') and not has_column_privilege('authenticated', 'public.staff', 'locked_until', 'update')
      and not has_column_privilege('authenticated', 'public.staff', 'failed_login_count', 'update'), 'staff lock columns: readable like guardians'', never client-writable');
select is((select string_agg(pg_get_userbyid(proowner) || ':' || prosecdef, ',') from pg_proc where oid = 'app.otp_verify(text,text,text,text)'::regprocedure), 'app_owner:true', 'owned by app_owner, SECURITY DEFINER (R2)');

select * from finish();
rollback;
