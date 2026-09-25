-- M19 — authz_integrity (T8): delegation cannot expand authority
--   (1) role escalation عبر membership_roles (E4)   (2) permission escalation عبر role_permissions (E14/F5)
--   (3) منح Scope لا يمكّن الهدف من صلاحيات تتجاوز صلاحيات المانح داخل ذلك الـScope
-- ولكل رفض ضابط إيجابي؛ وفصل الطبقات: ما ترفضه RLS يُرفض برسالة RLS، وما تجتازه ويخرق T8 يُرفض برسالة T8.
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
  execute 'set local role authenticated';
  perform pg_temp.rec(p_key, p_sql);
  execute 'reset role';
end $$;

create function pg_temp.mid(p_label text) returns uuid language sql as $$ select membership from ids where label = p_label $$;

-- ============ Fixture ============
insert into public.platform_tenants (id, tenant_code, name) values ('10000000-0000-0000-0000-000000000001', 'T1', 'T1');
insert into public.groups (id, platform_tenant_id, group_code, name) values
  ('a1000000-0000-0000-0000-00000000000a', '10000000-0000-0000-0000-000000000001', 'GA', 'GA');
insert into public.schools (id, platform_tenant_id, group_id, school_code, name, slug) values
  ('5a100000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', 'a1000000-0000-0000-0000-00000000000a', 'SA1', 'SA1', 'sa1'),
  ('5a200000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001', 'a1000000-0000-0000-0000-00000000000a', 'SA2', 'SA2', 'sa2');

insert into public.permissions (code, resource, operation, description)
  select c, split_part(c, '.', 1), split_part(c, '.', 2), 'test' from unnest(array[
    'student.read','student.update','student.archive','profile.read','role.assign','scope.assign',
    'role.read','role.update','tenant.update','fee.read','membership.read']) c;
create function pg_temp.perm(c text) returns uuid language sql as $$ select id from public.permissions where code = c $$;

-- أدوار النظام:
--   tadmin  كل الصلاحيات عدا fee.read (لا يملكها أحد من الفاعلين)
--   sadmin  role.assign, scope.assign, student.read, student.update, profile.read, membership.read   (المانح A في مثال القرار)
--   tadm2   tenant.update + student.read                                          (هدف E4: فوق صلاحيات sadmin)
--   teacher student.read                                                           (⊆ sadmin)
--   roleX   student.read, student.update, student.archive                          (العضو B في مثال القرار)
--   roleY   student.read, student.update                                           (⊆ sadmin)
--   roleZ   student.archive — يُعطَّل (status = inactive)
insert into public.roles (id, platform_tenant_id, code, name, is_system, status) values
  ('71000000-0000-0000-0000-000000000001', null, 'tadmin',  'TA',  true, 'active'),
  ('72000000-0000-0000-0000-000000000002', null, 'sadmin',  'SA',  true, 'active'),
  ('73000000-0000-0000-0000-000000000003', null, 'tadm2',   'TA2', true, 'active'),
  ('74000000-0000-0000-0000-000000000004', null, 'teacher', 'T',   true, 'active'),
  ('75000000-0000-0000-0000-000000000005', null, 'rolex',   'X',   true, 'active'),
  ('76000000-0000-0000-0000-000000000006', null, 'roley',   'Y',   true, 'active'),
  ('77000000-0000-0000-0000-000000000007', null, 'rolez',   'Z',   true, 'inactive');
insert into public.role_permissions (role_id, permission_id)
            select '71000000-0000-0000-0000-000000000001'::uuid, id from public.permissions where code <> 'fee.read'
  union all select '72000000-0000-0000-0000-000000000002'::uuid, pg_temp.perm(c) from unnest(array['role.assign','scope.assign','student.read','student.update','profile.read','membership.read']) c
  union all select '73000000-0000-0000-0000-000000000003'::uuid, pg_temp.perm(c) from unnest(array['tenant.update','student.read']) c
  union all select '74000000-0000-0000-0000-000000000004'::uuid, pg_temp.perm('student.read')
  union all select '75000000-0000-0000-0000-000000000005'::uuid, pg_temp.perm(c) from unnest(array['student.read','student.update','student.archive']) c
  union all select '76000000-0000-0000-0000-000000000006'::uuid, pg_temp.perm(c) from unnest(array['student.read','student.update']) c
  union all select '77000000-0000-0000-0000-000000000007'::uuid, pg_temp.perm('student.archive');
-- أدوار مخصصة: c1 فارغ (F5)، c3 فيه fee.read (أضافه service)
insert into public.roles (id, platform_tenant_id, code, name) values
  ('7c100000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', 'c1', 'C1'),
  ('7c300000-0000-0000-0000-000000000003', '10000000-0000-0000-0000-000000000001', 'c3', 'C3');
