-- V8 (جزء DB) — دالة إنشاء متحكَّم بها بعد إنشاء Auth user خارج المعاملة
-- المتغيرات من v8_saga.mjs: :student_id :auth1 :auth2 :caller
--   auth1 — حساب أُنشئ عبر Admin API للمسار الناجح
--   auth2 — حساب أُنشئ للمسار الفاشل؛ يُحذف تعويضياً بعد الـrollback

-- (a) service role: لا هوية فاعل
select m00.claims(null, 'service_role');
set local role service_role;
select m00.rec('V8a.service_role_auth_uid', 'select coalesce(auth.uid()::text, ''<null>'')');
reset role;

-- نموذج مصغّر: profiles مرتبطة بـauth.users، طالب 1:1 مع profile، تسجيل في مدرسة
create table m00.profiles (
  id           uuid primary key default gen_random_uuid(),
  auth_user_id uuid not null unique references auth.users (id),
  kind         text not null
);
create table m00.schools (id uuid primary key);
create table m00.students (
  id                 uuid primary key,
  student_profile_id uuid not null unique references m00.profiles (id)
);
create table m00.enrollments (
  id         uuid primary key default gen_random_uuid(),
  student_id uuid not null references m00.students (id),
  school_id  uuid not null references m00.schools (id)
);
create table m00.secretaries (auth_user_id uuid not null, school_id uuid not null, primary key (auth_user_id, school_id));
insert into m00.schools values ('a0000000-0000-0000-0000-00000000000a');
insert into m00.secretaries values
  (:caller, 'a0000000-0000-0000-0000-00000000000a'),
  -- لمسار الفشل الوسطي: تفويض على مدرسة غير موجودة في m00.schools
  -- ← يجتاز فحص التفويض، يُدرج profile و student، ثم يفشل FK الـenrollment
  (:caller, 'ffffffff-ffff-ffff-ffff-ffffffffffff');

create function m00.provision_student(p_student_id uuid, p_auth_user_id uuid, p_school_id uuid)
returns text
language plpgsql security definer set search_path = m00, pg_temp
as $$
declare v_profile uuid;
begin
  -- (1)(2)(3) الفاعل من JWT فقط، وتفويضه على المدرسة الهدف
  if not exists (select 1 from m00.secretaries s
                 where s.auth_user_id = auth.uid() and s.school_id = p_school_id) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  -- idempotency: إعادة المحاولة بنفس المعرّف تُرجع الموجود
  if exists (select 1 from m00.students st join m00.profiles p on p.id = st.student_profile_id
             where st.id = p_student_id and p.auth_user_id = p_auth_user_id) then
    return 'exists';
  end if;
  insert into m00.profiles (auth_user_id, kind) values (p_auth_user_id, 'student') returning id into v_profile;
  insert into m00.students (id, student_profile_id) values (p_student_id, v_profile);
  insert into m00.enrollments (student_id, school_id) values (p_student_id, p_school_id);
  return 'created actor=' || auth.uid();
end $$;
revoke execute on function m00.provision_student(uuid, uuid, uuid) from public, anon;
grant  execute on function m00.provision_student(uuid, uuid, uuid) to authenticated;
grant  usage on schema m00 to authenticated;

-- (b) المسار الناجح بهوية السكرتيرة
select m00.claims(:caller);
set local role authenticated;
select m00.rec('V8b.provision_ok',
  format('select m00.provision_student(%L, %L, %L)', :student_id, :auth1, 'a0000000-0000-0000-0000-00000000000a'));
select m00.rec('V8b.retry_same_id',
  format('select m00.provision_student(%L, %L, %L)', :student_id, :auth1, 'a0000000-0000-0000-0000-00000000000a'));
-- (c) مسار فاشل: مدرسة غير موجودة بعد إدراج profile و student داخل الدالة
select m00.rec('V8c.provision_fails_midway',
  format('select m00.provision_student(%L, %L, %L)', gen_random_uuid(), :auth2, 'ffffffff-ffff-ffff-ffff-ffffffffffff'));
reset role;

-- (d) مستخدم بلا تفويض
select m00.claims(:uid_c);
set local role authenticated;
select m00.rec('V8d.unauthorized_caller',
  format('select m00.provision_student(%L, %L, %L)', gen_random_uuid(), :auth2, 'a0000000-0000-0000-0000-00000000000a'));
select m00.rec('V8d.anon_can_execute', $q$select has_function_privilege('anon', 'm00.provision_student(uuid,uuid,uuid)', 'EXECUTE')::text$q$);
reset role;

-- الذرية: لا أثر للمسار الفاشل
select m00.rec('V8c.profile_left_for_auth2',
  format('select count(*)::text from m00.profiles where auth_user_id = %L', :auth2));
select m00.rec('V8c.students_total', 'select count(*)::text from m00.students');
select m00.rec('V8b.rows_for_student',
  format($q$select (select count(*) from m00.profiles p join m00.students s on s.student_profile_id = p.id where s.id = %L)
             || '/' || (select count(*) from m00.enrollments where student_id = %L)$q$, :student_id, :student_id));

select plan(8);
select is((select v from m00_res where k = 'V8a.service_role_auth_uid'), '<null>',
  'V8a: auth.uid() is NULL under service role (G7 exemption condition is well-defined)');
select is((select v from m00_res where k = 'V8b.provision_ok'), 'created actor=' || :caller,
  'V8b: controlled function sees the caller as actor (JWT identity preserved)');
select is((select v from m00_res where k = 'V8b.retry_same_id'), 'exists',
  'V8b: retry with the same pre-generated id is idempotent');
select is((select v from m00_res where k = 'V8b.rows_for_student'), '1/1',
  'V8b: profile + student + enrollment created exactly once');
select ok((select v from m00_res where k = 'V8c.provision_fails_midway') like 'ERR 23503%enrollments%',
  'V8c: failure happens midway — at the enrollment insert, after profile and student');
select ok((select v from m00_res where k = 'V8c.profile_left_for_auth2') = '0'
      and (select v from m00_res where k = 'V8c.students_total') = '1',
  'V8c: midway failure leaves no profile and no student (atomic)');
select ok((select v from m00_res where k = 'V8d.unauthorized_caller') like 'ERR 42501%',
  'V8d: caller without authority is rejected inside the function');
select is((select v from m00_res where k = 'V8d.anon_can_execute'), 'false',
  'V8d: anon cannot execute the controlled function');
select * from finish();
