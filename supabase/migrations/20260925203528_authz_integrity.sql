-- M19 — authz_integrity (T8)
-- المرجع: docs/DB_IMPLEMENTATION_SPEC_v1.md §B10 (M19)؛ docs/RLS_MODEL_v1.md §10.2.1 (F5)؛ Matrix §13؛ G7
--
-- delegation cannot expand authority — ثلاثة متطلبات معتمدة (2026-09-25):
--   (1) membership_roles INSERT/DELETE: كل صلاحيات الدور ⊆ صلاحيات الفاعل                (E4)
--   (2) role_permissions INSERT/DELETE: الصلاحية المضافة/المسحوبة ∈ صلاحيات الفاعل        (E14 خطوة 2، F5)
--   (3) membership_scopes INSERT: منح Scope لا يمكّن الهدف داخل ذلك الـScope من أي Permission
--       تتجاوز Permissions المانح الفعلية داخل نفس الـScope.
--
-- «صلاحيات الفاعل داخل الـScope»: في هذا النموذج صلاحيات العضوية تسري في كل نطاقاتها، والنطاق الممنوح ⊆ نطاق
-- الفاعل مفروض سلفاً في RLS (M15). فالشرط = كل صلاحيات أدوار الهدف ⊆ has_permission() للفاعل.
-- أدوار الهدف تُحسب كلها بلا اعتبار لحالتها (كـ(1) في §10.2.1): دور معطَّل قد يُعاد تفعيله، والمنح يجب ألا يعتمد عليه.
--
-- trigger AFTER لا BEFORE: BEFORE يسبق WITH CHECK في Postgres فيحجب رفض RLS (النطاق، can_manage) برسالة T8.
-- بـAFTER تبقى الطبقتان متمايزتين: RLS تقرر «على أي عضوية/نطاق»، و T8 «بأي صلاحيات» — للصفوف التي اجتازت RLS.
-- الإعفاء: سياق service (app.auth_uid() IS NULL) — G7. UPDATE على الجدولين غير متاح للعميل أصلاً (لا سياسة).
-- الرفض: SQLSTATE 42501 برسالة تبدأ بـ«T8:».

set local role app_owner;

create function app.tg_authz_integrity()
returns trigger
language plpgsql
security definer
set search_path = app, public, pg_temp
as $$
declare
  v_row     jsonb := case when tg_op = 'DELETE' then to_jsonb(old) else to_jsonb(new) end;
  v_missing text;
begin
  if app.auth_uid() is null then          -- G7: سياق service مُعفى
    return null;
  end if;

  if tg_table_name = 'membership_roles' then
    select string_agg(p.code, ', ' order by p.code) into v_missing
    from public.role_permissions rp
    join public.permissions p on p.id = rp.permission_id
    where rp.role_id = (v_row ->> 'role_id')::uuid
      and not app.has_permission(p.code);
    if v_missing is not null then
      raise exception 'T8: role grants permissions the actor does not hold: %', v_missing
        using errcode = '42501';
    end if;

  elsif tg_table_name = 'role_permissions' then
    select p.code into v_missing
    from public.permissions p
    where p.id = (v_row ->> 'permission_id')::uuid
      and not app.has_permission(p.code);
    if v_missing is not null then
      raise exception 'T8: permission not held by the actor: %', v_missing
        using errcode = '42501';
    end if;

  elsif tg_table_name = 'membership_scopes' then
    select string_agg(distinct p.code, ', ' order by p.code) into v_missing
    from public.membership_roles mr
    join public.role_permissions rp on rp.role_id = mr.role_id
    join public.permissions p       on p.id = rp.permission_id
    where mr.membership_id = (v_row ->> 'membership_id')::uuid
      and not app.has_permission(p.code);
    if v_missing is not null then
      raise exception 'T8: scope grant would enable permissions the actor does not hold: %', v_missing
        using errcode = '42501';
    end if;
  end if;

  return null;
end;
$$;

reset role;

create trigger authz_integrity after insert or delete on public.membership_roles
  for each row execute function app.tg_authz_integrity();
create trigger authz_integrity after insert or delete on public.role_permissions
  for each row execute function app.tg_authz_integrity();
create trigger authz_integrity after insert on public.membership_scopes
  for each row execute function app.tg_authz_integrity();
