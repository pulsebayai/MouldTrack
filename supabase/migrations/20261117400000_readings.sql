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
  early boolean not null default false, -- 8a R5: a closing submitted more than 30 minutes before the occurrence ends (stored, like late)
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
  constraint production_reading_early_closing_only check (not early or kind = 'closing'),
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
  early_closing boolean not null default false,
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

-- 8a R5: a closing is Early when submitted more than 30 minutes before the occurrence ends (accepted and flagged, never refused).
create function app._rd_is_early(p_end timestamptz, p_at timestamptz)
returns boolean
language sql
immutable
set search_path = ''
as $$ select p_at < p_end - interval '30 minutes' $$;

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
    rollover, needs_review, over_reported, late_opening, late_closing, early_closing, entered_by_ua, recorded_by, request_id)
  values (
    p_tenant, p_machine, p_shift, p_date, c_version, o.product_id, m.counter_unit, v_cav, m.counter_max, o.id, c.id,
    o.counter_value, c.counter_value, c.good, c.reject, v_target, v_units, v_pieces, v_unacc, v_att,
    v_rollover, v_review, coalesce(c.good + c.reject > v_pieces, false), o.late, c.late, c.early, (o.entered_by_ua or c.entered_by_ua), p_actor, p_request)
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
  if p_product_id is null then perform app._pm_fail('validation', 'Choose the product', 'product_id'); end if;
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

  -- D5 (8a R4): allowed from 30 minutes before the occurrence starts until 12 hours after it ends (late readings are accepted and flagged Late).
  v_w := app.shift_window(p_shift_id, p_shift_date);
  if now() < lower(v_w) - interval '30 minutes' then
    perform app._pm_fail('guard', 'The opening reading opens 30 minutes before the shift starts', 'window_not_open');
  end if;
  if now() > upper(v_w) + interval '12 hours' then
    perform app._pm_fail('guard', 'The opening window (12 hours after the shift) has passed', 'window_closed');
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
  s public.shift;
  v_late boolean;
  v_early boolean;
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
  select * into s from public.shift x where x.id = p_shift_id;
  if m.retired_at is not null then perform app._pm_fail('guard', 'This machine is retired', 'machine_retired'); end if;
  if s.retired_at is not null then perform app._pm_fail('guard', 'This shift is retired', 'shift_retired'); end if;
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
  v_early := app._rd_is_early(upper(v_w), now());
  v_ua := a->>'role' = 'unit_admin';
  insert into public.production_reading (tenant_id, machine_id, shift_id, shift_date, kind, counter_value, good, reject, remarks, late, early, entered_by_ua, recorded_by, recorded_at, request_id)
  values (v_tenant, p_machine_id, p_shift_id, p_shift_date, 'closing', p_counter, p_good, p_reject, v_remarks, v_late, v_early, v_ua, (a->>'actor')::uuid, now(), p_request_id)
  returning id into v_id;
  v_summary := app._rd_compute_summary(v_tenant, (a->>'actor')::uuid, p_machine_id, p_shift_id, p_shift_date, p_request_id);
  perform app._pm_audit(a, 'reading.closing', 'production_reading', v_id, null,
    jsonb_build_object('machine_code', m.code, 'shift_id', p_shift_id, 'shift_date', p_shift_date, 'counter', p_counter, 'good', p_good, 'reject', p_reject,
                       'late', v_late, 'early', v_early, 'entered_by_ua', v_ua, 'summary_id', v_summary),
    p_request_id, c_src);
  return jsonb_build_object('ok', true, 'id', v_id, 'late', v_late, 'early', v_early, 'entered_by_ua', v_ua, 'summary_id', v_summary);
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
  s public.shift;
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
    if p_product_id is null then perform app._pm_fail('validation', 'Choose the product', 'product_id'); end if;
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
  select * into s from public.shift x where x.id = old.shift_id;
  if m.retired_at is not null then perform app._pm_fail('guard', 'This machine is retired', 'machine_retired'); end if;
  if s.retired_at is not null then perform app._pm_fail('guard', 'This shift is retired', 'shift_retired'); end if;
  v_ua := a->>'role' = 'unit_admin';
  insert into public.production_reading (tenant_id, machine_id, shift_id, shift_date, kind, product_id, counter_value, good, reject, remarks, late, early, entered_by_ua,
                                         supersedes_id, correction_reason, recorded_by, recorded_at, request_id)
  values (v_tenant, old.machine_id, old.shift_id, old.shift_date, old.kind, p_product_id, p_counter, p_good, p_reject, v_remarks, old.late, old.early, v_ua,
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

-- 11. Reads (D8, D9) ------------------------------------------------------------------------------------------------------------------
-- Read RPCs return jsonb like the write RPCs: {ok:true, ...} or the generic denial {ok:false, code:'not_allowed'} (audited as access.denied).
-- R1 of 07's review: clients cannot choose the clock. The bodies are app.*_at(p_at) helpers (pgTAP calls them with explicit moments; only the owner
-- can execute them) and the public RPCs are thin wrappers that always pass now() and route callers without a membership (a Super Admin, a stranger)
-- through app._pm_authorise so the audited denial lives in one place (022).

