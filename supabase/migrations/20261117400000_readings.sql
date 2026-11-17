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
