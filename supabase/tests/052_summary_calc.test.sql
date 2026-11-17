-- 06 AC-9, AC-10, D7: the production summary calculation (calc_version 1). Normal, zero movement, rollover with a maximum, closing below opening without
-- a maximum, shots x cavities (change effective on its date), no target, shift override target (05), correction of the opening then the closing,
-- good + reject above the movement (Over-reported), pieces counters ignoring cavities, the input snapshot and versioning, and the exact numbers the
-- fixture readings (D11) rely on. Readings are inserted as the table owner and app._rd_compute_summary is called as the tenant's Unit Admin, so the
-- calculation is driven on fixed past dates (no clock involved). Self-contained; rolled back.
begin;
create extension if not exists pgtap with schema extensions;
select plan(60);

create temp table ids (k text primary key, v uuid);
create temp table sums (k text primary key, r jsonb);
create function pg_temp.id(k text) returns uuid language sql as $$ select v from ids where k = $1 $$;
create function pg_temp.as_user(k text) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', (select v from ids where ids.k = $1), 'role', 'authenticated')::text, true) $$;
-- Inserts an opening + a closing for a machine on a shift date and calculates; remembers the summary row under `label`.
create function pg_temp.run(label text, mach text, dd date, oc bigint, cc bigint, good int, reject int, prod text default 'p1', olate boolean default false, clate boolean default false, ua boolean default false)
returns jsonb language plpgsql as $$
declare
  o uuid := gen_random_uuid();
  c uuid := gen_random_uuid();
  sid uuid;
  r jsonb;
begin
  insert into public.production_reading (id, tenant_id, machine_id, shift_id, shift_date, kind, product_id, counter_value, late, entered_by_ua, recorded_by)
  values (o, pg_temp.id('tx'), pg_temp.id(mach), pg_temp.id('day'), dd, 'opening', pg_temp.id(prod), oc, olate, false, pg_temp.id('uax'));
  insert into public.production_reading (id, tenant_id, machine_id, shift_id, shift_date, kind, counter_value, good, reject, late, entered_by_ua, recorded_by)
  values (c, pg_temp.id('tx'), pg_temp.id(mach), pg_temp.id('day'), dd, 'closing', cc, good, reject, clate, ua, pg_temp.id('uax'));
  insert into ids values ('o_' || label, o), ('c_' || label, c);
  sid := app._rd_compute_summary(pg_temp.id('tx'), pg_temp.id('uax'), pg_temp.id(mach), pg_temp.id('day'), dd, null);
  select to_jsonb(s) into r from public.production_summary s where s.id = sid;
  insert into sums values (label, r);
  return r;
end $$;
create function pg_temp.s(label text, f text) returns text language sql as $$ select r ->> f from sums where k = $1 $$;

-- Fixtures (as postgres) ---------------------------------------------------
insert into auth.users (id, email, aud, role) values ('00000000-0000-4000-c652-0000000000a1', 'tap52-uax@example.test', 'authenticated', 'authenticated');
insert into ids values ('uax', '00000000-0000-4000-c652-0000000000a1'), ('tx', '50000000-0000-4000-c652-00000000000a');
insert into public.tenant (id, name, status, timezone) values ('50000000-0000-4000-c652-00000000000a', 'tap52 org X', 'active', 'Asia/Kolkata');
insert into public.membership (tenant_id, user_id, role, status, full_name, employee_id, phone_e164, must_change_password) values
  ('50000000-0000-4000-c652-00000000000a', '00000000-0000-4000-c652-0000000000a1', 'unit_admin', 'active', 'UA X', 'UA-X', '+919000026201', false);
