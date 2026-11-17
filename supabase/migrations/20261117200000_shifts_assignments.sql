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
  v_end timestamptz;
begin
  a := app._pm_authorise(p_request_id, c_src);
  if not (a->>'ok')::boolean then return a; end if;
  if a->>'done' is not null then return jsonb_build_object('ok', true, 'id', (a->>'done')::uuid, 'already', true); end if;

  v_own := app._sh_owned('shift', p_id, (a->>'tenant_id')::uuid);
  if v_own <> 'ok' then return app._pm_deny(a, v_own, 'shift', p_id, c_src); end if;
  if p_retired is null then perform app._pm_fail('validation', 'Choose retire or reinstate', 'retired'); end if;
  select * into cur from public.shift s where s.id = p_id;
  if (cur.retired_at is not null) = p_retired then return jsonb_build_object('ok', true, 'id', p_id, 'changed', false); end if;
  if p_retired then
    select upper(o.span) into v_end from app.current_occurrences(now()) o where o.shift_id = p_id limit 1;
    if v_end is not null then
      perform app._pm_fail('guard', 'This shift is running until ' || to_char(v_end at time zone (select z.timezone from public.site z where z.id = cur.site_id), 'HH24:MI')
        || ' — retire it after it ends', 'occurrence_running');
    end if;
  end if;

  update public.shift s set retired_at = case when p_retired then now() end, updated_at = now() where s.id = p_id returning * into upd;
  perform app._pm_audit(a, case when p_retired then 'shift.retired' else 'shift.reinstated' end, 'shift', p_id,
    to_jsonb(cur) - 'created_at' - 'updated_at', to_jsonb(upd) - 'created_at' - 'updated_at', p_request_id, c_src);
  return jsonb_build_object('ok', true, 'id', p_id, 'changed', true);
end
$$;

-- 7. Ownership resolution (D8) ---------------------------------------------------------------------------------------
-- Who is responsible for a machine on a shift occurrence: the latest cover of that occurrence (its supervisor, possibly null =
-- explicitly unassigned), else the plan version in force on the shift date (null = unassigned), else nobody. Returns one row
-- (supervisor_id, source plan|cover|none, cover reason), or no row when the shift is not the caller's (only the service role skips
-- the tenant check, like app.target_for). app.machine_owner is the contract for features 06-09; the board and my_shift use the same rows.
create function app.machine_owner_src(p_machine uuid, p_shift uuid, p_date date)
returns table (supervisor_id uuid, source text, reason text)
language sql
stable
security definer
set search_path = ''
as $$
  with t as (
    select s.id from public.shift s
    where s.id = p_shift and (auth.role() = 'service_role' or s.tenant_id = app.current_tenant_id())
  ),
  cv as (
    select c.supervisor_id, c.reason
    from public.assignment_cover c join t on t.id = c.shift_id
    where c.shift_date = p_date and c.machine_id = p_machine
    order by c.recorded_at desc, c.id desc
    limit 1
  ),
  pv as (
    select v.supervisor_id
    from public.assignment_version v join t on t.id = v.shift_id
    where v.machine_id = p_machine and v.effective_from <= p_date
    order by v.effective_from desc, v.recorded_at desc, v.id desc
    limit 1
  )
  select cv.supervisor_id, 'cover'::text, cv.reason from cv
  union all
  select pv.supervisor_id, case when pv.supervisor_id is null then 'none' else 'plan' end, null::text from pv where not exists (select 1 from cv)
  union all
  select null::uuid, 'none'::text, null::text
  where exists (select 1 from t) and not exists (select 1 from cv) and not exists (select 1 from pv)
$$;

create function app.machine_owner(p_machine uuid, p_shift uuid, p_date date)
returns uuid
language sql
stable
security definer
set search_path = ''
as $$ select o.supervisor_id from app.machine_owner_src(p_machine, p_shift, p_date) o $$;

