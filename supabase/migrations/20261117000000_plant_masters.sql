-- 04-plant-masters (schema lock: site, line, machine, product, target_version; split with 03). Steps 1-2 write into this single file.
-- Master data a Unit Admin maintains; clients read under RLS, every write goes through public.pm_* RPC functions (step 2).

-- 1. Audit actions (registry from the Batch A prerequisite) ---------------------------------------
insert into app.audit_action (action, feature) values
  ('site.created', '04'), ('site.updated', '04'),
  ('line.created', '04'), ('line.updated', '04'), ('line.archived', '04'),
  ('machine.created', '04'), ('machine.updated', '04'), ('machine.retired', '04'), ('machine.reinstated', '04'),
  ('product.created', '04'), ('product.updated', '04'), ('product.retired', '04'), ('product.reinstated', '04'),
  ('target.set', '04'), ('target.ended', '04');

-- 2. Tables ---------------------------------------------------------------------------------------------
-- Every child carries (tenant_id, parent_id) with a composite FK to the parent's (tenant_id, id), so a row can never
-- reference another tenant's parent (D5).
create table public.site (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenant (id) on delete restrict,
  name text not null check (name = btrim(name) and length(name) between 1 and 80),
  timezone text not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint site_one_per_tenant unique (tenant_id), -- R1 pilot rule; drop this constraint when multi-site arrives
  constraint site_tenant_id_key unique (tenant_id, id)
);

create table public.line (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenant (id) on delete restrict,
  site_id uuid not null,
  name text not null check (name = btrim(name) and length(name) between 1 and 60),
  archived_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint line_tenant_id_key unique (tenant_id, id),
  constraint line_site_fk foreign key (tenant_id, site_id) references public.site (tenant_id, id) on delete restrict
);
create unique index line_site_name_key on public.line (site_id, lower(name)) where archived_at is null;

create table public.machine (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenant (id) on delete restrict,
  site_id uuid not null,
  line_id uuid,
  code text not null check (code ~ '^[A-Za-z0-9_/-]{1,20}$'),
  name text not null check (name = btrim(name) and length(name) between 1 and 80),
  asset_tag text check (asset_tag = btrim(asset_tag) and length(asset_tag) between 1 and 80),
  make text check (make = btrim(make) and length(make) between 1 and 80),
  model text check (model = btrim(model) and length(model) between 1 and 80),
  controller text check (controller = btrim(controller) and length(controller) between 1 and 80),
  status text not null default 'active' check (status in ('active', 'under_maintenance')),
  retired_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint machine_tenant_id_key unique (tenant_id, id),
  constraint machine_site_fk foreign key (tenant_id, site_id) references public.site (tenant_id, id) on delete restrict,
  constraint machine_line_fk foreign key (tenant_id, line_id) references public.line (tenant_id, id) on delete restrict
);
create unique index machine_tenant_code_key on public.machine (tenant_id, lower(code));
create index machine_line_idx on public.machine (line_id) where line_id is not null;

create table public.product (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenant (id) on delete restrict,
  code text not null check (code ~ '^[A-Za-z0-9_/-]{1,20}$'),
  description text not null check (description = btrim(description) and length(description) between 1 and 120),
  uom text not null default 'pcs' check (uom = btrim(uom) and length(uom) between 1 and 10),
  retired_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint product_tenant_id_key unique (tenant_id, id)
);
create unique index product_tenant_code_key on public.product (tenant_id, lower(code));

-- Append-only history of targets (pieces per shift) per machine x product. pieces_per_shift null = the target ended.
create table public.target_version (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenant (id) on delete restrict,
  machine_id uuid not null,
  product_id uuid not null,
  effective_from date not null,
  pieces_per_shift integer check (pieces_per_shift between 1 and 1000000),
  recorded_by uuid not null,
  recorded_at timestamptz not null default clock_timestamp(), -- D10: strictly ordered even inside one transaction
  request_id uuid,
  constraint target_version_machine_fk foreign key (tenant_id, machine_id) references public.machine (tenant_id, id) on delete restrict,
  constraint target_version_product_fk foreign key (tenant_id, product_id) references public.product (tenant_id, id) on delete restrict
);
create index target_version_lookup_idx on public.target_version (machine_id, product_id, effective_from desc, recorded_at desc);
create index target_version_product_idx on public.target_version (tenant_id, product_id);