-- The UTC range [start, end) of the occurrence of a shift on a shift date, in the site's time zone. The same formula as app.shift_window (05) but
-- without its caller/tenant check, for set-based queries over many occurrences; pgTAP 053 pins the two to the same answers.
create function app._rd_window(p_start time, p_end time, p_date date, p_tz text)
returns tstzrange
language sql
stable
set search_path = ''
as $$
  select tstzrange((p_date + p_start) at time zone p_tz, ((p_date + case when p_end < p_start then 1 else 0 end) + p_end) at time zone p_tz, '[)')
$$;

-- AC-11: the caller's own machines in every occurrence where a reading can still be recorded: from 30 minutes before the start until 12 hours after
-- the end (running occurrences, the one that just ended whose closing is due, the next one about to open). The owner is resolved inline by the same
-- rule as app.machine_owner_src (latest cover of the occurrence, else the plan version in force); pgTAP 053 pins them together. Per machine:
-- state (opening_due | opening_done | closing_due | closed | opening_missed), the current opening/closing/summary, the default product (the product of the
-- latest opening still active) and what the caller may do now (can_open / can_close / can_correct) so the client only renders it.
create function app.reading_state_at(p_at timestamptz)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  c_src constant text := 'rpc:reading_state';
  a jsonb;
  v_tenant uuid;
  v_uid uuid;
  v_plant date;
  v_occ jsonb;
begin
  if not exists (select 1 from public.membership m where m.user_id = auth.uid()) then
    return app._pm_authorise(null, c_src);
  end if;
  a := app._sh_read_authorise(c_src, false);
  if not (a->>'ok')::boolean then return a; end if;
  v_tenant := (a->>'tenant_id')::uuid;
  v_uid := (a->>'actor')::uuid;
  if not exists (select 1 from public.shift s where s.tenant_id = v_tenant and s.retired_at is null) then
    return jsonb_build_object('ok', true, 'state', 'no_shifts', 'occurrences', '[]'::jsonb);
  end if;

  v_plant := app.plant_date_at(v_tenant, p_at);
  with cand as (
    select s.id as shift_id, s.name, s.start_time, s.end_time, z.timezone as tz, d.d as shift_date, app._rd_window(s.start_time, s.end_time, d.d, z.timezone) as w
      from public.shift s
      join public.site z on z.id = s.site_id
      cross join lateral unnest(array[v_plant - 2, v_plant - 1, v_plant, v_plant + 1]) as d(d)
     where s.tenant_id = v_tenant and s.retired_at is null
  ), win as (
    select c.* from cand c where p_at >= lower(c.w) - interval '30 minutes' and p_at <= upper(c.w) + interval '12 hours'
  ), mine as (
    select w.*, (w.w @> p_at) as running, m.id as machine_id, m.code, m.name as machine_name, m.counter_unit, m.counter_max, l.name as line
      from win w
      join public.machine m on m.tenant_id = v_tenant and m.retired_at is null
      left join public.line l on l.id = m.line_id
      left join lateral (select true as found, c.supervisor_id from public.assignment_cover c
                          where c.shift_id = w.shift_id and c.shift_date = w.shift_date and c.machine_id = m.id
                          order by c.recorded_at desc, c.id desc limit 1) cv on true
      left join lateral (select v.supervisor_id from public.assignment_version v
                          where v.shift_id = w.shift_id and v.machine_id = m.id and v.effective_from <= w.shift_date
                          order by v.effective_from desc, v.recorded_at desc, v.id desc limit 1) pv on true
     where (case when cv.found then cv.supervisor_id else pv.supervisor_id end) = v_uid
  ), rd as (
    select mi.*, o.id as o_id, o.counter_value as o_counter, o.product_id as o_product, op.code as o_product_code, o.recorded_at as o_at, o.late as o_late,
           o.entered_by_ua as o_ua, o.remarks as o_remarks,
           c.id as c_id, c.counter_value as c_counter, c.good as c_good, c.reject as c_reject, c.recorded_at as c_at, c.late as c_late, c.early as c_early, c.entered_by_ua as c_ua, c.remarks as c_remarks,
           sm.id as s_id, sm.target as s_target, sm.movement_pieces as s_pieces, sm.good as s_good, sm.reject as s_reject, sm.unaccounted as s_unacc, sm.attainment_pct as s_att,
           sm.rollover as s_roll, sm.needs_review as s_review, sm.over_reported as s_over, sm.early_closing as s_early,
           dp.product_id as default_product,
           lower(app._rd_window(mi.start_time, mi.end_time, mi.shift_date + 1, mi.tz)) as next_start
      from mine mi
      left join lateral (select r.* from public.production_reading r
                          where r.machine_id = mi.machine_id and r.shift_id = mi.shift_id and r.shift_date = mi.shift_date and r.kind = 'opening'
                            and not exists (select 1 from public.production_reading n where n.supersedes_id = r.id) limit 1) o on true
      left join public.product op on op.id = o.product_id
      left join lateral (select r.* from public.production_reading r
                          where r.machine_id = mi.machine_id and r.shift_id = mi.shift_id and r.shift_date = mi.shift_date and r.kind = 'closing'
                            and not exists (select 1 from public.production_reading n where n.supersedes_id = r.id) limit 1) c on true
      left join lateral (select x.* from public.production_summary x
                          where x.machine_id = mi.machine_id and x.shift_id = mi.shift_id and x.shift_date = mi.shift_date
                          order by x.recorded_at desc, x.id desc limit 1) sm on true
      left join lateral (select r.product_id from public.production_reading r join public.product p on p.id = r.product_id and p.retired_at is null
                          join public.shift hs on hs.id = r.shift_id
                          where r.machine_id = mi.machine_id and r.kind = 'opening' and not exists (select 1 from public.production_reading n where n.supersedes_id = r.id)
                          order by r.shift_date desc, hs.start_time desc, r.recorded_at desc, r.id desc limit 1) dp on true
  ), mach as (
    select x.shift_id, x.name, x.start_time, x.end_time, x.shift_date, x.w, x.running,
           jsonb_build_object(
             'machine_id', x.machine_id, 'code', x.code, 'name', x.machine_name, 'line', x.line, 'counter_unit', x.counter_unit, 'counter_max', x.counter_max,
             'state', case when x.c_id is not null then 'closed'
                           when x.o_id is not null then case when p_at >= upper(x.w) then 'closing_due' else 'opening_done' end
                           when p_at >= upper(x.w) then 'opening_missed'
                           else 'opening_due' end,
             'can_open', (x.o_id is null and p_at >= lower(x.w) - interval '30 minutes' and p_at <= upper(x.w) + interval '12 hours'),
             'can_close', (x.o_id is not null and x.c_id is null and p_at <= upper(x.w) + interval '12 hours'),
             'can_correct', ((x.o_id is not null or x.c_id is not null) and p_at < x.next_start),
             'default_product_id', x.default_product,
             'opening', case when x.o_id is null then null else jsonb_build_object('id', x.o_id, 'counter', x.o_counter, 'product_id', x.o_product, 'product_code', x.o_product_code,
                          'recorded_at', x.o_at, 'late', x.o_late, 'entered_by_ua', x.o_ua, 'remarks', x.o_remarks) end,
             'closing', case when x.c_id is null then null else jsonb_build_object('id', x.c_id, 'counter', x.c_counter, 'good', x.c_good, 'reject', x.c_reject,
                          'recorded_at', x.c_at, 'late', x.c_late, 'early', x.c_early, 'entered_by_ua', x.c_ua, 'remarks', x.c_remarks) end,
             'summary', case when x.s_id is null then null else jsonb_build_object('id', x.s_id, 'target', x.s_target, 'movement_pieces', x.s_pieces, 'good', x.s_good,
                          'reject', x.s_reject, 'unaccounted', x.s_unacc, 'attainment_pct', x.s_att, 'rollover', x.s_roll, 'needs_review', x.s_review, 'over_reported', x.s_over, 'early_closing', x.s_early) end
           ) as j, x.code
      from rd x
  ), occ as (
    select m.shift_id, m.name, m.start_time, m.end_time, m.shift_date, m.w, m.running, jsonb_agg(m.j order by m.code) as machines
      from mach m group by m.shift_id, m.name, m.start_time, m.end_time, m.shift_date, m.w, m.running
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'shift', jsonb_build_object('id', o.shift_id, 'name', o.name, 'start_time', to_char(o.start_time, 'HH24:MI'), 'end_time', to_char(o.end_time, 'HH24:MI')),
           'shift_date', o.shift_date, 'starts_at', lower(o.w), 'ends_at', upper(o.w), 'running', o.running, 'machines', o.machines)
           order by lower(o.w), o.name), '[]'::jsonb)
    into v_occ
    from occ o;
  return jsonb_build_object('ok', true, 'state', case when jsonb_array_length(v_occ) = 0 then 'none' else 'active' end, 'occurrences', v_occ);