-- 8. Write RPCs: assignments and cover -------------------------------------------------------------------------------
-- Machine id list: required, at most 500, de-duplicated by the callers. Returns the generic denial (audited) when an id is not the caller's.
create function app._sh_check_machines(p_auth jsonb, p_ids uuid[], p_src text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid;
  v_own text;
begin
  if p_ids is null or cardinality(p_ids) = 0 then perform app._pm_fail('validation', 'Choose at least one machine', 'machine_ids'); end if;
  if cardinality(p_ids) > 500 then perform app._pm_fail('validation', 'Choose at most 500 machines at a time', 'machine_ids'); end if;
  foreach v_id in array p_ids loop
    v_own := app._pm_owned('machine', v_id, (p_auth->>'tenant_id')::uuid);
    if v_own <> 'ok' then return app._pm_deny(p_auth, v_own, 'machine', v_id, p_src); end if;
  end loop;
  return null;
end
$$;

-- A supervisor to assign or cover with: an active, not-must-change member with the supervisor role (validation 'supervisor' otherwise).
create function app._sh_check_supervisor(p_user uuid)
returns void
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if not exists (select 1 from public.membership m
                 where m.user_id = p_user and m.role = 'supervisor' and m.status = 'active' and m.must_change_password = false) then
    perform app._pm_fail('validation', 'Choose an active supervisor', 'supervisor');
  end if;
end
$$;

-- The plan-level owner (ignores covers) of a machine on a plant date, for "who loses it" and the audit trail.
create function app._sh_plan_owner(p_shift uuid, p_machine uuid, p_date date)
returns uuid
language sql
stable
security definer
set search_path = ''
as $$
  select v.supervisor_id from public.assignment_version v
  where v.shift_id = p_shift and v.machine_id = p_machine and v.effective_from <= p_date
  order by v.effective_from desc, v.recorded_at desc, v.id desc
  limit 1
$$;

create function public.sh_assign(
  p_request_id uuid, p_shift_id uuid, p_supervisor_id uuid, p_machine_ids uuid[], p_from date, p_until date default null
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  c_src constant text := 'rpc:sh_assign';
  a jsonb;
  v_tenant uuid;
  v_own text;
  v_deny jsonb;
  v_ids uuid[];
  v_shift public.shift;
  v_codes text[];
  v_retired text[];
  v_super jsonb;
  v_prev jsonb;
begin
  a := app._pm_authorise(p_request_id, c_src);
  if not (a->>'ok')::boolean then return a; end if;
  if a->>'done' is not null then return jsonb_build_object('ok', true, 'id', (a->>'done')::uuid, 'already', true); end if;
  v_tenant := (a->>'tenant_id')::uuid;

  v_own := app._sh_owned('shift', p_shift_id, v_tenant);
  if v_own <> 'ok' then return app._pm_deny(a, v_own, 'shift', p_shift_id, c_src); end if;
  if p_supervisor_id is null then perform app._pm_fail('validation', 'Choose a supervisor', 'supervisor'); end if;
  v_own := app._sh_owned('member', p_supervisor_id, v_tenant);
  if v_own <> 'ok' then return app._pm_deny(a, v_own, 'member', p_supervisor_id, c_src); end if;
  v_ids := (select coalesce(array_agg(distinct x), '{}') from unnest(p_machine_ids) x);
  v_deny := app._sh_check_machines(a, v_ids, c_src);
  if v_deny is not null then return v_deny; end if;

  if p_from is null then perform app._pm_fail('validation', 'Choose a start date', 'from'); end if;
  if p_from < app.plant_date(v_tenant) then perform app._pm_fail('validation', 'Assignments can''t start in the past', 'from'); end if;
  if p_until is not null and p_until < p_from then perform app._pm_fail('validation', 'The end date can''t be before the start date', 'until'); end if;
  perform app._sh_check_supervisor(p_supervisor_id);
  select * into v_shift from public.shift s where s.id = p_shift_id;
  if v_shift.retired_at is not null then perform app._pm_fail('guard', 'This shift is retired', 'shift_id'); end if;
  -- R1: a plan change starts at the first occurrence that has not started; a started or ended occurrence is changed only by Cover.
  if now() >= lower(app.shift_window(p_shift_id, p_from)) then
    perform app._pm_fail('guard', 'This shift has already started — use Cover for this shift', 'occurrence_started');
  end if;
  select array_agg(m.code order by m.code) into v_retired from public.machine m where m.id = any (v_ids) and m.retired_at is not null;
  if v_retired is not null then
    perform app._pm_fail('guard', 'Retired machines can''t be assigned', 'machine_ids', jsonb_build_object('machines', to_jsonb(v_retired)));
  end if;

  select array_agg(m.code order by m.code), jsonb_agg(jsonb_build_object('machine_code', m.code, 'supervisor_id', app._sh_plan_owner(p_shift_id, m.id, p_from)) order by m.code)
    into v_codes, v_prev
    from public.machine m where m.id = any (v_ids);

  -- R4: re-planning supersedes (04's "end means end"): the new value is also written at every later scheduled version date of these machines
  -- on this shift, up to the end date (all of them when there is none), so an older scheduled change can't silently win later.
  select coalesce(jsonb_agg(jsonb_build_object('machine_code', q.code, 'dates', q.dates) order by q.code), '[]'::jsonb) into v_super
    from (select m.code, jsonb_agg(distinct v.effective_from order by v.effective_from) as dates
            from public.assignment_version v join public.machine m on m.id = v.machine_id
           where v.shift_id = p_shift_id and v.machine_id = any (v_ids) and v.effective_from > p_from
             and (p_until is null or v.effective_from <= p_until)
           group by m.code) q;
  insert into public.assignment_version (tenant_id, shift_id, machine_id, supervisor_id, effective_from, recorded_by, request_id)
  select v_tenant, p_shift_id, x, p_supervisor_id, p_from, (a->>'actor')::uuid, p_request_id from unnest(v_ids) x;
  insert into public.assignment_version (tenant_id, shift_id, machine_id, supervisor_id, effective_from, recorded_by, request_id)
  select v_tenant, p_shift_id, q.machine_id, p_supervisor_id, q.d, (a->>'actor')::uuid, p_request_id
    from (select distinct v.machine_id, v.effective_from as d from public.assignment_version v
           where v.shift_id = p_shift_id and v.machine_id = any (v_ids) and v.effective_from > p_from
             and (p_until is null or v.effective_from <= p_until) and v.request_id is distinct from p_request_id) q;
  if p_until is not null then
    insert into public.assignment_version (tenant_id, shift_id, machine_id, supervisor_id, effective_from, recorded_by, request_id)
    select v_tenant, p_shift_id, x, null, p_until + 1, (a->>'actor')::uuid, p_request_id from unnest(v_ids) x;
  end if;

  perform app._pm_audit(a, 'assignment.set', 'shift', p_shift_id,
    jsonb_build_object('previous', v_prev),
    jsonb_build_object('shift', v_shift.name, 'machines', to_jsonb(v_codes), 'supervisor_id', p_supervisor_id, 'from', p_from, 'until', p_until,
                       'superseded', v_super),
    p_request_id, c_src);
  return jsonb_build_object('ok', true, 'id', p_shift_id, 'machines', cardinality(v_ids));
end
$$;

create function public.sh_unassign(p_request_id uuid, p_shift_id uuid, p_machine_ids uuid[], p_from date)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  c_src constant text := 'rpc:sh_unassign';
  a jsonb;
  v_tenant uuid;
  v_own text;
  v_deny jsonb;
  v_ids uuid[];
  v_shift public.shift;
  v_ended uuid[];
  v_codes text[];
  v_super jsonb;
  v_prev jsonb;
begin
  a := app._pm_authorise(p_request_id, c_src);
  if not (a->>'ok')::boolean then return a; end if;
  if a->>'done' is not null then return jsonb_build_object('ok', true, 'id', (a->>'done')::uuid, 'already', true); end if;
  v_tenant := (a->>'tenant_id')::uuid;

  v_own := app._sh_owned('shift', p_shift_id, v_tenant);
  if v_own <> 'ok' then return app._pm_deny(a, v_own, 'shift', p_shift_id, c_src); end if;
  v_ids := (select coalesce(array_agg(distinct x), '{}') from unnest(p_machine_ids) x);
  v_deny := app._sh_check_machines(a, v_ids, c_src);
  if v_deny is not null then return v_deny; end if;

  if p_from is null then perform app._pm_fail('validation', 'Choose a date', 'from'); end if;
  if p_from < app.plant_date(v_tenant) then perform app._pm_fail('validation', 'Assignments can''t end in the past', 'from'); end if;
  select * into v_shift from public.shift s where s.id = p_shift_id;
  if now() >= lower(app.shift_window(p_shift_id, p_from)) then
    perform app._pm_fail('guard', 'This shift has already started — use Cover for this shift', 'occurrence_started');
  end if;

  -- Only machines that have a supervisor from that date (in force, or scheduled later) are ended; refused when none has.
  select coalesce(array_agg(m.id order by m.code), '{}'), array_agg(m.code order by m.code),
         jsonb_agg(jsonb_build_object('machine_code', m.code, 'supervisor_id', app._sh_plan_owner(p_shift_id, m.id, p_from)) order by m.code)
    into v_ended, v_codes, v_prev
    from public.machine m
   where m.id = any (v_ids)
     and (app._sh_plan_owner(p_shift_id, m.id, p_from) is not null
          or exists (select 1 from public.assignment_version v where v.shift_id = p_shift_id and v.machine_id = m.id
                      and v.effective_from > p_from and v.supervisor_id is not null));
  if cardinality(v_ended) = 0 then perform app._pm_fail('guard', 'None of these machines is assigned from that date', 'not_assigned'); end if;

  -- R4: ending supersedes every later scheduled version of these machines too (a null at each of those dates).
  select coalesce(jsonb_agg(jsonb_build_object('machine_code', q.code, 'dates', q.dates) order by q.code), '[]'::jsonb) into v_super
    from (select m.code, jsonb_agg(distinct v.effective_from order by v.effective_from) as dates
            from public.assignment_version v join public.machine m on m.id = v.machine_id
           where v.shift_id = p_shift_id and v.machine_id = any (v_ended) and v.effective_from > p_from
           group by m.code) q;
  insert into public.assignment_version (tenant_id, shift_id, machine_id, supervisor_id, effective_from, recorded_by, request_id)
  select v_tenant, p_shift_id, x, null, p_from, (a->>'actor')::uuid, p_request_id from unnest(v_ended) x;
  insert into public.assignment_version (tenant_id, shift_id, machine_id, supervisor_id, effective_from, recorded_by, request_id)
  select v_tenant, p_shift_id, q.machine_id, null, q.d, (a->>'actor')::uuid, p_request_id
    from (select distinct v.machine_id, v.effective_from as d from public.assignment_version v
           where v.shift_id = p_shift_id and v.machine_id = any (v_ended) and v.effective_from > p_from and v.request_id is distinct from p_request_id) q;

  perform app._pm_audit(a, 'assignment.ended', 'shift', p_shift_id,
    jsonb_build_object('previous', v_prev),
    jsonb_build_object('shift', v_shift.name, 'machines', to_jsonb(v_codes), 'from', p_from, 'superseded', v_super),
    p_request_id, c_src);
  return jsonb_build_object('ok', true, 'id', p_shift_id, 'machines', cardinality(v_ended));
end
$$;

create function public.sh_cover(p_request_id uuid, p_shift_id uuid, p_shift_date date, p_machine_ids uuid[], p_supervisor_id uuid, p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  c_src constant text := 'rpc:sh_cover';
  a jsonb;
  v_tenant uuid;
  v_own text;
  v_deny jsonb;
  v_ids uuid[];
  v_reason text := btrim(p_reason);
  v_shift public.shift;
  v_window tstzrange;
  v_codes text[];
  v_retired text[];
  v_prev jsonb;
begin
  a := app._pm_authorise(p_request_id, c_src);
  if not (a->>'ok')::boolean then return a; end if;
  if a->>'done' is not null then return jsonb_build_object('ok', true, 'id', (a->>'done')::uuid, 'already', true); end if;
  v_tenant := (a->>'tenant_id')::uuid;

  v_own := app._sh_owned('shift', p_shift_id, v_tenant);
  if v_own <> 'ok' then return app._pm_deny(a, v_own, 'shift', p_shift_id, c_src); end if;
  if p_supervisor_id is not null then
    v_own := app._sh_owned('member', p_supervisor_id, v_tenant);
    if v_own <> 'ok' then return app._pm_deny(a, v_own, 'member', p_supervisor_id, c_src); end if;
  end if;
  v_ids := (select coalesce(array_agg(distinct x), '{}') from unnest(p_machine_ids) x);
  v_deny := app._sh_check_machines(a, v_ids, c_src);
  if v_deny is not null then return v_deny; end if;

  if p_shift_date is null then perform app._pm_fail('validation', 'Choose the shift date', 'shift_date'); end if;
  perform app._pm_len(v_reason, 1, 200, 'reason', 'Enter a reason of 1 to 200 characters');
  if p_supervisor_id is not null then perform app._sh_check_supervisor(p_supervisor_id); end if;
  select * into v_shift from public.shift s where s.id = p_shift_id;
  if v_shift.retired_at is not null then perform app._pm_fail('guard', 'This shift is retired', 'shift_id'); end if;
  select array_agg(m.code order by m.code) into v_retired from public.machine m where m.id = any (v_ids) and m.retired_at is not null;
  if v_retired is not null then
    perform app._pm_fail('guard', 'Retired machines can''t be covered', 'machine_ids', jsonb_build_object('machines', to_jsonb(v_retired)));
  end if;
  -- Cover is for an occurrence that has not ended (a running one included) - D6. The clock is now(), the transaction start: a request that
  -- waits on the tenant lock across the end of the occurrence is judged at its own start, which is the moment the user acted.
  v_window := app.shift_window(p_shift_id, p_shift_date);
  if now() >= upper(v_window) then perform app._pm_fail('guard', 'This shift has already ended', 'occurrence_ended'); end if;

  select array_agg(m.code order by m.code),
         jsonb_agg(jsonb_build_object('machine_code', m.code, 'supervisor_id', (select o.supervisor_id from app.machine_owner_src(m.id, p_shift_id, p_shift_date) o)) order by m.code)
    into v_codes, v_prev
    from public.machine m where m.id = any (v_ids);

  insert into public.assignment_cover (tenant_id, shift_id, shift_date, machine_id, supervisor_id, reason, recorded_by, request_id)
  select v_tenant, p_shift_id, p_shift_date, x, p_supervisor_id, v_reason, (a->>'actor')::uuid, p_request_id from unnest(v_ids) x;

  perform app._pm_audit(a, 'assignment.covered', 'shift', p_shift_id,
    jsonb_build_object('previous', v_prev),
    jsonb_build_object('shift', v_shift.name, 'shift_date', p_shift_date, 'machines', to_jsonb(v_codes), 'supervisor_id', p_supervisor_id, 'reason', v_reason),
    p_request_id, c_src);
  return jsonb_build_object('ok', true, 'id', p_shift_id, 'machines', cardinality(v_ids));
end
$$;

-- 9. Per-shift target overrides (D9) -----------------------------------------------------------------------------------
-- The override in force for machine x product x shift on a plant date: pieces per shift, or null when there is none or it was ended.
-- Same caller rule as app.target_for: only the service role skips the tenant check.
create function app.override_for(p_machine uuid, p_product uuid, p_shift uuid, p_date date)
returns integer
language sql
stable
security definer
set search_path = ''
as $$
  select v.pieces_per_shift
  from public.target_override_version v
  where v.machine_id = p_machine
    and v.product_id = p_product
    and v.shift_id = p_shift
    and v.effective_from <= p_date
    and (auth.role() = 'service_role' or v.tenant_id = app.current_tenant_id())
  order by v.effective_from desc, v.recorded_at desc, v.id desc
  limit 1
$$;

-- AC-8: the target that applies to a machine-shift = the shift override in force, else 04's base target, else null.
-- The contract for features 06-09.
create function app.effective_target(p_machine uuid, p_product uuid, p_shift uuid, p_date date)
returns integer
language sql
stable
security definer
set search_path = ''
as $$ select coalesce(app.override_for(p_machine, p_product, p_shift, p_date), app.target_for(p_machine, p_product, p_date)) $$;

create function public.sh_set_target_override(
  p_request_id uuid, p_machine_id uuid, p_product_id uuid, p_shift_id uuid, p_pieces integer, p_effective_from date
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  c_src constant text := 'rpc:sh_set_target_override';
  a jsonb;
  v_tenant uuid;
  v_own text;
  m public.machine;
  p public.product;
  s public.shift;
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
  v_own := app._sh_owned('shift', p_shift_id, v_tenant);
  if v_own <> 'ok' then return app._pm_deny(a, v_own, 'shift', p_shift_id, c_src); end if;

  if p_pieces is null or p_pieces < 1 or p_pieces > 1000000 then
    perform app._pm_fail('validation', 'Enter a whole number from 1 to 1,000,000', 'pieces');
  end if;
  if p_effective_from is null then perform app._pm_fail('validation', 'Choose a start date', 'effective_from'); end if;
  if p_effective_from < app.plant_date(v_tenant) then
    perform app._pm_fail('validation', 'Targets can''t start in the past', 'effective_from');
  end if;
  select * into m from public.machine x where x.id = p_machine_id;
  select * into p from public.product x where x.id = p_product_id;
  select * into s from public.shift x where x.id = p_shift_id;
  if m.retired_at is not null then perform app._pm_fail('guard', 'This machine is retired', 'machine_id'); end if;
  if p.retired_at is not null then perform app._pm_fail('guard', 'This product is retired', 'product_id'); end if;
  if s.retired_at is not null then perform app._pm_fail('guard', 'This shift is retired', 'shift_id'); end if;
  -- R1: an override never rewrites a started occurrence. (Overrides don't freeze the shift's times: they depend on the date only, never on the window.)
  if now() >= lower(app.shift_window(p_shift_id, p_effective_from)) then
    perform app._pm_fail('guard', 'This shift has already started — use Cover for this shift', 'occurrence_started');
  end if;

  v_before := app.override_for(p_machine_id, p_product_id, p_shift_id, p_effective_from);
  insert into public.target_override_version (tenant_id, machine_id, product_id, shift_id, effective_from, pieces_per_shift, recorded_by, request_id)
  values (v_tenant, p_machine_id, p_product_id, p_shift_id, p_effective_from, p_pieces, (a->>'actor')::uuid, p_request_id)
  returning id into v_id;
  perform app._pm_audit(a, 'target_override.set', 'target_override_version', v_id,
    jsonb_build_object('pieces_per_shift', v_before),
    jsonb_build_object('machine_code', m.code, 'product_code', p.code, 'shift', s.name, 'pieces_per_shift', p_pieces, 'effective_from', p_effective_from),
    p_request_id, c_src);
  return jsonb_build_object('ok', true, 'id', v_id);
end
$$;

-- "End" means the base target applies again from the end date: besides the null at the end date, every later scheduled override whose
-- winning version is a target is cancelled with its own null, in this transaction (04's R1 rule).
create function public.sh_end_target_override(p_request_id uuid, p_machine_id uuid, p_product_id uuid, p_shift_id uuid, p_effective_from date)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  c_src constant text := 'rpc:sh_end_target_override';
  a jsonb;
  v_tenant uuid;
  v_own text;
  m public.machine;
  p public.product;
  s public.shift;
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
  v_own := app._sh_owned('shift', p_shift_id, v_tenant);
  if v_own <> 'ok' then return app._pm_deny(a, v_own, 'shift', p_shift_id, c_src); end if;

  if p_effective_from is null then perform app._pm_fail('validation', 'Choose an end date', 'effective_from'); end if;
  if p_effective_from < app.plant_date(v_tenant) then
    perform app._pm_fail('validation', 'Targets can''t end in the past', 'effective_from');
  end if;
  -- Ending works for retired machines, products and shifts too: that is how their overrides get cleaned up.
  select * into s from public.shift x where x.id = p_shift_id;
  if s.retired_at is null and now() >= lower(app.shift_window(p_shift_id, p_effective_from)) then
    perform app._pm_fail('guard', 'This shift has already started — use Cover for this shift', 'occurrence_started');
  end if;
  v_before := app.override_for(p_machine_id, p_product_id, p_shift_id, p_effective_from);
  select coalesce(array_agg(f.d order by f.d), '{}') into v_cancel
    from (select distinct t.effective_from as d
            from public.target_override_version t
           where t.machine_id = p_machine_id and t.product_id = p_product_id and t.shift_id = p_shift_id and t.effective_from > p_effective_from
             and app.override_for(p_machine_id, p_product_id, p_shift_id, t.effective_from) is not null) f;
  if v_before is null and cardinality(v_cancel) = 0 then
    perform app._pm_fail('guard', 'There is no shift target to end on that date', 'no_override');
  end if;
  select * into m from public.machine x where x.id = p_machine_id;
  select * into p from public.product x where x.id = p_product_id;
  select * into s from public.shift x where x.id = p_shift_id;

  insert into public.target_override_version (tenant_id, machine_id, product_id, shift_id, effective_from, pieces_per_shift, recorded_by, request_id)
  values (v_tenant, p_machine_id, p_product_id, p_shift_id, p_effective_from, null, (a->>'actor')::uuid, p_request_id)
  returning id into v_id;
  foreach v_d in array v_cancel loop
    insert into public.target_override_version (tenant_id, machine_id, product_id, shift_id, effective_from, pieces_per_shift, recorded_by, request_id)
    values (v_tenant, p_machine_id, p_product_id, p_shift_id, v_d, null, (a->>'actor')::uuid, p_request_id);
  end loop;
  perform app._pm_audit(a, 'target_override.ended', 'target_override_version', v_id,
    jsonb_build_object('pieces_per_shift', v_before),
    jsonb_build_object('machine_code', m.code, 'product_code', p.code, 'shift', s.name, 'pieces_per_shift', null, 'effective_from', p_effective_from,
                       'cancelled_dates', to_jsonb(v_cancel)),
    p_request_id, c_src);
  return jsonb_build_object('ok', true, 'id', v_id, 'cancelled', to_jsonb(v_cancel));
end
$$;

-- 10. Reads (D10) -------------------------------------------------------------------------------------------------
-- Read RPCs return jsonb like the write RPCs: {ok:true, ...} or the generic denial {ok:false, code:'not_allowed'} (audited as access.denied).
-- No per-tenant lock (reads don't serialise writers) and no request id (not a recorded request).
create function app._sh_read_authorise(p_source text, p_ua_only boolean)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := auth.uid();
  a record;
  v_reason text;
begin
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
  elsif p_ua_only and a.role <> 'unit_admin' then
    v_reason := 'role';
  end if;
  if v_reason is not null then
    perform app.audit_denied(v_actor, a.tenant_id, a.role::text, v_reason, null, null, p_source);
    return jsonb_build_object('ok', false, 'code', 'not_allowed');
  end if;
  return jsonb_build_object('ok', true, 'tenant_id', a.tenant_id, 'actor', v_actor, 'role', a.role);
end
$$;

-- AC-9: every non-retired machine of the tenant with its owner on a shift occurrence, where the owner comes from (plan | cover | none, cover
-- reason) and whether the owner is no longer an active supervisor. Unit Admin only.
-- R2: without a date the board shows the current occurrence of the shift, else its next one. R5: plan_owner_* is the owner by the plan alone
-- on plan_date = the first occurrence that has not started and is not before the board date (where an assignment made now would start),
-- and later_dates lists the plan changes already scheduled after it (a new assignment supersedes them).
create function public.shift_board(p_shift_id uuid, p_date date default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  c_src constant text := 'rpc:shift_board';
  a jsonb;
  v_tenant uuid;
  v_own text;
  v_date date;
  v_plant date;
  v_plan_date date;
  v_shift public.shift;
  v_window tstzrange;
  v_machines jsonb;
begin
  -- Callers without a membership (a Super Admin, a stranger) are denied and audited by the shared helper, so that rule lives in one place (022).
  if not exists (select 1 from public.membership m where m.user_id = auth.uid()) then
    return app._pm_authorise(null, c_src);
  end if;
  a := app._sh_read_authorise(c_src, true);
  if not (a->>'ok')::boolean then return a; end if;
  v_tenant := (a->>'tenant_id')::uuid;
  v_own := app._sh_owned('shift', p_shift_id, v_tenant);
  if v_own <> 'ok' then return app._pm_deny(a, v_own, 'shift', p_shift_id, c_src); end if;

  v_plant := app.plant_date(v_tenant);
  if p_date is null then
    select d.d into v_date
      from unnest(array[v_plant - 1, v_plant, v_plant + 1]) as d(d)
      where upper(app.shift_window(p_shift_id, d.d)) > now()
      order by d.d limit 1;
  else
    v_date := p_date;
  end if;
  select d.d into v_plan_date
    from unnest(array[v_plant, v_plant + 1]) as d(d)
    where lower(app.shift_window(p_shift_id, d.d)) > now()
    order by d.d limit 1;
  v_plan_date := greatest(v_date, v_plan_date);
  select * into v_shift from public.shift s where s.id = p_shift_id;
  v_window := app.shift_window(p_shift_id, v_date);

  select coalesce(jsonb_agg(jsonb_build_object(
           'machine_id', m.id, 'code', m.code, 'name', m.name, 'line', l.name, 'status', m.status,
           'owner_id', o.supervisor_id, 'owner_name', mem.full_name,
           'owner_inactive', (o.supervisor_id is not null and (mem.user_id is null or mem.status <> 'active' or mem.role <> 'supervisor')),
           'source', o.source, 'reason', o.reason,
           'plan_owner_id', po.supervisor_id, 'plan_owner_name', pm.full_name,
           'later_dates', (select coalesce(jsonb_agg(distinct v.effective_from order by v.effective_from), '[]'::jsonb)
                             from public.assignment_version v
                            where v.shift_id = p_shift_id and v.machine_id = m.id and v.effective_from > v_plan_date)) order by m.code), '[]'::jsonb)
    into v_machines
    from public.machine m
    left join public.line l on l.id = m.line_id
    cross join lateral app.machine_owner_src(m.id, p_shift_id, v_date) o
    left join public.membership mem on mem.user_id = o.supervisor_id and mem.tenant_id = v_tenant
    cross join lateral (select app._sh_plan_owner(p_shift_id, m.id, v_plan_date) as supervisor_id) po
    left join public.membership pm on pm.user_id = po.supervisor_id and pm.tenant_id = v_tenant
    where m.tenant_id = v_tenant and m.retired_at is null;

  return jsonb_build_object(
    'ok', true,
    'shift', jsonb_build_object('id', v_shift.id, 'name', v_shift.name, 'start_time', to_char(v_shift.start_time, 'HH24:MI'),
                                'end_time', to_char(v_shift.end_time, 'HH24:MI'), 'retired', v_shift.retired_at is not null),
    'shift_date', v_date, 'plan_date', v_plan_date, 'starts_at', lower(v_window), 'ends_at', upper(v_window),
    'machines', v_machines,
    'unassigned_count', (select count(*) from jsonb_array_elements(v_machines) e where e->>'owner_id' is null));
end
$$;

-- AC-10/11: the caller's own machines. R3: every running occurrence in which the caller owns at least one machine; when none is running, the
-- next occurrence starting within 36 hours in which they do. A supervisor sees planning data only through this function.
-- state: running | next | none (shifts exist, nothing assigned) | no_shifts; occurrences: [{shift, shift_date, starts_at, ends_at, machines}].
-- p_at exists so tests can pass an explicit moment; it only moves the clock for the caller's own machines.
-- One set-based query (R8-9): candidate occurrences x machines with the owner resolved inline by the same rule as app.machine_owner_src
-- (latest cover of the occurrence, else the plan version in force); the pgTAP file 033 pins the two to the same answers.
create function public.my_shift(p_at timestamptz default now())
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  c_src constant text := 'rpc:my_shift';
  a jsonb;
  v_tenant uuid;
  v_uid uuid;
  v_plant date;
  v_occ jsonb;
  v_running boolean;
begin
  -- Callers without a membership (a Super Admin, a stranger) are denied and audited by the shared helper, so that rule lives in one place (022).
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
    select s.id as shift_id, s.name, s.start_time, s.end_time, d.d as shift_date, app.shift_window(s.id, d.d) as w
      from public.shift s
      cross join lateral unnest(array[v_plant - 1, v_plant, v_plant + 1, v_plant + 2]) as d(d)
     where s.tenant_id = v_tenant and s.retired_at is null
  ), win as (
    select c.* from cand c where upper(c.w) > p_at and lower(c.w) <= p_at + interval '36 hours'
  ), mine as (
    select w.shift_id, w.name, w.start_time, w.end_time, w.shift_date, w.w, (w.w @> p_at) as running, m.id as machine_id, m.code, m.name as machine_name, l.name as line
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
  ), occ as (
    select mi.shift_id, mi.name, mi.start_time, mi.end_time, mi.shift_date, mi.w, mi.running,
           jsonb_agg(jsonb_build_object('machine_id', mi.machine_id, 'code', mi.code, 'name', mi.machine_name, 'line', mi.line) order by mi.code) as machines
      from mine mi group by mi.shift_id, mi.name, mi.start_time, mi.end_time, mi.shift_date, mi.w, mi.running
  ), first_next as (
    select o.shift_id, o.shift_date from occ o where not exists (select 1 from occ r where r.running) order by lower(o.w), o.name limit 1
  ), pick as (
    select o.* from occ o where o.running or exists (select 1 from first_next f where f.shift_id = o.shift_id and f.shift_date = o.shift_date)
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'shift', jsonb_build_object('id', p.shift_id, 'name', p.name, 'start_time', to_char(p.start_time, 'HH24:MI'), 'end_time', to_char(p.end_time, 'HH24:MI')),
           'shift_date', p.shift_date, 'starts_at', lower(p.w), 'ends_at', upper(p.w), 'running', p.running, 'machines', p.machines)
           order by lower(p.w), p.name), '[]'::jsonb),
         coalesce(bool_or(p.running), false)
    into v_occ, v_running
    from pick p;

  return jsonb_build_object('ok', true,
    'state', case when jsonb_array_length(v_occ) = 0 then 'none' when v_running then 'running' else 'next' end,
    'occurrences', v_occ);
end
$$;

-- R6: the site timezone is also locked once any shift data exists (shift times, plan dates, covers and overrides are all read in that zone).
-- pm_save_site (04) keeps its single copy; patch its lock condition in place, the way 03 patches its zone checks. The message stays 04's.
do $$
declare
  def text;
  old_block constant text := 'exists (select 1 from public.target_version t where t.tenant_id = v_tenant)';
  new_block constant text := '(exists (select 1 from public.target_version t where t.tenant_id = v_tenant)'
    || ' or exists (select 1 from public.shift t where t.tenant_id = v_tenant)'
    || ' or exists (select 1 from public.assignment_version t where t.tenant_id = v_tenant)'
    || ' or exists (select 1 from public.assignment_cover t where t.tenant_id = v_tenant)'
    || ' or exists (select 1 from public.target_override_version t where t.tenant_id = v_tenant))';
begin
  select pg_get_functiondef(p.oid) into def
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname = 'pm_save_site';
  if position(old_block in def) = 0 then
    raise exception 'expected timezone lock condition not found in public.pm_save_site';
  end if;
  execute replace(def, old_block, new_block);
end $$;

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