insert into public.site (id, tenant_id, name, timezone) values ('51000000-0000-4000-c652-00000000000a', pg_temp.id('tx'), 'Plant X', 'Asia/Kolkata');
insert into public.machine (id, tenant_id, site_id, code, name, counter_unit, counter_max) values
  ('53000000-0000-4000-c652-0000000000a1', pg_temp.id('tx'), '51000000-0000-4000-c652-00000000000a', 'MP', 'Pieces, no max', 'pieces', null),
  ('53000000-0000-4000-c652-0000000000a2', pg_temp.id('tx'), '51000000-0000-4000-c652-00000000000a', 'MR', 'Pieces, max 999999', 'pieces', 999999),
  ('53000000-0000-4000-c652-0000000000a3', pg_temp.id('tx'), '51000000-0000-4000-c652-00000000000a', 'MS', 'Shots, max 99999', 'shots', 99999),
  ('53000000-0000-4000-c652-0000000000a4', pg_temp.id('tx'), '51000000-0000-4000-c652-00000000000a', 'MN', 'No target', 'pieces', null);
insert into public.product (id, tenant_id, code, description) values
  ('54000000-0000-4000-c652-0000000000a1', pg_temp.id('tx'), 'P-1', 'Part 1'), ('54000000-0000-4000-c652-0000000000a2', pg_temp.id('tx'), 'P-2', 'Part 2');
insert into public.shift (id, tenant_id, site_id, name, start_time, end_time) values ('55000000-0000-4000-c652-0000000000a1', pg_temp.id('tx'), '51000000-0000-4000-c652-00000000000a', 'Day', '06:00', '14:00');
insert into ids values ('mp', '53000000-0000-4000-c652-0000000000a1'), ('mr', '53000000-0000-4000-c652-0000000000a2'), ('ms', '53000000-0000-4000-c652-0000000000a3'), ('mn', '53000000-0000-4000-c652-0000000000a4'),
  ('p1', '54000000-0000-4000-c652-0000000000a1'), ('p2', '54000000-0000-4000-c652-0000000000a2'), ('day', '55000000-0000-4000-c652-0000000000a1');
insert into public.target_version (tenant_id, machine_id, product_id, effective_from, pieces_per_shift, recorded_by) values
  (pg_temp.id('tx'), pg_temp.id('mp'), pg_temp.id('p1'), date '2026-01-01', 1000, pg_temp.id('uax')),
  (pg_temp.id('tx'), pg_temp.id('mr'), pg_temp.id('p1'), date '2026-01-01', 800, pg_temp.id('uax')),
  (pg_temp.id('tx'), pg_temp.id('ms'), pg_temp.id('p1'), date '2026-01-01', 1200, pg_temp.id('uax'));
-- 05's per-shift override: from 2026-03-05 the Day shift's target on MP is 900
insert into public.target_override_version (tenant_id, machine_id, product_id, shift_id, effective_from, pieces_per_shift, recorded_by) values
  (pg_temp.id('tx'), pg_temp.id('mp'), pg_temp.id('p1'), pg_temp.id('day'), date '2026-03-05', 900, pg_temp.id('uax'));
-- cavities: MS has 4 from 2026-01-01 and 2 from 2026-03-10; MP is a pieces machine with a (meaningless) setting that must be ignored
insert into public.cavity_version (tenant_id, machine_id, product_id, effective_from, cavities, recorded_by) values
  (pg_temp.id('tx'), pg_temp.id('ms'), pg_temp.id('p1'), date '2026-01-01', 4, pg_temp.id('uax')),
  (pg_temp.id('tx'), pg_temp.id('ms'), pg_temp.id('p1'), date '2026-03-10', 2, pg_temp.id('uax')),
  (pg_temp.id('tx'), pg_temp.id('mp'), pg_temp.id('p1'), date '2026-01-01', 8, pg_temp.id('uax'));
select pg_temp.as_user('uax');

-- 1. Normal ------------------------------------------------------------------------------------------------------------------------------------
select pg_temp.run('normal', 'mp', date '2026-03-02', 1000, 1250, 240, 5);
select is(pg_temp.s('normal', 'movement_units'), '250', 'normal: movement = closing - opening');
select is(pg_temp.s('normal', 'movement_pieces'), '250', 'pieces counter: movement pieces = movement');
select is(pg_temp.s('normal', 'unaccounted'), '5', 'unaccounted = movement pieces - good - reject');
select is(pg_temp.s('normal', 'target'), '1000', 'the target is 04''s effective target');
select is(pg_temp.s('normal', 'attainment_pct'), '24.00', 'attainment = good / target x 100 (240 / 1000)');
select is(pg_temp.s('normal', 'calc_version'), '1', 'calc_version is 1');
select is((select (r ->> 'rollover')::boolean or (r ->> 'needs_review')::boolean or (r ->> 'over_reported')::boolean from sums where k = 'normal'), false, 'no Rollover, Needs review or Over-reported flag');
select is(pg_temp.s('normal', 'cavities'), '1', 'a pieces counter ignores the cavity setting (8 on MP): the multiplier used is 1');

