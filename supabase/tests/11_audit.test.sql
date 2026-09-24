-- M11 — audit: T7 (الالتقاط)، الفاعل المستقل، T5 (الثبات)، الصلاحيات
-- كل تحقق رفض يطابق اسم القيد/الآلية المقصودة (CLAUDE.md).
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
  perform set_config('request.jwt.claims', case when p_sub is null then '' else json_build_object('sub', p_sub, 'role', 'authenticated')::text end, true);
  perform set_config('request.jwt.claim.sub', coalesce(p_sub::text, ''), true);
end $$;

-- آخر صف تدقيق لكيان
create function pg_temp.last_audit(p_entity_type text, p_entity_id text) returns public.audit_log
language sql as $$ select * from public.audit_log where entity_type = p_entity_type and entity_id = p_entity_id order by id desc limit 1 $$;

-- ============ Fixture (سياق service: لا فاعل) ============
select pg_temp.as_(null);
insert into public.platform_tenants (id, tenant_code, name) values ('10000000-0000-0000-0000-000000000001', 'T1', 'T1');
insert into public.schools (id, platform_tenant_id, school_code, name, slug) values
  ('55000000-0000-0000-0000-000000000004', '10000000-0000-0000-0000-000000000001', 'SS', 'SS', 'ss');

-- مستخدم Tenant
insert into auth.users (id, email) values
  ('c1000000-0000-0000-0000-000000000001', 'tu@m11.invalid'),
  ('c2000000-0000-0000-0000-000000000002', 'pa@m11.invalid');
insert into public.auth_identities values
  ('c1000000-0000-0000-0000-000000000001', 'tenant'),
  ('c2000000-0000-0000-0000-000000000002', 'platform');
insert into public.profiles (id, platform_tenant_id, auth_user_id, display_name) values
  ('b1000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', 'c1000000-0000-0000-0000-000000000001', 'TU');
insert into public.system_users (id, auth_user_id, display_name) values
  ('d2000000-0000-0000-0000-000000000002', 'c2000000-0000-0000-0000-000000000002', 'PA');

-- ============ الفاعل: ثلاثة سياقات ============
-- (1) مستخدم Tenant — جدول مدرسي بلا platform_tenant_id (يُشتق الـTenant من المدرسة)
select pg_temp.as_('c1000000-0000-0000-0000-000000000001');
insert into public.stages (id, school_id, name, sequence_no) values
  ('e1000000-0000-0000-0000-000000000001', '55000000-0000-0000-0000-000000000004', 'Primary', 1);
-- (2) Platform Admin — جدول بلا created_by: الفاعل الحقيقي يظهر في التدقيق وحده
select pg_temp.as_('c2000000-0000-0000-0000-000000000002');
insert into public.platform_admin_roles (id, code, name) values ('f1000000-0000-0000-0000-000000000001', 'platform_support', 'Support');
select pg_temp.as_(null);

-- ============ الحدث والسياق ============
-- انتقال حالة كما تفعله دوال §5.3: action + reason + source + ip
select set_config('app.audit_action', 'archive', true);
select set_config('app.audit_reason', 'school closed', true);
select set_config('app.request_source', 'web', true);
select set_config('request.headers', '{"x-forwarded-for": "203.0.113.7, 10.0.0.1"}', true);
update public.stages set status = 'inactive' where id = 'e1000000-0000-0000-0000-000000000001';
-- إعادة الضبط: تعديل عادي لاحق
select set_config('app.audit_action', '', true);
select set_config('app.audit_reason', '', true);
-- source غير معروف + ip غير صالح: لا يُفشلان الكتابة
select set_config('app.request_source', 'hacker', true);
select set_config('request.headers', '{"x-forwarded-for": "not-an-ip"}', true);
update public.stages set name = 'Primary Stage' where id = 'e1000000-0000-0000-0000-000000000001';
select set_config('app.request_source', '', true);
select set_config('request.headers', '', true);