end
$$;

-- AC-15: one machine-occurrence with its full reading history (every reading, corrections included), the current opening/closing, the latest
-- summary and what the caller may do. A supervisor sees only occurrences they own (also past ones), a Unit Admin every one of the tenant.
create function app.reading_detail_at(p_machine uuid, p_shift uuid, p_date date, p_at timestamptz)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  c_src constant text := 'rpc:reading_detail';
  a jsonb;
  v_tenant uuid;
  v_own text;
  v_owner uuid;
  v_w tstzrange;
  m public.machine;
  s public.shift;
  o public.production_reading;
  c public.production_reading;
  sm public.production_summary;
  v_hist jsonb;
  v_n int;
  v_next timestamptz;
begin
  if not exists (select 1 from public.membership x where x.user_id = auth.uid()) then
    return app._pm_authorise(null, c_src);
  end if;
  a := app._sh_read_authorise(c_src, false);
  if not (a->>'ok')::boolean then return a; end if;
  v_tenant := (a->>'tenant_id')::uuid;
  v_own := app._pm_owned('machine', p_machine, v_tenant);
  if v_own <> 'ok' then return app._pm_deny(a, v_own, 'machine', p_machine, c_src); end if;
  v_own := app._sh_owned('shift', p_shift, v_tenant);
  if v_own <> 'ok' then return app._pm_deny(a, v_own, 'shift', p_shift, c_src); end if;
  if p_date is null then perform app._pm_fail('validation', 'Choose the shift date', 'shift_date'); end if;
  v_owner := app.machine_owner(p_machine, p_shift, p_date);
  if a->>'role' = 'supervisor' and v_owner is distinct from (a->>'actor')::uuid then
    return app._pm_deny(a, 'not_owner', 'machine', p_machine, c_src);
  end if;

  select * into m from public.machine x where x.id = p_machine;
  select * into s from public.shift x where x.id = p_shift;
  v_w := app.shift_window(p_shift, p_date);
  select * into o from app._rd_current(p_machine, p_shift, p_date, 'opening');
  select * into c from app._rd_current(p_machine, p_shift, p_date, 'closing');
  select * into sm from public.production_summary x
    where x.machine_id = p_machine and x.shift_id = p_shift and x.shift_date = p_date order by x.recorded_at desc, x.id desc limit 1;
  select count(*)::int into v_n from public.production_summary x where x.machine_id = p_machine and x.shift_id = p_shift and x.shift_date = p_date;
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', r.id, 'kind', r.kind, 'counter', r.counter_value, 'product_id', r.product_id, 'product_code', p.code, 'good', r.good, 'reject', r.reject,
           'remarks', r.remarks, 'late', r.late, 'early', r.early, 'entered_by_ua', r.entered_by_ua, 'supersedes_id', r.supersedes_id, 'correction_reason', r.correction_reason,
           'recorded_by', r.recorded_by, 'recorded_by_name', mem.full_name, 'recorded_at', r.recorded_at,
           'current', not exists (select 1 from public.production_reading n where n.supersedes_id = r.id)) order by r.kind desc, r.recorded_at, r.id), '[]'::jsonb)
    into v_hist
    from public.production_reading r
    left join public.product p on p.id = r.product_id
    left join public.membership mem on mem.user_id = r.recorded_by and mem.tenant_id = v_tenant
    where r.machine_id = p_machine and r.shift_id = p_shift and r.shift_date = p_date;
  v_next := lower(app.shift_window(p_shift, p_date + 1));

  return jsonb_build_object(
    'ok', true,
    'machine', jsonb_build_object('id', m.id, 'code', m.code, 'name', m.name, 'counter_unit', m.counter_unit, 'counter_max', m.counter_max),
    'shift', jsonb_build_object('id', s.id, 'name', s.name, 'start_time', to_char(s.start_time, 'HH24:MI'), 'end_time', to_char(s.end_time, 'HH24:MI')),
    'shift_date', p_date, 'starts_at', lower(v_w), 'ends_at', upper(v_w),
    'owner_id', v_owner, 'owner_name', (select mem.full_name from public.membership mem where mem.user_id = v_owner and mem.tenant_id = v_tenant),
    'readings', v_hist,
    'opening', case when o.id is null then null else v_hist -> (select (i - 1)::int from jsonb_array_elements(v_hist) with ordinality as e(x, i) where (e.x ->> 'id')::uuid = o.id) end,
    'closing', case when c.id is null then null else v_hist -> (select (i - 1)::int from jsonb_array_elements(v_hist) with ordinality as e(x, i) where (e.x ->> 'id')::uuid = c.id) end,
    'summary', case when sm.id is null then null else to_jsonb(sm) - 'tenant_id' - 'request_id' end,
    'summary_count', v_n,
    'photos', (select coalesce(jsonb_agg(jsonb_build_object('id', t.id, 'reading_id', t.entity_id, 'path', t.storage_path, 'mime', t.mime, 'ready_at', t.ready_at) order by t.ready_at, t.id), '[]'::jsonb)
                 from public.attachment t
                 where t.entity_type = 'production_reading' and t.status = 'ready' and t.tenant_id = v_tenant
                   and t.entity_id in (select (e.x ->> 'id')::uuid from jsonb_array_elements(v_hist) e(x))),
    'allowed', jsonb_build_object(
      'can_open', (o.id is null and p_at >= lower(v_w) - interval '30 minutes' and p_at <= upper(v_w) + interval '12 hours' and m.retired_at is null and s.retired_at is null),
      'can_close', (o.id is not null and c.id is null and p_at <= upper(v_w) + interval '12 hours'),
      'can_correct', ((o.id is not null or c.id is not null) and (a->>'role' = 'unit_admin' or p_at < v_next))));
