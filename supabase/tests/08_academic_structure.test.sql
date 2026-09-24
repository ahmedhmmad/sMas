-- M08 — academic_structure: I33–I37، بديل T4 الإعلاني، EXCLUDE عبر btree_gist
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

insert into public.platform_tenants (id, tenant_code, name) values ('10000000-0000-0000-0000-000000000001', 'T1', 'T1');
insert into public.schools (id, platform_tenant_id, school_code, name, slug) values
  ('5a000000-0000-0000-0000-00000000000a', '10000000-0000-0000-0000-000000000001', 'SA', 'School A', 'sa'),
  ('5b000000-0000-0000-0000-00000000000b', '10000000-0000-0000-0000-000000000001', 'SB', 'School B', 'sb');

-- سنوات
insert into public.academic_years (id, school_id, name, start_date, end_date, status) values
  ('a1000000-0000-0000-0000-000000000001', '5a000000-0000-0000-0000-00000000000a', '2026/2027', '2026-09-01', '2027-06-30', 'active'),
  ('a2000000-0000-0000-0000-000000000002', '5a000000-0000-0000-0000-00000000000a', '2027/2028', '2027-09-01', '2028-06-30', 'planned'),
  ('b1000000-0000-0000-0000-000000000001', '5b000000-0000-0000-0000-00000000000b', '2026/2027', '2026-09-01', '2027-06-30', 'active');

select pg_temp.rec('ay.second_active', $q$update public.academic_years set status = 'active' where id = 'a2000000-0000-0000-0000-000000000002' returning 'ok'$q$);
select pg_temp.rec('ay.overlap',       $q$insert into public.academic_years (school_id, name, start_date, end_date) values ('5a000000-0000-0000-0000-00000000000a','overlap','2027-06-01','2027-08-31') returning 'ok'$q$);
select pg_temp.rec('ay.touching_end',  $q$insert into public.academic_years (school_id, name, start_date, end_date) values ('5a000000-0000-0000-0000-00000000000a','summer','2027-06-30','2027-08-31') returning 'ok'$q$);
select pg_temp.rec('ay.bad_dates',     $q$insert into public.academic_years (school_id, name, start_date, end_date) values ('5a000000-0000-0000-0000-00000000000a','bad','2030-06-30','2030-01-01') returning 'ok'$q$);
select pg_temp.rec('ay.dup_name',      $q$insert into public.academic_years (school_id, name, start_date, end_date) values ('5a000000-0000-0000-0000-00000000000a','2026/2027','2031-09-01','2032-06-30') returning 'ok'$q$);

-- فصول — عددها بيانات لا ثابت (ثلاثة هنا)
insert into public.terms (academic_year_id, school_id, year_start_date, year_end_date, name, sequence_no, start_date, end_date) values
  ('a1000000-0000-0000-0000-000000000001', '5a000000-0000-0000-0000-00000000000a', '2026-09-01', '2027-06-30', 'T1', 1, '2026-09-01', '2026-12-15'),
  ('a1000000-0000-0000-0000-000000000001', '5a000000-0000-0000-0000-00000000000a', '2026-09-01', '2027-06-30', 'T2', 2, '2027-01-05', '2027-03-31'),
  ('a1000000-0000-0000-0000-000000000001', '5a000000-0000-0000-0000-00000000000a', '2026-09-01', '2027-06-30', 'T3', 3, '2027-04-10', '2027-06-20');

select pg_temp.rec('t.outside_year',  $q$insert into public.terms (academic_year_id, school_id, year_start_date, year_end_date, name, sequence_no, start_date, end_date) values ('a1000000-0000-0000-0000-000000000001','5a000000-0000-0000-0000-00000000000a','2026-09-01','2027-06-30','X',9,'2027-06-25','2027-07-15') returning 'ok'$q$);
select pg_temp.rec('t.forged_bounds', $q$insert into public.terms (academic_year_id, school_id, year_start_date, year_end_date, name, sequence_no, start_date, end_date) values ('a1000000-0000-0000-0000-000000000001','5a000000-0000-0000-0000-00000000000a','2026-01-01','2027-12-31','Y',8,'2027-06-25','2027-07-15') returning 'ok'$q$);
select pg_temp.rec('t.other_school',  $q$insert into public.terms (academic_year_id, school_id, year_start_date, year_end_date, name, sequence_no, start_date, end_date) values ('a1000000-0000-0000-0000-000000000001','5b000000-0000-0000-0000-00000000000b','2026-09-01','2027-06-30','Z',7,'2027-06-21','2027-06-29') returning 'ok'$q$);  -- تواريخ لا تتداخل: يبقى الـFK السبب الوحيد
select pg_temp.rec('t.overlap',       $q$insert into public.terms (academic_year_id, school_id, year_start_date, year_end_date, name, sequence_no, start_date, end_date) values ('a1000000-0000-0000-0000-000000000001','5a000000-0000-0000-0000-00000000000a','2026-09-01','2027-06-30','O',4,'2026-12-01','2027-01-10') returning 'ok'$q$);
select pg_temp.rec('t.dup_seq',       $q$insert into public.terms (academic_year_id, school_id, year_start_date, year_end_date, name, sequence_no, start_date, end_date) values ('a1000000-0000-0000-0000-000000000001','5a000000-0000-0000-0000-00000000000a','2026-09-01','2027-06-30','Q',1,'2027-06-22','2027-06-29') returning 'ok'$q$);