insert into public.role_permissions values
  ('7c300000-0000-0000-0000-000000000003', pg_temp.perm('fee.read')),
  ('7c300000-0000-0000-0000-000000000003', pg_temp.perm('student.read'));

create function pg_temp.member(p_label text, p_roles uuid[], p_scopes text[]) returns void
language plpgsql as $$
declare v_auth uuid := gen_random_uuid(); v_profile uuid; v_m uuid; s text; rl uuid;
begin
  insert into auth.users (id, email) values (v_auth, p_label || '@m19.invalid');
  insert into public.auth_identities values (v_auth, 'tenant');
  insert into public.profiles (platform_tenant_id, auth_user_id, display_name) values ('10000000-0000-0000-0000-000000000001', v_auth, p_label) returning id into v_profile;
  insert into public.memberships (platform_tenant_id, profile_id) values ('10000000-0000-0000-0000-000000000001', v_profile) returning id into v_m;
  foreach rl in array coalesce(p_roles, '{}') loop
    insert into public.membership_roles (membership_id, role_id, platform_tenant_id, role_owner_key)
      values (v_m, rl, '10000000-0000-0000-0000-000000000001', (select owner_key from public.roles where id = rl));
  end loop;
  foreach s in array coalesce(p_scopes, '{}') loop
    if s = 'tenant' then
      insert into public.membership_scopes (membership_id, platform_tenant_id, scope_type) values (v_m, '10000000-0000-0000-0000-000000000001', 'tenant');
    elsif s like 'G%' then
      insert into public.membership_scopes (membership_id, platform_tenant_id, scope_type, group_id) values (v_m, '10000000-0000-0000-0000-000000000001', 'group', 'a1000000-0000-0000-0000-00000000000a');
    else
      insert into public.membership_scopes (membership_id, platform_tenant_id, scope_type, school_id)
        values (v_m, '10000000-0000-0000-0000-000000000001', 'school', (select id from public.schools where school_code = s));
    end if;
  end loop;
  insert into ids values (p_label, v_auth, v_profile, v_m);
end $$;

-- الفاعلون
select pg_temp.member('ta',  array['71000000-0000-0000-0000-000000000001']::uuid[], array['tenant']);
select pg_temp.member('sa1', array['72000000-0000-0000-0000-000000000002']::uuid[], array['SA1']);
select pg_temp.member('gm',  array['72000000-0000-0000-0000-000000000002']::uuid[], array['GA']);
-- الأهداف
select pg_temp.member('t1',   null,                                                array['SA1']);   -- بلا دور
select pg_temp.member('tx',   array['75000000-0000-0000-0000-000000000005']::uuid[], array['SA1']);   -- roleX
select pg_temp.member('ty',   array['76000000-0000-0000-0000-000000000006']::uuid[], array['SA1']);   -- roleY
select pg_temp.member('tz',   array['77000000-0000-0000-0000-000000000007']::uuid[], array['SA1']);   -- roleZ (معطَّل)
select pg_temp.member('twin', null,                                                array['SA1','SA2']); -- عضوية بنطاقين
select pg_temp.member('tsv',  null,                                                array['SA1']);   -- هدف اختبار سياق service
select pg_temp.member('gB',   array['75000000-0000-0000-0000-000000000005']::uuid[], null);           -- B: roleX، بلا نطاق
select pg_temp.member('gC',   array['76000000-0000-0000-0000-000000000006']::uuid[], null);           -- roleY، بلا نطاق

-- gB و gC وليا أمر لطالب في SA1 — فيديرهما SA1 عبر العلاقة (can_manage_membership)
do $$
declare v_y uuid; v_st uuid; v_gr uuid; v_sec uuid; v_s uuid; v_g uuid; l text;
  v_scope uuid := (select id from public.identity_scopes where group_id = 'a1000000-0000-0000-0000-00000000000a');
