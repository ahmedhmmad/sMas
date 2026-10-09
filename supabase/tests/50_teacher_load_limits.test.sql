-- M52 — teacher_load_limits (Phase 3A / 3-5): القيود بأسمائها، RLS (staff.assign + النطاق، أو صف الفاعل — لا staff.read)،
-- T18 قاعدةً قاعدة وعلى كل مسار، لا DELETE، التدقيق، و L7: النصاب لا يمنع التكليف (T17 بنصّه).
begin;

create temp table r (k text primary key, v text) on commit drop;
grant all on r to public;
create temp table actors (label text primary key, auth uuid) on commit drop;
grant select on actors to public;
create temp table lbl (id uuid primary key, label text) on commit drop;       -- أسماء مرئية للجميع: لا join على جدول محمي
grant select on lbl to public;

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

-- p_reason: ما يضعه الـAPI في app.audit_reason داخل معاملة الكتابة (C3)؛ NULL = بلا سبب
create function pg_temp.run(p_key text, p_label text, p_sql text, p_reason text default null) returns void
language plpgsql as $$
declare v_sub uuid := (select auth from actors where label = p_label);
begin
  perform set_config('request.jwt.claims', json_build_object('sub', v_sub, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', v_sub::text, true);
  perform set_config('app.audit_reason', coalesce(p_reason, ''), true);
  execute 'set local role authenticated';
  perform pg_temp.rec(p_key, p_sql);
  execute 'reset role';
  perform set_config('app.audit_reason', '', true);
end $$;

-- ============ Fixture ============
insert into public.platform_tenants (id, tenant_code, host_label, name) values
  ('10000000-0000-0000-0000-000000000001', 'T1', 't1', 'T1'), ('20000000-0000-0000-0000-000000000002', 'T2', 't2', 'T2');
insert into public.groups (id, platform_tenant_id, group_code, name) values ('a1000000-0000-0000-0000-00000000000a', '10000000-0000-0000-0000-000000000001', 'GA', 'GA');
insert into public.schools (id, platform_tenant_id, group_id, school_code, name, slug) values
  ('5a000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', 'a1000000-0000-0000-0000-00000000000a', 'SA', 'SA', 'sa'),
  ('5b000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001', 'a1000000-0000-0000-0000-00000000000a', 'SB', 'SB', 'sb'),
  ('5c000000-0000-0000-0000-000000000003', '20000000-0000-0000-0000-000000000002', null,                                   'SX', 'SX', 'sx');
-- SA: yC (تُغلق)، yA (نشطة)، yP (planned)؛ SB: yB؛ SX: yX
insert into public.academic_years (id, school_id, name, start_date, end_date) values
  ('c0000000-0000-0000-0000-000000000001', '5a000000-0000-0000-0000-000000000001', 'yC', '2025-09-01', '2026-06-30'),
  ('a0000000-0000-0000-0000-000000000002', '5a000000-0000-0000-0000-000000000001', 'yA', '2026-09-01', '2027-06-30'),
  ('b0000000-0000-0000-0000-000000000003', '5a000000-0000-0000-0000-000000000001', 'yP', '2027-09-01', '2028-06-30'),
  ('bb000000-0000-0000-0000-000000000004', '5b000000-0000-0000-0000-000000000002', 'yB', '2027-09-01', '2028-06-30'),
  ('cc000000-0000-0000-0000-000000000005', '5c000000-0000-0000-0000-000000000003', 'yX', '2027-09-01', '2028-06-30');
insert into lbl select id, name from public.academic_years;
insert into public.stages (id, school_id, name, sequence_no) values ('51000000-0000-0000-0000-000000000001', '5a000000-0000-0000-0000-000000000001', 'P', 1);
insert into public.grade_levels (id, school_id, stage_id, name, sequence_no) values
  ('61000000-0000-0000-0000-000000000001', '5a000000-0000-0000-0000-000000000001', '51000000-0000-0000-0000-000000000001', 'G1', 1);
insert into public.sections (id, school_id, academic_year_id, grade_level_id, name) values
  ('5ec00000-0000-0000-0000-0000000000a1', '5a000000-0000-0000-0000-000000000001', 'b0000000-0000-0000-0000-000000000003', '61000000-0000-0000-0000-000000000001', 'P1');
insert into public.subjects (id, school_id, subject_code, name) values
  ('5e000000-0000-0000-0000-000000000001', '5a000000-0000-0000-0000-000000000001', 'AR', 'Arabic'),
  ('5e000000-0000-0000-0000-000000000002', '5a000000-0000-0000-0000-000000000001', 'MA', 'Math');
insert into public.grade_subjects (school_id, academic_year_id, grade_level_id, subject_id, weekly_periods) values
  ('5a000000-0000-0000-0000-000000000001', 'b0000000-0000-0000-0000-000000000003', '61000000-0000-0000-0000-000000000001', '5e000000-0000-0000-0000-000000000001', 5),
  ('5a000000-0000-0000-0000-000000000001', 'b0000000-0000-0000-0000-000000000003', '61000000-0000-0000-0000-000000000001', '5e000000-0000-0000-0000-000000000002', 4);

-- حساب بدور ونطاق مدرسة (أو نطاق Tenant حين p_school فارغ و p_tenant_scope)
create function pg_temp.account(p_label text, p_role text, p_school_code text, p_auth uuid default gen_random_uuid(), p_tenant_scope boolean default false) returns uuid
language plpgsql as $$
declare v_p uuid; v_m uuid; v_s public.schools%rowtype;
begin
  select * into v_s from public.schools where school_code = p_school_code;
  insert into auth.users (id, email) values (p_auth, p_label || '@m52.invalid');
  insert into public.auth_identities (auth_user_id, kind) values (p_auth, 'tenant');
  insert into public.profiles (platform_tenant_id, auth_user_id, display_name) values (v_s.platform_tenant_id, p_auth, p_label) returning id into v_p;
  insert into public.memberships (platform_tenant_id, profile_id) values (v_s.platform_tenant_id, v_p) returning id into v_m;
  insert into public.membership_roles (membership_id, role_id, platform_tenant_id, role_owner_key)
    select v_m, ro.id, v_s.platform_tenant_id, ro.owner_key from public.roles ro where ro.code = p_role and ro.platform_tenant_id is null;
  if p_tenant_scope then
    insert into public.membership_scopes (membership_id, platform_tenant_id, scope_type) values (v_m, v_s.platform_tenant_id, 'tenant');
  else
    insert into public.membership_scopes (membership_id, platform_tenant_id, scope_type, school_id) values (v_m, v_s.platform_tenant_id, 'school', v_s.id);
  end if;
  insert into actors values (p_label, p_auth);
  return v_p;
end $$;
select pg_temp.account('sa',   'school_admin', 'SA');
select pg_temp.account('sbad', 'school_admin', 'SB');
select pg_temp.account('xad',  'school_admin', 'SX');
select pg_temp.account('ta',   'tenant_admin', 'SA', p_tenant_scope => true);
select pg_temp.account('sec',  'secretary',    'SA');

-- موظف (بحساب معلم اختيارياً) بتكليف مدرسة
create function pg_temp.staff(p_label text, p_school_code text, p_account boolean default false, p_assignment text default 'active') returns void
language plpgsql as $$
declare v_id uuid := gen_random_uuid(); v_p uuid; v_s public.schools%rowtype;
begin
  select * into v_s from public.schools where school_code = p_school_code;
  if p_account then v_p := pg_temp.account(p_label, 'teacher', p_school_code, v_id); end if;
  insert into public.staff (id, platform_tenant_id, profile_id, employee_code, first_name, family_name) values (v_id, v_s.platform_tenant_id, v_p, p_label, 'S', p_label);
  if p_assignment = 'active' then
    insert into public.staff_school_assignments (staff_id, school_id, platform_tenant_id, job_title, effective_from) values (v_id, v_s.id, v_s.platform_tenant_id, 'T', '2025-09-01');
  elsif p_assignment = 'ended' then
    insert into public.staff_school_assignments (staff_id, school_id, platform_tenant_id, job_title, effective_from, status, effective_to)
      values (v_id, v_s.id, v_s.platform_tenant_id, 'T', '2024-09-01', 'ended', '2025-06-30');
  end if;
  insert into lbl values (v_id, p_label);
end $$;
select pg_temp.staff('e1', 'SA', true);
select pg_temp.staff('e2', 'SA', true);
select pg_temp.staff('e3', 'SA');
select pg_temp.staff('e4', 'SA');
select pg_temp.staff('eOld', 'SA', false, 'ended');       -- تكليف مدرسته منتهٍ
select pg_temp.staff('eNone', 'SA', false, 'none');       -- لا تكليف مدرسة إطلاقاً
select pg_temp.staff('eB', 'SB', true);
select pg_temp.staff('eX', 'SX', true);

create function pg_temp.sid(p text) returns uuid language sql as $$ select id from lbl where label = p $$;
-- الإدراج كما يفعله الـAPI: الـTenant والمدرسة من صف المدرسة (مدرسة السنة ما لم تُحدَّد أخرى لاختبار الرفض)
create function pg_temp.ins(p_staff text, p_year text, p_max text, p_school text default null) returns text language sql as $$
  -- القيم حرفية (تُحسب هنا لا تحت RLS الفاعل): الرفض يأتي من السياسة أو القيد أو الحارس، لا من صف مدرسة غير مرئي
  select format($f$insert into public.teacher_load_limits (platform_tenant_id, school_id, academic_year_id, staff_id, max_weekly_periods)
                   values (%L, %L, %L, %L, %s) returning 'ok'$f$, sc.platform_tenant_id, sc.id, pg_temp.sid(p_year), pg_temp.sid(p_staff), p_max)
    from public.schools sc
   where sc.id = coalesce((select id from public.schools where school_code = p_school), (select school_id from public.academic_years where id = pg_temp.sid(p_year)))
$$;
create function pg_temp.limits(p_key text, p_actor text) returns void language sql as $$
  select pg_temp.run(p_key, p_actor, $q$select coalesce(string_agg(ls.label || '@' || ly.label || ':' || coalesce(t.max_weekly_periods::text, 'none'), ',' order by ly.label, ls.label), '')
                                        from public.teacher_load_limits t join lbl ls on ls.id = t.staff_id join lbl ly on ly.id = t.academic_year_id$q$)
$$;

-- ---------- القيود الإعلانية (كـpostgres؛ السنة planned فلا سبب مطلوب) ----------
select pg_temp.rec('c.zero',    pg_temp.ins('e1', 'yP', '0'));
select pg_temp.rec('c.over',    pg_temp.ins('e1', 'yP', '101'));
select pg_temp.rec('c.one',     pg_temp.ins('e3', 'yP', '1'));
select pg_temp.rec('c.hundred', pg_temp.ins('e4', 'yP', '100'));
select pg_temp.rec('c.null',    pg_temp.ins('e1', 'yP', 'null'));
select pg_temp.rec('c.dup',     pg_temp.ins('e1', 'yP', '9'));
select pg_temp.rec('c.year_fk', pg_temp.ins('eB', 'yP', '5', 'SB'));          -- سنة SA مع مدرسة SB (لـeB تكليف نشط في SB، فالحارس يمر)
-- FKا الـTenant: الحارس يسبقهما (لا تكليف مدرسة عبر الـTenant) — يُختبران باسميهما والحارس معطَّل داخل المعاملة
alter table public.teacher_load_limits disable trigger guard;
select pg_temp.rec('c.staff_fk', format($q$insert into public.teacher_load_limits (platform_tenant_id, school_id, academic_year_id, staff_id)
  values ('10000000-0000-0000-0000-000000000001', '5a000000-0000-0000-0000-000000000001', %L, %L) returning 'ok'$q$, pg_temp.sid('yP'), pg_temp.sid('eX')));
select pg_temp.rec('c.school_fk', format($q$insert into public.teacher_load_limits (platform_tenant_id, school_id, academic_year_id, staff_id)
  values ('20000000-0000-0000-0000-000000000002', '5a000000-0000-0000-0000-000000000001', %L, %L) returning 'ok'$q$, pg_temp.sid('yP'), pg_temp.sid('eX')));
alter table public.teacher_load_limits enable trigger guard;

-- ---------- بيانات القراءة: e1@yP بلا حد (أعلاه)، e3، e4؛ + e2@yP، eB@yB، eX@yX، e1@yC (قبل الإغلاق) ----------
select pg_temp.rec('f.e2', pg_temp.ins('e2', 'yP', '8'));
select pg_temp.rec('f.eB', pg_temp.ins('eB', 'yB', '6'));
select pg_temp.rec('f.eX', pg_temp.ins('eX', 'yX', '7'));
select pg_temp.rec('f.e1c', pg_temp.ins('e1', 'yC', '12'));
update public.academic_years set status = 'active' where id = 'c0000000-0000-0000-0000-000000000001';
update public.academic_years set status = 'closed' where id = 'c0000000-0000-0000-0000-000000000001';
update public.academic_years set status = 'active' where id = 'a0000000-0000-0000-0000-000000000002';

select pg_temp.limits('read.' || a, a) from unnest(array['sa', 'sbad', 'xad', 'ta', 'sec', 'e1', 'e2', 'eB', 'eX']) a;
-- فرع الذات للموظف active وحده
update public.staff set status = 'on_leave' where employee_code = 'e2';
select pg_temp.limits('read.e2_leave', 'e2');
update public.staff set status = 'active' where employee_code = 'e2';

-- ---------- الكتابة تحت RLS ----------
select pg_temp.run('w.sa_update',     'sa',   format($q$with u as (update public.teacher_load_limits set max_weekly_periods = 10 where staff_id = %L and academic_year_id = %L returning 1) select count(*)::text from u$q$, pg_temp.sid('e1'), pg_temp.sid('yP')));
select pg_temp.run('w.sa_clear',      'sa',   format($q$with u as (update public.teacher_load_limits set max_weekly_periods = null where staff_id = %L and academic_year_id = %L returning 1) select count(*)::text from u$q$, pg_temp.sid('e3'), pg_temp.sid('yP')));
select pg_temp.run('w.ta_update',     'ta',   format($q$with u as (update public.teacher_load_limits set max_weekly_periods = 30 where staff_id = %L returning 1) select count(*)::text from u$q$, pg_temp.sid('eB')));
select pg_temp.run('w.sec_insert',    'sec',  pg_temp.ins('e2', 'yA', '5'), 'r');
select pg_temp.run('w.tch_insert',    'e1',   pg_temp.ins('e1', 'yA', '5'), 'r');
select pg_temp.run('w.sa_other',      'sa',   pg_temp.ins('eB', 'yB', '5'));                 -- مدرسة خارج نطاقه (والصف موجود — الرفض بالسياسة قبل التفرد)
select pg_temp.run('w.sbad_in_sa',    'sbad', pg_temp.ins('e4', 'yA', '5'), 'r');
select pg_temp.run('w.xad_in_t1',     'xad',  pg_temp.ins('e4', 'yA', '5'), 'r');
select pg_temp.run('w.tch_own',       'e1',   format($q$with u as (update public.teacher_load_limits set max_weekly_periods = 99 where staff_id = %L returning 1) select count(*)::text from u$q$, pg_temp.sid('e1')));
select pg_temp.run('w.tch_blind',     'e1',   $q$with u as (update public.teacher_load_limits set max_weekly_periods = 99) select 'done'$q$);
select pg_temp.run('w.sec_blind',     'sec',  $q$with u as (update public.teacher_load_limits set max_weekly_periods = 98) select 'done'$q$);
select pg_temp.run('w.sbad_blind',    'sbad', $q$with u as (update public.teacher_load_limits set max_weekly_periods = 97) select 'done'$q$);
select pg_temp.rec('w.blind_result', $q$select coalesce(string_agg(ls.label || '@' || ly.label || ':' || t.max_weekly_periods, ',' order by ly.label, ls.label), '')
                                        from public.teacher_load_limits t join lbl ls on ls.id = t.staff_id join lbl ly on ly.id = t.academic_year_id where t.max_weekly_periods in (97, 98, 99)$q$);
select pg_temp.run('w.delete',        'sa',   $q$with d as (delete from public.teacher_load_limits returning 1) select count(*)::text from d$q$);
select pg_temp.run('w.col_staff',     'sa',   format($q$update public.teacher_load_limits set staff_id = %L where staff_id = %L$q$, pg_temp.sid('e4'), pg_temp.sid('e3')));
select pg_temp.run('w.col_insert_id', 'sa',   $q$insert into public.teacher_load_limits (id, platform_tenant_id, school_id, academic_year_id, staff_id) values (gen_random_uuid(), null, null, null, null)$q$);

-- ---------- T18 ----------
select pg_temp.run('g.active_noreason', 'sa', pg_temp.ins('e1', 'yA', '20'));
select pg_temp.run('g.active_reason',   'sa', pg_temp.ins('e1', 'yA', '20'), 'new timetable');
select pg_temp.run('g.active_upd_noreason', 'sa', format($q$with u as (update public.teacher_load_limits set max_weekly_periods = 21 where staff_id = %L and academic_year_id = %L returning 1) select count(*)::text from u$q$, pg_temp.sid('e1'), pg_temp.sid('yA')));
select pg_temp.run('g.active_upd_reason',   'sa', format($q$with u as (update public.teacher_load_limits set max_weekly_periods = 21 where staff_id = %L and academic_year_id = %L returning 1) select count(*)::text from u$q$, pg_temp.sid('e1'), pg_temp.sid('yA')), 'adjusted');
select pg_temp.rec('g.active_postgres', pg_temp.ins('e2', 'yA', '20'));                       -- المسار المميّز بلا سبب
select pg_temp.run('g.closed_insert', 'sa', pg_temp.ins('e2', 'yC', '5'), 'r');
select pg_temp.run('g.closed_update', 'sa', format($q$update public.teacher_load_limits set max_weekly_periods = 1 where academic_year_id = %L returning 'ok'$q$, pg_temp.sid('yC')), 'r');
select pg_temp.rec('g.closed_postgres', format($q$update public.teacher_load_limits set max_weekly_periods = 1 where academic_year_id = %L returning 'ok'$q$, pg_temp.sid('yC')));
select pg_temp.rec('g.identity_staff', format($q$update public.teacher_load_limits set staff_id = %L where staff_id = %L and academic_year_id = %L returning 'ok'$q$, pg_temp.sid('e4'), pg_temp.sid('e2'), pg_temp.sid('yP')));
select pg_temp.rec('g.identity_year',  format($q$update public.teacher_load_limits set academic_year_id = %L where staff_id = %L and academic_year_id = %L returning 'ok'$q$, pg_temp.sid('yA'), pg_temp.sid('e3'), pg_temp.sid('yP')));
select pg_temp.run('g.no_assignment',    'sa', pg_temp.ins('eNone', 'yP', '5'));
select pg_temp.run('g.ended_assignment', 'sa', pg_temp.ins('eOld', 'yP', '5'));
select pg_temp.rec('g.other_school_assignment', pg_temp.ins('eB', 'yP', '5'));                 -- تكليفه النشط في SB لا في مدرسة السنة
-- الحد إعداد: تعديله لا يشترط حالة الموظف
update public.staff set status = 'on_leave' where employee_code = 'e4';
select pg_temp.run('g.update_on_leave', 'sa', format($q$with u as (update public.teacher_load_limits set max_weekly_periods = 15 where staff_id = %L returning 1) select count(*)::text from u$q$, pg_temp.sid('e4')));

-- ---------- L7: النصاب لا يمنع التكليف ----------
select pg_temp.run('l7.limit', 'sa', format($q$with u as (update public.teacher_load_limits set max_weekly_periods = 4 where staff_id = %L and academic_year_id = %L returning 1) select count(*)::text from u$q$, pg_temp.sid('e1'), pg_temp.sid('yP')));
create function pg_temp.assign(p_subject text) returns text language sql as $$
  select format($f$insert into public.teaching_assignments (platform_tenant_id, school_id, academic_year_id, grade_level_id, section_id, subject_id, staff_id, effective_from)
    select '10000000-0000-0000-0000-000000000001', s.school_id, s.academic_year_id, s.grade_level_id, s.id, sb.id, %L, '2027-09-01'
      from public.sections s, public.subjects sb where s.id = '5ec00000-0000-0000-0000-0000000000a1' and sb.subject_code = %L and sb.school_id = s.school_id returning 'ok'$f$, pg_temp.sid('e1'), p_subject)
$$;
select pg_temp.run('l7.first',  'sa', pg_temp.assign('AR'));       -- 5 > 4
select pg_temp.run('l7.second', 'sa', pg_temp.assign('MA'));       -- 9 > 4
select pg_temp.rec('l7.load', format($q$select sum(gs.weekly_periods)::text || '>' || (select max_weekly_periods from public.teacher_load_limits where staff_id = %1$L and academic_year_id = %2$L)
  from public.teaching_assignments t join public.grade_subjects gs on gs.academic_year_id = t.academic_year_id and gs.grade_level_id = t.grade_level_id and gs.subject_id = t.subject_id
 where t.staff_id = %1$L and t.academic_year_id = %2$L and t.status = 'active'$q$, pg_temp.sid('e1'), pg_temp.sid('yP')));

select plan(9 + 10 + 14 + 14 + 3 + 9);

-- ---------- القيود ----------
select ok((select v from r where k = 'c.zero') like 'ERR 23514%teacher_load_limits_max_chk%', 'max_chk: 0 is rejected by name');
select ok((select v from r where k = 'c.over') like 'ERR 23514%teacher_load_limits_max_chk%', 'max_chk: 101 is rejected by name');
select is((select v from r where k = 'c.one') || (select v from r where k = 'c.hundred') || (select v from r where k = 'c.null'), 'okokok', 'the bounds 1 and 100 and NULL (no limit) are accepted');
select ok((select v from r where k = 'c.dup') like 'ERR 23505%teacher_load_limits_year_staff_uq%', 'one row per (year, staff) — by name');
select ok((select v from r where k = 'c.year_fk') like 'ERR 23503%teacher_load_limits_year_fk%', 'year_fk: a year of another school is rejected by name');
select ok((select v from r where k = 'c.staff_fk') like 'ERR 23503%teacher_load_limits_staff_fk%', 'staff_fk: a staff member of another tenant is rejected by name (guard disabled for this check)');
select ok((select v from r where k = 'c.school_fk') like 'ERR 23503%teacher_load_limits_school_fk%', 'school_fk: a school under another tenant is rejected by name (guard disabled for this check)');
select is((select string_agg(v, '') from r where k in ('f.e2', 'f.eB', 'f.eX', 'f.e1c')), 'okokokok', 'fixture rows inserted');
select is((select string_agg(a.attname, ',' order by a.attnum) from pg_attribute a where a.attrelid = 'public.teacher_load_limits'::regclass and a.attnum > 0 and not a.attisdropped),
          'id,platform_tenant_id,school_id,academic_year_id,staff_id,max_weekly_periods,created_at,created_by,updated_at,updated_by',
          'the table stores the limit only — no workload column anywhere (L2)');

-- ---------- القراءة ----------
select is((select v from r where k = 'read.sa'),   'e1@yC:12,e1@yP:none,e2@yP:8,e3@yP:1,e4@yP:100', 'school admin (staff.assign + SA scope): every limit of its school, the closed year included');
select is((select v from r where k = 'read.sbad'), 'eB@yB:6', 'another school''s admin: its own school only');
select is((select v from r where k = 'read.xad'),  'eX@yX:7', 'another tenant''s admin: its own tenant only');
select is((select v from r where k = 'read.ta'),   'eB@yB:6,e1@yC:12,e1@yP:none,e2@yP:8,e3@yP:1,e4@yP:100', 'tenant admin: every school of the tenant, never T2');
select is((select v from r where k = 'read.sec'),  '', 'secretary (no staff.assign, not staff): nothing');
select is((select v from r where k = 'read.e1'),   'e1@yC:12,e1@yP:none', 'L5: a teacher reads its OWN limits only — not its colleagues'' (staff.read does not open them)');
select is((select v from r where k = 'read.e2'),   'e2@yP:8', '…each teacher its own');
select is((select v from r where k = 'read.eB') || '|' || (select v from r where k = 'read.eX'), 'eB@yB:6|eX@yX:7', '…in another school and another tenant too');
select is((select v from r where k = 'read.e2_leave'), '', 'the self branch is for an ACTIVE staff member: on leave reads nothing');
select is((select count(*)::int from pg_policies where tablename = 'teacher_load_limits' and (qual ~ 'staff\.read' or with_check ~ 'staff\.read')), 0, 'no policy on the table mentions staff.read');

-- ---------- الكتابة ----------
select is((select v from r where k = 'w.sa_update') || (select v from r where k = 'w.sa_clear') || (select v from r where k = 'w.ta_update'), '111', 'school admin sets and clears (NULL) a limit; tenant admin writes in SB');
select ok((select v from r where k = 'w.sec_insert') like 'ERR 42501%row-level security%', 'secretary cannot insert (no staff.assign)');
select ok((select v from r where k = 'w.tch_insert') like 'ERR 42501%row-level security%', 'a teacher cannot set its own limit (staff.read is not staff.assign)');
select ok((select v from r where k = 'w.sa_other') like 'ERR 42501%row-level security%', 'school admin cannot insert for another school');
select ok((select v from r where k = 'w.sbad_in_sa') like 'ERR 42501%row-level security%', 'SB admin cannot insert in SA');
select ok((select v from r where k = 'w.xad_in_t1') like 'ERR 42501%row-level security%', 'another tenant''s admin cannot insert in T1');
select is((select v from r where k = 'w.tch_own'), '0', 'a teacher''s targeted UPDATE of its own visible row changes nothing (SELECT by self ≠ UPDATE)');
select is((select v from r where k = 'w.tch_blind') || (select v from r where k = 'w.sec_blind') || (select v from r where k = 'w.sbad_blind'), 'donedonedone', 'the blind updates ran');
select is((select v from r where k = 'w.blind_result'), 'eB@yB:97', 'blind UPDATE: teacher and secretary change nothing; SB admin changes SB only — the UPDATE policy carries the scope itself');
select ok((select v from r where k = 'w.delete') like 'ERR 42501%permission denied%', 'no DELETE for the client (removal is NULL — L3)');
select ok((select v from r where k = 'w.col_staff') like 'ERR 42501%permission denied%', 'UPDATE of any column but max_weekly_periods is not granted');
select ok((select v from r where k = 'w.col_insert_id') like 'ERR 42501%permission denied%', 'INSERT of id is not granted');
select is((select count(*)::int from pg_policies where tablename = 'teacher_load_limits'), 3, 'three policies: select, insert, update — no delete');
select ok((select relrowsecurity and relforcerowsecurity from pg_class where oid = 'public.teacher_load_limits'::regclass), 'RLS enabled and forced');

-- ---------- T18 ----------
select ok((select v from r where k = 'g.active_noreason') like 'ERR 22023%reason required%', 'active year: insert without a reason is refused (C3)');
select is((select v from r where k = 'g.active_reason'), 'ok', '…and accepted with one');
select ok((select v from r where k = 'g.active_upd_noreason') like 'ERR 22023%reason required%', 'active year: update without a reason is refused');
select is((select v from r where k = 'g.active_upd_reason'), '1', '…and accepted with one');
select ok((select v from r where k = 'g.active_postgres') like 'ERR 22023%reason required%', 'the reason is a DB invariant: the privileged path is refused too');
select ok((select v from r where k = 'g.closed_insert') like 'ERR 23514%closed%', 'closed year: no insert');
select ok((select v from r where k = 'g.closed_update') like 'ERR 23514%closed%', 'closed year: no update');
select ok((select v from r where k = 'g.closed_postgres') like 'ERR 23514%closed%', 'closed year: frozen on the privileged path too');
select ok((select v from r where k = 'g.identity_staff') like 'ERR 23514%cannot change its school, year or staff member%', 'identity: the staff member is fixed');
select ok((select v from r where k = 'g.identity_year') like 'ERR 23514%cannot change its school, year or staff member%', 'identity: the year is fixed');
select ok((select v from r where k = 'g.no_assignment') like 'ERR 23514%no active assignment in this school%', 'insert: a staff member with no school assignment is refused');
select ok((select v from r where k = 'g.ended_assignment') like 'ERR 23514%no active assignment in this school%', 'insert: an ended school assignment does not count');
select ok((select v from r where k = 'g.other_school_assignment') like 'ERR 23514%no active assignment in this school%', 'insert: an active assignment in another school does not count');
select is((select v from r where k = 'g.update_on_leave'), '1', 'the limit is a setting: updating it does not depend on the staff state');

-- ---------- التدقيق ----------
select is((select actor_type || '/' || reason from public.audit_log where entity_type = 'teacher_load_limits' and action = 'insert' and reason is not null order by id desc limit 1),
          'tenant_user/new timetable', 'T7: the insert is audited with the actor and the reason');
select is((select (old_values ->> 'max_weekly_periods') || '>' || (new_values ->> 'max_weekly_periods') || '/' || reason from public.audit_log
            where entity_type = 'teacher_load_limits' and action = 'update' and reason = 'adjusted'), '20>21/adjusted', 'T7: the update keeps old and new values');
select is((select count(*)::int from public.audit_log where entity_type = 'teacher_load_limits' and action = 'delete'), 0, 'nothing was ever deleted');

-- ---------- L7 والعقود ----------
select is((select v from r where k = 'l7.limit') || (select v from r where k = 'l7.first') || (select v from r where k = 'l7.second'), '1okok',
          'L7: with a limit of 4, assigning 5 and then 4 more periods both SUCCEED — the load never refuses an assignment');
select is((select v from r where k = 'l7.load'), '9>4', '…the derived load (9) is over the limit (4): a warning, nothing else');
select is((select md5(prosrc) from pg_proc where pronamespace = 'app'::regnamespace and proname = 'tg_teaching_assignment_guard'), '4d04ce3b294e284022da727733d808b9',
          'T17 is untouched by 3-5 (pinned hash of its source as of M48)');
select is((select count(*)::int from pg_proc p where p.pronamespace = 'app'::regnamespace and p.prosrc ~ 'teacher_load_limits' and p.proname <> 'tg_teacher_load_limit_guard'), 0,
          'no function in app reads the limits — not the assignment guard, not the end functions, not P5');
select is((select pg_get_userbyid(p.proowner) || '/' || p.prosecdef::text || '/' || has_function_privilege('authenticated', p.oid, 'EXECUTE')::text || '/' || has_function_privilege('anon', p.oid, 'EXECUTE')::text
             from pg_proc p where p.oid = 'app.tg_teacher_load_limit_guard()'::regprocedure), 'app_owner/true/false/false', 'T18: owned by app_owner, SECURITY DEFINER, no EXECUTE for API roles');
select is((select has_function_privilege('authenticated', 'app.current_staff_id()', 'EXECUTE')::text || '/' || has_function_privilege('anon', 'app.current_staff_id()', 'EXECUTE')::text),
          'true/false', 'current_staff_id (M50) is executable by authenticated — the self branch calls it — and never by anon');
select is((select count(*)::int from public.permissions), 79, 'no permission key added (catalog 79)');
select is((select count(*)::int from pg_trigger where tgrelid = 'public.teacher_load_limits'::regclass and not tgisinternal and tgenabled = 'O'), 3, 'stamp, audit and guard are attached and enabled');
select is((select count(*)::int from information_schema.columns where table_schema = 'public' and column_name ~ 'workload|load_total|weekly_load'), 0, 'no stored workload column in the schema');

select * from finish();
rollback;