-- التسلسل المرجعي: تمديد السنة ينتشر؛ تقليصها تحت فصل يُرفض
select pg_temp.rec('t.extend_year', $q$update public.academic_years set end_date = '2027-07-31' where id = 'a1000000-0000-0000-0000-000000000001' returning 'ok'$q$);
select pg_temp.rec('t.bounds_after_extend', $q$select string_agg(distinct year_end_date::text, ',') from public.terms where academic_year_id = 'a1000000-0000-0000-0000-000000000001'$q$);
select pg_temp.rec('t.shrink_year', $q$update public.academic_years set end_date = '2027-06-01' where id = 'a1000000-0000-0000-0000-000000000001' returning 'ok'$q$);

-- مراحل وصفوف
insert into public.stages (id, school_id, name, sequence_no) values
  ('c1000000-0000-0000-0000-000000000001', '5a000000-0000-0000-0000-00000000000a', 'KG',        1),
  ('c2000000-0000-0000-0000-000000000002', '5a000000-0000-0000-0000-00000000000a', 'Primary',   2),
  ('cb000000-0000-0000-0000-00000000000b', '5b000000-0000-0000-0000-00000000000b', 'Primary',   1);
insert into public.grade_levels (id, school_id, stage_id, name, sequence_no) values
  ('d1000000-0000-0000-0000-000000000001', '5a000000-0000-0000-0000-00000000000a', 'c1000000-0000-0000-0000-000000000001', 'KG1', 1),
  ('d2000000-0000-0000-0000-000000000002', '5a000000-0000-0000-0000-00000000000a', 'c2000000-0000-0000-0000-000000000002', 'G1',  2),
  ('db000000-0000-0000-0000-00000000000b', '5b000000-0000-0000-0000-00000000000b', 'cb000000-0000-0000-0000-00000000000b', 'G1',  1);

select pg_temp.rec('gl.stage_other_school', $q$insert into public.grade_levels (school_id, stage_id, name, sequence_no) values ('5a000000-0000-0000-0000-00000000000a','cb000000-0000-0000-0000-00000000000b','X',9) returning 'ok'$q$);
select pg_temp.rec('st.dup_seq',            $q$insert into public.stages (school_id, name, sequence_no) values ('5a000000-0000-0000-0000-00000000000a','Middle',1) returning 'ok'$q$);
select pg_temp.rec('st.bad_seq',            $q$insert into public.stages (school_id, name, sequence_no) values ('5a000000-0000-0000-0000-00000000000a','Zero',0) returning 'ok'$q$);

-- شعب
insert into public.sections (school_id, academic_year_id, grade_level_id, name, capacity) values
  ('5a000000-0000-0000-0000-00000000000a', 'a1000000-0000-0000-0000-000000000001', 'd2000000-0000-0000-0000-000000000002', 'A', 30),
  ('5a000000-0000-0000-0000-00000000000a', 'a1000000-0000-0000-0000-000000000001', 'd1000000-0000-0000-0000-000000000001', 'A', 20),   -- نفس الاسم، صف آخر
  ('5a000000-0000-0000-0000-00000000000a', 'a2000000-0000-0000-0000-000000000002', 'd2000000-0000-0000-0000-000000000002', 'A', null); -- نفس الاسم، سنة أخرى

select pg_temp.rec('sec.dup_name',        $q$insert into public.sections (school_id, academic_year_id, grade_level_id, name) values ('5a000000-0000-0000-0000-00000000000a','a1000000-0000-0000-0000-000000000001','d2000000-0000-0000-0000-000000000002','A') returning 'ok'$q$);
select pg_temp.rec('sec.year_other_school',  $q$insert into public.sections (school_id, academic_year_id, grade_level_id, name) values ('5a000000-0000-0000-0000-00000000000a','b1000000-0000-0000-0000-000000000001','d2000000-0000-0000-0000-000000000002','B') returning 'ok'$q$);
select pg_temp.rec('sec.grade_other_school', $q$insert into public.sections (school_id, academic_year_id, grade_level_id, name) values ('5a000000-0000-0000-0000-00000000000a','a1000000-0000-0000-0000-000000000001','db000000-0000-0000-0000-00000000000b','C') returning 'ok'$q$);
select pg_temp.rec('sec.zero_capacity',   $q$insert into public.sections (school_id, academic_year_id, grade_level_id, name, capacity) values ('5a000000-0000-0000-0000-00000000000a','a1000000-0000-0000-0000-000000000001','d2000000-0000-0000-0000-000000000002','D',0) returning 'ok'$q$);
select pg_temp.rec('sec.bad_gender',      $q$insert into public.sections (school_id, academic_year_id, grade_level_id, name, gender_policy) values ('5a000000-0000-0000-0000-00000000000a','a1000000-0000-0000-0000-000000000001','d2000000-0000-0000-0000-000000000002','E','boys') returning 'ok'$q$);

