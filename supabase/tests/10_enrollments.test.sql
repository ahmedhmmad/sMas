-- M10 — enrollments: I38–I42، G3، G6، B6
-- كل تحقق رفض يطابق اسم القيد المقصود، ومع كل رفض ضابط إيجابي (CLAUDE.md).
-- استثناء موثق: I38 محتوى في G6، فالتسجيل النشط المكرر يُقبل رفضه من أيٍّ من القيدين (انظر رأس الـmigration).
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

create function pg_temp.mk_profile(p_tenant uuid, p_label text) returns uuid
language plpgsql as $$
declare v_auth uuid := gen_random_uuid(); v_profile uuid;
begin
  insert into auth.users (id, email) values (v_auth, p_label || '-' || v_auth || '@m10.invalid');
  insert into public.auth_identities values (v_auth, 'tenant');
  insert into public.profiles (platform_tenant_id, auth_user_id, display_name) values (p_tenant, v_auth, p_label) returning id into v_profile;
  return v_profile;
end $$;

-- ============ Fixture ============
-- T1: group GA (SA1, SA2)، group GB (SB1)، مستقلة SS — T2: مستقلة S2
insert into public.platform_tenants (id, tenant_code, name) values
  ('10000000-0000-0000-0000-000000000001', 'T1', 'T1'), ('20000000-0000-0000-0000-000000000002', 'T2', 'T2');
insert into public.groups (id, platform_tenant_id, group_code, name) values
  ('a1000000-0000-0000-0000-00000000000a', '10000000-0000-0000-0000-000000000001', 'GA', 'GA'),
  ('a2000000-0000-0000-0000-00000000000b', '10000000-0000-0000-0000-000000000001', 'GB', 'GB');
insert into public.schools (id, platform_tenant_id, group_id, school_code, name, slug) values
  ('5a100000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', 'a1000000-0000-0000-0000-00000000000a', 'SA1', 'SA1', 'sa1'),
  ('5a200000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001', 'a1000000-0000-0000-0000-00000000000a', 'SA2', 'SA2', 'sa2'),
  ('5b100000-0000-0000-0000-000000000003', '10000000-0000-0000-0000-000000000001', 'a2000000-0000-0000-0000-00000000000b', 'SB1', 'SB1', 'sb1'),
  ('55000000-0000-0000-0000-000000000004', '10000000-0000-0000-0000-000000000001', null, 'SS', 'SS', 'ss'),
  ('52000000-0000-0000-0000-000000000005', '20000000-0000-0000-0000-000000000002', null, 'S2', 'S2', 's2');

-- لكل مدرسة: سنة 2026/2027، مرحلة، صفّان G1 و G2، شعبة A لكل صف (المعرّفات مشتقة بالحساب)
create temp table ctx (school uuid primary key, year uuid, stage uuid, g1 uuid, g2 uuid, sec_g1 uuid, sec_g2 uuid) on commit drop;
insert into ctx select s.id, gen_random_uuid(), gen_random_uuid(), gen_random_uuid(), gen_random_uuid(), gen_random_uuid(), gen_random_uuid() from public.schools s;
insert into public.academic_years (id, school_id, name, start_date, end_date, status) select year, school, '2026/2027', '2026-09-01', '2027-06-30', 'active' from ctx;
insert into public.stages (id, school_id, name, sequence_no) select stage, school, 'Primary', 1 from ctx;
insert into public.grade_levels (id, school_id, stage_id, name, sequence_no)
  select g1, school, stage, 'G1', 1 from ctx union all select g2, school, stage, 'G2', 2 from ctx;
insert into public.sections (id, school_id, academic_year_id, grade_level_id, name)
  select sec_g1, school, year, g1, 'A' from ctx union all select sec_g2, school, year, g2, 'A' from ctx;
grant select on ctx to public;

create function pg_temp.scope_group(g uuid)  returns uuid language sql as $$ select id from public.identity_scopes where group_id = g $$;
create function pg_temp.scope_school(s uuid) returns uuid language sql as $$ select id from public.identity_scopes where school_id = s $$;
create function pg_temp.owner(s uuid) returns uuid language sql as $$ select scope_owner_id from public.schools where id = s $$;

