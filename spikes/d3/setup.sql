-- D3 Spike — هوية اصطناعية لكل حساب Tenant (ولي الأمر) + OTP + جلسة Supabase Auth. ليس migration.
-- يُطبَّق على Supabase المحلي (مع seed E5) ويُزال بـ`npx supabase db reset`.
--
--   spike_d3.otp          تحديات OTP (hash لا نص، صلاحية، محاولات، استهلاك)
--   spike_d3.bind_guardian ربط حساب Auth اصطناعي بولي أمر: auth_identities ← profile ← membership + دور guardian
--   spike_d3.resolve       (tenant_code, phone) ← الحساب — قبل أي JWT (يقابل resolve_student_login في D1)

create schema spike_d3;

create table spike_d3.otp (
  id          bigserial primary key,
  tenant_id   uuid not null,
  phone_e164  text not null,
  account_id  uuid not null,              -- auth_user_id
  salt        text not null,
  code_hash   text not null,
  expires_at  timestamptz not null,
  attempts    int not null default 0,
  consumed_at timestamptz
);

-- (tenant_code, phone) ← guardian + account؛ NULL واحد لكل فشل
create function spike_d3.resolve(p_tenant_code text, p_phone text)
returns table (tenant_id uuid, guardian_id uuid, account_id uuid, locked boolean)
language sql stable security definer set search_path = public, pg_temp
as $$
  select t.id, g.id, p.auth_user_id, coalesce(g.locked_until > now(), false)
  from public.platform_tenants t
  join public.guardians g on g.platform_tenant_id = t.id and g.phone_e164 = btrim(p_phone) and g.status = 'active'
  join public.profiles p on p.id = g.profile_id
  where t.tenant_code = upper(btrim(p_tenant_code)) and t.status = 'active'
$$;

create function spike_d3.bind_guardian(p_tenant uuid, p_guardian uuid, p_auth uuid)
returns uuid language plpgsql security definer set search_path = public, app, pg_temp
as $$
declare v_p uuid; v_m uuid;
begin
  insert into public.auth_identities (auth_user_id, kind) values (p_auth, 'tenant');
  insert into public.profiles (platform_tenant_id, auth_user_id, display_name) values (p_tenant, p_auth, 'guardian') returning id into v_p;
  insert into public.memberships (platform_tenant_id, profile_id) values (p_tenant, v_p) returning id into v_m;
  insert into public.membership_roles (membership_id, role_id, platform_tenant_id, role_owner_key)
    values (v_m, app.system_role_id('guardian'), p_tenant, '00000000-0000-0000-0000-000000000000');
  update public.guardians set profile_id = v_p where id = p_guardian;
  return v_p;
end $$;

grant usage on schema spike_d3 to postgres;
grant all on all tables in schema spike_d3 to postgres;
grant all on all sequences in schema spike_d3 to postgres;
grant execute on all functions in schema spike_d3 to postgres;