-- حذف: السجل يبقى بعد زوال الكيان (بلا FK)
insert into public.families (id, platform_tenant_id, family_name) values ('fa000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', 'Temp');
delete from public.families where id = 'fa000000-0000-0000-0000-000000000001';

-- مفاتيح مركّبة
insert into public.permissions (id, code, resource, operation, description) values ('91000000-0000-0000-0000-000000000001', 'student.read', 'student', 'read', 'x');
insert into public.roles (id, platform_tenant_id, code, name, is_system) values
  ('71000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', 'custom', 'Custom', false),
  ('72000000-0000-0000-0000-000000000002', null, 'sys', 'System', true);
insert into public.role_permissions values
  ('71000000-0000-0000-0000-000000000001', '91000000-0000-0000-0000-000000000001'),
  ('72000000-0000-0000-0000-000000000002', '91000000-0000-0000-0000-000000000001');
insert into public.memberships (id, platform_tenant_id, profile_id) values ('a1000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', 'b1000000-0000-0000-0000-000000000001');
insert into public.membership_roles (membership_id, role_id, platform_tenant_id, role_owner_key) values
  ('a1000000-0000-0000-0000-000000000001', '72000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000000');
insert into public.membership_scopes (membership_id, platform_tenant_id, scope_type) values
  ('a1000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', 'tenant');
-- CASCADE: حذف العضوية يحذف أدوارها ونطاقاتها — والحذف المتسلسل يُدقَّق أيضاً
delete from public.memberships where id = 'a1000000-0000-0000-0000-000000000001';

-- ============ الثبات (T5) والصلاحيات ============
set local role service_role;
select pg_temp.rec('t5.service_update',   'update public.audit_log set action = ''tampered'' returning ''ok''');
select pg_temp.rec('t5.service_delete',   'delete from public.audit_log returning ''ok''');
select pg_temp.rec('t5.service_truncate', 'truncate public.audit_log; select ''ok''');
reset role;
select pg_temp.rec('t5.owner_update',   'update public.audit_log set action = ''tampered'' returning ''ok''');
select pg_temp.rec('t5.owner_delete',   'delete from public.audit_log returning ''ok''');
select pg_temp.rec('t5.owner_truncate', 'truncate public.audit_log; select ''ok''');
select pg_temp.rec('chk.actorless_user', $q$insert into public.audit_log (actor_type, action, entity_type, entity_id) values ('tenant_user','x','t','1') returning 'ok'$q$);

select pg_temp.as_('c1000000-0000-0000-0000-000000000001');
set local role authenticated;
select pg_temp.rec('priv.auth_select', 'select count(*)::text from public.audit_log');
select pg_temp.rec('priv.auth_insert', $q$insert into public.audit_log (actor_type, action, entity_type, entity_id) values ('system','forged','t','1') returning 'ok'$q$);
reset role;
select pg_temp.as_(null);

select plan(44);

-- البنية
select ok((select relrowsecurity and relforcerowsecurity from pg_class where oid = 'public.audit_log'::regclass), 'RLS enabled and forced on audit_log');
select is((select count(*)::int from pg_constraint where conrelid = 'public.audit_log'::regclass and contype = 'f'), 0,
          'audit_log has no foreign keys (survives entity archival or deletion)');
select is((select count(*)::int from pg_trigger t join pg_class c on c.oid = t.tgrelid
           where c.relnamespace = 'public'::regnamespace and t.tgfoid = 'app.tg_audit()'::regprocedure and not t.tgisinternal), 28,
          'T7 attached to 28 tables');
select is((select coalesce(string_agg(c.relname, ','), '<none>') from pg_class c
           where c.relnamespace = 'public'::regnamespace and c.relkind = 'r' and c.relname <> 'audit_log'
             and not exists (select 1 from pg_trigger t where t.tgrelid = c.oid and t.tgfoid = 'app.tg_audit()'::regprocedure)),
          '<none>', 'every Foundation table except audit_log is audited');