-- طلاب: stA (نطاق GA)، stB (نطاق GA)، stS (نطاق SS)، st2 (T2، نطاق S2)
insert into public.students (id, platform_tenant_id, identity_scope_id, student_profile_id, official_id, official_id_type, first_name, family_name) values
  ('7a000000-0000-0000-0000-00000000000a', '10000000-0000-0000-0000-000000000001', pg_temp.scope_group('a1000000-0000-0000-0000-00000000000a'), pg_temp.mk_profile('10000000-0000-0000-0000-000000000001','stA'), 'N-1', 'national_id', 'A', 'A'),
  ('7b000000-0000-0000-0000-00000000000b', '10000000-0000-0000-0000-000000000001', pg_temp.scope_group('a1000000-0000-0000-0000-00000000000a'), pg_temp.mk_profile('10000000-0000-0000-0000-000000000001','stB'), 'N-2', 'national_id', 'B', 'B'),
  ('75000000-0000-0000-0000-000000000005', '10000000-0000-0000-0000-000000000001', pg_temp.scope_school('55000000-0000-0000-0000-000000000004'), pg_temp.mk_profile('10000000-0000-0000-0000-000000000001','stS'), 'N-3', 'national_id', 'S', 'S'),
  ('72000000-0000-0000-0000-000000000002', '20000000-0000-0000-0000-000000000002', pg_temp.scope_school('52000000-0000-0000-0000-000000000005'), pg_temp.mk_profile('20000000-0000-0000-0000-000000000002','st2'), 'N-4', 'national_id', 'T', 'T'),
  -- بلا أي تسجيل: حالات الرفض لا يسبقها G6 (EXCLUDE يُفحص عند الإدراج، والـFK في نهاية الجملة)
  ('7c000000-0000-0000-0000-00000000000c', '10000000-0000-0000-0000-000000000001', pg_temp.scope_group('a1000000-0000-0000-0000-00000000000a'), pg_temp.mk_profile('10000000-0000-0000-0000-000000000001','stC'), 'N-5', 'national_id', 'C', 'C'),
  ('7e000000-0000-0000-0000-00000000000e', '10000000-0000-0000-0000-000000000001', pg_temp.scope_school('55000000-0000-0000-0000-000000000004'), pg_temp.mk_profile('10000000-0000-0000-0000-000000000001','stN'), 'N-6', 'national_id', 'N', 'N');

-- مولّد SQL لتسجيل: المفاتيح «الصادقة» (نطاق الطالب، مالك المدرسة) ما لم تُمرَّر قيم مزوّرة
create function pg_temp.enr(p_student uuid, p_school uuid, p_from date,
                            p_to date default null, p_status text default 'active',
                            p_grade text default 'g1', p_section_school uuid default null,
                            p_scope uuid default null, p_owner uuid default null,
                            p_tenant uuid default null, p_no text default null) returns text
language plpgsql as $$
declare c ctx; sc ctx;
begin
  select * into c  from ctx where school = p_school;
  select * into sc from ctx where school = coalesce(p_section_school, p_school);
  return format($q$insert into public.enrollments (school_id, student_id, platform_tenant_id, academic_year_id, grade_level_id, section_id,
                   identity_scope_id, scope_owner_id, enrollment_no, status, effective_from, effective_to)
                   values (%L,%L,%L,%L,%L,%L,%L,%L,%L,%L,%L,%L) returning 'ok'$q$,
    p_school, p_student,
    coalesce(p_tenant, (select platform_tenant_id from public.students where id = p_student)),
    c.year,
    case p_grade when 'g1' then c.g1 else c.g2 end,
    case p_grade when 'g1' then sc.sec_g1 else sc.sec_g2 end,
    coalesce(p_scope, (select identity_scope_id from public.students where id = p_student)),
    coalesce(p_owner, pg_temp.owner(p_school)),
    p_no, p_status, p_from, p_to);
end $$;

