-- 03-tenant-console (architecture lock + split schema lock: tenant columns, platform_admin, phone_claim).
-- Steps 1-3 of the plan write into this single file.

-- 1. Tenant columns -------------------------------------------------------------------------------------------------------------------------
create type public.plan_label as enum ('trial', 'active');
alter table public.tenant
  add column plan_label public.plan_label not null default 'trial',
  add column updated_at timestamptz not null default now(),
  add column suspended_reason text,
  add constraint tenant_name_length check (length(name) <= 80),
  add constraint tenant_suspended_reason_length check (suspended_reason is null or length(suspended_reason) between 1 and 200);
create unique index tenant_name_lower_key on public.tenant (lower(name));

-- 2. Platform Super Admin identity (separate from membership) ----------------------------------------------------------------------------------
create table public.platform_admin (
  user_id uuid primary key references auth.users (id) on delete cascade,
  full_name text not null,
  phone_e164 text not null,
  status public.membership_status not null default 'active',
  must_change_password boolean not null default true,
  temp_password_expires_at timestamptz,
  created_by uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint platform_admin_full_name_check check (length(full_name) between 1 and 80 and full_name = btrim(full_name)),
  constraint platform_admin_phone_e164_check check (phone_e164 ~ '^\+91[6-9][0-9]{9}$')
);
alter table public.platform_admin enable row level security;
alter table public.platform_admin force row level security;
create policy platform_admin_select_own on public.platform_admin
  for select to authenticated
  using (user_id = (select auth.uid()));
revoke all on public.platform_admin from public, anon, authenticated, service_role;
grant select on public.platform_admin to authenticated, service_role; -- writes only through the service-only SQL functions

-- 3. phone_claim: one phone per person across membership and platform_admin ---------------------------------------------------------------------
create table app.phone_claim (
  phone_e164 text not null,
  user_id uuid not null,
  kind text not null check (kind in ('membership', 'platform_admin')),
  constraint phone_claim_phone_e164_key primary key (phone_e164),
  constraint phone_claim_user_id_key unique (user_id)
);
revoke all on app.phone_claim from public, anon, authenticated;

insert into app.phone_claim (phone_e164, user_id, kind)
select m.phone_e164, m.user_id, 'membership' from public.membership m;

create function app.phone_claim_sync()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_kind text := case tg_table_name when 'membership' then 'membership' else 'platform_admin' end;
begin
  if tg_op = 'INSERT' then
    insert into app.phone_claim (phone_e164, user_id, kind) values (new.phone_e164, new.user_id, v_kind);
    return new;
  elsif tg_op = 'UPDATE' then
    if new.phone_e164 is distinct from old.phone_e164 then
      update app.phone_claim c set phone_e164 = new.phone_e164 where c.user_id = new.user_id and c.kind = v_kind;
    end if;
    return new;
  else
    delete from app.phone_claim c where c.user_id = old.user_id and c.kind = v_kind;
    return old;
  end if;
end
$$;
revoke all on function app.phone_claim_sync() from public, anon, authenticated;

create trigger membership_phone_claim after insert or update of phone_e164 or delete on public.membership
  for each row execute function app.phone_claim_sync();
create trigger platform_admin_phone_claim after insert or update of phone_e164 or delete on public.platform_admin
  for each row execute function app.phone_claim_sync();

-- 02's duplicate check now sees every phone, including Super Admins' (same message, no existence leak).
create or replace function app._ua_dupcheck(p_tenant uuid, p_emp text, p_phone text, p_exclude uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if p_phone is not null and exists (
    select 1 from app.phone_claim c where c.phone_e164 = p_phone and c.user_id is distinct from p_exclude
  ) then
    perform app._ua_fail('duplicate', 'This phone number is already registered', 'phone');
  end if;
  if p_emp is not null and exists (
    select 1 from public.membership m
    where m.tenant_id = p_tenant and lower(m.employee_id) = lower(p_emp) and m.user_id is distinct from p_exclude
  ) then
    perform app._ua_fail('duplicate', 'This employee ID is already in use', 'employee_id');
  end if;
end
$$;

-- 4. Gate helper (not executable by clients: only security-definer functions use it) ---------------------------------------------------------------
create function app.is_platform_admin()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.platform_admin pa
    where pa.user_id = auth.uid() and pa.status = 'active' and pa.must_change_password = false
  )
$$;
revoke all on function app.is_platform_admin() from public, anon, authenticated;
grant execute on function app.is_platform_admin() to service_role;

-- A Super Admin reads tenant rows (tenant-level facts only). The check is inlined: 02's test 004 forbids any client-executable app function
-- besides the two RLS helpers. platform_admin's own-row policy lets the sub-select see exactly the caller's row.
create policy tenant_select_platform_admin on public.tenant
  for select to authenticated
  using (exists (
    select 1 from public.platform_admin pa
    where pa.user_id = (select auth.uid()) and pa.status = 'active' and pa.must_change_password = false
  ));

-- 5. Audit action registry (PR #6) ----------------------------------------------------------------------------------------------------------------
insert into app.audit_action (action, feature) values
  ('tenant.created', '03'), ('tenant.updated', '03'), ('tenant.suspended', '03'), ('tenant.activated', '03'),
  ('platform_admin.created', '03'), ('platform_admin.deactivated', '03'), ('platform_admin.reactivated', '03'),
  ('platform_admin.password_reset', '03'), ('platform_admin.password_changed', '03');
