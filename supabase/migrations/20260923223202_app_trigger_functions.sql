-- M02 — app_trigger_functions
-- المرجع: docs/DB_IMPLEMENTATION_SPEC_v1.md §B10 (M02)، §3.3 (T5، T6)؛ docs/DATA_DICTIONARY_v1.md §0.3، §2.17.1
-- دوال فقط — تُربط بالجداول في الـmigrations التي تنشئها (T6 من M03، T5 في M11).
-- كل الكائنات تُنشأ بهوية app_owner: تولد ملكاً له وبلا EXECUTE لأحد (M01).

set local role app_owner;

-- ------------------------------------------------------------------
-- T5 — رفض أي تعديل أو حذف (audit_log)
--   تُربط مرتين في M11:
--     before update or delete on audit_log for each row
--     before truncate         on audit_log for each statement   ← trigger الصف لا يعمل عند TRUNCATE،
--                                                                 وservice_role يملك TRUNCATE في Supabase
--   تعمل حتى على service_role و postgres — REVOKE وحده لا يكفي (DATA_DICTIONARY §2.26).
-- ------------------------------------------------------------------
create function app.tg_reject_mutation()
returns trigger
language plpgsql
set search_path = app, pg_temp
as $$
begin
  raise exception '% on %.% is not allowed: rows are immutable', tg_op, tg_table_schema, tg_table_name
    using errcode = '42501';
end;
$$;

-- ------------------------------------------------------------------
-- T6 — ختم created_* / updated_* / granted_*
--   before insert or update ... for each row
--   INSERT: يكتب الوقت والفاعل ويتجاهل ما يرسله العميل (منع تزوير النسب).
--   UPDATE: created_* و granted_* ثابتة من OLD؛ updated_* تُكتب من جديد.
--   عام: الأعمدة غير الموجودة في الجدول تُتجاهل (jsonb_populate_record)، فيُربط بأي جدول.
--   الفاعل: app.current_profile_id() (M12) — NULL لـPlatform Admin وسياق service؛ المسجّل
--   الموثوق للفاعل في هذه الحالات هو audit_log (T7).
--   SECURITY DEFINER: لا يعتمد على منح EXECUTE لكل دور يكتب (authenticated، service_role، migrations).
-- ------------------------------------------------------------------
create function app.tg_stamp()
returns trigger
language plpgsql
security definer
set search_path = app, pg_temp
as $$
declare
  v_actor uuid        := app.current_profile_id();
  v_now   timestamptz := now();
  v_old   jsonb;
begin
  if tg_op = 'INSERT' then
    new := jsonb_populate_record(new, jsonb_build_object(
      'created_at', v_now,  'created_by', v_actor,
      'updated_at', v_now,  'updated_by', v_actor,
      'granted_at', v_now,  'granted_by', v_actor));
  elsif tg_op = 'UPDATE' then
    v_old := to_jsonb(old);
    new := jsonb_populate_record(new, jsonb_build_object(
      'created_at', v_old -> 'created_at',  'created_by', v_old -> 'created_by',
      'granted_at', v_old -> 'granted_at',  'granted_by', v_old -> 'granted_by',
      'updated_at', v_now,                  'updated_by', v_actor));
  end if;
  return new;
end;
$$;

-- ------------------------------------------------------------------
-- temporary_id — قرار O3: TMP-{YEAR}-{SEQUENCE}، ذري، بلا إعادة استخدام
--   nextval() غير تعاملي: الأرقام المهجورة بعد rollback لا تُعاد؛ الفجوات مقبولة.
--   ⚠️ تصحيح على DATA_DICTIONARY §2.17.1: lpad(n, 6) يقطع الأرقام الأطول
--      (lpad('1000000',6) = '100000' ← يكرر معرّف الطالب رقم 100000). الإصلاح:
--      lpad(n, greatest(6, length(n))).
--   يُستدعى من دوال الإنشاء المتحكَّم بها (M22) فقط — لا EXECUTE لأي دور API.
-- ------------------------------------------------------------------
create sequence app.temporary_id_seq as bigint no cycle;

create function app.next_temporary_id()
returns text
language sql
volatile
set search_path = app, pg_temp
as $$
  select 'TMP-' || to_char(now(), 'YYYY') || '-'
      || lpad(n::text, greatest(6, length(n::text)), '0')
  from (select nextval('app.temporary_id_seq') as n) s;
$$;

reset role;
