-- 05-shifts-and-assignments (schema lock: shift, assignment_version, assignment_cover, target_override_version; split with 03).
-- Shift master, recurring assignment plan, per-occurrence cover and per-shift target overrides. Clients read under RLS (Unit Admins read the
-- planning tables, every member reads shifts); every write goes through public.sh_* RPC functions that reuse 04's authorisation helpers.
-- The RPCs are named sh_* (not pm_*): 04's pgTAP test 011 pins the number of pm_* RPCs at nine.
-- One file, written step by step: 1 shifts, 2 assignments, 3 target overrides, 4 reads.

-- 1. Audit actions ----------------------------------------------------------------------------------------
insert into app.audit_action (action, feature) values
  ('shift.created', '05'), ('shift.updated', '05'), ('shift.retired', '05'), ('shift.reinstated', '05'),
  ('assignment.set', '05'), ('assignment.ended', '05'), ('assignment.covered', '05'),
  ('target_override.set', '05'), ('target_override.ended', '05');

-- 2. Tables ---------------------------------------------------------------------------------------------------
-- A shift is a daily pattern in the site's timezone. end_time < start_time means it ends the next day (overnight); the shift date of an
-- occurrence is the plant date on which it starts. Times are whole 15-minute steps, never 24:00.
create table public.shift (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenant (id) on delete restrict,
  site_id uuid not null,
  name text not null check (name = btrim(name) and length(name) between 1 and 40),
  start_time time not null check (start_time < time '24:00' and extract(second from start_time) = 0 and extract(minute from start_time) in (0, 15, 30, 45)),
  end_time time not null check (end_time < time '24:00' and extract(second from end_time) = 0 and extract(minute from end_time) in (0, 15, 30, 45)),
  retired_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint shift_times_differ check (end_time <> start_time),
  constraint shift_tenant_id_key unique (tenant_id, id),
  constraint shift_site_fk foreign key (tenant_id, site_id) references public.site (tenant_id, id) on delete restrict
);
create unique index shift_site_name_key on public.shift (site_id, lower(name));

-- Recurring plan, append-only: from effective_from (a plant date) the machine is covered by supervisor_id on this shift; null = unassigned.
-- supervisor_id deliberately has no foreign key: history must outlive the membership. A trigger checks the tenant on insert.
create table public.assignment_version (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenant (id) on delete restrict,
  shift_id uuid not null,
  machine_id uuid not null,
  supervisor_id uuid,
  effective_from date not null,
  recorded_by uuid not null,
  recorded_at timestamptz not null default clock_timestamp(), -- strictly ordered even inside one transaction
  request_id uuid,
  constraint assignment_version_shift_fk foreign key (tenant_id, shift_id) references public.shift (tenant_id, id) on delete restrict,
  constraint assignment_version_machine_fk foreign key (tenant_id, machine_id) references public.machine (tenant_id, id) on delete restrict
);
create index assignment_version_lookup_idx on public.assignment_version (tenant_id, shift_id, machine_id, effective_from desc, recorded_at desc);
create index assignment_version_machine_idx on public.assignment_version (machine_id);

-- Cover for one shift occurrence (shift + shift date), append-only; the latest row per (shift, date, machine) wins; supervisor_id null = unassigned.
create table public.assignment_cover (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenant (id) on delete restrict,
  shift_id uuid not null,
  shift_date date not null,
  machine_id uuid not null,
  supervisor_id uuid,
  reason text not null check (reason = btrim(reason) and length(reason) between 1 and 200),
  recorded_by uuid not null,
  recorded_at timestamptz not null default clock_timestamp(),
  request_id uuid,
  constraint assignment_cover_shift_fk foreign key (tenant_id, shift_id) references public.shift (tenant_id, id) on delete restrict,
  constraint assignment_cover_machine_fk foreign key (tenant_id, machine_id) references public.machine (tenant_id, id) on delete restrict
);
create index assignment_cover_lookup_idx on public.assignment_cover (shift_id, shift_date, machine_id, recorded_at desc);
create index assignment_cover_machine_idx on public.assignment_cover (machine_id);

