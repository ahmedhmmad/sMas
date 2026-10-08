-- M49 — staff_lifecycle (Phase 3A / 3-3، T10، T11): P10 بنطاقيه وإسقاط التفويض.
--   end_staff_assignment  ← تكليفات **تلك المدرسة وحدها** + نطاقها وحده، وفقط إن لم يبقَ تكليف مدرسة نشط آخر فيها؛ الأدوار والعضوية كما هي
--   set_staff_status(ended) ← كل التكليفات في مدارس الـTenant + العضوية ended **بلا حذف أي صف**
--   on_leave ← لا أثر · السنة المغلقة لا تُمس · T8 بلا تعديل
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
create temp table who (label text primary key, staff uuid, membership uuid) on commit drop;
grant select on who to public;

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
insert into public.platform_tenants (id, tenant_code, host_label, name) values ('10000000-0000-0000-0000-000000000001', 'T1', 't1', 'T1');
insert into public.groups (id, platform_tenant_id, group_code, name) values ('a1000000-0000-0000-0000-00000000000a', '10000000-0000-0000-0000-000000000001', 'GA', 'GA');
insert into public.schools (id, platform_tenant_id, group_id, school_code, name, slug) values
  ('5a000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', 'a1000000-0000-0000-0000-00000000000a', 'SA', 'SA', 'sa'),
  ('5b000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001', 'a1000000-0000-0000-0000-00000000000a', 'SB', 'SB', 'sb');
insert into public.academic_years (id, school_id, name, start_date, end_date) values
  ('c0000000-0000-0000-0000-000000000001', '5a000000-0000-0000-0000-000000000001', '2025', '2025-09-01', '2026-06-30'),
  ('b0000000-0000-0000-0000-000000000003', '5a000000-0000-0000-0000-000000000001', '2027', '2027-09-01', '2028-06-30'),
  ('bb000000-0000-0000-0000-000000000004', '5b000000-0000-0000-0000-000000000002', '2027', '2027-09-01', '2028-06-30');
insert into public.stages (id, school_id, name, sequence_no) values
  ('51000000-0000-0000-0000-000000000001', '5a000000-0000-0000-0000-000000000001', 'P', 1),
  ('52000000-0000-0000-0000-000000000002', '5b000000-0000-0000-0000-000000000002', 'P', 1);
insert into public.grade_levels (id, school_id, stage_id, name, sequence_no) values
  ('61000000-0000-0000-0000-000000000001', '5a000000-0000-0000-0000-000000000001', '51000000-0000-0000-0000-000000000001', 'G1', 1),
  ('62000000-0000-0000-0000-000000000001', '5b000000-0000-0000-0000-000000000002', '52000000-0000-0000-0000-000000000002', 'G1', 1);
insert into public.subjects (id, school_id, subject_code, name) values
  ('5e000000-0000-0000-0000-000000000001', '5a000000-0000-0000-0000-000000000001', 'AR', 'Arabic'),
  ('5e000000-0000-0000-0000-0000000000b1', '5b000000-0000-0000-0000-000000000002', 'AR', 'Arabic');
insert into public.grade_subjects (school_id, academic_year_id, grade_level_id, subject_id, weekly_periods) values
  ('5a000000-0000-0000-0000-000000000001', 'b0000000-0000-0000-0000-000000000003', '61000000-0000-0000-0000-000000000001', '5e000000-0000-0000-0000-000000000001', 5),
  ('5a000000-0000-0000-0000-000000000001', 'c0000000-0000-0000-0000-000000000001', '61000000-0000-0000-0000-000000000001', '5e000000-0000-0000-0000-000000000001', 5),
  ('5b000000-0000-0000-0000-000000000002', 'bb000000-0000-0000-0000-000000000004', '62000000-0000-0000-0000-000000000001', '5e000000-0000-0000-0000-0000000000b1', 5);

create function pg_temp.member(p_label text, p_role text, p_scope text, p_target uuid) returns void
language plpgsql as $$
declare v_a uuid := gen_random_uuid(); v_p uuid; v_m uuid; v_t uuid := '10000000-0000-0000-0000-000000000001';
begin
  insert into auth.users (id, email) values (v_a, p_label || '@m49.invalid');
  insert into public.auth_identities (auth_user_id, kind) values (v_a, 'tenant');
  insert into public.profiles (platform_tenant_id, auth_user_id, display_name) values (v_t, v_a, p_label) returning id into v_p;
  insert into public.memberships (platform_tenant_id, profile_id) values (v_t, v_p) returning id into v_m;
  insert into public.membership_roles (membership_id, role_id, platform_tenant_id, role_owner_key)
    values (v_m, (select id from public.roles where code = p_role and platform_tenant_id is null), v_t, '00000000-0000-0000-0000-000000000000');
  insert into public.membership_scopes (membership_id, platform_tenant_id, scope_type, school_id)
    values (v_m, v_t, p_scope, case when p_scope = 'school' then p_target end);
  insert into actors values (p_label, v_a);