select ok((select pg_get_userbyid(proowner) = 'app_owner' and prosecdef from pg_proc where oid = 'app.tg_audit()'::regprocedure)
      and not has_function_privilege('anon', 'app.tg_audit()', 'EXECUTE'),
          'T7: SECURITY DEFINER owned by app_owner, no EXECUTE for anon');

-- الفاعل — service
select is((pg_temp.last_audit('platform_tenants', '10000000-0000-0000-0000-000000000001')).actor_type, 'system', 'service context → actor system');
select is((pg_temp.last_audit('platform_tenants', '10000000-0000-0000-0000-000000000001')).actor_id, null::uuid, 'service context → no actor id');
select is((pg_temp.last_audit('platform_tenants', '10000000-0000-0000-0000-000000000001')).platform_tenant_id, '10000000-0000-0000-0000-000000000001'::uuid,
          'platform_tenants row audited under its own tenant');
-- الفاعل — مستخدم Tenant
select is((select actor_type from public.audit_log where entity_type = 'stages' and action = 'insert'), 'tenant_user', 'tenant user → actor tenant_user');
select is((select actor_id from public.audit_log where entity_type = 'stages' and action = 'insert'), 'b1000000-0000-0000-0000-000000000001'::uuid, 'tenant user → actor_id = profile');
select is((select platform_tenant_id from public.audit_log where entity_type = 'stages' and action = 'insert'), '10000000-0000-0000-0000-000000000001'::uuid,
          'school-level table without tenant column: tenant derived from the school');
select is((select school_id from public.audit_log where entity_type = 'stages' and action = 'insert'), '55000000-0000-0000-0000-000000000004'::uuid, 'school_id captured');
-- الفاعل — Platform Admin (حيث لا يستطيع created_by تمثيله)
select hasnt_column('public', 'platform_admin_roles', 'created_by', 'platform_admin_roles has no created_by (M05)');
select is((pg_temp.last_audit('platform_admin_roles', 'f1000000-0000-0000-0000-000000000001')).actor_type, 'platform_admin', 'platform admin → actor platform_admin');
select is((pg_temp.last_audit('platform_admin_roles', 'f1000000-0000-0000-0000-000000000001')).actor_id, 'd2000000-0000-0000-0000-000000000002'::uuid,
          'platform admin → actor_id = system user (audit records who created_by cannot)');

-- الحدث — انتقال حالة
select is((select count(*)::int from public.audit_log where entity_type = 'stages'), 3, 'insert + two updates → three audit rows');
select is((select action from public.audit_log where entity_type = 'stages' and reason = 'school closed'), 'archive', 'app.audit_action applied to the state transition');
select is((select source from public.audit_log where entity_type = 'stages' and reason = 'school closed'), 'web', 'known source kept');
select is((select host(ip_address) from public.audit_log where entity_type = 'stages' and reason = 'school closed'), '203.0.113.7', 'client ip = first x-forwarded-for entry');
select is((select old_values ->> 'status' || '→' || (new_values ->> 'status') from public.audit_log where entity_type = 'stages' and reason = 'school closed'),
          'active→inactive', 'old and new values captured');
-- الحدث — تعديل عادي بعد إعادة الضبط + سياق غير صالح
select is((select action from public.audit_log where entity_type = 'stages' and new_values ->> 'name' = 'Primary Stage'), 'update', 'plain update after reset → update');
select is((select reason from public.audit_log where entity_type = 'stages' and new_values ->> 'name' = 'Primary Stage'), null::text, 'reason not carried over');
select is((select source from public.audit_log where entity_type = 'stages' and new_values ->> 'name' = 'Primary Stage'), 'api', 'unknown source coerced to api (write not broken)');
select is((select ip_address from public.audit_log where entity_type = 'stages' and new_values ->> 'name' = 'Primary Stage'), null::inet, 'invalid ip header → NULL (write not broken)');