begin
  insert into public.academic_years (school_id, name, start_date, end_date, status) values ('5a100000-0000-0000-0000-000000000001', 'Y', '2026-09-01', '2027-06-30', 'active') returning id into v_y;
  insert into public.stages (school_id, name, sequence_no) values ('5a100000-0000-0000-0000-000000000001', 'P', 1) returning id into v_st;
  insert into public.grade_levels (school_id, stage_id, name, sequence_no) values ('5a100000-0000-0000-0000-000000000001', v_st, 'G1', 1) returning id into v_gr;
  insert into public.sections (school_id, academic_year_id, grade_level_id, name) values ('5a100000-0000-0000-0000-000000000001', v_y, v_gr, 'A') returning id into v_sec;
  insert into public.students (platform_tenant_id, identity_scope_id, student_profile_id, official_id, official_id_type, first_name, family_name)
    values ('10000000-0000-0000-0000-000000000001', v_scope, (select profile from ids where label = 't1'), 'N1', 'national_id', 'S', 'S') returning id into v_s;
  insert into public.enrollments (school_id, student_id, platform_tenant_id, academic_year_id, grade_level_id, section_id, identity_scope_id, scope_owner_id, status, effective_from)
    values ('5a100000-0000-0000-0000-000000000001', v_s, '10000000-0000-0000-0000-000000000001', v_y, v_gr, v_sec, v_scope, 'a1000000-0000-0000-0000-00000000000a', 'active', '2026-09-01');
  foreach l in array array['gB','gC'] loop
    insert into public.guardians (platform_tenant_id, profile_id, first_name, family_name, phone_e164)
      values ('10000000-0000-0000-0000-000000000001', (select profile from ids where label = l), l, l, case l when 'gB' then '+201000000001' else '+201000000002' end)
      returning id into v_g;
    insert into public.student_guardians (student_id, guardian_id, platform_tenant_id, relationship_type) values (v_s, v_g, '10000000-0000-0000-0000-000000000001', 'father');
  end loop;
end $$;

create function pg_temp.assign_sql(p_target text, p_role uuid) returns text language sql as $$
  select format($f$insert into public.membership_roles (membership_id, role_id, platform_tenant_id, role_owner_key)
                   values (%L, %L, '10000000-0000-0000-0000-000000000001', %L) returning 'ok'$f$,
                pg_temp.mid(p_target), p_role, (select owner_key from public.roles where id = p_role)) $$;
create function pg_temp.revoke_sql(p_target text, p_role uuid) returns text language sql as $$
  select format($f$with u as (delete from public.membership_roles where membership_id = %L and role_id = %L returning 1) select count(*)::text from u$f$,
                pg_temp.mid(p_target), p_role) $$;
create function pg_temp.scope_sql(p_target text, p_school text) returns text language sql as $$
  select format($f$insert into public.membership_scopes (membership_id, platform_tenant_id, scope_type, school_id)
                   values (%L, '10000000-0000-0000-0000-000000000001', 'school', %L) returning 'ok'$f$,
                pg_temp.mid(p_target), (select id from public.schools where school_code = p_school)) $$;

-- ============ (1) role escalation — membership_roles ============
select pg_temp.run('r1.e4',          'sa1', pg_temp.assign_sql('t1', '73000000-0000-0000-0000-000000000003'));   -- tadm2
select pg_temp.run('r1.rolex',       'sa1', pg_temp.assign_sql('t1', '75000000-0000-0000-0000-000000000005'));
select pg_temp.run('r1.teacher',     'sa1', pg_temp.assign_sql('t1', '74000000-0000-0000-0000-000000000004'));
select pg_temp.run('r1.ta_rolex',    'ta',  pg_temp.assign_sql('t1', '75000000-0000-0000-0000-000000000005'));
select pg_temp.run('r1.ta_c3',       'ta',  pg_temp.assign_sql('t1', '7c300000-0000-0000-0000-000000000003'));   -- c3 فيه fee.read
select pg_temp.run('r1.sa1_revoke_x','sa1', pg_temp.revoke_sql('t1', '75000000-0000-0000-0000-000000000005'));
select pg_temp.run('r1.sa1_revoke_t','sa1', pg_temp.revoke_sql('t1', '74000000-0000-0000-0000-000000000004'));
select pg_temp.run('r1.ta_revoke_x', 'ta',  pg_temp.revoke_sql('t1', '75000000-0000-0000-0000-000000000005'));
-- فصل الطبقات: عضوية بنطاق خارج الفاعل → RLS أولاً، لا T8
select pg_temp.run('r1.layer_rls',   'sa1', pg_temp.assign_sql('twin', '75000000-0000-0000-0000-000000000005'));
-- G7: سياق service مُعفى
select set_config('request.jwt.claims', '', true), set_config('request.jwt.claim.sub', '', true);   -- claims آخر run تبقى في المعاملة؛ تُمسح
select pg_temp.rec('r1.service', pg_temp.assign_sql('tsv', '73000000-0000-0000-0000-000000000003'));