-- ============ الحالات الإيجابية ============
select pg_temp.rec('ok.stA_SA1',  pg_temp.enr('7a000000-0000-0000-0000-00000000000a', '5a100000-0000-0000-0000-000000000001', '2026-09-01', p_no => 'R-1'));
select pg_temp.rec('ok.stS_SS',   pg_temp.enr('75000000-0000-0000-0000-000000000005', '55000000-0000-0000-0000-000000000004', '2026-09-01'));
select pg_temp.rec('ok.st2_S2',   pg_temp.enr('72000000-0000-0000-0000-000000000002', '52000000-0000-0000-0000-000000000005', '2026-09-01'));
select pg_temp.rec('ok.stB_SA2',  pg_temp.enr('7b000000-0000-0000-0000-00000000000b', '5a200000-0000-0000-0000-000000000002', '2026-09-01', p_no => 'R-1'));   -- نفس رقم القيد، مدرسة أخرى

-- ============ G3 / I40: المدرسة داخل نطاق هوية الطالب ============
-- stA (نطاق GA) في المدرسة المستقلة SS بمفاتيح صادقة: نطاق GA ≠ مالك SS
select pg_temp.rec('g3.honest_keys',  pg_temp.enr('7c000000-0000-0000-0000-00000000000c', '55000000-0000-0000-0000-000000000004', '2027-07-01', p_to => '2027-08-01', p_status => 'completed'));
-- مالك مزوَّر = GA لكن المدرسة SS
select pg_temp.rec('g3.forged_owner', pg_temp.enr('7c000000-0000-0000-0000-00000000000c', '55000000-0000-0000-0000-000000000004', '2027-07-01', p_to => '2027-08-01', p_status => 'completed',
                                                  p_owner => 'a1000000-0000-0000-0000-00000000000a'));
-- نطاق مزوَّر = نطاق SS لكن الطالب في نطاق GA
select pg_temp.rec('g3.forged_scope', pg_temp.enr('7c000000-0000-0000-0000-00000000000c', '55000000-0000-0000-0000-000000000004', '2027-07-01', p_to => '2027-08-01', p_status => 'completed',
                                                  p_scope => pg_temp.scope_school('55000000-0000-0000-0000-000000000004')));
-- stA في SB1 (مجموعة أخرى داخل الـTenant نفسه)
select pg_temp.rec('g3.other_group',  pg_temp.enr('7c000000-0000-0000-0000-00000000000c', '5b100000-0000-0000-0000-000000000003', '2027-07-01', p_to => '2027-08-01', p_status => 'completed'));

-- ============ I39: السنة/الصف/الشعبة متسقة ومن المدرسة نفسها ============
-- شعبة G2 مع صف G1 (المولّد يأخذ الشعبة من p_grade؛ نمرر صفاً مخالفاً يدوياً)
select pg_temp.rec('i39.grade_section_mismatch', format($q$insert into public.enrollments (school_id, student_id, platform_tenant_id, academic_year_id, grade_level_id, section_id, identity_scope_id, scope_owner_id, status, effective_from, effective_to)
  select c.school, '7c000000-0000-0000-0000-00000000000c', '10000000-0000-0000-0000-000000000001', c.year, c.g1, c.sec_g2, s.identity_scope_id, %L, 'completed', '2027-07-01', '2027-08-01'
  from ctx c, public.students s where c.school = '5a200000-0000-0000-0000-000000000002' and s.id = '7c000000-0000-0000-0000-00000000000c' returning 'ok'$q$, pg_temp.owner('5a200000-0000-0000-0000-000000000002')));
-- شعبة من SA1 مع مدرسة SA2 (نفس المجموعة، فلا يتدخل G3)
select pg_temp.rec('i39.section_other_school', pg_temp.enr('7c000000-0000-0000-0000-00000000000c', '5a200000-0000-0000-0000-000000000002', '2027-07-01', p_to => '2027-08-01', p_status => 'completed',
                                                           p_section_school => '5a100000-0000-0000-0000-000000000001'));

