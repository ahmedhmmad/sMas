-- V6 — ON UPDATE CASCADE على FK مركّب بتواريخ السنة + إعادة تقييم CHECK، تحت FORCE RLS
-- (يحل محل trigger T4: الفصل داخل حدود السنة)
-- terms بلا أي سياسة لـauthenticated: يثبت أن التسلسل المرجعي لا يعتمد على RLS

create table m00.academic_years (
  id         uuid primary key default gen_random_uuid(),
  school_id  uuid not null,
  start_date date not null,
  end_date   date not null,
  unique (id, school_id, start_date, end_date)
);
create table m00.terms (
  id              uuid primary key default gen_random_uuid(),
  academic_year_id uuid not null,
  school_id       uuid not null,
  year_start_date date not null,
  year_end_date   date not null,
  start_date      date not null,
  end_date        date not null,
  foreign key (academic_year_id, school_id, year_start_date, year_end_date)
    references m00.academic_years (id, school_id, start_date, end_date) on update cascade,
  check (start_date >= year_start_date and end_date <= year_end_date)
);

insert into m00.academic_years values
  ('e0000000-0000-0000-0000-00000000000e', 'a0000000-0000-0000-0000-00000000000a', '2026-09-01', '2027-06-30');
insert into m00.terms (academic_year_id, school_id, year_start_date, year_end_date, start_date, end_date) values
  ('e0000000-0000-0000-0000-00000000000e', 'a0000000-0000-0000-0000-00000000000a', '2026-09-01', '2027-06-30', '2026-09-01', '2027-01-31'),
  ('e0000000-0000-0000-0000-00000000000e', 'a0000000-0000-0000-0000-00000000000a', '2026-09-01', '2027-06-30', '2027-02-01', '2027-06-15');

-- إدراج فصل خارج السنة مباشرة
select m00.rec('V6.insert_term_outside_year',
  $q$insert into m00.terms (academic_year_id, school_id, year_start_date, year_end_date, start_date, end_date) values ('e0000000-0000-0000-0000-00000000000e','a0000000-0000-0000-0000-00000000000a','2026-09-01','2027-06-30','2027-06-01','2027-07-15') returning 'ok'$q$);

alter table m00.academic_years enable row level security;
alter table m00.academic_years force  row level security;
alter table m00.terms          enable row level security;
alter table m00.terms          force  row level security;
create policy years_all on m00.academic_years for all to authenticated using (true) with check (true);
grant select, update on m00.academic_years to authenticated;
-- terms: لا سياسة ولا صلاحية لـauthenticated

select m00.claims(:uid_a);
set local role authenticated;
select m00.rec('V6.extend_year',
  $q$update m00.academic_years set end_date = '2027-07-31' where id = 'e0000000-0000-0000-0000-00000000000e' returning 'ok'$q$);
select m00.rec('V6.shrink_year_excluding_term',
  $q$update m00.academic_years set end_date = '2027-05-31' where id = 'e0000000-0000-0000-0000-00000000000e' returning 'ok'$q$);
reset role;

-- التحقق من أثر التسلسل بدور يتجاوز RLS
alter table m00.terms no force row level security;
select m00.rec('V6.terms_year_end_after_extend',
  $q$select string_agg(distinct year_end_date::text, ',') from m00.terms$q$);

select plan(4);
select ok((select v from m00_res where k = 'V6.insert_term_outside_year') like 'ERR 23514%',
  'V6: term outside year rejected on insert');
select is((select v from m00_res where k = 'V6.extend_year'), 'ok',
  'V6: extending the year succeeds under FORCE RLS (terms has no policy)');
select is((select v from m00_res where k = 'V6.terms_year_end_after_extend'), '2027-07-31',
  'V6: ON UPDATE CASCADE propagated new year bounds into terms');
select ok((select v from m00_res where k = 'V6.shrink_year_excluding_term') like 'ERR 23514%',
  'V6: shrinking the year below a term is rejected by the re-evaluated CHECK');
select * from finish();
