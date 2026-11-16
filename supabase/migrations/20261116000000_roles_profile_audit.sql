-- 02-tenancy-and-roles (schema lock 02): membership profile, must-change-password gate, role helper,
-- role-aware RLS, append-only audit_event. Steps 2-3 of the plan write into this single file.

-- 1. Membership profile columns --------------------------------------------------------------
alter table public.membership
  add column full_name text,
  add column employee_id text,
  add column phone_e164 text,
  add column must_change_password boolean not null default false,
  add column temp_password_expires_at timestamptz,
  add column created_by uuid,
  add column updated_at timestamptz not null default now();

-- Backfill existing rows (dev fixtures only) with placeholders, then constrain.
with numbered as (
  select id, row_number() over (order by created_at, id) as rn from public.membership
)
update public.membership m
set full_name = 'Fixture',
    employee_id = 'FX-' || left(m.id::text, 8),
    phone_e164 = '+9190000' || lpad(n.rn::text, 5, '0'),
    must_change_password = false
from numbered n
where n.id = m.id;

alter table public.membership
  alter column full_name set not null,
  alter column employee_id set not null,
  alter column phone_e164 set not null,
  alter column must_change_password set default true;

alter table public.membership
  add constraint membership_full_name_check check (length(full_name) between 1 and 80 and full_name = btrim(full_name)),
  add constraint membership_employee_id_check check (employee_id ~ '^[A-Za-z0-9_/-]{1,30}$'),
  add constraint membership_phone_e164_check check (phone_e164 ~ '^\+91[6-9][0-9]{9}$'),
  add constraint membership_phone_e164_key unique (phone_e164);
create unique index membership_tenant_employee_id_key on public.membership (tenant_id, lower(employee_id));

-- 2. Helpers: the must-change gate lives here, so every RLS policy built on them inherits it ---
create or replace function app.current_tenant_id()
returns uuid
language sql
stable
security definer
set search_path = ''
as $$
  select m.tenant_id
  from public.membership m
  join public.tenant t on t.id = m.tenant_id
  where m.user_id = auth.uid()
    and m.status = 'active'
    and m.must_change_password = false
    and t.status = 'active'
  limit 1
$$;

create function app."current_role"()
returns public.member_role
language sql
stable
security definer
set search_path = ''
as $$
  select m.role
  from public.membership m
  join public.tenant t on t.id = m.tenant_id
  where m.user_id = auth.uid()
    and m.status = 'active'
    and m.must_change_password = false
    and t.status = 'active'
  limit 1
$$;
revoke all on function app."current_role"() from public, anon;
grant execute on function app."current_role"() to authenticated;

-- 3. Membership RLS: own row, or every row of the tenant for its Unit Admin ----------------------
drop policy membership_select_own on public.membership;
create policy membership_select on public.membership
  for select to authenticated
  using (
    user_id = (select auth.uid())
    or (tenant_id = app.current_tenant_id() and app."current_role"() = 'unit_admin')
  );

-- 4. Audit events (tenant-owned, append-only) ---------------------------------------------------
create table public.audit_event (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid references public.tenant (id) on delete restrict, -- null only for denials by callers with no tenant
  actor_user_id uuid,
  actor_role text,
  action text not null check (action in (
    'user.created', 'user.updated', 'user.deactivated', 'user.reactivated',
    'user.password_reset', 'user.password_changed', 'access.denied'
  )),
  entity_type text,
  entity_id uuid,
  before jsonb,
  after jsonb,
  reason text,
  source text not null,
  request_id uuid,
  occurred_at timestamptz not null default now()
);
create unique index audit_event_actor_request_key on public.audit_event (actor_user_id, request_id)
  where request_id is not null;
create index audit_event_tenant_occurred_idx on public.audit_event (tenant_id, occurred_at desc);

alter table public.audit_event enable row level security;
alter table public.audit_event force row level security;

create policy audit_event_select_ua on public.audit_event
  for select to authenticated
  using (tenant_id = app.current_tenant_id() and app."current_role"() = 'unit_admin');

-- Privileges: clients read only; service role may append, never change or remove.
revoke all on public.audit_event from public, anon, authenticated, service_role;
grant select on public.audit_event to authenticated;
grant select, insert on public.audit_event to service_role;

-- Second layer: blocks UPDATE/DELETE/TRUNCATE even for roles that hold the privilege (owner, superuser paths).
create function app.audit_event_append_only()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  raise exception 'audit_event is append-only' using errcode = 'P0001';
end
$$;
revoke all on function app.audit_event_append_only() from public, anon, authenticated;
create trigger audit_event_no_update_delete
  before update or delete on public.audit_event
  for each row execute function app.audit_event_append_only();
create trigger audit_event_no_truncate
  before truncate on public.audit_event
  for each statement execute function app.audit_event_append_only();