end $$;
select pg_temp.member('sa', 'school_admin', 'school', '5a000000-0000-0000-0000-000000000001');
select pg_temp.member('sb', 'school_admin', 'school', '5b000000-0000-0000-0000-000000000002');
select pg_temp.member('ta', 'tenant_admin', 'tenant', null);

-- موظف: p_schools تكليفات مدرسة نشطة؛ p_role ⇒ حساب بدور ونطاق لكل مدرسة؛ لكل مدرسة شعبة خاصة به بتكليف تدريس وتكليف مربٍّ
create function pg_temp.staffer(p_label text, p_schools text[], p_role text default 'teacher') returns void
language plpgsql as $$
declare v_s uuid := gen_random_uuid(); v_p uuid; v_m uuid; v_t uuid := '10000000-0000-0000-0000-000000000001'; c text; v_school uuid; v_year uuid; v_grade uuid; v_subj uuid; v_sec uuid;
begin
  if p_role is not null then
    insert into auth.users (id, email) values (v_s, v_s || '@staff.smas.invalid');
    insert into public.auth_identities (auth_user_id, kind) values (v_s, 'tenant');
    insert into public.profiles (platform_tenant_id, auth_user_id, display_name) values (v_t, v_s, p_label) returning id into v_p;
    insert into public.memberships (platform_tenant_id, profile_id) values (v_t, v_p) returning id into v_m;
    insert into public.membership_roles (membership_id, role_id, platform_tenant_id, role_owner_key)
      values (v_m, (select id from public.roles where code = p_role and platform_tenant_id is null), v_t, '00000000-0000-0000-0000-000000000000');
    insert into actors values (p_label, v_s);
  end if;
  insert into public.staff (id, platform_tenant_id, profile_id, employee_code, first_name, family_name) values (v_s, v_t, v_p, p_label, 'S', p_label);
  foreach c in array p_schools loop
    select id into v_school from public.schools where school_code = c;
    v_year  := case c when 'SA' then 'b0000000-0000-0000-0000-000000000003' else 'bb000000-0000-0000-0000-000000000004' end;
    v_grade := case c when 'SA' then '61000000-0000-0000-0000-000000000001' else '62000000-0000-0000-0000-000000000001' end;
    v_subj  := case c when 'SA' then '5e000000-0000-0000-0000-000000000001' else '5e000000-0000-0000-0000-0000000000b1' end;
    insert into public.staff_school_assignments (staff_id, school_id, platform_tenant_id, job_title, effective_from) values (v_s, v_school, v_t, 'T', '2025-09-01');
    insert into public.sections (school_id, academic_year_id, grade_level_id, name) values (v_school, v_year, v_grade, p_label || c) returning id into v_sec;
    insert into public.teaching_assignments (platform_tenant_id, school_id, academic_year_id, grade_level_id, section_id, subject_id, staff_id, effective_from)
      values (v_t, v_school, v_year, v_grade, v_sec, v_subj, v_s, '2027-09-01');
    insert into public.class_teacher_assignments (platform_tenant_id, school_id, academic_year_id, grade_level_id, section_id, staff_id, effective_from)
      values (v_t, v_school, v_year, v_grade, v_sec, v_s, '2027-09-01');
    if v_m is not null then
      insert into public.membership_scopes (membership_id, platform_tenant_id, scope_type, school_id) values (v_m, v_t, 'school', v_school);
    end if;
  end loop;
  insert into who values (p_label, v_s, v_m);
end $$;
select pg_temp.staffer('m1', array['SA', 'SB']);                  -- مدرستان: إنهاء SA لا يمس SB
select pg_temp.staffer('m2', array['SA']);                        -- تكليفا مدرسة نشطان في SA
select pg_temp.staffer('m3', array['SA'], 'tenant_admin');        -- يحمل دوراً أعلى من منهي تكليفه
select pg_temp.staffer('m4', array['SA', 'SB']);                  -- ended
select pg_temp.staffer('m5', array['SA']);                        -- on_leave
select pg_temp.staffer('m6', array['SA'], null);                  -- بلا حساب
insert into public.staff_school_assignments (staff_id, school_id, platform_tenant_id, job_title, effective_from)
  select staff, '5a000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', 'Coordinator', '2026-01-01' from who where label = 'm2';