end
$$;

-- AC-12: the Unit Admin's Today board. For every active shift its latest started occurrence (current, running or just ended) and the one before it:
-- every ASSIGNED machine (owner by cover/plan not null; unassigned machines are excluded, retired ones unless they have a reading) with owner,
-- product, target (the summary's snapshot once closed, else the effective target of the opening's product, else of the machine's default product,
-- target_assumed:true), opening/closing status (missing | on_time | late), movement, good, reject, unaccounted, attainment and flag keys, plus totals
-- per occurrence. Totals: target = all machines with a target; good = closed machines; attainment = good / target over closed machines that have a
-- target (a missing closing is shown as missing, never as a shortfall). One set-based query. Unit Admin only.
create function app.today_board_at(p_at timestamptz)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  c_src constant text := 'rpc:today_board';
  a jsonb;
  v_tenant uuid;
  v_plant date;
  v_occ jsonb;
begin
  if not exists (select 1 from public.membership m where m.user_id = auth.uid()) then
    return app._pm_authorise(null, c_src);
  end if;
  a := app._sh_read_authorise(c_src, true);
  if not (a->>'ok')::boolean then return a; end if;
  v_tenant := (a->>'tenant_id')::uuid;
  v_plant := app.plant_date_at(v_tenant, p_at);

  with cand as (
    select s.id as shift_id, s.name, s.start_time, s.end_time, z.timezone as tz, d.d as shift_date, app._rd_window(s.start_time, s.end_time, d.d, z.timezone) as w
      from public.shift s
      join public.site z on z.id = s.site_id
      cross join lateral unnest(array[v_plant - 2, v_plant - 1, v_plant, v_plant + 1]) as d(d)
     where s.tenant_id = v_tenant and s.retired_at is null
  ), started as (
    select c.*, row_number() over (partition by c.shift_id order by lower(c.w) desc) as rn from cand c where lower(c.w) <= p_at
  ), occ as (
    select * from started where rn <= 2
  ), assigned as (
    select o.*, m.id as machine_id, m.code, m.name as machine_name, m.counter_unit,
           (case when cv.found then cv.supervisor_id else pv.supervisor_id end) as owner_id
      from occ o
      join public.machine m on m.tenant_id = v_tenant
      left join lateral (select true as found, c.supervisor_id from public.assignment_cover c
                          where c.shift_id = o.shift_id and c.shift_date = o.shift_date and c.machine_id = m.id
                          order by c.recorded_at desc, c.id desc limit 1) cv on true
      left join lateral (select v.supervisor_id from public.assignment_version v
                          where v.shift_id = o.shift_id and v.machine_id = m.id and v.effective_from <= o.shift_date
                          order by v.effective_from desc, v.recorded_at desc, v.id desc limit 1) pv on true
     where (case when cv.found then cv.supervisor_id else pv.supervisor_id end) is not null
       and (m.retired_at is null or exists (select 1 from public.production_reading r where r.machine_id = m.id and r.shift_id = o.shift_id and r.shift_date = o.shift_date))
  ), rd as (
    select x.*, mem.full_name as owner_name,
           o.id as o_id, o.product_id as o_product, op.code as o_product_code, o.late as o_late, o.entered_by_ua as o_ua, o.counter_value as o_counter,
           c.id as c_id, c.late as c_late, c.early as c_early, c.entered_by_ua as c_ua, c.counter_value as c_counter,
           sm.id as s_id, sm.target as s_target, sm.movement_pieces as s_pieces, sm.good as s_good, sm.reject as s_reject, sm.unaccounted as s_unacc,
           sm.attainment_pct as s_att, sm.rollover as s_roll, sm.needs_review as s_review, sm.over_reported as s_over,
           dp.product_id as default_product
      from assigned x
      left join public.membership mem on mem.user_id = x.owner_id and mem.tenant_id = v_tenant
      left join lateral (select r.* from public.production_reading r
                          where r.machine_id = x.machine_id and r.shift_id = x.shift_id and r.shift_date = x.shift_date and r.kind = 'opening'
                            and not exists (select 1 from public.production_reading n where n.supersedes_id = r.id) limit 1) o on true
      left join public.product op on op.id = o.product_id
      left join lateral (select r.* from public.production_reading r
                          where r.machine_id = x.machine_id and r.shift_id = x.shift_id and r.shift_date = x.shift_date and r.kind = 'closing'
                            and not exists (select 1 from public.production_reading n where n.supersedes_id = r.id) limit 1) c on true
      left join lateral (select y.* from public.production_summary y
                          where y.machine_id = x.machine_id and y.shift_id = x.shift_id and y.shift_date = x.shift_date
                          order by y.recorded_at desc, y.id desc limit 1) sm on true
      left join lateral (select r.product_id from public.production_reading r join public.product p on p.id = r.product_id and p.retired_at is null
                          join public.shift hs on hs.id = r.shift_id
                          where o.id is null and r.machine_id = x.machine_id and r.kind = 'opening' and not exists (select 1 from public.production_reading n where n.supersedes_id = r.id)
                          order by r.shift_date desc, hs.start_time desc, r.recorded_at desc, r.id desc limit 1) dp on true
  ), calc as (
    select r.*,
           coalesce(r.s_target, case when coalesce(r.o_product, r.default_product) is not null
                                     then app.effective_target(r.machine_id, coalesce(r.o_product, r.default_product), r.shift_id, r.shift_date) end) as target,
           (r.s_target is null and r.o_id is null and r.default_product is not null) as target_assumed,
           case when r.o_id is null then 'missing' when r.o_late then 'late' else 'on_time' end as o_status,
           case when r.c_id is null then 'missing' when r.c_late then 'late' when r.c_early then 'early' else 'on_time' end as c_status
      from rd r
  ), shaped as (
    select k.shift_id, k.name, k.start_time, k.end_time, k.shift_date, k.w, k.rn, k.code, k.target, k.target_assumed, k.o_status, k.c_status, k.c_id, k.s_good,
           jsonb_build_object(
             'machine_id', k.machine_id, 'code', k.code, 'name', k.machine_name, 'counter_unit', k.counter_unit, 'owner_id', k.owner_id, 'owner_name', k.owner_name,
             'product_id', k.o_product, 'product_code', k.o_product_code, 'target', k.target, 'target_assumed', k.target_assumed,
             'opening_status', k.o_status, 'closing_status', k.c_status, 'opening_counter', k.o_counter, 'closing_counter', k.c_counter,
             'movement_pieces', k.s_pieces, 'good', k.s_good, 'reject', k.s_reject, 'unaccounted', k.s_unacc, 'attainment_pct', k.s_att,
             'flags', to_jsonb(array_remove(array[
                case when k.o_late then 'late_opening' end, case when k.c_late then 'late_closing' end, case when k.c_early then 'early_closing' end, case when k.s_roll then 'rollover' end,
                case when k.s_review then 'needs_review' end, case when k.s_over then 'over_reported' end,
                case when coalesce(k.o_ua, false) or coalesce(k.c_ua, false) then 'entered_by_ua' end], null))) as j
      from calc k
  ), agg as (
    select h.shift_id, h.name, h.start_time, h.end_time, h.shift_date, h.w, h.rn,
           jsonb_agg(h.j order by h.code) as machines,
           count(*) as expected,
           count(*) filter (where h.o_status = 'on_time') as openings_on_time,
           count(*) filter (where h.c_status = 'on_time') as closings_on_time,
           count(*) filter (where h.o_status = 'on_time' and h.c_status = 'on_time') as both_on_time,
           coalesce(sum(h.target) filter (where h.target is not null), 0) as t_all,
           coalesce(sum(h.target) filter (where h.target is not null and h.target_assumed), 0) as t_assumed,
           coalesce(sum(h.target) filter (where h.target is not null and h.c_id is not null), 0) as t_closed,
           coalesce(sum(h.s_good) filter (where h.c_id is not null), 0) as g_closed,
           coalesce(sum(h.s_good) filter (where h.c_id is not null and h.target is not null), 0) as g_closed_t
      from shaped h group by h.shift_id, h.name, h.start_time, h.end_time, h.shift_date, h.w, h.rn
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'shift', jsonb_build_object('id', g.shift_id, 'name', g.name, 'start_time', to_char(g.start_time, 'HH24:MI'), 'end_time', to_char(g.end_time, 'HH24:MI')),
           'shift_date', g.shift_date, 'starts_at', lower(g.w), 'ends_at', upper(g.w), 'running', (g.w @> p_at), 'current', (g.rn = 1), 'machines', g.machines, 'assumed_target', g.t_assumed,
           'totals', jsonb_build_object('machines_expected', g.expected, 'openings_on_time', g.openings_on_time, 'closings_on_time', g.closings_on_time,
                                        'both_on_time', g.both_on_time, 'target', g.t_all, 'target_closed', g.t_closed, 'good', g.g_closed,
                                        'attainment_pct', case when g.t_closed > 0 then round(g.g_closed_t * 100.0 / g.t_closed, 2) end))
           order by g.name, lower(g.w) desc), '[]'::jsonb)
    into v_occ
    from agg g;
  return jsonb_build_object('ok', true, 'as_of', p_at, 'occurrences', v_occ);