-- ============ (2) permission escalation — role_permissions ============
select pg_temp.run('r2.ta_fee',      'ta', format($q$insert into public.role_permissions values ('7c100000-0000-0000-0000-000000000001', %L) returning 'ok'$q$, pg_temp.perm('fee.read')));
select pg_temp.run('r2.ta_archive',  'ta', format($q$insert into public.role_permissions values ('7c100000-0000-0000-0000-000000000001', %L) returning 'ok'$q$, pg_temp.perm('student.archive')));
select pg_temp.run('r2.ta_del_fee',  'ta', format($q$with u as (delete from public.role_permissions where role_id = '7c300000-0000-0000-0000-000000000003' and permission_id = %L returning 1) select count(*)::text from u$q$, pg_temp.perm('fee.read')));
select pg_temp.run('r2.ta_del_read', 'ta', format($q$with u as (delete from public.role_permissions where role_id = '7c300000-0000-0000-0000-000000000003' and permission_id = %L returning 1) select count(*)::text from u$q$, pg_temp.perm('student.read')));
-- F5 كاملاً: الخطوة 1 (إسناد دور مخصص فارغ للذات) ترفضها RLS؛ الخطوة 2 (ملؤه بما لا يملكه) يرفضها T8
select pg_temp.run('r2.f5_step1',    'ta', pg_temp.assign_sql('ta', '7c100000-0000-0000-0000-000000000001'));
select pg_temp.run('r2.f5_step2',    'ta', format($q$insert into public.role_permissions values ('7c100000-0000-0000-0000-000000000001', %L) returning 'ok'$q$, pg_temp.perm('fee.read')));

-- ============ (3) scope grant ============
select pg_temp.run('r3.example',     'sa1', pg_temp.scope_sql('gB', 'SA1'));   -- مثال القرار حرفياً: A يمنح B نطاق SA1
select pg_temp.run('r3.example_ok',  'sa1', pg_temp.scope_sql('gC', 'SA1'));
select pg_temp.run('r3.gm_tx',       'gm',  pg_temp.scope_sql('tx', 'SA2'));
select pg_temp.run('r3.gm_ty',       'gm',  pg_temp.scope_sql('ty', 'SA2'));
select pg_temp.run('r3.ta_tx',       'ta',  pg_temp.scope_sql('tx', 'SA2'));
select pg_temp.run('r3.gm_tz',       'gm',  pg_temp.scope_sql('tz', 'SA2'));   -- الدور المعطَّل يُحسب
select pg_temp.run('r3.layer_rls',   'sa1', pg_temp.scope_sql('t1', 'SA2'));   -- SA2 خارج نطاق الفاعل → RLS

-- UPDATE غير متاح للعميل على الجدولين
select pg_temp.run('u.mr', 'ta', $q$with u as (update public.membership_roles set role_owner_key = role_owner_key returning 1) select count(*)::text from u$q$);
select pg_temp.run('u.rp', 'ta', $q$with u as (update public.role_permissions set permission_id = permission_id returning 1) select count(*)::text from u$q$);

-- الحالة النهائية المتوقعة لأدوار t1 ونطاقات tx
select pg_temp.rec('state.t1', $q$select string_agg(r.code, ',' order by r.code) from public.membership_roles mr join public.roles r on r.id = mr.role_id join ids i on i.membership = mr.membership_id where i.label = 't1'$q$);
select pg_temp.rec('state.c1', $q$select string_agg(p.code, ',' order by p.code) from public.role_permissions rp join public.permissions p on p.id = rp.permission_id where rp.role_id = '7c100000-0000-0000-0000-000000000001'$q$);

select plan(31);

-- (1)
select ok((select v from r where k = 'r1.e4')    like 'ERR 42501%T8: role grants permissions the actor does not hold: tenant.update', 'E4: school admin cannot assign a tenant-admin-level role (tenant.update)');
select ok((select v from r where k = 'r1.rolex') like 'ERR 42501%T8: role grants permissions the actor does not hold: student.archive', 'role escalation: a role with one permission beyond the actor is rejected, naming it');
select is((select v from r where k = 'r1.teacher'),   'ok', 'role within the actor''s permissions (control)');
select is((select v from r where k = 'r1.ta_rolex'),  'ok', 'tenant admin holding every permission of the role (control)');
select ok((select v from r where k = 'r1.ta_c3')  like 'ERR 42501%T8: role grants permissions the actor does not hold: fee.read', 'even a tenant admin cannot assign a role carrying a permission it does not hold');
select ok((select v from r where k = 'r1.sa1_revoke_x') like 'ERR 42501%T8: role grants permissions the actor does not hold: student.archive', 'revoke is checked too: a lower admin cannot strip a role above its authority (§10.2.1)');
select is((select v from r where k = 'r1.sa1_revoke_t'), '1', 'revoke within the actor''s permissions (control)');
select is((select v from r where k = 'r1.ta_revoke_x'),  '1', 'revoke by an actor holding the role''s permissions (control)');
select ok((select v from r where k = 'r1.layer_rls') like 'ERR 42501%row-level security%membership_roles%', 'layering: an out-of-scope target is rejected by RLS, not masked by T8 (AFTER trigger)');
select is((select v from r where k = 'r1.service'), 'ok', 'G7: service context is exempt');

