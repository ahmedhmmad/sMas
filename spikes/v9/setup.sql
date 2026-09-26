-- V9 — Spike لآلية D2 (first-login password change). ليس migration.
-- يُطبَّق على Supabase المحلي فقط ويُزال بـ`npx supabase db reset`.
--
-- ما يُركَّب:
--   1. نموذج الآلية المقترحة (docs/F2_AUTHENTICATION.md §3) بحذافيرها: trigger على auth.users عند تغيّر
--      encrypted_password — إن كانت الحالة pending والـhash ≠ اللقطة ⇒ active.
--   2. سجل كل إطلاق للـtrigger: الأعمدة التي تغيّرت فعلاً، الدور، application_name، المعاملة — لمعرفة
--      هل يوجد في auth.users ما يميّز تغيير المستخدم عن إعادة ضبط المدير.
--   3. بوابة الجذر (نمط M21b) على current_profile_id/current_tenant_id: NULL ما لم تكن الحالة active.
--   4. فشل مُفتعل داخل معاملة Supabase Auth (spike_v9.fail_for) لاختبار الإلغاء.

create schema spike_v9;
grant usage on schema spike_v9 to app_owner;

create table spike_v9.credential (
  auth_user_id uuid primary key,
  state        text not null check (state in ('issuing', 'pending', 'active')),
  snapshot     text
);
grant select on spike_v9.credential to app_owner;

create table spike_v9.events (
  id           bigserial primary key,
  at           timestamptz not null default clock_timestamp(),
  auth_user_id uuid,
  changed      text[],
  cur_user     text,
  sess_user    text,
  app_name     text,
  xid          xid8,
  state_before text,
  state_after  text
);

create table spike_v9.fail_for (auth_user_id uuid primary key);

create function spike_v9.tg_password() returns trigger
language plpgsql security definer set search_path = spike_v9, pg_temp
as $$
declare v_state text; v_snap text; v_after text; v_changed text[];
begin
  select array_agg(n.key order by n.key) into v_changed
    from jsonb_each(to_jsonb(new)) n where n.value is distinct from (to_jsonb(old) -> n.key);
  select state, snapshot into v_state, v_snap from spike_v9.credential where auth_user_id = new.id for update;
  v_after := v_state;
  if v_state = 'pending' and new.encrypted_password is distinct from v_snap then      -- الآلية المقترحة كما هي
    v_after := 'active';
    update spike_v9.credential set state = 'active' where auth_user_id = new.id;
  end if;
  insert into spike_v9.events (auth_user_id, changed, cur_user, sess_user, app_name, xid, state_before, state_after)
    values (new.id, v_changed, current_user, session_user, current_setting('application_name', true), pg_current_xact_id(), v_state, v_after);
  if exists (select 1 from spike_v9.fail_for where auth_user_id = new.id) then
    raise exception 'V9 forced failure inside the Auth transaction';
  end if;
  return new;
end $$;

create trigger spike_v9_password
  after update of encrypted_password on auth.users
  for each row execute function spike_v9.tg_password();

-- arm: لقطة الـhash الحالي ⇒ pending
create function spike_v9.arm(p uuid) returns void language sql security definer set search_path = spike_v9, pg_temp as $$
  insert into spike_v9.credential (auth_user_id, state, snapshot)
    values (p, 'pending', (select encrypted_password from auth.users where id = p))
  on conflict (auth_user_id) do update set state = 'pending', snapshot = excluded.snapshot;
$$;

-- بوابة الجذر (نمط M21b) — نسخة Spike تُزال بـdb reset
create or replace function app.current_profile_id()
returns uuid language sql stable security definer set search_path = app, public, pg_temp
as $$
  select p.id
  from public.profiles p
  join public.platform_tenants t on t.id = p.platform_tenant_id
  where p.auth_user_id = app.auth_uid()
    and p.status = 'active'
    and t.status = 'active'
    and not exists (select 1 from spike_v9.credential c where c.auth_user_id = p.auth_user_id and c.state <> 'active');
$$;

create or replace function app.current_tenant_id()
returns uuid language sql stable security definer set search_path = app, public, pg_temp
as $$
  select p.platform_tenant_id
  from public.profiles p
  join public.platform_tenants t on t.id = p.platform_tenant_id
  where p.auth_user_id = app.auth_uid()
    and p.status = 'active'
    and t.status = 'active'
    and not exists (select 1 from spike_v9.credential c where c.auth_user_id = p.auth_user_id and c.state <> 'active');
$$;

-- مشغّل الـSpike يتصل بـpostgres
grant usage on schema spike_v9 to postgres;
grant all on all tables in schema spike_v9 to postgres;
grant all on all sequences in schema spike_v9 to postgres;
grant execute on all functions in schema spike_v9 to postgres;