-- Per-shift target override (pieces per shift) for a machine x product x shift, effective-dated and append-only like target_version.
-- pieces_per_shift null = the override ended (the base target applies again).
create table public.target_override_version (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenant (id) on delete restrict,
  machine_id uuid not null,
  product_id uuid not null,
  shift_id uuid not null,
  effective_from date not null,
  pieces_per_shift integer check (pieces_per_shift between 1 and 1000000),
  recorded_by uuid not null,
  recorded_at timestamptz not null default clock_timestamp(),
  request_id uuid,
  constraint target_override_machine_fk foreign key (tenant_id, machine_id) references public.machine (tenant_id, id) on delete restrict,
  constraint target_override_product_fk foreign key (tenant_id, product_id) references public.product (tenant_id, id) on delete restrict,
  constraint target_override_shift_fk foreign key (tenant_id, shift_id) references public.shift (tenant_id, id) on delete restrict
);
create index target_override_lookup_idx on public.target_override_version (tenant_id, machine_id, product_id, shift_id, effective_from desc, recorded_at desc);
create index target_override_product_idx on public.target_override_version (product_id);
create index target_override_shift_idx on public.target_override_version (shift_id);

-- 3. Row-level security ---------------------------------------------------------------------------------------
-- shift: every active member of the tenant reads. The three planning tables: Unit Admins only (a supervisor sees their own machines
-- through my_shift(), never the raw plan). Nobody writes through the API.
alter table public.shift enable row level security;
alter table public.shift force row level security;
create policy shift_select_member on public.shift for select to authenticated using (tenant_id = (select app.current_tenant_id()));
revoke all on public.shift from public, anon, authenticated, service_role;
grant select on public.shift to authenticated;
grant select, insert, update, delete on public.shift to service_role;