-- (2)
select ok((select v from r where k = 'r2.ta_fee') like 'ERR 42501%T8: permission not held by the actor: fee.read', 'E14 step 2: a tenant admin cannot add a permission it does not hold to a custom role');
select is((select v from r where k = 'r2.ta_archive'), 'ok', 'adding a held permission to a custom role (control)');
select ok((select v from r where k = 'r2.ta_del_fee') like 'ERR 42501%T8: permission not held by the actor: fee.read', 'removing a permission the actor does not hold is rejected too');
select is((select v from r where k = 'r2.ta_del_read'), '1', 'removing a held permission (control)');
select ok((select v from r where k = 'r2.f5_step1') like 'ERR 42501%row-level security%membership_roles%', 'F5 step 1: self-assigning an empty custom role — RLS (no self-management)');
select ok((select v from r where k = 'r2.f5_step2') like 'ERR 42501%T8: permission not held by the actor: fee.read', 'F5 step 2: filling a custom role with an unheld permission — T8');

-- (3)
select ok((select v from r where k = 'r3.example') like 'ERR 42501%T8: scope grant would enable permissions the actor does not hold: student.archive',
          '(3) the decision example: A {read, update} grants SA1 to B (roleX incl. archive) → rejected, naming student.archive');
select is((select v from r where k = 'r3.example_ok'), 'ok', '(3) same grant when the target''s roles are within the grantor''s permissions (control)');
select ok((select v from r where k = 'r3.gm_tx') like 'ERR 42501%T8: scope grant would enable permissions the actor does not hold: student.archive',
          '(3) a group manager cannot extend a stronger member into a second school');
select is((select v from r where k = 'r3.gm_ty'), 'ok', '(3) group manager extends a member whose roles it covers (control)');
select is((select v from r where k = 'r3.ta_tx'), 'ok', '(3) tenant admin holding archive may extend the stronger member');
select ok((select v from r where k = 'r3.gm_tz') like 'ERR 42501%T8: scope grant would enable permissions the actor does not hold: student.archive',
          '(3) an inactive role of the target still counts — reactivation must not bypass the check');
select ok((select v from r where k = 'r3.layer_rls') like 'ERR 42501%row-level security%membership_scopes%', 'layering: a scope beyond the actor is rejected by RLS, not T8');

-- UPDATE
select ok((select v from r where k = 'u.mr') like 'ERR 42501%permission denied%membership_roles%', 'membership_roles: no client UPDATE privilege');
select ok((select v from r where k = 'u.rp') like 'ERR 42501%permission denied%role_permissions%', 'role_permissions: no client UPDATE privilege');

-- الحالة
select is((select v from r where k = 'state.t1'), '<null>', 'state: t1 ends with no role — every rejected change left no trace; the legitimate ones were later revoked');
select is((select v from r where k = 'state.c1'), 'student.archive', 'c1 holds only the permission legitimately added');

-- البنية
select is((select string_agg(c.relname || ':' || t.tgtype::text, ',' order by c.relname) from pg_trigger t join pg_class c on c.oid = t.tgrelid
            where t.tgname = 'authz_integrity' and not t.tgisinternal),
          'membership_roles:13,membership_scopes:5,role_permissions:13',
          'T8 is an AFTER ROW trigger: INSERT/DELETE on membership_roles and role_permissions, INSERT on membership_scopes');
select ok((select pg_get_userbyid(proowner) = 'app_owner' and prosecdef and array_to_string(proconfig, ',') like 'search_path=%'
           from pg_proc where oid = 'app.tg_authz_integrity()'::regprocedure), 'T8 function: SECURITY DEFINER, owner app_owner, pinned search_path');
select is((select count(*)::int from unnest(array['anon','authenticated','public']) g
            where has_function_privilege(g, 'app.tg_authz_integrity()'::regprocedure, 'EXECUTE')), 0, 'T8 function: executable by no client role');
select is((select count(*)::int from pg_trigger t join pg_class c on c.oid = t.tgrelid
            where t.tgname = 'authz_integrity' and c.relname = 'membership_scopes' and (t.tgtype & 8) <> 0), 0,
          'membership_scopes: T8 on grant only — revoking a scope cannot expand authority');

select * from finish();
rollback;