-- RLS
select set_config('request.jwt.claims', '{"sub":"aaaaaaaa-0000-0000-0000-000000000001","role":"authenticated"}', true);
set local role authenticated;
select pg_temp.rec('rls.rows', $q$select ((select count(*) from public.academic_years) + (select count(*) from public.terms) + (select count(*) from public.stages)
                                  + (select count(*) from public.grade_levels) + (select count(*) from public.sections))::text$q$);
reset role;

select plan(30);

select ok((select bool_and(relrowsecurity and relforcerowsecurity) from pg_class
           where oid in ('public.academic_years'::regclass, 'public.terms'::regclass, 'public.stages'::regclass,
                         'public.grade_levels'::regclass, 'public.sections'::regclass)),
          'RLS enabled and forced on the five academic tables');
select ok((select bool_and(a.attnotnull) from pg_attribute a
           where a.attname = 'school_id' and a.attrelid in ('public.academic_years'::regclass, 'public.terms'::regclass,
                 'public.stages'::regclass, 'public.grade_levels'::regclass, 'public.sections'::regclass)),
          'school_id NOT NULL on every school-level table (PLAN §3.3 rule 1)');

-- academic_years
select ok((select v from r where k = 'ay.second_active') like 'ERR 23505%', 'I33: one active year per school');
select is((select count(*)::int from public.academic_years where status = 'active'), 2, 'I33: other schools keep their own active year');
select ok((select v from r where k = 'ay.overlap')       like 'ERR 23P01%', 'I34: overlapping years rejected (EXCLUDE via btree_gist)');
select ok((select v from r where k = 'ay.touching_end')  like 'ERR 23P01%', 'I34: inclusive bounds — a year starting on the previous end date overlaps');
select ok((select v from r where k = 'ay.bad_dates')     like 'ERR 23514%', 'end_date after start_date');
select ok((select v from r where k = 'ay.dup_name')      like 'ERR 23505%', 'year name unique within school');
select is((select count(*)::int from public.academic_years where name = '2026/2027'), 2, 'same year name allowed in another school');

-- terms
select is((select count(*)::int from public.terms where academic_year_id = 'a1000000-0000-0000-0000-000000000001'), 3,
          'number of terms is data, not a constant (three terms here)');
select ok((select v from r where k = 't.outside_year')  like 'ERR 23514%', 'I35: term outside the year rejected');
select ok((select v from r where k = 't.forged_bounds') like 'ERR 23503%', 'I35: forged year bounds rejected by the FK');
select ok((select v from r where k = 't.other_school')  like 'ERR 23503%terms_year_fk%', 'term cannot attach to a year of another school');
select ok((select v from r where k = 't.overlap')       like 'ERR 23P01%', 'I36: overlapping terms rejected');
select ok((select v from r where k = 't.dup_seq')       like 'ERR 23505%', 'term sequence unique within the year');
select is((select v from r where k = 't.extend_year'), 'ok',                 'extending the year succeeds');
select is((select v from r where k = 't.bounds_after_extend'), '2027-07-31', 'ON UPDATE CASCADE carried the new year end into every term');
select ok((select v from r where k = 't.shrink_year') like 'ERR 23514%',     'shrinking the year below a term is rejected (T4 replaced)');

-- stages / grade_levels
select ok((select v from r where k = 'gl.stage_other_school') like 'ERR 23503%', 'I37: grade level cannot use a stage of another school');
select ok((select v from r where k = 'st.dup_seq') like 'ERR 23505%', 'stage sequence unique within school');
select ok((select v from r where k = 'st.bad_seq') like 'ERR 23514%', 'stage sequence positive');

-- sections
select is((select count(*)::int from public.sections where name = 'A'), 3, 'section name reused across grades and years');
select ok((select v from r where k = 'sec.dup_name')           like 'ERR 23505%', 'section name unique within (school, year, grade)');
select ok((select v from r where k = 'sec.year_other_school')  like 'ERR 23503%', 'I37: section cannot use a year of another school');
select ok((select v from r where k = 'sec.grade_other_school') like 'ERR 23503%', 'I37: section cannot use a grade of another school');
select ok((select v from r where k = 'sec.zero_capacity')      like 'ERR 23514%', 'capacity positive when set');
select ok((select v from r where k = 'sec.bad_gender')         like 'ERR 23514%', 'gender policy restricted');
select col_is_unique('public', 'sections', array['id', 'school_id', 'academic_year_id', 'grade_level_id'],
          'sections (id, school, year, grade) unique — single FK target for enrollments (T3 replaced)');

-- RLS / الامتدادات
select is((select v from r where k = 'rls.rows'), '0', 'RLS: authenticated sees nothing before policies');
select ok(exists (select 1 from pg_constraint where conname = 'academic_years_no_overlap' and contype = 'x'),
          'EXCLUDE constraint present (btree_gist in schema extensions resolves for uuid)');

select * from finish();
rollback;