-- 2. Zero movement and over-reported ---------------------------------------------------------------------------------------------------------
select pg_temp.run('zero', 'mp', date '2026-03-03', 500, 500, 0, 0);
select is(pg_temp.s('zero', 'movement_units') || '/' || pg_temp.s('zero', 'unaccounted') || '/' || pg_temp.s('zero', 'attainment_pct'), '0/0/0.00', 'zero movement with nothing produced: movement 0, unaccounted 0, attainment 0');
select is(pg_temp.s('zero', 'over_reported'), 'false', 'and not over-reported');
select pg_temp.run('over', 'mp', date '2026-03-04', 500, 500, 10, 0);
select is(pg_temp.s('over', 'unaccounted'), '-10', 'good + reject above the movement gives a negative unaccounted');
select is(pg_temp.s('over', 'over_reported'), 'true', 'flagged Over-reported');
select is(pg_temp.s('over', 'target'), '1000', 'the target before the override date is the base target');

-- 3. Rollover with a maximum -----------------------------------------------------------------------------------------------------------------
select pg_temp.run('roll', 'mr', date '2026-03-02', 999900, 100, 150, 10);
select is(pg_temp.s('roll', 'movement_units'), '200', 'rollover: (maximum + 1 - opening) + closing');
select is(pg_temp.s('roll', 'rollover') || '/' || pg_temp.s('roll', 'needs_review'), 'true/false', 'flagged Rollover, not Needs review');
select is(pg_temp.s('roll', 'unaccounted') || '/' || pg_temp.s('roll', 'attainment_pct') || '/' || pg_temp.s('roll', 'counter_max'), '40/18.75/999999', 'unaccounted 40, attainment 150 / 800, and the maximum is in the snapshot');
select pg_temp.run('roll2', 'mr', date '2026-03-03', 1000000, 5, 1, 1);
select is(pg_temp.s('roll2', 'needs_review') || '/' || coalesce(pg_temp.s('roll2', 'movement_units'), 'null'), 'true/null', 'an opening above the maximum is not guessed: Needs review');
select pg_temp.run('roll3', 'mr', date '2026-03-04', 999999, 0, 1, 0);
select is(pg_temp.s('roll3', 'movement_units') || '/' || pg_temp.s('roll3', 'rollover'), '1/true', 'the counter at its maximum rolling to 0 is one unit');
select pg_temp.run('same', 'mr', date '2026-03-05', 100, 100, 0, 0);
select is(pg_temp.s('same', 'rollover') || '/' || pg_temp.s('same', 'movement_units'), 'false/0', 'equal readings are zero movement, never a rollover');

-- 4. Closing below opening without a maximum ---------------------------------------------------------------------------------------------------
select pg_temp.run('nomax', 'mp', date '2026-03-05', 800, 100, 50, 5);
select is(pg_temp.s('nomax', 'needs_review'), 'true', 'closing < opening without a maximum: flagged Needs review');
select is(coalesce(pg_temp.s('nomax', 'movement_units'), 'null') || '/' || coalesce(pg_temp.s('nomax', 'movement_pieces'), 'null') || '/' || coalesce(pg_temp.s('nomax', 'unaccounted'), 'null'), 'null/null/null', 'movement, pieces and unaccounted are null (never guessed)');
select is(pg_temp.s('nomax', 'rollover') || '/' || pg_temp.s('nomax', 'over_reported'), 'false/false', 'neither Rollover nor Over-reported');
select is(pg_temp.s('nomax', 'attainment_pct'), '5.56', 'attainment is still good / target (50 / 900, the override applies from 2026-03-05)');