-- ============ عزل Tenant ============
-- كل المراجع من T1 لكن platform_tenant_id = T2
select pg_temp.rec('tenant.mismatch', pg_temp.enr('7c000000-0000-0000-0000-00000000000c', '5a200000-0000-0000-0000-000000000002', '2027-07-01', p_to => '2027-08-01', p_status => 'completed',
                                                  p_tenant => '20000000-0000-0000-0000-000000000002'));

-- ============ G6 / I41: لا تداخل زمني ============
-- stA نشط في SA1 منذ 2026-09-01؛ تسجيل ثانٍ في SA2 (نفس النطاق) يبدأ 2027-01-01 يتداخل
select pg_temp.rec('g6.overlap_other_school', pg_temp.enr('7a000000-0000-0000-0000-00000000000a', '5a200000-0000-0000-0000-000000000002', '2027-01-01'));
-- I38 ⊂ G6: نشط مكرر لنفس الطالب/المدرسة/السنة
select pg_temp.rec('i38.duplicate_active',    pg_temp.enr('7a000000-0000-0000-0000-00000000000a', '5a100000-0000-0000-0000-000000000001', '2026-10-01'));
-- نقل داخل المجموعة: إغلاق SA1 عند 2027-01-01 ثم SA2 من 2027-01-01 (فترات نصف مفتوحة متلاصقة)
update public.enrollments set status = 'transferred', effective_to = '2027-01-01'
 where student_id = '7a000000-0000-0000-0000-00000000000a' and school_id = '5a100000-0000-0000-0000-000000000001';
select pg_temp.rec('ok.transfer_adjacent', pg_temp.enr('7a000000-0000-0000-0000-00000000000a', '5a200000-0000-0000-0000-000000000002', '2027-01-01'));
-- تسجيل تاريخي يتداخل مع فترة مغلقة
select pg_temp.rec('g6.overlap_closed_history', pg_temp.enr('7a000000-0000-0000-0000-00000000000a', '5a200000-0000-0000-0000-000000000002', '2026-12-01', p_to => '2026-12-20', p_status => 'completed'));

-- ============ I42 / B6 ============
select pg_temp.rec('b6.active_with_end', pg_temp.enr('7b000000-0000-0000-0000-00000000000b', '5a200000-0000-0000-0000-000000000002', '2027-07-01', p_to => '2027-08-01'));
select pg_temp.rec('b6.closed_no_end',   pg_temp.enr('7b000000-0000-0000-0000-00000000000b', '5a200000-0000-0000-0000-000000000002', '2027-07-01', p_status => 'withdrawn'));
select pg_temp.rec('b6.empty_period',    pg_temp.enr('7b000000-0000-0000-0000-00000000000b', '5a200000-0000-0000-0000-000000000002', '2027-07-01', p_to => '2027-07-01', p_status => 'withdrawn'));
select pg_temp.rec('b6.bad_status',      pg_temp.enr('7b000000-0000-0000-0000-00000000000b', '5a200000-0000-0000-0000-000000000002', '2027-07-01', p_to => '2027-08-01', p_status => 'expelled'));

-- ============ رقم القيد ============
select pg_temp.rec('no.dup_same_school_year', pg_temp.enr('7e000000-0000-0000-0000-00000000000e', '55000000-0000-0000-0000-000000000004', '2027-07-01', p_to => '2027-08-01', p_status => 'completed', p_no => 'X-1'));
select pg_temp.rec('no.dup_same_school_year2', pg_temp.enr('7e000000-0000-0000-0000-00000000000e', '55000000-0000-0000-0000-000000000004', '2027-08-01', p_to => '2027-08-15', p_status => 'completed', p_no => 'X-1'));

-- ============ RLS ============
select set_config('request.jwt.claims', '{"sub":"aaaaaaaa-0000-0000-0000-000000000001","role":"authenticated"}', true);
set local role authenticated;
select pg_temp.rec('rls.rows', 'select count(*)::text from public.enrollments');
reset role;

select plan(26);

select ok((select relrowsecurity and relforcerowsecurity from pg_class where oid = 'public.enrollments'::regclass), 'RLS enabled and forced on enrollments');
select col_not_null('public', 'enrollments', 'school_id', 'school_id NOT NULL (school-level table)');

