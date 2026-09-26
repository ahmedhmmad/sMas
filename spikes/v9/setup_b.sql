-- V9b — هل سجل تدقيق Supabase Auth إشارة موثوقة؟ trigger تسجيل فقط (لا تفعيل) على auth.audit_log_entries.
create table spike_v9.audit_events (
  id bigserial primary key, auth_user_id uuid, action text, actor_id text, actor_username text, xid xid8
);
create function spike_v9.tg_auth_audit() returns trigger
language plpgsql security definer set search_path = spike_v9, pg_temp
as $$
begin
  insert into spike_v9.audit_events (auth_user_id, action, actor_id, actor_username, xid)
  values (coalesce(nullif(new.payload->'traits'->>'user_id', ''), new.payload->>'actor_id')::uuid,
          new.payload->>'action', new.payload->>'actor_id', new.payload->>'actor_username', pg_current_xact_id());
  return new;
end $$;
create trigger spike_v9_auth_audit after insert on auth.audit_log_entries
  for each row execute function spike_v9.tg_auth_audit();
grant all on all tables in schema spike_v9 to postgres;
grant all on all sequences in schema spike_v9 to postgres;