-- 5. Shots x cavities -------------------------------------------------------------------------------------------------------------------------------------
select pg_temp.run('shots', 'ms', date '2026-03-02', 1000, 1250, 950, 30);
select is(pg_temp.s('shots', 'movement_units') || '/' || pg_temp.s('shots', 'cavities') || '/' || pg_temp.s('shots', 'movement_pieces'), '250/4/1000', 'shots: 250 shots x 4 cavities = 1000 pieces');
select is(pg_temp.s('shots', 'unaccounted') || '/' || pg_temp.s('shots', 'attainment_pct') || '/' || pg_temp.s('shots', 'counter_unit'), '20/79.17/shots', 'unaccounted 20, attainment 950 / 1200, unit shots');
select pg_temp.run('cav9', 'ms', date '2026-03-09', 1000, 1250, 400, 0);
select is(pg_temp.s('cav9', 'cavities'), '4', 'the day before the cavity change the old setting applies');
select pg_temp.run('cav10', 'ms', date '2026-03-10', 1000, 1250, 400, 0);
select is(pg_temp.s('cav10', 'cavities') || '/' || pg_temp.s('cav10', 'movement_pieces'), '2/500', 'on the effective date the new setting applies (250 x 2)');
select pg_temp.run('shroll', 'ms', date '2026-03-11', 99990, 20, 40, 0);
select is(pg_temp.s('shroll', 'movement_units') || '/' || pg_temp.s('shroll', 'movement_pieces') || '/' || pg_temp.s('shroll', 'rollover'), '30/60/true', 'a shots rollover: 30 shots x 2 cavities');
select pg_temp.run('nocav', 'ms', date '2025-12-31', 0, 10, 40, 0);
select is(pg_temp.s('nocav', 'cavities') || '/' || pg_temp.s('nocav', 'movement_pieces'), '1/10', 'before any cavity setting exists the default (1) applies');
select is(pg_temp.s('nocav', 'target'), null, 'and before the first target there is none');

-- 6. No target -----------------------------------------------------------------------------------------------------------------------------------------------
select pg_temp.run('notarget', 'mn', date '2026-03-02', 10, 60, 40, 5, 'p2');
select is(coalesce(pg_temp.s('notarget', 'target'), 'null') || '/' || coalesce(pg_temp.s('notarget', 'attainment_pct'), 'null'), 'null/null', 'no target: target and attainment are null ("No target set")');
select is(pg_temp.s('notarget', 'movement_units') || '/' || pg_temp.s('notarget', 'unaccounted'), '50/5', 'the movement is still calculated');

-- 7. Override target (05) ------------------------------------------------------------------------------------------------------------------------------------
select pg_temp.run('ovr', 'mp', date '2026-03-06', 0, 100, 90, 0);
select is(pg_temp.s('ovr', 'target') || '/' || pg_temp.s('ovr', 'attainment_pct'), '900/10.00', 'the shift override replaces the base target from its date (90 / 900)');
select is(app.effective_target(pg_temp.id('mp'), pg_temp.id('p1'), pg_temp.id('day'), date '2026-03-04'), 1000, 'and the base target applied before it');

-- 8. Corrections: the opening, then the closing ----------------------------------------------------------------------------------------------------------
select pg_temp.run('corr', 'mp', date '2026-03-07', 100, 400, 290, 5);
select is(pg_temp.s('corr', 'movement_units'), '300', 'correction case: first summary, movement 300');
insert into public.production_reading (id, tenant_id, machine_id, shift_id, shift_date, kind, product_id, counter_value, late, recorded_by, supersedes_id, correction_reason) values
  ('56000000-0000-4000-c652-0000000000a1', pg_temp.id('tx'), pg_temp.id('mp'), pg_temp.id('day'), date '2026-03-07', 'opening', pg_temp.id('p1'), 150, false, pg_temp.id('uax'), pg_temp.id('o_corr'), 'typo');