-- الحذف
select is((select count(*)::int from public.audit_log where entity_type = 'families' and entity_id = 'fa000000-0000-0000-0000-000000000001'), 2,
          'insert and delete audited; history survives the deleted row');
select ok((select old_values is not null and new_values is null from public.audit_log
           where entity_type = 'families' and entity_id = 'fa000000-0000-0000-0000-000000000001' and action = 'delete'),
          'delete keeps old values, no new values');

-- مفاتيح مركّبة ونطاق الأدوار
select ok(exists (select 1 from public.audit_log where entity_type = 'role_permissions'
                  and entity_id = '71000000-0000-0000-0000-000000000001:91000000-0000-0000-0000-000000000001'),
          'composite key entity id for role_permissions');
select is((select platform_tenant_id from public.audit_log where entity_type = 'role_permissions' and entity_id like '71000000%'),
          '10000000-0000-0000-0000-000000000001'::uuid, 'custom role grant audited under the role tenant');
select is((select platform_tenant_id from public.audit_log where entity_type = 'role_permissions' and entity_id like '72000000%'),
          null::uuid, 'system role grant audited without tenant (platform-level)');
select ok(exists (select 1 from public.audit_log where entity_type = 'membership_roles'
                  and entity_id = 'a1000000-0000-0000-0000-000000000001:72000000-0000-0000-0000-000000000002'),
          'composite key entity id for membership_roles');
select ok(exists (select 1 from public.audit_log where entity_type = 'auth_identities' and entity_id = 'c1000000-0000-0000-0000-000000000001'),
          'auth_identities keyed by auth_user_id');
select ok(exists (select 1 from public.audit_log where entity_type = 'membership_roles' and action = 'delete')
      and exists (select 1 from public.audit_log where entity_type = 'membership_scopes' and action = 'delete'),
          'cascaded deletes are audited (role and scope removed with the membership)');
select ok(exists (select 1 from public.audit_log where entity_type = 'identity_scopes' and action = 'insert'),
          'T9-created identity scope is audited');

-- T5 — الثبات حتى على service_role والمالك
select ok((select v from r where k = 't5.service_update')   like 'ERR 42501%', 'service_role cannot UPDATE audit rows');
select ok((select v from r where k = 't5.service_delete')   like 'ERR 42501%', 'service_role cannot DELETE audit rows');
select ok((select v from r where k = 't5.service_truncate') like 'ERR 42501%', 'service_role cannot TRUNCATE audit_log');
select ok((select v from r where k = 't5.owner_update')   like 'ERR 42501%immutable%', 'T5: table owner cannot UPDATE (trigger, not privileges)');
select ok((select v from r where k = 't5.owner_delete')   like 'ERR 42501%immutable%', 'T5: table owner cannot DELETE');
select ok((select v from r where k = 't5.owner_truncate') like 'ERR 42501%immutable%', 'T5: table owner cannot TRUNCATE (statement trigger)');
select ok((select v from r where k = 'chk.actorless_user') like 'ERR 23514%audit_log_actor_chk%', 'non-system actor requires actor_id');

-- الصلاحيات
select ok((select v from r where k = 'priv.auth_select') like 'ERR 42501%', 'authenticated cannot read audit_log directly (visibility comes in M18/M20)');
select ok((select v from r where k = 'priv.auth_insert') like 'ERR 42501%', 'authenticated cannot forge audit rows');
select ok(has_table_privilege('service_role', 'public.audit_log', 'INSERT'), 'service_role may INSERT (FastAPI read/export audit, §7.4)');
select ok(not has_table_privilege('anon', 'public.audit_log', 'SELECT') and not has_table_privilege('anon', 'public.audit_log', 'INSERT'),
          'anon has no access to audit_log');

select * from finish();
rollback;
