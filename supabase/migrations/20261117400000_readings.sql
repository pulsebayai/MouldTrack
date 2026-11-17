-- 06-shift-readings (schema lock, 06's share, split with 07: production_reading, production_summary, cavity_version and the counter columns of machine).
-- Opening/closing counter readings per machine-shift occurrence, counter semantics per machine (unit + optional maximum + cavities), an append-only
-- production summary with a versioned calculation, and the reads the supervisor and the Unit Admin need. Clients read under RLS (Unit Admins read
-- the tables; supervisors only through the read RPCs); every write goes through public.rd_* RPC functions that reuse 04/05's helpers.
-- The RPCs are named rd_* (not pm_*/sh_*): 04's and 05's pgTAP tests pin the number of pm_* and sh_* RPCs.
-- One file, written step by step: 1 tables + counter settings + cavities, 2 reading RPCs, 3 summary, 4 reads.

-- 1. Audit actions -------------------------------------------------------------------------------------------------
insert into app.audit_action (action, feature) values
  ('machine_counter.updated', '06'),
  ('cavities.set', '06'), ('cavities.ended', '06'),
  ('reading.opening', '06'), ('reading.closing', '06'), ('reading.corrected', '06');

-- 2. Counter settings on 04's machine table (D3) ----------------------------------------------------------------------
-- counter_unit: what the machine's counter counts. pieces = one count per piece; shots = one count per cycle (pieces = shots x cavities).
-- counter_max: the highest value the counter shows before it rolls over to 0 (null = unknown, a drop is then never guessed). Changed only
-- through public.rd_set_machine_counter; existing machines default to pieces / no maximum.
alter table public.machine
  add column counter_unit text not null default 'pieces' constraint machine_counter_unit_check check (counter_unit in ('pieces', 'shots')),
  add column counter_max bigint constraint machine_counter_max_check check (counter_max between 9 and 1000000000000);

-- 3. Tables ------------------------------------------------------------------------------------------------------------
-- Cavities per machine x product, effective-dated and append-only like target_version. cavities null = the setting ended (default 1 applies).
create table public.cavity_version (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenant (id) on delete restrict,
  machine_id uuid not null,
  product_id uuid not null,
  effective_from date not null,
  cavities integer check (cavities between 1 and 256),
  recorded_by uuid not null,
  recorded_at timestamptz not null default clock_timestamp(), -- strictly ordered even inside one transaction
  request_id uuid,
  constraint cavity_version_machine_fk foreign key (tenant_id, machine_id) references public.machine (tenant_id, id) on delete restrict,
  constraint cavity_version_product_fk foreign key (tenant_id, product_id) references public.product (tenant_id, id) on delete restrict
);
create index cavity_version_lookup_idx on public.cavity_version (machine_id, product_id, effective_from desc, recorded_at desc);
create index cavity_version_product_idx on public.cavity_version (tenant_id, product_id);

-- A reading is never changed: a correction is a new row that supersedes the earlier one (supersedes_id). The current reading of a kind for a
-- machine-occurrence is the one nothing supersedes. `late` is stored at insert (never recomputed) and a correction carries the flag of the
-- occurrence's earliest submission. recorded_by has no foreign key: history must outlive the membership.
create table public.production_reading (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenant (id) on delete restrict,
  machine_id uuid not null,
  shift_id uuid not null,
  shift_date date not null,
  kind text not null check (kind in ('opening', 'closing')),
  product_id uuid,
  counter_value bigint not null check (counter_value between 0 and 1000000000000),
  good integer check (good between 0 and 10000000),
  reject integer check (reject between 0 and 10000000),
  remarks text check (remarks = btrim(remarks) and length(remarks) between 1 and 500),
  late boolean not null,
  entered_by_ua boolean not null default false,
  supersedes_id uuid,
  correction_reason text check (correction_reason = btrim(correction_reason) and length(correction_reason) between 1 and 200),
  recorded_by uuid not null,
  recorded_at timestamptz not null default now(),
  request_id uuid,
  constraint production_reading_tenant_id_key unique (tenant_id, id),
  constraint production_reading_machine_fk foreign key (tenant_id, machine_id) references public.machine (tenant_id, id) on delete restrict,
  constraint production_reading_shift_fk foreign key (tenant_id, shift_id) references public.shift (tenant_id, id) on delete restrict,
  constraint production_reading_product_fk foreign key (tenant_id, product_id) references public.product (tenant_id, id) on delete restrict,
  constraint production_reading_supersedes_fk foreign key (tenant_id, supersedes_id) references public.production_reading (tenant_id, id) on delete restrict,
  -- an opening names its product and has no good/reject; a closing has good + reject and no product
  constraint production_reading_shape check (
    (kind = 'opening' and product_id is not null and good is null and reject is null)
    or (kind = 'closing' and product_id is null and good is not null and reject is not null)),
  constraint production_reading_correction_reason check ((supersedes_id is null) = (correction_reason is null))
);
-- One original reading per kind and machine-occurrence, and every reading is superseded at most once: the chain of corrections is linear.
create unique index production_reading_original_key on public.production_reading (machine_id, shift_id, shift_date, kind) where supersedes_id is null;
create unique index production_reading_supersede_key on public.production_reading (supersedes_id) where supersedes_id is not null;
create index production_reading_occurrence_idx on public.production_reading (tenant_id, shift_id, shift_date, machine_id);
create index production_reading_machine_idx on public.production_reading (machine_id, recorded_at desc);
create index production_reading_product_idx on public.production_reading (tenant_id, product_id) where product_id is not null;

-- One row per calculation (D7): the inputs it used (snapshot) and what was derived. calc_version identifies the rule set, so a later rule
-- change appends calc_version 2 rows and never rewrites these. The latest row per machine-occurrence is the current one.
create table public.production_summary (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenant (id) on delete restrict,
  machine_id uuid not null,
  shift_id uuid not null,
  shift_date date not null,
  calc_version integer not null check (calc_version >= 1),
  product_id uuid not null,
  counter_unit text not null check (counter_unit in ('pieces', 'shots')),
  cavities integer not null check (cavities between 1 and 256), -- the multiplier used (1 for a pieces counter)
  counter_max bigint,
  opening_reading_id uuid not null,
  closing_reading_id uuid not null,
  opening_counter bigint not null,
  closing_counter bigint not null,
  good integer not null,
  reject integer not null,
  target integer, -- app.effective_target on the shift date; null = no target set
  movement_units bigint, -- null when it needs review
  movement_pieces bigint,
  unaccounted bigint, -- movement pieces - good - reject
  attainment_pct numeric(14, 2), -- good / target * 100; null without a target
  rollover boolean not null,
  needs_review boolean not null,
  over_reported boolean not null,
  late_opening boolean not null,
  late_closing boolean not null,
  entered_by_ua boolean not null,
  recorded_by uuid,
  recorded_at timestamptz not null default clock_timestamp(),
  request_id uuid,
  constraint production_summary_machine_fk foreign key (tenant_id, machine_id) references public.machine (tenant_id, id) on delete restrict,
  constraint production_summary_shift_fk foreign key (tenant_id, shift_id) references public.shift (tenant_id, id) on delete restrict,
  constraint production_summary_product_fk foreign key (tenant_id, product_id) references public.product (tenant_id, id) on delete restrict,
  constraint production_summary_opening_fk foreign key (tenant_id, opening_reading_id) references public.production_reading (tenant_id, id) on delete restrict,
  constraint production_summary_closing_fk foreign key (tenant_id, closing_reading_id) references public.production_reading (tenant_id, id) on delete restrict
);
create index production_summary_current_idx on public.production_summary (machine_id, shift_id, shift_date, recorded_at desc);
create index production_summary_occurrence_idx on public.production_summary (tenant_id, shift_id, shift_date);
create index production_summary_product_idx on public.production_summary (tenant_id, product_id);

-- 4. Row-level security: Unit Admins read, nobody writes through the API ------------------------------------------------------
-- A supervisor has no table access at all: they read their own readings through the read RPCs (step 4), which apply the ownership rule.
do $$
declare t text;
begin
  foreach t in array array['cavity_version', 'production_reading', 'production_summary'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('alter table public.%I force row level security', t);
    execute format($p$create policy %I on public.%I for select to authenticated
      using (tenant_id = (select app.current_tenant_id()) and (select app."current_role"()) = 'unit_admin')$p$, t || '_select_ua', t);
    execute format('revoke all on public.%I from public, anon, authenticated, service_role', t);
    execute format('grant select on public.%I to authenticated', t);
    execute format('grant select, insert on public.%I to service_role', t); -- fixtures only; history is never changed
  end loop;
end $$;

-- 5. Append-only history (no privilege for any role, plus triggers that also stop the owner) ---------------------------------------
create function app.rd_append_only()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  raise exception '% is append-only', tg_table_name using errcode = 'P0001';
end
$$;
do $$
declare t text;
begin
  foreach t in array array['cavity_version', 'production_reading', 'production_summary'] loop
    execute format('create trigger %I before update or delete on public.%I for each row execute function app.rd_append_only()', t || '_no_update_delete', t);
    execute format('create trigger %I before truncate on public.%I for each statement execute function app.rd_append_only()', t || '_no_truncate', t);
  end loop;
end $$;

-- A correction supersedes a reading of the same kind and machine-occurrence (a composite FK cannot say that).
create function app.rd_reading_chain()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  prev public.production_reading;
begin
  if new.supersedes_id is not null then
    select * into prev from public.production_reading r where r.id = new.supersedes_id;
    if prev.kind <> new.kind or prev.machine_id <> new.machine_id or prev.shift_id <> new.shift_id or prev.shift_date <> new.shift_date then
      raise exception 'A correction must supersede a reading of the same kind and machine-occurrence' using errcode = '23514';
    end if;
  end if;
  return new;
end
$$;
create trigger production_reading_chain before insert on public.production_reading for each row execute function app.rd_reading_chain();

-- The counter unit decides what every stored reading means, so it is locked once the machine has one (also for direct writes).
create function app.rd_machine_unit_lock()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if exists (select 1 from public.production_reading r where r.machine_id = new.id) then
    raise exception 'Readings already use this unit' using errcode = 'P0001', detail = '{"code":"counter_unit_locked","field":"counter_unit"}';
  end if;
  return new;
end
$$;
create trigger machine_counter_unit_lock before update of counter_unit on public.machine
  for each row when (old.counter_unit is distinct from new.counter_unit) execute function app.rd_machine_unit_lock();

-- 6. Cavities lookup (D4) -----------------------------------------------------------------------------------------------------
-- The raw setting in force for a machine x product on a plant date; null when there is none or it was ended. Server-side callers only; the tenant
-- check is skipped only for the service role (like app.target_for: no claims at all gets nothing).
create function app._cavities_raw(p_machine uuid, p_product uuid, p_date date)
returns integer
language sql
stable
security definer
set search_path = ''
as $$
  select v.cavities
  from public.cavity_version v
  where v.machine_id = p_machine
    and v.product_id = p_product
    and v.effective_from <= p_date
    and (auth.role() = 'service_role' or v.tenant_id = app.current_tenant_id())
  order by v.effective_from desc, v.recorded_at desc, v.id desc
  limit 1
$$;

-- Cavities in force, 1 when none is set (AC-2).
create function app.cavities_for(p_machine uuid, p_product uuid, p_date date)
returns integer
language sql
stable
security definer
set search_path = ''
as $$ select coalesce(app._cavities_raw(p_machine, p_product, p_date), 1) $$;

-- 7. Write RPCs: counter settings and cavities ---------------------------------------------------------------------------------
-- Same contract as 04's pm_* RPCs (D2): authorise via app._pm_authorise (Unit Admin only, per-tenant lock, idempotency by request id + source),
-- denials are committed and returned as {ok:false, code:'not_allowed'}, validation/guard errors raise P0001 with detail {code, field?, ...}.
create function public.rd_set_machine_counter(p_request_id uuid, p_machine_id uuid, p_unit text, p_max bigint)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  c_src constant text := 'rpc:rd_set_machine_counter';
  a jsonb;
  v_tenant uuid;
  v_own text;
  v_unit text := lower(btrim(p_unit));
  cur public.machine;
  upd public.machine;
begin
  a := app._pm_authorise(p_request_id, c_src);
  if not (a->>'ok')::boolean then return a; end if;
  if a->>'done' is not null then return jsonb_build_object('ok', true, 'id', (a->>'done')::uuid, 'already', true); end if;
  v_tenant := (a->>'tenant_id')::uuid;

  v_own := app._pm_owned('machine', p_machine_id, v_tenant);
  if v_own <> 'ok' then return app._pm_deny(a, v_own, 'machine', p_machine_id, c_src); end if;
  if v_unit is null or v_unit not in ('pieces', 'shots') then
    perform app._pm_fail('validation', 'Choose Pieces or Shots/cycles', 'counter_unit');
  end if;
  if p_max is not null and (p_max < 9 or p_max > 1000000000000) then
    perform app._pm_fail('validation', 'Enter a whole number from 9 to 1,000,000,000,000, or leave it empty', 'counter_max');
  end if;
  select * into cur from public.machine m where m.id = p_machine_id;
  if cur.retired_at is not null then perform app._pm_fail('guard', 'Reinstate this machine before editing it', 'retired'); end if;
  if cur.counter_unit = v_unit and cur.counter_max is not distinct from p_max then
    return jsonb_build_object('ok', true, 'id', p_machine_id, 'changed', false);
  end if;
  if cur.counter_unit <> v_unit and exists (select 1 from public.production_reading r where r.machine_id = p_machine_id) then
    perform app._pm_fail('guard', 'Readings already use this unit', 'counter_unit_locked');
  end if;

  update public.machine m set counter_unit = v_unit, counter_max = p_max, updated_at = now() where m.id = p_machine_id returning * into upd;
  perform app._pm_audit(a, 'machine_counter.updated', 'machine', p_machine_id,
    jsonb_build_object('machine_code', cur.code, 'counter_unit', cur.counter_unit, 'counter_max', cur.counter_max),
    jsonb_build_object('machine_code', upd.code, 'counter_unit', upd.counter_unit, 'counter_max', upd.counter_max),
    p_request_id, c_src);
  return jsonb_build_object('ok', true, 'id', p_machine_id, 'changed', true);
end
$$;

create function public.rd_set_cavities(p_request_id uuid, p_machine_id uuid, p_product_id uuid, p_cavities integer, p_effective_from date)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  c_src constant text := 'rpc:rd_set_cavities';
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

  if p_cavities is null or p_cavities < 1 or p_cavities > 256 then
    perform app._pm_fail('validation', 'Enter a whole number from 1 to 256', 'cavities');
  end if;
  if p_effective_from is null then perform app._pm_fail('validation', 'Choose a start date', 'effective_from'); end if;
  if p_effective_from < app.plant_date(v_tenant) then
    perform app._pm_fail('validation', 'Cavities can''t start in the past', 'effective_from');
  end if;
  select * into m from public.machine x where x.id = p_machine_id;
  select * into p from public.product x where x.id = p_product_id;
  if m.retired_at is not null then perform app._pm_fail('guard', 'This machine is retired', 'machine_id'); end if;
  if p.retired_at is not null then perform app._pm_fail('guard', 'This product is retired', 'product_id'); end if;
  if m.counter_unit <> 'shots' then perform app._pm_fail('guard', 'Cavities apply to machines whose counter counts shots or cycles', 'not_shots'); end if;

  v_before := app._cavities_raw(p_machine_id, p_product_id, p_effective_from);
  insert into public.cavity_version (tenant_id, machine_id, product_id, effective_from, cavities, recorded_by, request_id)
  values (v_tenant, p_machine_id, p_product_id, p_effective_from, p_cavities, (a->>'actor')::uuid, p_request_id)
  returning id into v_id;
  perform app._pm_audit(a, 'cavities.set', 'cavity_version', v_id,
    jsonb_build_object('cavities', v_before),
    jsonb_build_object('machine_code', m.code, 'product_code', p.code, 'cavities', p_cavities, 'effective_from', p_effective_from),
    p_request_id, c_src);
  return jsonb_build_object('ok', true, 'id', v_id);
end
$$;

-- "End" means the default (1) applies from the end date onwards (04's rule for targets): besides the null at the end date, every later scheduled
-- change whose winning version is a setting is cancelled with its own null, all in this transaction.
create function public.rd_end_cavities(p_request_id uuid, p_machine_id uuid, p_product_id uuid, p_effective_from date)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  c_src constant text := 'rpc:rd_end_cavities';
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
    perform app._pm_fail('validation', 'Cavities can''t end in the past', 'effective_from');
  end if;
  -- Works for retired machines and products too: that is how their settings get cleaned up.
  v_before := app._cavities_raw(p_machine_id, p_product_id, p_effective_from);
  select coalesce(array_agg(f.d order by f.d), '{}') into v_cancel
    from (select distinct t.effective_from as d
            from public.cavity_version t
           where t.machine_id = p_machine_id and t.product_id = p_product_id and t.effective_from > p_effective_from
             and app._cavities_raw(p_machine_id, p_product_id, t.effective_from) is not null) f;
  if v_before is null and cardinality(v_cancel) = 0 then
    perform app._pm_fail('guard', 'There is no cavity setting to end on that date', 'no_cavities');
  end if;
  select * into m from public.machine x where x.id = p_machine_id;
  select * into p from public.product x where x.id = p_product_id;

  insert into public.cavity_version (tenant_id, machine_id, product_id, effective_from, cavities, recorded_by, request_id)
  values (v_tenant, p_machine_id, p_product_id, p_effective_from, null, (a->>'actor')::uuid, p_request_id)
  returning id into v_id;
  foreach v_d in array v_cancel loop
    insert into public.cavity_version (tenant_id, machine_id, product_id, effective_from, cavities, recorded_by, request_id)
    values (v_tenant, p_machine_id, p_product_id, v_d, null, (a->>'actor')::uuid, p_request_id);
  end loop;
  perform app._pm_audit(a, 'cavities.ended', 'cavity_version', v_id,
    jsonb_build_object('cavities', v_before),
    jsonb_build_object('machine_code', m.code, 'product_code', p.code, 'cavities', null, 'effective_from', p_effective_from, 'cancelled_dates', to_jsonb(v_cancel)),
    p_request_id, c_src);
  return jsonb_build_object('ok', true, 'id', v_id, 'cancelled', to_jsonb(v_cancel));
end
$$;

-- 8. Reading authorisation and lookup helpers (step 2) ---------------------------------------------------------------------------
-- Same contract as 04's _pm_authorise (per-tenant row lock first, idempotency by request id + source, generic audited denial) but any active
-- Unit Admin or supervisor passes (04's helper denies every non-Unit-Admin). The rd_* RPCs call app._pm_authorise( first for callers without a
-- membership (a Super Admin, a stranger), the 05 pattern, so that denial rule lives in one place and 022's static check holds.
create function app._rd_authorise(p_request_id uuid, p_source text)
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
  elsif a.role::text not in ('unit_admin', 'supervisor') then
    v_reason := 'role';
  end if;
  if v_reason is not null then
    perform app.audit_denied(v_actor, v_tenant, a.role::text, v_reason, null, null, p_source);
    return jsonb_build_object('ok', false, 'code', 'not_allowed');
  end if;
  if p_request_id is null then
    perform app._pm_fail('validation', 'A request id is required', 'request_id');
  end if;
  -- A request id already recorded by this actor for THIS RPC is a replay; on another RPC it trips the unique (actor, request_id) audit key.
  select e.entity_id into v_done from public.audit_event e where e.actor_user_id = v_actor and e.request_id = p_request_id and e.source = p_source;
  return jsonb_build_object('ok', true, 'tenant_id', a.tenant_id, 'actor', v_actor, 'role', a.role, 'done', v_done);
end
$$;

-- 'ok' when the reading exists in the caller's tenant, else 'cross_tenant' (exists elsewhere) or 'not_found'.
create function app._rd_owned(p_reading uuid, p_tenant uuid)
returns text
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_tenant uuid;
begin
  if p_reading is null then return 'not_found'; end if;
  select r.tenant_id into v_tenant from public.production_reading r where r.id = p_reading;
  if v_tenant is null then return 'not_found'; end if;
  if v_tenant <> p_tenant then return 'cross_tenant'; end if;
  return 'ok';
end
$$;

-- The current reading of a kind for a machine-occurrence: the one nothing supersedes (zero or one row).
create function app._rd_current(p_machine uuid, p_shift uuid, p_date date, p_kind text)
returns setof public.production_reading
language sql
stable
security definer
set search_path = ''
as $$
  select r.*
  from public.production_reading r
  where r.machine_id = p_machine and r.shift_id = p_shift and r.shift_date = p_date and r.kind = p_kind
    and (auth.role() = 'service_role' or r.tenant_id = app.current_tenant_id())
    and not exists (select 1 from public.production_reading n where n.supersedes_id = r.id)
$$;

-- D5: a reading is late when it is submitted more than 30 minutes after its boundary (opening: occurrence start, closing: occurrence end).
create function app._rd_is_late(p_boundary timestamptz, p_at timestamptz)
returns boolean
language sql
immutable
set search_path = ''
as $$ select p_at > p_boundary + interval '30 minutes' $$;

-- Machine and shift must belong to the caller's tenant (else the generic audited denial), the date is required, and a supervisor must own the
-- machine in that occurrence (a Unit Admin may record for any machine, AC-7/AC-8). Returns the denial, or null when the caller may go on.
create function app._rd_check(p_auth jsonb, p_machine uuid, p_shift uuid, p_date date, p_src text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_own text;
begin
  v_own := app._pm_owned('machine', p_machine, (p_auth->>'tenant_id')::uuid);
  if v_own <> 'ok' then return app._pm_deny(p_auth, v_own, 'machine', p_machine, p_src); end if;
  v_own := app._sh_owned('shift', p_shift, (p_auth->>'tenant_id')::uuid);
  if v_own <> 'ok' then return app._pm_deny(p_auth, v_own, 'shift', p_shift, p_src); end if;
  if p_date is null then perform app._pm_fail('validation', 'Choose the shift date', 'shift_date'); end if;
  if p_auth->>'role' = 'supervisor' and app.machine_owner(p_machine, p_shift, p_date) is distinct from (p_auth->>'actor')::uuid then
    return app._pm_deny(p_auth, 'not_owner', 'machine', p_machine, p_src);
  end if;
  return null;
end
$$;

create function app._rd_counter_ok(p_value bigint, p_field text, p_label text)
returns void
language plpgsql
immutable
security definer
set search_path = ''
as $$
begin
  if p_value is null or p_value < 0 or p_value > 1000000000000 then
    perform app._pm_fail('validation', p_label || ': enter a whole number from 0 to 1,000,000,000,000', p_field);
  end if;
end
$$;

create function app._rd_qty_ok(p_value integer, p_field text, p_label text)
returns void
language plpgsql
immutable
security definer
set search_path = ''
as $$
begin
  if p_value is null or p_value < 0 or p_value > 10000000 then
    perform app._pm_fail('validation', p_label || ': enter a whole number from 0 to 10,000,000', p_field);
  end if;
end
$$;

-- Remarks: trimmed, empty = none, at most 500 characters.
create function app._rd_remarks(p_remarks text)
returns text
language plpgsql
immutable
security definer
set search_path = ''
as $$
declare
  v text := nullif(btrim(p_remarks), '');
begin
  perform app._pm_len(v, 0, 500, 'remarks', 'Remarks: up to 500 characters');
  return v;
end
$$;

-- 9. Production summary calculation (D7) --------------------------------------------------------------------------------------
-- Appends ONE production_summary row from the CURRENT opening and closing of a machine-occurrence (nothing when a closing does not exist yet),
-- with the inputs snapshotted: product, unit, cavities (1 for a pieces counter), counter maximum, readings, effective target (05) on the shift
-- date, good, reject. Calculation version 1:
--   movement (units) = closing - opening when closing >= opening;
--   closing < opening with a maximum and opening <= maximum: Rollover, movement = (maximum + 1 - opening) + closing;
--   otherwise (no maximum, or an opening above the maximum) movement is null and the row is flagged Needs review (never guessed);
--   movement pieces = movement x cavities; unaccounted = movement pieces - good - reject; over_reported when good + reject exceeds the movement;
--   attainment = good / target x 100 (null without a target).
-- Called by rd_closing and rd_correct in their own transaction; a rule change later adds calc_version 2 rows and never rewrites these.
create function app._rd_compute_summary(p_tenant uuid, p_actor uuid, p_machine uuid, p_shift uuid, p_date date, p_request uuid)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  c_version constant integer := 1;
  o public.production_reading;
  c public.production_reading;
  m public.machine;
  v_cav integer;
  v_target integer;
  v_units bigint;
  v_pieces bigint;
  v_unacc bigint;
  v_att numeric;
  v_rollover boolean := false;
  v_review boolean := false;
  v_id uuid;
begin
  select * into o from app._rd_current(p_machine, p_shift, p_date, 'opening');
  select * into c from app._rd_current(p_machine, p_shift, p_date, 'closing');
  if o.id is null or c.id is null then return null; end if;
  select * into m from public.machine x where x.id = p_machine;

  v_cav := case when m.counter_unit = 'shots' then app.cavities_for(p_machine, o.product_id, p_date) else 1 end;
  v_target := app.effective_target(p_machine, o.product_id, p_shift, p_date);

  if c.counter_value >= o.counter_value then
    v_units := c.counter_value - o.counter_value;
  elsif m.counter_max is not null and o.counter_value <= m.counter_max then
    v_units := (m.counter_max + 1 - o.counter_value) + c.counter_value;
    v_rollover := true;
  else
    v_review := true;
  end if;
  v_pieces := v_units * v_cav;
  v_unacc := v_pieces - c.good - c.reject;
  if v_target is not null then v_att := round(c.good * 100.0 / v_target, 2); end if;

  insert into public.production_summary (
    tenant_id, machine_id, shift_id, shift_date, calc_version, product_id, counter_unit, cavities, counter_max, opening_reading_id, closing_reading_id,
    opening_counter, closing_counter, good, reject, target, movement_units, movement_pieces, unaccounted, attainment_pct,
    rollover, needs_review, over_reported, late_opening, late_closing, entered_by_ua, recorded_by, request_id)
  values (
    p_tenant, p_machine, p_shift, p_date, c_version, o.product_id, m.counter_unit, v_cav, m.counter_max, o.id, c.id,
    o.counter_value, c.counter_value, c.good, c.reject, v_target, v_units, v_pieces, v_unacc, v_att,
    v_rollover, v_review, coalesce(c.good + c.reject > v_pieces, false), o.late, c.late, (o.entered_by_ua or c.entered_by_ua), p_actor, p_request)
  returning id into v_id;
  return v_id;
end
$$;

-- 10. Write RPCs: readings (D2, D5, D6) ---------------------------------------------------------------------------------------------
-- Supervisors (the machine's owner in that occurrence) and Unit Admins record readings; a Unit Admin's reading is labelled entered_by_ua.
-- Denials are committed and returned as {ok:false, code:'not_allowed'}; windows, duplicates and state errors raise P0001 {code:'guard', field}.
create function public.rd_opening(
  p_request_id uuid, p_machine_id uuid, p_shift_id uuid, p_shift_date date, p_product_id uuid, p_counter bigint, p_remarks text default null
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  c_src constant text := 'rpc:rd_opening';
  a jsonb;
  v_tenant uuid;
  v_deny jsonb;
  v_own text;
  v_remarks text;
  m public.machine;
  p public.product;
  s public.shift;
  v_w tstzrange;
  cur public.production_reading;
  v_late boolean;
  v_ua boolean;
  v_id uuid;
begin
  if not exists (select 1 from public.membership x where x.user_id = auth.uid()) then
    return app._pm_authorise(p_request_id, c_src);
  end if;
  a := app._rd_authorise(p_request_id, c_src);
  if not (a->>'ok')::boolean then return a; end if;
  if a->>'done' is not null then return jsonb_build_object('ok', true, 'id', (a->>'done')::uuid, 'already', true); end if;
  v_tenant := (a->>'tenant_id')::uuid;

  v_deny := app._rd_check(a, p_machine_id, p_shift_id, p_shift_date, c_src);
  if v_deny is not null then return v_deny; end if;
  v_own := app._pm_owned('product', p_product_id, v_tenant);
  if v_own <> 'ok' then return app._pm_deny(a, v_own, 'product', p_product_id, c_src); end if;
  perform app._rd_counter_ok(p_counter, 'counter', 'Counter');
  v_remarks := app._rd_remarks(p_remarks);

  select * into m from public.machine x where x.id = p_machine_id;
  select * into p from public.product x where x.id = p_product_id;
  select * into s from public.shift x where x.id = p_shift_id;
  if m.retired_at is not null then perform app._pm_fail('guard', 'This machine is retired', 'machine_retired'); end if;
  if p.retired_at is not null then perform app._pm_fail('guard', 'This product is retired', 'product_id'); end if;
  if s.retired_at is not null then perform app._pm_fail('guard', 'This shift is retired', 'shift_retired'); end if;

  -- D5: allowed from 30 minutes before the occurrence starts until it ends.
  v_w := app.shift_window(p_shift_id, p_shift_date);
  if now() < lower(v_w) - interval '30 minutes' then
    perform app._pm_fail('guard', 'The opening reading opens 30 minutes before the shift starts', 'window_not_open');
  end if;
  if now() >= upper(v_w) then
    perform app._pm_fail('guard', 'This shift has ended; ask a Unit Admin to record the opening', 'window_closed');
  end if;
  select * into cur from app._rd_current(p_machine_id, p_shift_id, p_shift_date, 'opening');
  if cur.id is not null then
    perform app._pm_fail('guard', 'The opening reading is already recorded. Submit a correction instead.', 'already_recorded');
  end if;

  v_late := app._rd_is_late(lower(v_w), now());
  v_ua := a->>'role' = 'unit_admin';
  insert into public.production_reading (tenant_id, machine_id, shift_id, shift_date, kind, product_id, counter_value, remarks, late, entered_by_ua, recorded_by, recorded_at, request_id)
  values (v_tenant, p_machine_id, p_shift_id, p_shift_date, 'opening', p_product_id, p_counter, v_remarks, v_late, v_ua, (a->>'actor')::uuid, now(), p_request_id)
  returning id into v_id;
  perform app._pm_audit(a, 'reading.opening', 'production_reading', v_id, null,
    jsonb_build_object('machine_code', m.code, 'shift_id', p_shift_id, 'shift_date', p_shift_date, 'product_code', p.code, 'counter', p_counter,
                       'late', v_late, 'entered_by_ua', v_ua),
    p_request_id, c_src);
  return jsonb_build_object('ok', true, 'id', v_id, 'late', v_late, 'entered_by_ua', v_ua);
end
$$;

create function public.rd_closing(
  p_request_id uuid, p_machine_id uuid, p_shift_id uuid, p_shift_date date, p_counter bigint, p_good integer, p_reject integer, p_remarks text default null
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  c_src constant text := 'rpc:rd_closing';
  a jsonb;
  v_tenant uuid;
  v_deny jsonb;
  v_remarks text;
  m public.machine;
  v_w tstzrange;
  o public.production_reading;
  cur public.production_reading;
  v_late boolean;
  v_ua boolean;
  v_id uuid;
  v_summary uuid;
begin
  if not exists (select 1 from public.membership x where x.user_id = auth.uid()) then
    return app._pm_authorise(p_request_id, c_src);
  end if;
  a := app._rd_authorise(p_request_id, c_src);
  if not (a->>'ok')::boolean then return a; end if;
  if a->>'done' is not null then return jsonb_build_object('ok', true, 'id', (a->>'done')::uuid, 'already', true); end if;
  v_tenant := (a->>'tenant_id')::uuid;

  v_deny := app._rd_check(a, p_machine_id, p_shift_id, p_shift_date, c_src);
  if v_deny is not null then return v_deny; end if;
  perform app._rd_counter_ok(p_counter, 'counter', 'Counter');
  perform app._rd_qty_ok(p_good, 'good', 'Good');
  perform app._rd_qty_ok(p_reject, 'reject', 'Reject');
  v_remarks := app._rd_remarks(p_remarks);

  select * into m from public.machine x where x.id = p_machine_id;
  select * into o from app._rd_current(p_machine_id, p_shift_id, p_shift_date, 'opening');
  if o.id is null then perform app._pm_fail('guard', 'Record the opening reading first', 'no_opening'); end if;
  -- D5: allowed from the opening until 12 hours after the occurrence ends.
  v_w := app.shift_window(p_shift_id, p_shift_date);
  if now() > upper(v_w) + interval '12 hours' then
    perform app._pm_fail('guard', 'The closing window (12 hours after the shift) has passed', 'window_closed');
  end if;
  select * into cur from app._rd_current(p_machine_id, p_shift_id, p_shift_date, 'closing');
  if cur.id is not null then
    perform app._pm_fail('guard', 'The closing reading is already recorded. Submit a correction instead.', 'already_recorded');
  end if;

  v_late := app._rd_is_late(upper(v_w), now());
  v_ua := a->>'role' = 'unit_admin';
  insert into public.production_reading (tenant_id, machine_id, shift_id, shift_date, kind, counter_value, good, reject, remarks, late, entered_by_ua, recorded_by, recorded_at, request_id)
  values (v_tenant, p_machine_id, p_shift_id, p_shift_date, 'closing', p_counter, p_good, p_reject, v_remarks, v_late, v_ua, (a->>'actor')::uuid, now(), p_request_id)
  returning id into v_id;
  v_summary := app._rd_compute_summary(v_tenant, (a->>'actor')::uuid, p_machine_id, p_shift_id, p_shift_date, p_request_id);
  perform app._pm_audit(a, 'reading.closing', 'production_reading', v_id, null,
    jsonb_build_object('machine_code', m.code, 'shift_id', p_shift_id, 'shift_date', p_shift_date, 'counter', p_counter, 'good', p_good, 'reject', p_reject,
                       'late', v_late, 'entered_by_ua', v_ua, 'summary_id', v_summary),
    p_request_id, c_src);
  return jsonb_build_object('ok', true, 'id', v_id, 'late', v_late, 'entered_by_ua', v_ua, 'summary_id', v_summary);
end
$$;

-- AC-6: a correction is a NEW reading that supersedes the current one of its kind (the old one stays in history). The supervisor who owns the
-- occurrence may correct until the next occurrence of that shift starts; a Unit Admin any time. For an opening pass counter + product, for a
-- closing counter + good + reject. The correction keeps the Late flag of the occurrence's earliest submission and recomputes the summary.
create function public.rd_correct(
  p_request_id uuid, p_reading_id uuid, p_counter bigint, p_product_id uuid, p_good integer, p_reject integer, p_remarks text, p_reason text
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  c_src constant text := 'rpc:rd_correct';
  a jsonb;
  v_tenant uuid;
  v_own text;
  v_remarks text;
  v_reason text := btrim(p_reason);
  old public.production_reading;
  cur public.production_reading;
  m public.machine;
  p public.product;
  v_ua boolean;
  v_id uuid;
  v_summary uuid;
begin
  if not exists (select 1 from public.membership x where x.user_id = auth.uid()) then
    return app._pm_authorise(p_request_id, c_src);
  end if;
  a := app._rd_authorise(p_request_id, c_src);
  if not (a->>'ok')::boolean then return a; end if;
  if a->>'done' is not null then return jsonb_build_object('ok', true, 'id', (a->>'done')::uuid, 'already', true); end if;
  v_tenant := (a->>'tenant_id')::uuid;

  v_own := app._rd_owned(p_reading_id, v_tenant);
  if v_own <> 'ok' then return app._pm_deny(a, v_own, 'production_reading', p_reading_id, c_src); end if;
  select * into old from public.production_reading r where r.id = p_reading_id;
  if a->>'role' = 'supervisor' and app.machine_owner(old.machine_id, old.shift_id, old.shift_date) is distinct from (a->>'actor')::uuid then
    return app._pm_deny(a, 'not_owner', 'production_reading', p_reading_id, c_src);
  end if;

  perform app._pm_len(v_reason, 1, 200, 'reason', 'Enter a reason of 1 to 200 characters');
  perform app._rd_counter_ok(p_counter, 'counter', 'Counter');
  v_remarks := app._rd_remarks(p_remarks);
  if old.kind = 'opening' then
    if p_good is not null or p_reject is not null then perform app._pm_fail('validation', 'An opening reading has no good or reject quantity', 'good'); end if;
    v_own := app._pm_owned('product', p_product_id, v_tenant);
    if v_own <> 'ok' then return app._pm_deny(a, v_own, 'product', p_product_id, c_src); end if;
    select * into p from public.product x where x.id = p_product_id;
    if p.retired_at is not null then perform app._pm_fail('guard', 'This product is retired', 'product_id'); end if;
  else
    if p_product_id is not null then perform app._pm_fail('validation', 'A closing reading has no product', 'product_id'); end if;
    perform app._rd_qty_ok(p_good, 'good', 'Good');
    perform app._rd_qty_ok(p_reject, 'reject', 'Reject');
  end if;

  select * into cur from app._rd_current(old.machine_id, old.shift_id, old.shift_date, old.kind);
  if cur.id is distinct from old.id then
    perform app._pm_fail('guard', 'This reading was already corrected; correct the latest one', 'not_current');
  end if;
  -- AC-6: the supervisor may correct until the next occurrence of the shift starts; a Unit Admin may at any time.
  if a->>'role' = 'supervisor' and now() >= lower(app.shift_window(old.shift_id, old.shift_date + 1)) then
    perform app._pm_fail('guard', 'The next shift has started; ask a Unit Admin to correct this reading', 'correction_window_closed');
  end if;

  select * into m from public.machine x where x.id = old.machine_id;
  v_ua := a->>'role' = 'unit_admin';
  insert into public.production_reading (tenant_id, machine_id, shift_id, shift_date, kind, product_id, counter_value, good, reject, remarks, late, entered_by_ua,
                                         supersedes_id, correction_reason, recorded_by, recorded_at, request_id)
  values (v_tenant, old.machine_id, old.shift_id, old.shift_date, old.kind, p_product_id, p_counter, p_good, p_reject, v_remarks, old.late, v_ua,
          old.id, v_reason, (a->>'actor')::uuid, now(), p_request_id)
  returning id into v_id;
  v_summary := app._rd_compute_summary(v_tenant, (a->>'actor')::uuid, old.machine_id, old.shift_id, old.shift_date, p_request_id);
  perform app._pm_audit(a, 'reading.corrected', 'production_reading', v_id,
    jsonb_build_object('reading_id', old.id, 'kind', old.kind, 'counter', old.counter_value, 'product_id', old.product_id, 'good', old.good, 'reject', old.reject),
    jsonb_build_object('machine_code', m.code, 'shift_id', old.shift_id, 'shift_date', old.shift_date, 'kind', old.kind, 'counter', p_counter, 'product_id', p_product_id,
                       'good', p_good, 'reject', p_reject, 'reason', v_reason, 'late', old.late, 'entered_by_ua', v_ua, 'summary_id', v_summary),
    p_request_id, c_src);
  return jsonb_build_object('ok', true, 'id', v_id, 'late', old.late, 'entered_by_ua', v_ua, 'summary_id', v_summary);
end
$$;

-- 99. Function privileges: no app function is executable by clients (test 004); the public entry points are executable by authenticated only.
-- Repeated at the end of every step's section: each step adds functions, the loop runs over the whole 06 name range.
do $$
declare f record;
begin
  for f in
    select p.oid::regprocedure as sig, n.nspname
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where (n.nspname = 'app' and p.proname ~ '^(_rd_|rd_|reading_|today_board|cavities_for$|_cavities_raw$)')
       or (n.nspname = 'public' and p.proname ~ '^(rd_|reading_|today_board$)')
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    if f.nspname = 'public' then
      execute format('grant execute on function %s to authenticated', f.sig);
    end if;
  end loop;
end $$;