select is((select app._rd_compute_summary(pg_temp.id('tx'), pg_temp.id('uax'), pg_temp.id('mp'), pg_temp.id('day'), date '2026-03-07', null) is not null), true, 'a corrected opening produces a new summary');
select results_eq($$ select opening_counter, closing_counter, movement_units, opening_reading_id from public.production_summary where machine_id = pg_temp.id('mp') and shift_date = date '2026-03-07' order by recorded_at desc, id limit 1 $$,
  $$ values (150::bigint, 400::bigint, 250::bigint, '56000000-0000-4000-c652-0000000000a1'::uuid) $$, 'it uses the corrected opening (150) and the original closing');
insert into public.production_reading (id, tenant_id, machine_id, shift_id, shift_date, kind, counter_value, good, reject, late, recorded_by, supersedes_id, correction_reason) values
  ('56000000-0000-4000-c652-0000000000a2', pg_temp.id('tx'), pg_temp.id('mp'), pg_temp.id('day'), date '2026-03-07', 'closing', 380, 240, 4, false, pg_temp.id('uax'), pg_temp.id('c_corr'), 'recount');
select is((select app._rd_compute_summary(pg_temp.id('tx'), pg_temp.id('uax'), pg_temp.id('mp'), pg_temp.id('day'), date '2026-03-07', null) is not null), true, 'a corrected closing produces another');
select results_eq($$ select opening_counter, closing_counter, movement_units, good, reject, unaccounted from public.production_summary where machine_id = pg_temp.id('mp') and shift_date = date '2026-03-07' order by recorded_at desc, id limit 1 $$,
  $$ values (150::bigint, 380::bigint, 230::bigint, 240, 4, -14::bigint) $$, 'the latest summary uses both corrections (movement 230, unaccounted -14)');
select is((select count(*)::int from public.production_summary where machine_id = pg_temp.id('mp') and shift_date = date '2026-03-07'), 3, 'three summaries exist for the occurrence: history is never rewritten');
select results_eq($$ select opening_counter, closing_counter, movement_units from public.production_summary where machine_id = pg_temp.id('mp') and shift_date = date '2026-03-07' order by recorded_at, id limit 1 $$,
  $$ values (100::bigint, 400::bigint, 300::bigint) $$, 'the first summary still shows the original readings');
select is((select count(*)::int from public.production_summary where machine_id = pg_temp.id('mp') and shift_date = date '2026-03-07' and over_reported), 2, 'the two corrected summaries are Over-reported (295 > 250 after the opening fix, 244 > 230 after the closing fix); the original one is not');

-- 9. Nothing without a closing ---------------------------------------------------------------------------------------------------------------------------------
insert into public.production_reading (id, tenant_id, machine_id, shift_id, shift_date, kind, product_id, counter_value, late, recorded_by) values
  ('56000000-0000-4000-c652-0000000000a3', pg_temp.id('tx'), pg_temp.id('mn'), pg_temp.id('day'), date '2026-03-20', 'opening', pg_temp.id('p2'), 1, false, pg_temp.id('uax'));
select is(app._rd_compute_summary(pg_temp.id('tx'), pg_temp.id('uax'), pg_temp.id('mn'), pg_temp.id('day'), date '2026-03-20', null), null, 'an opening alone produces no summary');
select is(app._rd_compute_summary(pg_temp.id('tx'), pg_temp.id('uax'), pg_temp.id('mn'), pg_temp.id('day'), date '2026-03-21', null), null, 'and neither does an occurrence without readings');
select is((select count(*)::int from public.production_summary where machine_id = pg_temp.id('mn') and shift_date >= date '2026-03-20'), 0, 'nothing was appended');

-- 10. The input snapshot -----------------------------------------------------------------------------------------------------------------------------------------
select is((select (r ->> 'opening_reading_id')::uuid = pg_temp.id('o_roll') and (r ->> 'closing_reading_id')::uuid = pg_temp.id('c_roll') and (r ->> 'product_id')::uuid = pg_temp.id('p1') from sums where k = 'roll'), true,
  'the summary names the readings and the product it used');
