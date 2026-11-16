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
  -- R1 pilot rule: one site per tenant. When multi-site arrives, drop this constraint and the site lookups that assume one row
  -- per tenant (app.plant_date_at, pm_save_site, the plant_today view); site_one_per_tenant is also mapped in app._pm_dup.
  constraint site_one_per_tenant unique (tenant_id),
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

-- site.timezone must be a real IANA zone: a CHECK cannot read pg_timezone_names, so a trigger does it (also covers direct writes).
create function app.site_timezone_valid()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not exists (select 1 from pg_catalog.pg_timezone_names z where z.name = new.timezone) then
    raise exception 'Unknown time zone %', new.timezone using errcode = '23514';
  end if;
  return new;
end
$$;
create trigger site_timezone_valid before insert or update of timezone on public.site
  for each row execute function app.site_timezone_valid();

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
-- Server-side callers only. The tenant check is skipped only for the service role; every other caller (including no claims at all) must
-- belong to the machine's tenant, so there is no unauthenticated bypass (6a R3).
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
    and (auth.role() = 'service_role' or v.tenant_id = app.current_tenant_id())
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
    where n.nspname = 'app' and p.proname in ('target_version_append_only', 'site_timezone_valid', 'plant_date_at', 'plant_date', 'target_for')
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
  end loop;
end $$;

-- 8. Write RPCs (step 2, D2) ---------------------------------------------------------------------------------------
-- public.pm_* are the only way to change plant data: security definer, executable by authenticated, each authorises
-- (Unit Admin of an active tenant, no pending password change), validates, writes and audits in one transaction.
-- Authorisation failures COMMIT an access.denied row and RETURN {ok:false, code:'not_allowed'} (02, D13).
-- Validation / duplicate / guard failures RAISE P0001 with detail {code, field?, ...}. Success returns {ok:true, id, ...}.

create function app._pm_fail(p_code text, p_message text, p_field text default null, p_extra jsonb default null)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  raise exception '%', p_message
    using errcode = 'P0001',
          detail = (jsonb_strip_nulls(jsonb_build_object('code', p_code, 'field', p_field)) || coalesce(p_extra, '{}'::jsonb))::text;
end
$$;