-- m3 في السنة المغلقة: تكليف بقي active لحظة الإغلاق
insert into public.sections (id, school_id, academic_year_id, grade_level_id, name) values
  ('5ec00000-0000-0000-0000-0000000000c6', '5a000000-0000-0000-0000-000000000001', 'c0000000-0000-0000-0000-000000000001', '61000000-0000-0000-0000-000000000001', 'C');
insert into public.teaching_assignments (id, platform_tenant_id, school_id, academic_year_id, grade_level_id, section_id, subject_id, staff_id, effective_from)
  select '7c000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', '5a000000-0000-0000-0000-000000000001', 'c0000000-0000-0000-0000-000000000001',
         '61000000-0000-0000-0000-000000000001', '5ec00000-0000-0000-0000-0000000000c6', '5e000000-0000-0000-0000-000000000001', staff, '2025-09-01' from who where label = 'm3';
update public.academic_years set status = 'active' where id = 'c0000000-0000-0000-0000-000000000001';
update public.academic_years set status = 'closed' where id = 'c0000000-0000-0000-0000-000000000001';

-- لقطة: حالة موظف كاملة في سطر
create function pg_temp.state(p_label text) returns text language sql as $$
  select format('ssa[%s] teach[%s] class[%s] scopes[%s] roles[%s] membership[%s]',
    (select coalesce(string_agg(sc.school_code || ':' || a.status, ',' order by sc.school_code, a.effective_from), '') from public.staff_school_assignments a join public.schools sc on sc.id = a.school_id where a.staff_id = w.staff),
    (select coalesce(string_agg(sc.school_code || ':' || y.status || ':' || t.status || coalesce('@' || t.effective_to, ''), ',' order by sc.school_code, y.start_date), '')
       from public.teaching_assignments t join public.schools sc on sc.id = t.school_id join public.academic_years y on y.id = t.academic_year_id where t.staff_id = w.staff),
    (select coalesce(string_agg(sc.school_code || ':' || t.status, ',' order by sc.school_code), '') from public.class_teacher_assignments t join public.schools sc on sc.id = t.school_id where t.staff_id = w.staff),
    (select coalesce(string_agg(sc.school_code, ',' order by sc.school_code), '') from public.membership_scopes ms join public.schools sc on sc.id = ms.school_id where ms.membership_id = w.membership),
    (select coalesce(string_agg(ro.code, ',' order by ro.code), '') from public.membership_roles mr join public.roles ro on ro.id = mr.role_id where mr.membership_id = w.membership),
    (select coalesce(m.status, '-') from (select 1) x left join public.memberships m on m.id = w.membership))
  from who w where w.label = p_label
$$;
create function pg_temp.end_ssa(p_label text, p_school text, p_to text, p_reason text, p_from text default null) returns text language sql as $$
  select format($f$select app.end_staff_assignment(%L, %L, %L)::text$f$,
    (select a.id from public.staff_school_assignments a join who w on w.staff = a.staff_id join public.schools sc on sc.id = a.school_id
      where w.label = p_label and sc.school_code = p_school and a.status = 'active' and (p_from is null or a.effective_from = p_from::date)
      order by a.effective_from limit 1), p_to, p_reason)
$$;
create function pg_temp.set_status(p_label text, p_status text, p_reason text, p_to text default null) returns text language sql as $$
  select format($f$select app.set_staff_status(%L, %L, %L, %L)::text$f$, (select staff from who where label = p_label), p_status, p_reason, p_to)
$$;

select pg_temp.rec('before.m1', $q$select pg_temp.state('m1')$q$);

-- ============ A. إنهاء تكليف مدرسة واحدة من اثنتين ============
select pg_temp.run('a.end_sa', 'sa', pg_temp.end_ssa('m1', 'SA', '2026-12-31', 'left SA'));
select pg_temp.rec('a.m1', $q$select pg_temp.state('m1')$q$);
select pg_temp.run('a.m1_reach', 'm1', $q$select app.can_access_school('5a000000-0000-0000-0000-000000000001')::text || '/' || app.can_access_school('5b000000-0000-0000-0000-000000000002')::text$q$);