select is(pg_temp.s('roll', 'opening_counter') || '/' || pg_temp.s('roll', 'closing_counter') || '/' || pg_temp.s('roll', 'good') || '/' || pg_temp.s('roll', 'reject'), '999900/100/150/10', 'and the counters and quantities');
update public.machine set counter_max = 500 where id = pg_temp.id('mr');
select pg_temp.run('roll4', 'mr', date '2026-03-12', 400, 10, 1, 0);
select is(pg_temp.s('roll4', 'counter_max') || '/' || pg_temp.s('roll4', 'movement_units'), '500/111', 'a changed maximum applies to later calculations (500 + 1 - 400 + 10)');
select is((select counter_max::text from public.production_summary where id = (pg_temp.s('roll', 'id'))::uuid), '999999', 'and earlier summaries keep the maximum they used');
select is(pg_temp.s('shots', 'cavities'), '4', 'cavity snapshots do not change when the setting later does (the 2026-03-02 row stays 4)');
select pg_temp.run('flags', 'mp', date '2026-03-13', 10, 20, 5, 0, 'p1', true, true, true);
select is(pg_temp.s('flags', 'late_opening') || '/' || pg_temp.s('flags', 'late_closing') || '/' || pg_temp.s('flags', 'entered_by_ua'), 'true/true/true', 'the Late and Entered-by-Unit-Admin flags of the readings are copied');
select is(pg_temp.s('normal', 'recorded_by'), pg_temp.id('uax')::text, 'the actor is recorded');

-- 11. Rounding and bounds ------------------------------------------------------------------------------------------------------------------------------------------
select pg_temp.run('round', 'ms', date '2026-03-14', 0, 1, 1, 0);
select pg_temp.run('big', 'mp', date '2026-03-15', 0, 1000000000000, 10000000, 10000000);
select is(pg_temp.s('big', 'movement_units') || '/' || pg_temp.s('big', 'unaccounted'), '1000000000000/999980000000', 'the largest counter and quantities calculate without overflow');
select is(pg_temp.s('round', 'attainment_pct'), '0.08', 'attainment rounds to two decimals (1 / 1200 = 0.0833)');

-- 12. Fixture numbers (D11) ----------------------------------------------------------------------------------------------------------------------------------------
-- seed.sql and scripts/fixtures-reset.ts insert these readings with these summary values; this pins that the calculation gives them.
select is(pg_temp.s('shots', 'movement_pieces') || '/' || pg_temp.s('shots', 'unaccounted') || '/' || pg_temp.s('shots', 'attainment_pct') || '/' || pg_temp.s('shots', 'target'), '1000/20/79.17/1200',
  'fixture FX-MU1 (shots, 4 cavities, opening 1000, closing 1250, good 950, reject 30, target 1200): 1000 pieces, unaccounted 20, 79.17 %');
select is(pg_temp.s('roll', 'movement_units') || '/' || pg_temp.s('roll', 'unaccounted') || '/' || pg_temp.s('roll', 'attainment_pct') || '/' || pg_temp.s('roll', 'target') || '/' || pg_temp.s('roll', 'rollover'), '200/40/18.75/800/true',
  'fixture FX-MU2 (pieces, maximum 999999, opening 999900, closing 100, good 150, reject 10, target 800): rollover, 200 units, unaccounted 40, 18.75 %');

-- Append-only and tenancy -------------------------------------------------------------------------------------------------------------------------------------------
select throws_ok($$ update public.production_summary set good = 0 $$, 'P0001', null, 'a summary cannot be changed');
select throws_ok($$ delete from public.production_summary $$, 'P0001', null, 'or removed');
select is((select count(distinct calc_version)::int from public.production_summary), 1, 'every summary so far has calc_version 1 (a later rule change adds 2, never rewrites)');
select is((select count(*)::int from public.production_summary s where s.tenant_id <> pg_temp.id('tx') and exists (select 1 from ids i where i.v = s.machine_id)), 0, 'summaries carry the tenant of their readings (scoped to this test''s machines: the seed adds fixture summaries of its own)');

select * from finish();
rollback;