do $$
declare t text;
begin
  foreach t in array array['assignment_version', 'assignment_cover', 'target_override_version'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('alter table public.%I force row level security', t);
    execute format($p$create policy %I on public.%I for select to authenticated
      using (tenant_id = (select app.current_tenant_id()) and (select app."current_role"()) = 'unit_admin')$p$, t || '_select_ua', t);
    execute format('revoke all on public.%I from public, anon, authenticated, service_role', t);
    execute format('grant select on public.%I to authenticated', t);
    execute format('grant select, insert on public.%I to service_role', t);
  end loop;
end $$;

-- 4. Append-only history (no privilege for any role, plus triggers that also stop the owner) ------------------------
create function app.sh_append_only()
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
  foreach t in array array['assignment_version', 'assignment_cover', 'target_override_version'] loop
    execute format('create trigger %I before update or delete on public.%I for each row execute function app.sh_append_only()', t || '_no_update_delete', t);
    execute format('create trigger %I before truncate on public.%I for each statement execute function app.sh_append_only()', t || '_no_truncate', t);
  end loop;
end $$;

-- A supervisor named in the plan or a cover must belong to the same tenant (no foreign key, see above).
create function app.sh_supervisor_same_tenant()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.supervisor_id is not null
     and not exists (select 1 from public.membership m where m.user_id = new.supervisor_id and m.tenant_id = new.tenant_id) then
    raise exception 'The supervisor does not belong to this tenant' using errcode = '23514';
  end if;
  return new;
end
$$;
create trigger assignment_version_supervisor before insert on public.assignment_version for each row execute function app.sh_supervisor_same_tenant();
create trigger assignment_cover_supervisor before insert on public.assignment_cover for each row execute function app.sh_supervisor_same_tenant();

-- 5. Shift occurrences ------------------------------------------------------------------------------------------
-- The UTC range [start, end) of the occurrence of a shift on a shift date, computed in the site's timezone. Null when the shift is unknown or
-- is not the caller's (only the service role skips the tenant check; no claims at all gets null, like app.target_for).
create function app.shift_window(p_shift uuid, p_date date)
returns tstzrange
language sql
stable
security definer
set search_path = ''
as $$
  select tstzrange(
    (p_date + s.start_time) at time zone z.timezone,
    ((p_date + case when s.end_time < s.start_time then 1 else 0 end) + s.end_time) at time zone z.timezone,
    '[)')
  from public.shift s
  join public.site z on z.id = s.site_id
  where s.id = p_shift
    and (auth.role() = 'service_role' or s.tenant_id = app.current_tenant_id())
$$;

-- The occurrences running at a moment: the caller's tenant (every tenant for the service role). A shift that started on the previous plant
-- date is current until its end (overnight). Retired shifts are never current.
create function app.current_occurrences(p_at timestamptz default now())
returns table (tenant_id uuid, shift_id uuid, shift_date date, span tstzrange)
language sql
stable
security definer
set search_path = ''
as $$
  select s.tenant_id, s.id, d.d, w.w
  from public.shift s
  join public.site z on z.id = s.site_id
  cross join lateral unnest(array[(p_at at time zone z.timezone)::date - 1, (p_at at time zone z.timezone)::date]) as d(d)
  cross join lateral (select app.shift_window(s.id, d.d) as w) w
  where s.retired_at is null
    and (auth.role() = 'service_role' or s.tenant_id = app.current_tenant_id())
    and w.w @> p_at
$$;

-- 6. Write RPCs: shifts -----------------------------------------------------------------------------------------
-- Same contract as 04's pm_* RPCs (D2): authorise via app._pm_authorise (Unit Admin only, per-tenant lock, idempotency by request id + source),
-- denials are committed and returned as {ok:false, code:'not_allowed'}, validation/guard errors raise P0001 with detail {code, field?, ...}.

-- 'ok' when the row exists in the caller's tenant, else 'cross_tenant' (exists elsewhere) or 'not_found'. kind: shift | member (by user id).
create function app._sh_owned(p_kind text, p_id uuid, p_tenant uuid)
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
  if p_kind = 'shift' then select s.tenant_id into v_tenant from public.shift s where s.id = p_id;
  elsif p_kind = 'member' then select m.tenant_id into v_tenant from public.membership m where m.user_id = p_id;
  else raise exception 'unknown kind %', p_kind; end if;
  if v_tenant is null then return 'not_found'; end if;
  if v_tenant <> p_tenant then return 'cross_tenant'; end if;
  return 'ok';
end
$$;

-- Maps a violated unique index of 05 to a field error; returns normally for constraints it does not know (the caller re-raises).
create function app._sh_dup(p_constraint text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if p_constraint = 'shift_site_name_key' then
    perform app._pm_fail('duplicate', 'A shift with this name already exists', 'name');
  end if;
end
$$;

-- 'HH:MM' on a 15-minute step -> time; anything else is a validation error on p_field.
create function app._sh_time(p_value text, p_field text)
returns time
language plpgsql
immutable
security definer
set search_path = ''
as $$
declare
  v text := btrim(p_value);
begin
  if v is null or v !~ '^([01][0-9]|2[0-3]):[0-5][0-9]$' then
    perform app._pm_fail('validation', 'Enter a time as HH:MM (24-hour)', p_field);
  end if;
  if substr(v, 4, 2)::int % 15 <> 0 then
    perform app._pm_fail('validation', 'Use 15-minute steps: :00, :15, :30 or :45', p_field);
  end if;
  return v::time;
end
$$;

create function public.sh_save_shift(p_request_id uuid, p_id uuid, p_name text, p_start text, p_end text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  c_src constant text := 'rpc:sh_save_shift';
  a jsonb;
  v_tenant uuid;
  v_own text;
  v_name text := btrim(p_name);
  v_start time;
  v_end time;
  v_site public.site;
  cur public.shift;
  upd public.shift;
  v_c text;
begin
  a := app._pm_authorise(p_request_id, c_src);
  if not (a->>'ok')::boolean then return a; end if;
  if a->>'done' is not null then return jsonb_build_object('ok', true, 'id', (a->>'done')::uuid, 'already', true); end if;
  v_tenant := (a->>'tenant_id')::uuid;

  if p_id is not null then
    v_own := app._sh_owned('shift', p_id, v_tenant);
    if v_own <> 'ok' then return app._pm_deny(a, v_own, 'shift', p_id, c_src); end if;
  end if;
  perform app._pm_len(v_name, 1, 40, 'name', 'Enter a name of 1 to 40 characters');
  v_start := app._sh_time(p_start, 'start_time');
  v_end := app._sh_time(p_end, 'end_time');
  if v_end = v_start then perform app._pm_fail('validation', 'The end time must differ from the start time', 'end_time'); end if;

  begin
    if p_id is null then
      select * into v_site from public.site s where s.tenant_id = v_tenant;
      if not found then perform app._pm_fail('validation', 'Set up your site first', 'site'); end if;
      insert into public.shift (tenant_id, site_id, name, start_time, end_time) values (v_tenant, v_site.id, v_name, v_start, v_end) returning * into upd;
    else
      select * into cur from public.shift s where s.id = p_id;
      if cur.retired_at is not null then perform app._pm_fail('guard', 'Reinstate this shift before editing it', 'retired'); end if;
      -- Past occurrences must never change meaning (D4): times are frozen once the shift has a plan version or a cover.
      if (v_start <> cur.start_time or v_end <> cur.end_time)
         and (exists (select 1 from public.assignment_version v where v.shift_id = p_id)
              or exists (select 1 from public.assignment_cover c where c.shift_id = p_id)) then
        perform app._pm_fail('guard', 'Times can''t change once the shift has assignments. Retire it and create a new shift.', 'shift_times_locked');
      end if;
      update public.shift s set name = v_name, start_time = v_start, end_time = v_end, updated_at = now() where s.id = p_id returning * into upd;
    end if;
  exception when unique_violation then
    get stacked diagnostics v_c = constraint_name;
    perform app._sh_dup(v_c);
    raise;
  end;

  if p_id is null then
    perform app._pm_audit(a, 'shift.created', 'shift', upd.id, null, to_jsonb(upd) - 'created_at' - 'updated_at', p_request_id, c_src);
  else
    perform app._pm_audit(a, 'shift.updated', 'shift', upd.id,
      to_jsonb(cur) - 'created_at' - 'updated_at', to_jsonb(upd) - 'created_at' - 'updated_at', p_request_id, c_src);
  end if;
  return jsonb_build_object('ok', true, 'id', upd.id);
end
$$;

create function public.sh_set_shift_retired(p_request_id uuid, p_id uuid, p_retired boolean)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  c_src constant text := 'rpc:sh_set_shift_retired';
  a jsonb;
  v_own text;
  cur public.shift;
  upd public.shift;
begin
  a := app._pm_authorise(p_request_id, c_src);
  if not (a->>'ok')::boolean then return a; end if;
  if a->>'done' is not null then return jsonb_build_object('ok', true, 'id', (a->>'done')::uuid, 'already', true); end if;

  v_own := app._sh_owned('shift', p_id, (a->>'tenant_id')::uuid);
  if v_own <> 'ok' then return app._pm_deny(a, v_own, 'shift', p_id, c_src); end if;
  if p_retired is null then perform app._pm_fail('validation', 'Choose retire or reinstate', 'retired'); end if;
  select * into cur from public.shift s where s.id = p_id;
  if (cur.retired_at is not null) = p_retired then return jsonb_build_object('ok', true, 'id', p_id, 'changed', false); end if;

  update public.shift s set retired_at = case when p_retired then now() end, updated_at = now() where s.id = p_id returning * into upd;
  perform app._pm_audit(a, case when p_retired then 'shift.retired' else 'shift.reinstated' end, 'shift', p_id,
    to_jsonb(cur) - 'created_at' - 'updated_at', to_jsonb(upd) - 'created_at' - 'updated_at', p_request_id, c_src);
  return jsonb_build_object('ok', true, 'id', p_id, 'changed', true);
end
$$;

-- 99. Function privileges: no app function is executable by clients (test 004); the public entry points are executable by authenticated only.
do $$
declare f record;
begin
  for f in
    select p.oid::regprocedure as sig, n.nspname
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where (n.nspname = 'app' and p.proname ~ '^(_sh_|sh_|shift_window$|current_occurrences$|machine_owner|override_for$|effective_target$)')
       or (n.nspname = 'public' and p.proname ~ '^(sh_|shift_board$|my_shift$)')
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    if f.nspname = 'public' then
      execute format('grant execute on function %s to authenticated', f.sig);
    end if;
  end loop;
end $$;