-- ============ B. تكليفا مدرسة نشطان في المدرسة نفسها ============
select pg_temp.run('b.end_first', 'sa', pg_temp.end_ssa('m2', 'SA', '2027-10-01', 'no longer teacher', '2025-09-01'));
select pg_temp.rec('b.m2_one_left', $q$select pg_temp.state('m2')$q$);
select pg_temp.run('b.end_second', 'sa', pg_temp.end_ssa('m2', 'SA', '2027-11-01', 'left SA', '2026-01-01'));
select pg_temp.rec('b.m2_none_left', $q$select pg_temp.state('m2')$q$);
select pg_temp.run('b.m2_perm', 'm2', $q$select app.has_permission('staff.read')::text || '/' || app.can_access_school('5a000000-0000-0000-0000-000000000001')::text$q$);
-- العودة: تكليف مدرسة جديد ثم منح النطاق من مدير المدرسة (M47 — عضوية بلا نطاقات + تكليف نشط)
select pg_temp.run('b.reassign', 'sa', format($f$insert into public.staff_school_assignments (staff_id, school_id, platform_tenant_id, job_title, effective_from)
  values (%L, '5a000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', 'T', '2028-01-01') returning 'ok'$f$, (select staff from who where label = 'm2')));
select pg_temp.run('b.regrant', 'sa', format($f$insert into public.membership_scopes (membership_id, platform_tenant_id, scope_type, school_id)
  values (%L, '10000000-0000-0000-0000-000000000001', 'school', '5a000000-0000-0000-0000-000000000001') returning 'ok'$f$, (select membership from who where label = 'm2')));

-- ============ C. الهدف يحمل دوراً أعلى من الفاعل؛ والسنة المغلقة ============
select pg_temp.run('c.end', 'sa', pg_temp.end_ssa('m3', 'SA', '2027-12-31', 'left'));
select pg_temp.rec('c.m3', $q$select pg_temp.state('m3')$q$);
select pg_temp.run('c.reassign', 'sa', format($f$insert into public.staff_school_assignments (staff_id, school_id, platform_tenant_id, job_title, effective_from)
  values (%L, '5a000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', 'T', '2028-01-01') returning 'ok'$f$, (select staff from who where label = 'm3')));
select pg_temp.run('c.regrant_refused', 'sa', format($f$insert into public.membership_scopes (membership_id, platform_tenant_id, scope_type, school_id)
  values (%L, '10000000-0000-0000-0000-000000000001', 'school', '5a000000-0000-0000-0000-000000000001') returning 'ok'$f$, (select membership from who where label = 'm3')));

-- ============ D. set_staff_status(ended) ============
select pg_temp.run('d.sa_refused', 'sa', pg_temp.set_status('m4', 'ended', 'resigned', '2027-12-31'));        -- تكليف نشط خارج نطاق sa — القاعدة القائمة
select pg_temp.rec('d.m4_untouched', $q$select pg_temp.state('m4')$q$);
select pg_temp.rec('d.rows_before', format($f$select (select count(*) from public.membership_roles where membership_id = %1$L) || '/' || (select count(*) from public.membership_scopes where membership_id = %1$L)$f$, (select membership from who where label = 'm4')));
select pg_temp.run('d.ta_end', 'ta', pg_temp.set_status('m4', 'ended', 'resigned', '2027-12-31'));
select pg_temp.rec('d.m4', $q$select pg_temp.state('m4')$q$);
select pg_temp.rec('d.rows_after', format($f$select (select count(*) from public.membership_roles where membership_id = %1$L) || '/' || (select count(*) from public.membership_scopes where membership_id = %1$L)$f$, (select membership from who where label = 'm4')));
select pg_temp.rec('d.staff', $q$select status from public.staff where employee_code = 'm4'$q$);
select pg_temp.run('d.m4_dead', 'm4', $q$select app.has_permission('staff.read')::text || '/' || app.can_access_school('5a000000-0000-0000-0000-000000000001')::text || '/' || app.can_access_school('5b000000-0000-0000-0000-000000000002')::text$q$);
select pg_temp.run('d.archive', 'ta', pg_temp.set_status('m4', 'archived', 'archive'));

