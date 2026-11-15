-- 01-walking-skeleton: tenant + membership with tenant isolation (spec §Data model).
create type public.tenant_status as enum ('active', 'suspended');
create type public.member_role as enum ('unit_admin', 'supervisor', 'maintenance');
create type public.membership_status as enum ('active', 'inactive');

create table public.tenant (
  id uuid primary key default gen_random_uuid(),
  name text not null check (length(trim(name)) > 0),
  status public.tenant_status not null default 'active',
  timezone text not null default 'Asia/Kolkata',
  created_at timestamptz not null default now()
);

create table public.membership (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenant (id) on delete restrict,
  user_id uuid not null references auth.users (id) on delete cascade,
  role public.member_role not null,
  status public.membership_status not null default 'active',
  created_at timestamptz not null default now(),
  constraint membership_one_tenant_per_user unique (user_id)
);
create index membership_tenant_id_idx on public.membership (tenant_id);

-- Tenant of the caller's active membership in an active tenant, else null.
create schema if not exists app;
grant usage on schema app to authenticated;

create function app.current_tenant_id()
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
    and t.status = 'active'
  limit 1
$$;
revoke all on function app.current_tenant_id() from public, anon;
grant execute on function app.current_tenant_id() to authenticated;

-- Row-level security.
alter table public.tenant enable row level security;
alter table public.tenant force row level security;
alter table public.membership enable row level security;
alter table public.membership force row level security;

create policy tenant_select_own on public.tenant
  for select to authenticated
  using (id = app.current_tenant_id());

create policy membership_select_own on public.membership
  for select to authenticated
  using (user_id = (select auth.uid()));

-- Clients read only; writes come via service role now and RPC functions later (02).
revoke all on public.tenant, public.membership from anon, authenticated;
grant select on public.tenant, public.membership to authenticated;