-- Maps a violated unique constraint to a field error; returns normally for constraints it does not know (caller re-raises).
create function app._pm_dup(p_constraint text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if p_constraint in ('machine_tenant_code_key', 'product_tenant_code_key') then
    perform app._pm_fail('duplicate', 'This code is already in use', 'code');
  elsif p_constraint = 'line_site_name_key' then
    perform app._pm_fail('duplicate', 'A line with this name already exists', 'name');
  elsif p_constraint = 'site_one_per_tenant' then
    perform app._pm_fail('guard', 'This unit already has a site', 'site');
  end if;
end
$$;

-- Serialises per tenant (row lock first, so authorisation sees committed state), then authorises the caller as a Unit Admin.
-- Returns {ok:true, tenant_id, actor, role[, done]} (done = entity of an already-recorded request) or the generic denial.
create function app._pm_authorise(p_request_id uuid, p_source text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  v_tenant uuid;
  a record;
  v_reason text;
  v_done uuid;
begin
  select m.tenant_id into v_tenant from public.membership m where m.user_id = v_actor;
  if v_tenant is not null then
    perform 1 from public.tenant t where t.id = v_tenant for no key update;
  end if;

  select m.tenant_id, m.role, m.status, m.must_change_password, t.status as tenant_status
    into a
    from public.membership m join public.tenant t on t.id = m.tenant_id
    where m.user_id = v_actor;

  if not found then
    v_reason := 'no_membership';
  elsif a.status <> 'active' or a.tenant_status <> 'active' then
    v_reason := 'inactive';
  elsif a.must_change_password then
    v_reason := 'must_change_password';
  elsif a.role <> 'unit_admin' then
    v_reason := 'role';
  end if;

  if v_reason is not null then
    perform app.audit_denied(v_actor, v_tenant, a.role::text, v_reason, null, null, p_source);
    return jsonb_build_object('ok', false, 'code', 'not_allowed');
  end if;

  if p_request_id is null then
    perform app._pm_fail('validation', 'A request id is required', 'request_id');
  end if;
  -- Idempotency: a request id already recorded by this actor for THIS RPC (source) is a replay and returns the first outcome.
  -- The same id on a different RPC is not a replay: it falls through and trips the unique (actor, request_id) audit key.
  select e.entity_id into v_done from public.audit_event e where e.actor_user_id = v_actor and e.request_id = p_request_id and e.source = p_source;
  return jsonb_build_object('ok', true, 'tenant_id', a.tenant_id, 'actor', v_actor, 'role', a.role, 'done', v_done);
end
$$;

-- Records a denial for an id that is not the caller's: another tenant's, or unknown (indistinguishable to the caller).
create function app._pm_deny(p_auth jsonb, p_reason text, p_entity_type text, p_entity uuid, p_source text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform app.audit_denied((p_auth->>'actor')::uuid, (p_auth->>'tenant_id')::uuid, p_auth->>'role', p_reason, p_entity_type, p_entity, p_source);
  return jsonb_build_object('ok', false, 'code', 'not_allowed');
end
$$;

-- 'ok' when the row exists in the caller's tenant, else 'cross_tenant' (exists elsewhere) or 'not_found'.
create function app._pm_owned(p_table text, p_id uuid, p_tenant uuid)
returns text
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_tenant uuid;
begin
  if p_id is null then return 'not_found'; end if;
  if p_table = 'line' then select l.tenant_id into v_tenant from public.line l where l.id = p_id;
  elsif p_table = 'machine' then select m.tenant_id into v_tenant from public.machine m where m.id = p_id;
  elsif p_table = 'product' then select p.tenant_id into v_tenant from public.product p where p.id = p_id;
  else raise exception 'unknown table %', p_table; end if;
  if v_tenant is null then return 'not_found'; end if;
  if v_tenant <> p_tenant then return 'cross_tenant'; end if;
  return 'ok';
end
$$;

create function app._pm_audit(
  p_auth jsonb, p_action text, p_entity_type text, p_entity uuid, p_before jsonb, p_after jsonb, p_request uuid, p_source text
) returns void
language sql
security definer
set search_path = ''
as $$
  insert into public.audit_event (tenant_id, actor_user_id, actor_role, action, entity_type, entity_id, before, after, source, request_id)
  values ((p_auth->>'tenant_id')::uuid, (p_auth->>'actor')::uuid, p_auth->>'role', p_action, p_entity_type, p_entity, p_before, p_after, p_source, p_request)
$$;

-- Length check on an already trimmed value; null is allowed only when p_min = 0.
create function app._pm_len(p_value text, p_min int, p_max int, p_field text, p_message text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if p_value is null then
    if p_min > 0 then perform app._pm_fail('validation', p_message, p_field); end if;
  elsif length(p_value) < p_min or length(p_value) > p_max then
    perform app._pm_fail('validation', p_message, p_field);
  end if;
end
$$;

create function public.pm_save_site(p_request_id uuid, p_name text, p_timezone text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  c_src constant text := 'rpc:pm_save_site';
  a jsonb;
  v_tenant uuid;
  v_name text := btrim(p_name);
  v_tz text := nullif(btrim(p_timezone), '');
  cur public.site;
  upd public.site;
  v_c text;
begin
  a := app._pm_authorise(p_request_id, c_src);
  if not (a->>'ok')::boolean then return a; end if;
  if a->>'done' is not null then return jsonb_build_object('ok', true, 'id', (a->>'done')::uuid, 'already', true); end if;
  v_tenant := (a->>'tenant_id')::uuid;

  perform app._pm_len(v_name, 1, 80, 'name', 'Enter a name of 1 to 80 characters');
  if v_tz is null then
    select t.timezone into v_tz from public.tenant t where t.id = v_tenant;
  end if;
  begin
    perform now() at time zone v_tz;
  exception when others then
    perform app._pm_fail('validation', 'Choose a valid time zone', 'timezone');
  end;
  if not exists (select 1 from pg_catalog.pg_timezone_names z where z.name = v_tz) then
    perform app._pm_fail('validation', 'Choose a valid time zone', 'timezone');
  end if;

  select * into cur from public.site s where s.tenant_id = v_tenant;
  begin
    if not found then
      insert into public.site (tenant_id, name, timezone) values (v_tenant, v_name, v_tz) returning * into upd;
    else
      -- Dates of targets are interpreted in the site timezone; moving it would silently shift every effective date.
      if v_tz <> cur.timezone and exists (select 1 from public.target_version t where t.tenant_id = v_tenant) then
        perform app._pm_fail('guard', 'The site timezone can''t change once targets exist', 'timezone_locked');
      end if;
      update public.site s set name = v_name, timezone = v_tz, updated_at = now() where s.id = cur.id returning * into upd;
    end if;
  exception when unique_violation then
    get stacked diagnostics v_c = constraint_name;
    perform app._pm_dup(v_c);
    raise;
  end;
  if cur.id is null then
    perform app._pm_audit(a, 'site.created', 'site', upd.id, null, to_jsonb(upd) - 'created_at' - 'updated_at', p_request_id, c_src);
  else
    perform app._pm_audit(a, 'site.updated', 'site', upd.id,
      to_jsonb(cur) - 'created_at' - 'updated_at', to_jsonb(upd) - 'created_at' - 'updated_at', p_request_id, c_src);
  end if;
  return jsonb_build_object('ok', true, 'id', upd.id);
end
$$;

create function public.pm_save_line(p_request_id uuid, p_id uuid, p_name text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  c_src constant text := 'rpc:pm_save_line';
  a jsonb;
  v_tenant uuid;
  v_own text;
  v_name text := btrim(p_name);
  v_site public.site;
  cur public.line;
  upd public.line;
  v_c text;
begin
  a := app._pm_authorise(p_request_id, c_src);
  if not (a->>'ok')::boolean then return a; end if;
  if a->>'done' is not null then return jsonb_build_object('ok', true, 'id', (a->>'done')::uuid, 'already', true); end if;
  v_tenant := (a->>'tenant_id')::uuid;

  if p_id is not null then
    v_own := app._pm_owned('line', p_id, v_tenant);
    if v_own <> 'ok' then return app._pm_deny(a, v_own, 'line', p_id, c_src); end if;
  end if;
  perform app._pm_len(v_name, 1, 60, 'name', 'Enter a name of 1 to 60 characters');

  begin
    if p_id is null then
      select * into v_site from public.site s where s.tenant_id = v_tenant;
      if not found then perform app._pm_fail('validation', 'Set up your site first', 'site'); end if;
      insert into public.line (tenant_id, site_id, name) values (v_tenant, v_site.id, v_name) returning * into upd;
    else
      select * into cur from public.line l where l.id = p_id;
      if cur.archived_at is not null then perform app._pm_fail('guard', 'This line is archived', 'archived'); end if;
      update public.line l set name = v_name, updated_at = now() where l.id = p_id returning * into upd;
    end if;
  exception when unique_violation then
    get stacked diagnostics v_c = constraint_name;
    perform app._pm_dup(v_c);
    raise;
  end;

  if p_id is null then
    perform app._pm_audit(a, 'line.created', 'line', upd.id, null, to_jsonb(upd) - 'created_at' - 'updated_at', p_request_id, c_src);
  else
    perform app._pm_audit(a, 'line.updated', 'line', upd.id,
      to_jsonb(cur) - 'created_at' - 'updated_at', to_jsonb(upd) - 'created_at' - 'updated_at', p_request_id, c_src);
  end if;
  return jsonb_build_object('ok', true, 'id', upd.id);
end
$$;

create function public.pm_archive_line(p_request_id uuid, p_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  c_src constant text := 'rpc:pm_archive_line';
  a jsonb;
  v_tenant uuid;
  v_own text;
  cur public.line;
  upd public.line;
  v_codes text[];
begin
  a := app._pm_authorise(p_request_id, c_src);
  if not (a->>'ok')::boolean then return a; end if;
  if a->>'done' is not null then return jsonb_build_object('ok', true, 'id', (a->>'done')::uuid, 'already', true); end if;
  v_tenant := (a->>'tenant_id')::uuid;

  v_own := app._pm_owned('line', p_id, v_tenant);
  if v_own <> 'ok' then return app._pm_deny(a, v_own, 'line', p_id, c_src); end if;
  select * into cur from public.line l where l.id = p_id;
  if cur.archived_at is not null then return jsonb_build_object('ok', true, 'id', p_id, 'changed', false); end if;

  select array_agg(m.code order by m.code) into v_codes
    from public.machine m where m.line_id = p_id and m.retired_at is null;
  if v_codes is not null then
    perform app._pm_fail('guard', 'Move or retire its machines first', 'line', jsonb_build_object('machines', to_jsonb(v_codes)));
  end if;

  update public.line l set archived_at = now(), updated_at = now() where l.id = p_id returning * into upd;
  perform app._pm_audit(a, 'line.archived', 'line', p_id,
    to_jsonb(cur) - 'created_at' - 'updated_at', to_jsonb(upd) - 'created_at' - 'updated_at', p_request_id, c_src);
  return jsonb_build_object('ok', true, 'id', p_id, 'changed', true);
end
$$;

create function public.pm_save_machine(
  p_request_id uuid, p_id uuid, p_code text, p_name text, p_asset_tag text, p_make text, p_model text,
  p_controller text, p_line_id uuid, p_status text
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  c_src constant text := 'rpc:pm_save_machine';
  a jsonb;
  v_tenant uuid;
  v_own text;
  v_code text := btrim(p_code);
  v_name text := btrim(p_name);
  v_asset text := nullif(btrim(p_asset_tag), '');
  v_make text := nullif(btrim(p_make), '');
  v_model text := nullif(btrim(p_model), '');
  v_ctrl text := nullif(btrim(p_controller), '');
  v_site public.site;
  v_line public.line;
  cur public.machine;
  upd public.machine;
  v_c text;
begin
  a := app._pm_authorise(p_request_id, c_src);
  if not (a->>'ok')::boolean then return a; end if;
  if a->>'done' is not null then return jsonb_build_object('ok', true, 'id', (a->>'done')::uuid, 'already', true); end if;
  v_tenant := (a->>'tenant_id')::uuid;

  if p_id is not null then
    v_own := app._pm_owned('machine', p_id, v_tenant);
    if v_own <> 'ok' then return app._pm_deny(a, v_own, 'machine', p_id, c_src); end if;
  end if;
  if p_line_id is not null then
    v_own := app._pm_owned('line', p_line_id, v_tenant);
    if v_own <> 'ok' then return app._pm_deny(a, v_own, 'line', p_line_id, c_src); end if;
  end if;

  if v_code is null or v_code !~ '^[A-Za-z0-9_/-]{1,20}$' then
    perform app._pm_fail('validation', 'Code: 1 to 20 letters, digits, - _ or /', 'code');
  end if;
  perform app._pm_len(v_name, 1, 80, 'name', 'Enter a name of 1 to 80 characters');
  perform app._pm_len(v_asset, 0, 80, 'asset_tag', 'Asset tag: up to 80 characters');
  perform app._pm_len(v_make, 0, 80, 'make', 'Make: up to 80 characters');
  perform app._pm_len(v_model, 0, 80, 'model', 'Model: up to 80 characters');
  perform app._pm_len(v_ctrl, 0, 80, 'controller', 'Controller: up to 80 characters');
  if p_status is null or p_status not in ('active', 'under_maintenance') then
    perform app._pm_fail('validation', 'Choose Active or Under maintenance', 'status');
  end if;
  if p_line_id is not null then
    select * into v_line from public.line l where l.id = p_line_id;
    if v_line.archived_at is not null then perform app._pm_fail('validation', 'This line is archived', 'line_id'); end if;
  end if;

  begin
    if p_id is null then
      select * into v_site from public.site s where s.tenant_id = v_tenant;
      if not found then perform app._pm_fail('validation', 'Set up your site first', 'site'); end if;
      insert into public.machine (tenant_id, site_id, line_id, code, name, asset_tag, make, model, controller, status)
      values (v_tenant, v_site.id, p_line_id, v_code, v_name, v_asset, v_make, v_model, v_ctrl, p_status)
      returning * into upd;
    else
      select * into cur from public.machine m where m.id = p_id;
      if cur.retired_at is not null then perform app._pm_fail('guard', 'Reinstate this machine before editing it', 'retired'); end if;
      update public.machine m
      set line_id = p_line_id, code = v_code, name = v_name, asset_tag = v_asset, make = v_make, model = v_model,
          controller = v_ctrl, status = p_status, updated_at = now()
      where m.id = p_id returning * into upd;
    end if;
  exception when unique_violation then
    get stacked diagnostics v_c = constraint_name;
    perform app._pm_dup(v_c);
    raise;
  end;

  if p_id is null then
    perform app._pm_audit(a, 'machine.created', 'machine', upd.id, null, to_jsonb(upd) - 'created_at' - 'updated_at', p_request_id, c_src);
  else
    perform app._pm_audit(a, 'machine.updated', 'machine', upd.id,
      to_jsonb(cur) - 'created_at' - 'updated_at', to_jsonb(upd) - 'created_at' - 'updated_at', p_request_id, c_src);
  end if;
  return jsonb_build_object('ok', true, 'id', upd.id);
end
$$;

create function public.pm_set_machine_retired(p_request_id uuid, p_id uuid, p_retired boolean)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  c_src constant text := 'rpc:pm_set_machine_retired';
  a jsonb;
  v_own text;
  cur public.machine;
  upd public.machine;
begin
  a := app._pm_authorise(p_request_id, c_src);
  if not (a->>'ok')::boolean then return a; end if;
  if a->>'done' is not null then return jsonb_build_object('ok', true, 'id', (a->>'done')::uuid, 'already', true); end if;

  v_own := app._pm_owned('machine', p_id, (a->>'tenant_id')::uuid);
  if v_own <> 'ok' then return app._pm_deny(a, v_own, 'machine', p_id, c_src); end if;
  if p_retired is null then perform app._pm_fail('validation', 'Choose retire or reinstate', 'retired'); end if;
  select * into cur from public.machine m where m.id = p_id;
  if (cur.retired_at is not null) = p_retired then return jsonb_build_object('ok', true, 'id', p_id, 'changed', false); end if;

  if p_retired then
    update public.machine m set retired_at = now(), updated_at = now() where m.id = p_id returning * into upd;
  else
    -- A line archived while the machine was retired cannot be reused: the machine comes back without a line.
    update public.machine m
    set retired_at = null, updated_at = now(),
        line_id = case when exists (select 1 from public.line l where l.id = m.line_id and l.archived_at is not null) then null else m.line_id end
    where m.id = p_id returning * into upd;
  end if;
  perform app._pm_audit(a, case when p_retired then 'machine.retired' else 'machine.reinstated' end, 'machine', p_id,
    to_jsonb(cur) - 'created_at' - 'updated_at', to_jsonb(upd) - 'created_at' - 'updated_at', p_request_id, c_src);
  return jsonb_build_object('ok', true, 'id', p_id, 'changed', true);
end
$$;

create function public.pm_save_product(p_request_id uuid, p_id uuid, p_code text, p_description text, p_uom text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  c_src constant text := 'rpc:pm_save_product';
  a jsonb;
  v_tenant uuid;
  v_own text;
  v_code text := btrim(p_code);
  v_desc text := btrim(p_description);
  v_uom text := coalesce(nullif(btrim(p_uom), ''), 'pcs');
  cur public.product;
  upd public.product;
  v_c text;
begin
  a := app._pm_authorise(p_request_id, c_src);
  if not (a->>'ok')::boolean then return a; end if;
  if a->>'done' is not null then return jsonb_build_object('ok', true, 'id', (a->>'done')::uuid, 'already', true); end if;
  v_tenant := (a->>'tenant_id')::uuid;

  if p_id is not null then
    v_own := app._pm_owned('product', p_id, v_tenant);
    if v_own <> 'ok' then return app._pm_deny(a, v_own, 'product', p_id, c_src); end if;
  end if;
  if v_code is null or v_code !~ '^[A-Za-z0-9_/-]{1,20}$' then
    perform app._pm_fail('validation', 'Code: 1 to 20 letters, digits, - _ or /', 'code');
  end if;
  perform app._pm_len(v_desc, 1, 120, 'description', 'Enter a description of 1 to 120 characters');
  perform app._pm_len(v_uom, 1, 10, 'uom', 'Unit of measure: 1 to 10 characters');

  begin
    if p_id is null then
      insert into public.product (tenant_id, code, description, uom) values (v_tenant, v_code, v_desc, v_uom) returning * into upd;
    else
      select * into cur from public.product p where p.id = p_id;
      if cur.retired_at is not null then perform app._pm_fail('guard', 'Reinstate this product before editing it', 'retired'); end if;
      update public.product p set code = v_code, description = v_desc, uom = v_uom, updated_at = now() where p.id = p_id returning * into upd;
    end if;
  exception when unique_violation then
    get stacked diagnostics v_c = constraint_name;
    perform app._pm_dup(v_c);
    raise;
  end;

  if p_id is null then
    perform app._pm_audit(a, 'product.created', 'product', upd.id, null, to_jsonb(upd) - 'created_at' - 'updated_at', p_request_id, c_src);
  else
    perform app._pm_audit(a, 'product.updated', 'product', upd.id,
      to_jsonb(cur) - 'created_at' - 'updated_at', to_jsonb(upd) - 'created_at' - 'updated_at', p_request_id, c_src);
  end if;
  return jsonb_build_object('ok', true, 'id', upd.id);
end
$$;

create function public.pm_set_product_retired(p_request_id uuid, p_id uuid, p_retired boolean)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  c_src constant text := 'rpc:pm_set_product_retired';
  a jsonb;
  v_tenant uuid;
  v_own text;
  v_today date;
  v_codes text[];
  cur public.product;
  upd public.product;
begin
  a := app._pm_authorise(p_request_id, c_src);
  if not (a->>'ok')::boolean then return a; end if;
  if a->>'done' is not null then return jsonb_build_object('ok', true, 'id', (a->>'done')::uuid, 'already', true); end if;
  v_tenant := (a->>'tenant_id')::uuid;

  v_own := app._pm_owned('product', p_id, v_tenant);
  if v_own <> 'ok' then return app._pm_deny(a, v_own, 'product', p_id, c_src); end if;
  if p_retired is null then perform app._pm_fail('validation', 'Choose retire or reinstate', 'retired'); end if;
  select * into cur from public.product p where p.id = p_id;
  if (cur.retired_at is not null) = p_retired then return jsonb_build_object('ok', true, 'id', p_id, 'changed', false); end if;

  if p_retired then
    -- A product with a current or future target cannot be retired (AC-4): the Unit Admin ends the targets first.
    v_today := app.plant_date(v_tenant);
    select array_agg(m.code order by m.code) into v_codes
    from public.machine m
    where m.tenant_id = v_tenant
      and exists (select 1 from public.target_version v where v.machine_id = m.id and v.product_id = p_id)
      and (
        app.target_for(m.id, p_id, v_today) is not null
        or exists (select 1 from public.target_version f
                   where f.machine_id = m.id and f.product_id = p_id and f.effective_from > v_today and f.pieces_per_shift is not null
                     and app.target_for(m.id, p_id, f.effective_from) is not null) -- not cancelled by a same-day end
      );
    if v_codes is not null then
      perform app._pm_fail('guard', 'End its targets first', 'product', jsonb_build_object('machines', to_jsonb(v_codes)));
    end if;
    update public.product p set retired_at = now(), updated_at = now() where p.id = p_id returning * into upd;
  else
    update public.product p set retired_at = null, updated_at = now() where p.id = p_id returning * into upd;
  end if;
  perform app._pm_audit(a, case when p_retired then 'product.retired' else 'product.reinstated' end, 'product', p_id,
    to_jsonb(cur) - 'created_at' - 'updated_at', to_jsonb(upd) - 'created_at' - 'updated_at', p_request_id, c_src);
  return jsonb_build_object('ok', true, 'id', p_id, 'changed', true);
end
$$;

create function public.pm_set_target(p_request_id uuid, p_machine_id uuid, p_product_id uuid, p_pieces integer, p_effective_from date)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  c_src constant text := 'rpc:pm_set_target';
  a jsonb;
  v_tenant uuid;
  v_own text;
  m public.machine;
  p public.product;
  v_before integer;
  v_id uuid;
begin
  a := app._pm_authorise(p_request_id, c_src);
  if not (a->>'ok')::boolean then return a; end if;
  if a->>'done' is not null then return jsonb_build_object('ok', true, 'id', (a->>'done')::uuid, 'already', true); end if;
  v_tenant := (a->>'tenant_id')::uuid;

  v_own := app._pm_owned('machine', p_machine_id, v_tenant);
  if v_own <> 'ok' then return app._pm_deny(a, v_own, 'machine', p_machine_id, c_src); end if;
  v_own := app._pm_owned('product', p_product_id, v_tenant);
  if v_own <> 'ok' then return app._pm_deny(a, v_own, 'product', p_product_id, c_src); end if;

  if p_pieces is null or p_pieces < 1 or p_pieces > 1000000 then
    perform app._pm_fail('validation', 'Enter a whole number from 1 to 1,000,000', 'pieces');
  end if;
  if p_effective_from is null then perform app._pm_fail('validation', 'Choose a start date', 'effective_from'); end if;
  if p_effective_from < app.plant_date(v_tenant) then
    perform app._pm_fail('validation', 'Targets can''t start in the past', 'effective_from');
  end if;
  select * into m from public.machine x where x.id = p_machine_id;
  select * into p from public.product x where x.id = p_product_id;
  if m.retired_at is not null then perform app._pm_fail('guard', 'This machine is retired', 'machine_id'); end if;
  if p.retired_at is not null then perform app._pm_fail('guard', 'This product is retired', 'product_id'); end if;

  v_before := app.target_for(p_machine_id, p_product_id, p_effective_from);
  insert into public.target_version (tenant_id, machine_id, product_id, effective_from, pieces_per_shift, recorded_by, request_id)
  values (v_tenant, p_machine_id, p_product_id, p_effective_from, p_pieces, (a->>'actor')::uuid, p_request_id)
  returning id into v_id;
  perform app._pm_audit(a, 'target.set', 'target_version', v_id,
    jsonb_build_object('pieces_per_shift', v_before),
    jsonb_build_object('machine_code', m.code, 'product_code', p.code, 'pieces_per_shift', p_pieces, 'effective_from', p_effective_from),
    p_request_id, c_src);
  return jsonb_build_object('ok', true, 'id', v_id);
end
$$;

create function public.pm_end_target(p_request_id uuid, p_machine_id uuid, p_product_id uuid, p_effective_from date)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  c_src constant text := 'rpc:pm_end_target';
  a jsonb;
  v_tenant uuid;
  v_own text;
  m public.machine;
  p public.product;
  v_before integer;
  v_id uuid;
  v_cancel date[];
  v_d date;
begin
  a := app._pm_authorise(p_request_id, c_src);
  if not (a->>'ok')::boolean then return a; end if;
  if a->>'done' is not null then return jsonb_build_object('ok', true, 'id', (a->>'done')::uuid, 'already', true); end if;
  v_tenant := (a->>'tenant_id')::uuid;

  v_own := app._pm_owned('machine', p_machine_id, v_tenant);
  if v_own <> 'ok' then return app._pm_deny(a, v_own, 'machine', p_machine_id, c_src); end if;
  v_own := app._pm_owned('product', p_product_id, v_tenant);
  if v_own <> 'ok' then return app._pm_deny(a, v_own, 'product', p_product_id, c_src); end if;

  if p_effective_from is null then perform app._pm_fail('validation', 'Choose an end date', 'effective_from'); end if;
  if p_effective_from < app.plant_date(v_tenant) then
    perform app._pm_fail('validation', 'Targets can''t end in the past', 'effective_from');
  end if;
  -- Ending works for retired machines and products too: that is how their targets get cleaned up.
  -- "End" means no target from the end date onwards (6a R1): besides the null at the end date, every later scheduled change whose
  -- winning version is a target is cancelled with its own null, all in this transaction. Refused only when the pair has no target
  -- in force on the date and none scheduled after it.
  v_before := app.target_for(p_machine_id, p_product_id, p_effective_from);
  select coalesce(array_agg(f.d order by f.d), '{}') into v_cancel
    from (select distinct t.effective_from as d
            from public.target_version t
           where t.machine_id = p_machine_id and t.product_id = p_product_id and t.effective_from > p_effective_from
             and app.target_for(p_machine_id, p_product_id, t.effective_from) is not null) f;
  if v_before is null and cardinality(v_cancel) = 0 then
    perform app._pm_fail('guard', 'There is no target to end on that date', 'no_target');
  end if;
  select * into m from public.machine x where x.id = p_machine_id;
  select * into p from public.product x where x.id = p_product_id;

  insert into public.target_version (tenant_id, machine_id, product_id, effective_from, pieces_per_shift, recorded_by, request_id)
  values (v_tenant, p_machine_id, p_product_id, p_effective_from, null, (a->>'actor')::uuid, p_request_id)
  returning id into v_id;
  foreach v_d in array v_cancel loop
    insert into public.target_version (tenant_id, machine_id, product_id, effective_from, pieces_per_shift, recorded_by, request_id)
    values (v_tenant, p_machine_id, p_product_id, v_d, null, (a->>'actor')::uuid, p_request_id);
  end loop;
  perform app._pm_audit(a, 'target.ended', 'target_version', v_id,
    jsonb_build_object('pieces_per_shift', v_before),
    jsonb_build_object('machine_code', m.code, 'product_code', p.code, 'pieces_per_shift', null, 'effective_from', p_effective_from,
                       'cancelled_dates', to_jsonb(v_cancel)),
    p_request_id, c_src);
  return jsonb_build_object('ok', true, 'id', v_id, 'cancelled', to_jsonb(v_cancel));
end
$$;

do $$
declare f record;
begin
  for f in
    select p.oid::regprocedure as sig, n.nspname
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where (n.nspname = 'app' and p.proname ~ '^_pm_') or (n.nspname = 'public' and p.proname ~ '^pm_')
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    if f.nspname = 'public' then
      execute format('grant execute on function %s to authenticated', f.sig);
    end if;
  end loop;
end $$;