-- ============ E. on_leave لا أثر ============
select pg_temp.rec('e.before', $q$select pg_temp.state('m5')$q$);
select pg_temp.run('e.leave', 'sa', pg_temp.set_status('m5', 'on_leave', 'medical'));
select pg_temp.rec('e.on_leave', $q$select pg_temp.state('m5')$q$);
select pg_temp.run('e.back', 'sa', pg_temp.set_status('m5', 'active', 'back'));
select pg_temp.rec('e.back_state', $q$select pg_temp.state('m5')$q$);

-- ============ F. بلا حساب ============
select pg_temp.run('f.end', 'sa', pg_temp.end_ssa('m6', 'SA', '2027-12-31', 'left'));
select pg_temp.rec('f.m6', $q$select pg_temp.state('m6')$q$);

-- ============ العقد القائم لم يتغير ============
select pg_temp.run('k.no_reason', 'sa', pg_temp.end_ssa('m5', 'SA', '2027-12-31', ' '));
select pg_temp.run('k.sb',        'sb', pg_temp.end_ssa('m5', 'SA', '2027-12-31', 'r'));
select pg_temp.run('k.date',      'sa', pg_temp.end_ssa('m5', 'SA', '2025-09-01', 'r'));
select pg_temp.rec('k.m5_intact', $q$select pg_temp.state('m5')$q$);

select plan(5 + 7 + 5 + 9 + 3 + 2 + 4 + 6);

-- A
select is((select v from r where k = 'before.m1'),
          'ssa[SA:active,SB:active] teach[SA:planned:active,SB:planned:active] class[SA:active,SB:active] scopes[SA,SB] roles[teacher] membership[active]', 'fixture: staff in two schools');
select is((select v from r where k = 'a.end_sa'), '', 'school admin SA ends the SA school assignment');
select is((select v from r where k = 'a.m1'),
          'ssa[SA:ended,SB:active] teach[SA:planned:ended@2027-09-01,SB:planned:active] class[SA:ended,SB:active] scopes[SB] roles[teacher] membership[active]',
          'P10: only SA''s teaching and class-teacher assignments end (end date clamped to their start), only SA''s scope is removed — SB, the role and the membership are untouched');
select is((select v from r where k = 'a.m1_reach'), 'false/true', 'the staff member loses SA and keeps SB at once');
select is((select v from r where k = 'a.end_sa#ctx'), '|', 'the audit context is cleared');

-- B
select is((select v from r where k = 'b.end_first'), '', 'one of two active assignments in the same school is ended');
select is((select v from r where k = 'b.m2_one_left'),
          'ssa[SA:ended,SA:active] teach[SA:planned:active] class[SA:active] scopes[SA] roles[teacher] membership[active]',
          'another active assignment in that school remains → nothing is cascaded, the scope stays');
select is((select v from r where k = 'b.m2_none_left'),
          'ssa[SA:ended,SA:ended] teach[SA:planned:ended@2027-11-01] class[SA:ended] scopes[] roles[teacher] membership[active]',
          'the last one ends → cascade and scope removal; the role stays and the membership is NOT ended (T11)');
select is((select v from r where k = 'b.m2_perm'), 'true/false', 'a role without a scope reaches no school');
select is((select v from r where k = 'b.reassign'), 'ok', 'the staff member is assigned to the school again');
select is((select v from r where k = 'b.regrant'),  'ok', '…and the school admin grants the scope again (M47 first-grant door) — the account survived');
select is((select count(*)::int from public.memberships where id = (select membership from who where label = 'm2') and status = 'active'), 1, 'the membership was never ended by a partial end');

-- C
select is((select v from r where k = 'c.end'), '', 'a school admin ends the assignment of someone holding a higher role (no T8 on scope removal)');
select is((select v from r where k = 'c.m3'),
          'ssa[SA:ended] teach[SA:closed:active,SA:planned:ended@2027-12-31] class[SA:ended] scopes[] roles[tenant_admin] membership[active]',
          'the scope is removed, the role is NOT (T11); the closed year''s assignment is untouched (T7)');
select is((select v from r where k = 'c.reassign'), 'ok', 'reassigned to the school');
select ok((select v from r where k = 'c.regrant_refused') like 'ERR 42501%T8: scope grant would enable permissions the actor does not hold%',
          'T8 unchanged: the school admin cannot re-scope a membership holding a higher role');
select is((select pg_get_triggerdef(t.oid) ~ 'AFTER INSERT ON public.membership_scopes' from pg_trigger t where t.tgrelid = 'public.membership_scopes'::regclass and t.tgname = 'authz_integrity'), true,
          'tg_authz_integrity still fires on scope INSERT only — M49 added no T8 exemption');