-- إيجابية
select is((select v from r where k = 'ok.stA_SA1'), 'ok', 'positive: group student enrolled in a group school');
select is((select v from r where k = 'ok.stS_SS'),  'ok', 'positive: standalone-scope student enrolled in its standalone school');
select is((select v from r where k = 'ok.st2_S2'),  'ok', 'positive: enrollment in another tenant');
select is((select v from r where k = 'ok.stB_SA2'), 'ok', 'positive: same enrollment number in a different school');
select is((select v from r where k = 'ok.transfer_adjacent'), 'ok', 'positive: transfer inside the group — adjacent half-open periods do not overlap (B6)');

-- G3 — كل قيد باسمه
select ok((select v from r where k = 'g3.honest_keys')  like 'ERR 23503%enrollments_scope_owner_fk%',  'G3: group-scope student cannot enroll in a standalone school (scope does not own the school)');
select ok((select v from r where k = 'g3.forged_owner') like 'ERR 23503%enrollments_school_owner_fk%', 'G3: forged scope owner rejected against the school');
select ok((select v from r where k = 'g3.forged_scope') like 'ERR 23503%enrollments_student_scope_fk%','G3: forged identity scope rejected against the student');
select ok((select v from r where k = 'g3.other_group')  like 'ERR 23503%enrollments_scope_owner_fk%',  'G3: student cannot enroll in a school of another group in the same tenant');
select ok((select bool_and(condeferrable and not condeferred) from pg_constraint
           where conname in ('enrollments_student_scope_fk', 'enrollments_school_owner_fk', 'enrollments_scope_owner_fk')),
          'G3 FKs: DEFERRABLE INITIALLY IMMEDIATE (immediate now, deferrable for the merge procedure)');

-- I39
select ok((select v from r where k = 'i39.grade_section_mismatch') like 'ERR 23503%enrollments_section_fk%', 'I39: section must belong to the enrolled grade');
select ok((select v from r where k = 'i39.section_other_school')  like 'ERR 23503%enrollments_section_fk%', 'I39: section must belong to the enrolled school');

-- Tenant
select ok((select v from r where k = 'tenant.mismatch') ~ '^ERR 23503.*enrollments_(student|school)_fk', 'enrollment tenant must match its student and school');

-- G6 / I38
select ok((select v from r where k = 'g6.overlap_other_school')   like 'ERR 23P01%enrollments_no_overlap%', 'G6: no overlapping enrollments across schools');
select ok((select v from r where k = 'g6.overlap_closed_history') like 'ERR 23P01%enrollments_no_overlap%', 'G6: history cannot overlap a closed period');
select ok((select v from r where k = 'i38.duplicate_active') ~ '^ERR (23P01.*enrollments_no_overlap|23505.*enrollments_active_uq)',
          'I38 (subsumed by G6): duplicate active enrollment rejected');
select is((select count(*)::int from public.enrollments where student_id = '7a000000-0000-0000-0000-00000000000a'), 2,
          'history kept: transferred SA1 period + active SA2 period');

-- B6 / I42
select ok((select v from r where k = 'b6.active_with_end') like 'ERR 23514%enrollments_active_chk%', 'B6: active enrollment has no effective_to');
select ok((select v from r where k = 'b6.closed_no_end')   like 'ERR 23514%enrollments_active_chk%', 'B6: closed enrollment requires effective_to');
select ok((select v from r where k = 'b6.empty_period')    like 'ERR 23514%enrollments_dates_chk%',  'B6: empty half-open period rejected');
select ok((select v from r where k = 'b6.bad_status')      like 'ERR 23514%enrollments_status_chk%', 'status restricted');

-- رقم القيد
select is((select v from r where k = 'no.dup_same_school_year'), 'ok', 'positive: first use of an enrollment number');
select ok((select v from r where k = 'no.dup_same_school_year2') like 'ERR 23505%enrollments_school_year_no_uq%', 'enrollment number unique within school and year');

-- RLS
select is((select v from r where k = 'rls.rows'), '0', 'RLS: authenticated sees nothing before policies');

select * from finish();
rollback;