end
$$;

create function public.reading_state()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not exists (select 1 from public.membership m where m.user_id = auth.uid()) then
    return app._pm_authorise(null, 'rpc:reading_state');
  end if;
  return app.reading_state_at(now());
end
$$;
create function public.reading_detail(p_machine_id uuid, p_shift_id uuid, p_shift_date date)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not exists (select 1 from public.membership m where m.user_id = auth.uid()) then
    return app._pm_authorise(null, 'rpc:reading_detail');
  end if;
  return app.reading_detail_at(p_machine_id, p_shift_id, p_shift_date, now());
end
$$;
create function public.today_board()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not exists (select 1 from public.membership m where m.user_id = auth.uid()) then
    return app._pm_authorise(null, 'rpc:today_board');
  end if;
  return app.today_board_at(now());
end
$$;

-- 12. Reading capture rate (D9, AC-13) ---------------------------------------------------------------------------------------------
-- The definition of product metric 1 for 09 to report: over the shift dates from..to (at most 366 days), EXPECTED = assigned machine-occurrences
-- (owner by cover/plan not null) whose window has ended before p_at; ON TIME = those with a current opening AND a current closing that are not
-- late (a correction carries the Late flag of the earliest submission, so the current row tells). Unassigned machines and occurrences that have not
-- ended are not counted. App-only (no client can execute it; 09 will wrap it): the tenant is a parameter, not the caller's.
create function app.reading_capture_at(p_tenant uuid, p_from date, p_to date, p_at timestamptz)
returns table (expected bigint, on_time bigint)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if p_tenant is null or p_from is null or p_to is null or p_to < p_from then
    perform app._pm_fail('validation', 'Choose a valid date range', 'range');
  end if;
  if p_to - p_from > 366 then
    perform app._pm_fail('validation', 'Choose at most 367 days', 'range');
  end if;
  return query
  with occ as (
    select s.id as shift_id, d.d as shift_date, app._rd_window(s.start_time, s.end_time, d.d, z.timezone) as w, s.retired_at as s_retired
      from public.shift s
      join public.site z on z.id = s.site_id
      cross join lateral (select (p_from + g.n) as d from generate_series(0, p_to - p_from) as g(n)) d
     where s.tenant_id = p_tenant
  ), ended as (
    select o.* from occ o where upper(o.w) + interval '30 minutes' <= p_at and (o.s_retired is null or o.s_retired >= upper(o.w))
  ), owned as (
    select e.shift_id, e.shift_date, m.id as machine_id
      from ended e
      join public.machine m on m.tenant_id = p_tenant and (m.retired_at is null or m.retired_at >= upper(e.w))
      left join lateral (select true as found, c.supervisor_id from public.assignment_cover c
                          where c.shift_id = e.shift_id and c.shift_date = e.shift_date and c.machine_id = m.id
                          order by c.recorded_at desc, c.id desc limit 1) cv on true
      left join lateral (select v.supervisor_id from public.assignment_version v
                          where v.shift_id = e.shift_id and v.machine_id = m.id and v.effective_from <= e.shift_date
                          order by v.effective_from desc, v.recorded_at desc, v.id desc limit 1) pv on true
     where (case when cv.found then cv.supervisor_id else pv.supervisor_id end) is not null
  )
  select count(*)::bigint,
         count(*) filter (where o.id is not null and not o.late and c.id is not null and not c.late and not c.early)::bigint
    from owned w
    left join lateral (select r.id, r.late from public.production_reading r
                        where r.machine_id = w.machine_id and r.shift_id = w.shift_id and r.shift_date = w.shift_date and r.kind = 'opening'
                          and not exists (select 1 from public.production_reading n where n.supersedes_id = r.id) limit 1) o on true
    left join lateral (select r.id, r.late, r.early from public.production_reading r
                        where r.machine_id = w.machine_id and r.shift_id = w.shift_id and r.shift_date = w.shift_date and r.kind = 'closing'
                          and not exists (select 1 from public.production_reading n where n.supersedes_id = r.id) limit 1) c on true;