-- 3. Row-level security: members of the tenant read, nobody writes through the API ---------------------------
do $$
declare t text;
begin
  foreach t in array array['site', 'line', 'machine', 'product', 'target_version'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('alter table public.%I force row level security', t);
    execute format($p$create policy %I on public.%I for select to authenticated using (tenant_id = (select app.current_tenant_id()))$p$, t || '_select_member', t);
    execute format('revoke all on public.%I from public, anon, authenticated, service_role', t);
    execute format('grant select on public.%I to authenticated', t);
  end loop;
end $$;
-- The service role maintains fixtures (never target_version history).
grant select, insert, update, delete on public.site, public.line, public.machine, public.product to service_role;
grant select, insert on public.target_version to service_role;

-- 4. target_version is append-only: no privilege for any role, plus a trigger that also stops the owner -----------
create function app.target_version_append_only()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  raise exception 'target_version is append-only' using errcode = 'P0001';
end
$$;
create trigger target_version_no_update_delete
  before update or delete on public.target_version
  for each row execute function app.target_version_append_only();
create trigger target_version_no_truncate
  before truncate on public.target_version
  for each statement execute function app.target_version_append_only();

-- 5. Plant date and target lookup ------------------------------------------------------------------------------
-- Plant date = calendar date in the site's timezone (tenant timezone until a site exists). Computed on the server only (FR-4).
create function app.plant_date_at(p_tenant uuid, p_at timestamptz)
returns date
language sql
stable
security definer
set search_path = ''
as $$
  select (p_at at time zone coalesce(s.timezone, t.timezone))::date
  from public.tenant t
  left join public.site s on s.tenant_id = t.id
  where t.id = p_tenant
$$;

create function app.plant_date(p_tenant uuid)
returns date
language sql
stable
security definer
set search_path = ''
as $$ select app.plant_date_at(p_tenant, now()) $$;

-- Pieces per shift in force for a machine x product on a plant date; null when there is none or it was ended (AC-7).
-- Server-side callers only. When called with a user's JWT it also refuses other tenants' machines.
create function app.target_for(p_machine uuid, p_product uuid, p_date date)
returns integer
language sql
stable
security definer
set search_path = ''
as $$
  select v.pieces_per_shift
  from public.target_version v
  where v.machine_id = p_machine
    and v.product_id = p_product
    and v.effective_from <= p_date
    and (auth.uid() is null or v.tenant_id = app.current_tenant_id())
  order by v.effective_from desc, v.recorded_at desc, v.id desc
  limit 1
$$;

-- 6. Read views (security invoker: RLS applies to the caller) ------------------------------------------------------
-- Today's plant date for the caller's tenant (lets the UI show "current / next" without doing date maths itself).
create view public.plant_today with (security_invoker = true) as
  select s.tenant_id, (now() at time zone s.timezone)::date as plant_date
  from public.site s;

-- The target in force today per machine x product (ended pairs and pairs that only start in the future are absent).
create view public.current_target with (security_invoker = true) as
  select x.tenant_id, x.machine_id, x.product_id, x.pieces_per_shift, x.effective_from
  from (
    select distinct on (v.machine_id, v.product_id)
      v.tenant_id, v.machine_id, v.product_id, v.pieces_per_shift, v.effective_from
    from public.target_version v
    join public.tenant t on t.id = v.tenant_id
    left join public.site s on s.tenant_id = v.tenant_id
    where v.effective_from <= (now() at time zone coalesce(s.timezone, t.timezone))::date
    order by v.machine_id, v.product_id, v.effective_from desc, v.recorded_at desc, v.id desc
  ) x
  where x.pieces_per_shift is not null;

revoke all on public.plant_today, public.current_target from public, anon, authenticated, service_role;
grant select on public.plant_today, public.current_target to authenticated;

-- 7. Function privileges: no app function is executable by clients (test 004). pm_* wrappers in public are the entry points.
do $$
declare f record;
begin
  for f in
    select p.oid::regprocedure as sig
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'app' and p.proname in ('target_version_append_only', 'plant_date_at', 'plant_date', 'target_for')
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
  end loop;
end $$;