-- D
select ok((select v from r where k = 'd.sa_refused') like 'ERR 23514%active assignments outside the actor''s scope%', 'existing rule kept: a school admin cannot end staff active in another school');
select is((select v from r where k = 'd.m4_untouched'),
          'ssa[SA:active,SB:active] teach[SA:planned:active,SB:planned:active] class[SA:active,SB:active] scopes[SA,SB] roles[teacher] membership[active]', 'the refusal left nothing behind');
select is((select v from r where k = 'd.ta_end'), '', 'tenant admin ends the staff member');
select is((select v from r where k = 'd.m4'),
          'ssa[SA:ended,SB:ended] teach[SA:planned:ended@2027-12-31,SB:planned:ended@2027-12-31] class[SA:ended,SB:ended] scopes[SA,SB] roles[teacher] membership[ended]',
          'P10: every assignment in every school ends; the membership is ended and its scope and role rows are kept');
select is((select v from r where k = 'd.rows_after'), (select v from r where k = 'd.rows_before'), 'no role or scope row was deleted by the global end');
select is((select v from r where k = 'd.staff'), 'ended', 'the staff member is ended');
select is((select v from r where k = 'd.m4_dead'), 'false/false/false', 'an ended membership grants nothing: no permission, no school');
select is((select v from r where k = 'd.archive'), '', 'ended → archived still works');
select is((select v from r where k = 'd.ta_end#ctx'), '|', 'the audit context is cleared');

-- E
select is((select v from r where k = 'e.leave') || (select v from r where k = 'e.back'), '', 'active ↔ on_leave');
select is((select v from r where k = 'e.on_leave'), (select v from r where k = 'e.before'), 'on_leave ends nothing and revokes nothing (Q4)');
select is((select v from r where k = 'e.back_state'), (select v from r where k = 'e.before'), 'back to active: everything as it was');

-- F
select is((select v from r where k = 'f.end'), '', 'a staff member without an account: the cascade simply has no membership to touch');
select is((select v from r where k = 'f.m6'), 'ssa[SA:ended] teach[SA:planned:ended@2027-12-31] class[SA:ended] scopes[] roles[] membership[-]', 'their assignments end all the same');

-- العقد القائم
select ok((select v from r where k = 'k.no_reason') like 'ERR 22023%reason required%',                       'M21 contract kept: reason required');
select ok((select v from r where k = 'k.sb')        like 'ERR P0002%not found%',                             'M21 contract kept: another school finds nothing');
select ok((select v from r where k = 'k.date')      like 'ERR 22023%effective_to must be after effective_from%', 'M21 contract kept: the date rule and its message');
select is((select v from r where k = 'k.m5_intact'), (select v from r where k = 'e.before'), 'refusals leave no trace');

-- التدقيق
select is((select string_agg(distinct a.reason, ',') from public.audit_log a where a.entity_type = 'membership_scopes' and a.action = 'delete'), 'left,left SA',
          'T7: each removed scope is audited (delete) with the lifecycle reason');
select is((select count(*)::int from public.audit_log a where a.entity_type = 'membership_scopes' and a.action = 'delete' and a.actor_type = 'tenant_user' and a.old_values is not null and a.new_values is null), 3,
          '…under the acting user, with the old row kept (m1, m2, m3)');
select is((select a.action || '/' || a.reason from public.audit_log a where a.entity_type = 'memberships' and a.entity_id = (select membership::text from who where label = 'm4') order by a.id desc limit 1),
          'end/resigned', 'T7: the membership end is audited with the reason');
select is((select count(*)::int from public.audit_log a where a.entity_type in ('teaching_assignments', 'class_teacher_assignments') and a.action = 'end' and a.reason = 'resigned'), 4,
          'T7: the four cascaded endings of the global end carry its reason');
select is((select count(*)::int from public.audit_log a where a.entity_type = 'membership_roles' and a.action in ('delete', 'revoke')), 0, 'no role row was ever removed by the lifecycle');
select is((select string_agg(p.oid::regprocedure::text, ',' order by 1) from pg_proc p where p.pronamespace = 'app'::regnamespace and p.proname in ('set_staff_status', 'end_staff_assignment')),
          'app.end_staff_assignment(uuid,date,text),app.set_staff_status(uuid,text,text,date)', 'signatures unchanged (create or replace)');

select * from finish();
rollback;