end
$$;
create function app.reading_capture(p_tenant uuid, p_from date, p_to date)
returns table (expected bigint, on_time bigint)
language sql
stable
security definer
set search_path = ''
as $$ select * from app.reading_capture_at(p_tenant, p_from, p_to, now()) $$;

-- 13. Reading photos (step 6, D6): 07's attachment model with entity type `production_reading` -----------------------------------------------------
-- A photo of the counter display belongs to one reading (entity_id = parent_id = the reading id) and is visible to the owner of that machine in that
-- occurrence and to Unit Admins of the tenant. Same two-phase upload as 07 (begin -> Storage upload -> commit); the Storage INSERT policy is 07's
-- (own pending path only). The SELECT helper is redefined additively: 07's issue branch is unchanged and a production_reading branch is added.
-- No new function in app_policy (its contract is pinned by 07's tests): the reading rule lives in app._rd_can_see_reading, called as the owner.
create function app._rd_can_see_reading(p_reading uuid, p_user uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.production_reading r
    join public.membership m on m.user_id = p_user and m.tenant_id = r.tenant_id and m.status = 'active'
    where r.id = p_reading
      and (m.role = 'unit_admin'
           or (m.role = 'supervisor' and app.machine_owner(r.machine_id, r.shift_id, r.shift_date) = p_user)))
$$;

create or replace function app_policy.can_see_attachment(p_name text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.attachment a
    where a.storage_path = p_name
      and a.tenant_id = app.current_tenant_id()
      and (
        (a.status = 'pending' and a.uploaded_by = auth.uid())
        or (a.status = 'ready' and a.entity_type = 'issue_action'
            and exists (select 1 from public.issue_action x where x.id = a.entity_id and x.tenant_id = a.tenant_id and app.can_see_issue(x.issue_id)))
        or (a.status = 'ready' and a.entity_type = 'production_reading' and app._rd_can_see_reading(a.entity_id, auth.uid()))))
$$;

create function public.rd_attachment_begin(p_request_id uuid, p_reading_id uuid, p_mime text, p_size bigint, p_sha256 text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  c_src constant text := 'rpc:rd_attachment_begin';
  a jsonb;
  v_actor uuid;
  v_tenant uuid;
  v_own text;
  v_sha text := lower(btrim(p_sha256));
  v_ext text;
  v_id uuid := gen_random_uuid();
  v_path text;
  ex public.attachment;
  r public.production_reading;
begin
  if not exists (select 1 from public.membership m where m.user_id = auth.uid()) then
    return app._pm_authorise(p_request_id, c_src);
  end if;
  a := app._rd_authorise(p_request_id, c_src);
  if not (a->>'ok')::boolean then return a; end if;
  v_actor := (a->>'actor')::uuid;
  v_tenant := (a->>'tenant_id')::uuid;
  -- begin writes no audit row, so an audit row with this request id belongs to another RPC (reuse across RPCs -> validation)
  if exists (select 1 from public.audit_event e where e.actor_user_id = v_actor and e.request_id = p_request_id) then
    perform app._pm_fail('validation', 'This request id was already used for another action', 'request_id');
  end if;

  v_own := app._rd_owned(p_reading_id, v_tenant);
  if v_own <> 'ok' then return app._pm_deny(a, v_own, 'production_reading', p_reading_id, c_src); end if;
  select * into r from public.production_reading x where x.id = p_reading_id;
  if a->>'role' = 'supervisor' and app.machine_owner(r.machine_id, r.shift_id, r.shift_date) is distinct from v_actor then
    return app._pm_deny(a, 'not_owner', 'production_reading', p_reading_id, c_src);
  end if;

  if exists (select 1 from public.production_reading n where n.supersedes_id = p_reading_id) then
    perform app._pm_fail('guard', 'This reading was corrected; attach the photo to the latest reading', 'not_current');
  end if;

  v_ext := case lower(btrim(p_mime)) when 'image/jpeg' then 'jpg' when 'image/png' then 'png' when 'image/webp' then 'webp' end;
  if v_ext is null then perform app._pm_fail('validation', 'Photos must be JPEG, PNG or WebP', 'mime'); end if;
  if p_size is null or p_size < 1 or p_size > 5242880 then perform app._pm_fail('validation', 'A photo must be 5 MB or smaller', 'size'); end if;
  if v_sha is null or v_sha !~ '^[0-9a-f]{64}$' then perform app._pm_fail('validation', 'The checksum must be a SHA-256 hex digest', 'sha256'); end if;

  -- a retried begin (same request id) returns the same row
  select * into ex from public.attachment x where x.uploaded_by = v_actor and x.begin_request_id = p_request_id;
  if found then
    if ex.parent_id is distinct from p_reading_id or ex.entity_type <> 'production_reading' then
      perform app._pm_fail('validation', 'This request id was already used for another action', 'request_id');
    end if;
    return jsonb_build_object('ok', true, 'id', ex.id, 'path', ex.storage_path, 'status', ex.status, 'already', true);
  end if;

  if (select count(*) from public.attachment x where x.uploaded_by = v_actor and x.parent_id = p_reading_id and x.status = 'pending'
        and x.created_at > now() - interval '10 minutes') >= 3 then
    perform app._pm_fail('guard', 'Finish or wait for the photos already being uploaded (up to 3 at a time)', 'too_many_pending');
  end if;
  if (select count(*) from public.attachment x where x.parent_id = p_reading_id and x.entity_type = 'production_reading' and x.status = 'ready') >= 3 then
    perform app._pm_fail('guard', 'This reading already has 3 photos', 'photo_limit');
  end if;

  v_path := 'tenant/' || v_tenant::text || '/reading/' || p_reading_id::text || '/' || v_id::text || '.' || v_ext;
  insert into public.attachment (id, tenant_id, entity_type, entity_id, storage_path, mime, size_bytes, sha256, uploaded_by, parent_id, begin_request_id)
  values (v_id, v_tenant, 'production_reading', p_reading_id, v_path, lower(btrim(p_mime)), p_size::integer, v_sha, v_actor, p_reading_id, p_request_id);
  return jsonb_build_object('ok', true, 'id', v_id, 'path', v_path, 'status', 'pending');
end
$$;

create function public.rd_attachment_commit(p_request_id uuid, p_attachment_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  c_src constant text := 'rpc:rd_attachment_commit';
  a jsonb;
  v_actor uuid;
  att public.attachment;
  obj record;
  r public.production_reading;
begin
  if not exists (select 1 from public.membership m where m.user_id = auth.uid()) then
    return app._pm_authorise(p_request_id, c_src);
  end if;
  a := app._rd_authorise(p_request_id, c_src);
  if not (a->>'ok')::boolean then return a; end if;
  if a->>'done' is not null then return jsonb_build_object('ok', true, 'id', (a->>'done')::uuid, 'already', true); end if;
  v_actor := (a->>'actor')::uuid;

  select * into att from public.attachment x where x.id = p_attachment_id;
  if not found then return app._pm_deny(a, 'not_found', 'attachment', p_attachment_id, c_src); end if;
  if att.tenant_id <> (a->>'tenant_id')::uuid then return app._pm_deny(a, 'cross_tenant', 'attachment', p_attachment_id, c_src); end if;
  if att.uploaded_by <> v_actor then return app._pm_deny(a, 'not_uploader', 'attachment', p_attachment_id, c_src); end if;
  if att.entity_type <> 'production_reading' then perform app._pm_fail('guard', 'This attachment is not a reading photo', 'entity_type'); end if;
  if att.status <> 'pending' then perform app._pm_fail('guard', 'This photo is already attached', 'already_ready'); end if;
  if att.created_at < now() - interval '1 hour' then perform app._pm_fail('guard', 'This upload expired. Start again', 'expired'); end if;
  if not app._rd_can_see_reading(att.parent_id, v_actor) then return app._pm_deny(a, 'not_visible', 'attachment', p_attachment_id, c_src); end if;

  select o.metadata into obj from storage.objects o where o.bucket_id = 'attachments' and o.name = att.storage_path;
  if not found then perform app._pm_fail('guard', 'The photo has not been uploaded', 'not_uploaded'); end if;
  if (obj.metadata->>'size')::bigint is distinct from att.size_bytes or obj.metadata->>'mimetype' is distinct from att.mime then
    perform app._pm_fail('guard', 'The uploaded photo does not match what was declared', 'mismatch');
  end if;

  select * into r from public.production_reading x where x.id = att.parent_id;
  if exists (select 1 from public.production_reading n where n.supersedes_id = r.id) then
    perform app._pm_fail('guard', 'This reading was corrected; attach the photo to the latest reading', 'not_current');
  end if;
  if (select count(*) from public.attachment x where x.parent_id = r.id and x.entity_type = 'production_reading' and x.status = 'ready') >= 3 then
    perform app._pm_fail('guard', 'This reading already has 3 photos', 'photo_limit');
  end if;
  update public.attachment x set status = 'ready', ready_at = now() where x.id = att.id;
  perform app._pm_audit(a, 'attachment.added', 'attachment', att.id, null,
    jsonb_build_object('reading_id', r.id, 'kind', r.kind, 'mime', att.mime, 'size_bytes', att.size_bytes, 'sha256', att.sha256), p_request_id, c_src);
  return jsonb_build_object('ok', true, 'id', att.id);
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
