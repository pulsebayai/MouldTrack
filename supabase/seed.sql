-- Local/ephemeral databases ONLY (supabase start / db reset). Never applied to hosted projects:
-- hosted dev fixtures come from scripts/fixtures-reset.ts. All Auth addresses use the reserved .invalid domain (phone identities).
-- The password below is a non-secret local value (E2E_FIXTURE_PASSWORD in PR CI uses the same literal).
do $$
declare
  pw text := extensions.crypt('local-e2e-Passw0rd!', extensions.gen_salt('bf'));
  u record;
begin
  insert into public.tenant (id, name, status) values
    ('20000000-0000-4000-a000-00000000000a', 'e2e org A', 'active'),
    ('20000000-0000-4000-a000-00000000000b', 'e2e org B', 'active'),
    ('20000000-0000-4000-a000-00000000000d', 'e2e org S', 'suspended'),
    ('20000000-0000-4000-a000-00000000000e', 'e2e org U', 'active');

  -- Phone identities (02, D2/D3): Auth address = <10 digits>@phone.mouldtrack.invalid, phones in the canonical block
  -- +91 90000 00001-00099. Must match scripts/fixtures-reset.ts (a Jest test checks this file against it).
  for u in
    select * from (values
      ('30000000-0000-4000-a000-0000000000a1'::uuid, '9000000001'),
      ('30000000-0000-4000-a000-0000000000a2'::uuid, '9000000002'),
      ('30000000-0000-4000-a000-0000000000b2'::uuid, '9000000003'),
      ('30000000-0000-4000-a000-0000000000d2'::uuid, '9000000004'),
      ('30000000-0000-4000-a000-0000000000c1'::uuid, '9000000005'),
      ('30000000-0000-4000-a000-0000000000e1'::uuid, '9000000006'),
      ('30000000-0000-4000-a000-0000000000e2'::uuid, '9000000007'),
      ('30000000-0000-4000-a000-0000000000e3'::uuid, '9000000008'),
      ('30000000-0000-4000-a000-0000000000e4'::uuid, '9000000009'),
      -- 03: fixture Platform Super Admins (+91 90000 00098-99)
      ('30000000-0000-4000-a000-0000000000f0'::uuid, '9000000098'),
      ('30000000-0000-4000-a000-0000000000f1'::uuid, '9000000099')
    ) as t(id, digits)
  loop
    insert into auth.users (
      instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
      raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
      confirmation_token, recovery_token, email_change_token_new, email_change
    ) values (
      '00000000-0000-0000-0000-000000000000', u.id, 'authenticated', 'authenticated',
      u.digits || '@phone.mouldtrack.invalid', pw, now(),
      '{"provider":"email","providers":["email"]}', '{}', now(), now(), '', '', '', ''
    );
    insert into auth.identities (id, user_id, provider_id, identity_data, provider, last_sign_in_at, created_at, updated_at)
    values (gen_random_uuid(), u.id, u.id::text,
            jsonb_build_object('sub', u.id::text, 'email', u.digits || '@phone.mouldtrack.invalid', 'email_verified', true),
            'email', now(), now(), now());
  end loop;

  insert into public.membership (tenant_id, user_id, role, full_name, employee_id, phone_e164, must_change_password, temp_password_expires_at) values
    ('20000000-0000-4000-a000-00000000000a', '30000000-0000-4000-a000-0000000000a1', 'unit_admin', 'Fixture Admin A', 'FX-A1', '+919000000001', false, null),
    ('20000000-0000-4000-a000-00000000000a', '30000000-0000-4000-a000-0000000000a2', 'supervisor', 'Fixture Supervisor A', 'FX-A2', '+919000000002', false, null),
    ('20000000-0000-4000-a000-00000000000b', '30000000-0000-4000-a000-0000000000b2', 'supervisor', 'Fixture Supervisor B', 'FX-B2', '+919000000003', false, null),
    ('20000000-0000-4000-a000-00000000000d', '30000000-0000-4000-a000-0000000000d2', 'supervisor', 'Fixture Suspended S', 'FX-S2', '+919000000004', false, null),
    ('20000000-0000-4000-a000-00000000000e', '30000000-0000-4000-a000-0000000000e1', 'unit_admin', 'Fixture Admin U1', 'FX-U1', '+919000000006', false, null),
    ('20000000-0000-4000-a000-00000000000e', '30000000-0000-4000-a000-0000000000e2', 'unit_admin', 'Fixture Admin U2', 'FX-U2', '+919000000007', false, null),
    ('20000000-0000-4000-a000-00000000000e', '30000000-0000-4000-a000-0000000000e3', 'supervisor', 'Fixture Supervisor U3', 'FX-U3', '+919000000008', false, null),
    ('20000000-0000-4000-a000-00000000000e', '30000000-0000-4000-a000-0000000000e4', 'supervisor', 'Fixture Fresh U4', 'FX-U4', '+919000000009', true, now() + interval '30 days');

  -- 03: Super Admins are not tenant members; they live in platform_admin. Plan labels on fixture tenants.
  insert into public.platform_admin (user_id, full_name, phone_e164, must_change_password, temp_password_expires_at) values
    ('30000000-0000-4000-a000-0000000000f0', 'Fixture Super Admin 1', '+919000000098', false, null),
    ('30000000-0000-4000-a000-0000000000f1', 'Fixture Super Admin 2', '+919000000099', false, null);
  update public.tenant set plan_label = 'active' where name in ('e2e org A', 'e2e org U');
end $$;

-- 04-plant-masters (D8): fixture plant. Must match PLANT in scripts/fixtures-reset.ts (a Jest test checks this file against it).
-- Org U is mutated by e2e; A and B hold one machine and one product for read-only isolation checks.
insert into public.site (id, tenant_id, name, timezone) values
  ('41000000-0000-4000-a000-00000000000a', '20000000-0000-4000-a000-00000000000a', 'Fixture Plant A', 'Asia/Kolkata'),
  ('41000000-0000-4000-a000-00000000000b', '20000000-0000-4000-a000-00000000000b', 'Fixture Plant B', 'Asia/Kolkata'),
  ('41000000-0000-4000-a000-00000000000e', '20000000-0000-4000-a000-00000000000e', 'Fixture Plant U', 'Asia/Kolkata');
insert into public.line (id, tenant_id, site_id, name) values
  ('42000000-0000-4000-a000-0000000000e1', '20000000-0000-4000-a000-00000000000e', '41000000-0000-4000-a000-00000000000e', 'Fixture Line 1'),
  ('42000000-0000-4000-a000-0000000000e2', '20000000-0000-4000-a000-00000000000e', '41000000-0000-4000-a000-00000000000e', 'Fixture Line 2');
insert into public.machine (id, tenant_id, site_id, line_id, code, name) values
  ('43000000-0000-4000-a000-0000000000a1', '20000000-0000-4000-a000-00000000000a', '41000000-0000-4000-a000-00000000000a', null, 'FX-MA1', 'Fixture Machine A1'),
  ('43000000-0000-4000-a000-0000000000b1', '20000000-0000-4000-a000-00000000000b', '41000000-0000-4000-a000-00000000000b', null, 'FX-MB1', 'Fixture Machine B1'),
  ('43000000-0000-4000-a000-0000000000e1', '20000000-0000-4000-a000-00000000000e', '41000000-0000-4000-a000-00000000000e', '42000000-0000-4000-a000-0000000000e1', 'FX-MU1', 'Fixture Machine U1'),
  ('43000000-0000-4000-a000-0000000000e2', '20000000-0000-4000-a000-00000000000e', '41000000-0000-4000-a000-00000000000e', '42000000-0000-4000-a000-0000000000e2', 'FX-MU2', 'Fixture Machine U2'),
  ('43000000-0000-4000-a000-0000000000e3', '20000000-0000-4000-a000-00000000000e', '41000000-0000-4000-a000-00000000000e', null, 'FX-MU3', 'Fixture Machine U3');
insert into public.product (id, tenant_id, code, description) values
  ('44000000-0000-4000-a000-0000000000a1', '20000000-0000-4000-a000-00000000000a', 'FX-PA1', 'Fixture Product A1'),
  ('44000000-0000-4000-a000-0000000000b1', '20000000-0000-4000-a000-00000000000b', 'FX-PB1', 'Fixture Product B1'),
  ('44000000-0000-4000-a000-0000000000e1', '20000000-0000-4000-a000-00000000000e', 'FX-PU1', 'Fixture Product U1'),
  ('44000000-0000-4000-a000-0000000000e2', '20000000-0000-4000-a000-00000000000e', 'FX-PU2', 'Fixture Product U2'),
  ('44000000-0000-4000-a000-0000000000e3', '20000000-0000-4000-a000-00000000000e', 'FX-PU3', 'Fixture Product U3');
-- FX-MU3 deliberately has no target ("No target set").
insert into public.target_version (tenant_id, machine_id, product_id, effective_from, pieces_per_shift, recorded_by) values
  ('20000000-0000-4000-a000-00000000000a', '43000000-0000-4000-a000-0000000000a1', '44000000-0000-4000-a000-0000000000a1', date '2026-01-01', 1000, '30000000-0000-4000-a000-0000000000a1'),
  ('20000000-0000-4000-a000-00000000000b', '43000000-0000-4000-a000-0000000000b1', '44000000-0000-4000-a000-0000000000b1', date '2026-01-01', 500, '30000000-0000-4000-a000-0000000000b2'),
  ('20000000-0000-4000-a000-00000000000e', '43000000-0000-4000-a000-0000000000e1', '44000000-0000-4000-a000-0000000000e1', date '2026-01-01', 1200, '30000000-0000-4000-a000-0000000000e1'),
  ('20000000-0000-4000-a000-00000000000e', '43000000-0000-4000-a000-0000000000e2', '44000000-0000-4000-a000-0000000000e2', date '2026-01-01', 800, '30000000-0000-4000-a000-0000000000e1');

-- 05-shifts-and-assignments (D12): fixture shifts and recurring plan. Must match SHIFTS in scripts/fixtures-reset.ts (a Jest test checks this file against it).
-- Org A: two shifts that together cover all 24 hours, so supervisor A always has a running occurrence. Org U: Morning and Night, supervisor U3 owns two machines on both.
insert into public.shift (id, tenant_id, site_id, name, start_time, end_time) values
  ('54000000-0000-4000-a000-0000000000a1', '20000000-0000-4000-a000-00000000000a', '41000000-0000-4000-a000-00000000000a', 'Fixture Shift A1', '00:00', '12:00'),
  ('54000000-0000-4000-a000-0000000000a2', '20000000-0000-4000-a000-00000000000a', '41000000-0000-4000-a000-00000000000a', 'Fixture Shift A2', '12:00', '00:00'),
  ('54000000-0000-4000-a000-0000000000e1', '20000000-0000-4000-a000-00000000000e', '41000000-0000-4000-a000-00000000000e', 'Fixture Morning', '06:00', '14:00'),
  ('54000000-0000-4000-a000-0000000000e2', '20000000-0000-4000-a000-00000000000e', '41000000-0000-4000-a000-00000000000e', 'Fixture Night', '22:00', '06:00');
insert into public.assignment_version (tenant_id, shift_id, machine_id, supervisor_id, effective_from, recorded_by) values
  ('20000000-0000-4000-a000-00000000000a', '54000000-0000-4000-a000-0000000000a1', '43000000-0000-4000-a000-0000000000a1', '30000000-0000-4000-a000-0000000000a2', date '2026-01-01', '30000000-0000-4000-a000-0000000000a1'),
  ('20000000-0000-4000-a000-00000000000a', '54000000-0000-4000-a000-0000000000a2', '43000000-0000-4000-a000-0000000000a1', '30000000-0000-4000-a000-0000000000a2', date '2026-01-01', '30000000-0000-4000-a000-0000000000a1'),
  ('20000000-0000-4000-a000-00000000000e', '54000000-0000-4000-a000-0000000000e1', '43000000-0000-4000-a000-0000000000e1', '30000000-0000-4000-a000-0000000000e3', date '2026-01-01', '30000000-0000-4000-a000-0000000000e1'),
  ('20000000-0000-4000-a000-00000000000e', '54000000-0000-4000-a000-0000000000e1', '43000000-0000-4000-a000-0000000000e2', '30000000-0000-4000-a000-0000000000e3', date '2026-01-01', '30000000-0000-4000-a000-0000000000e1'),
  ('20000000-0000-4000-a000-00000000000e', '54000000-0000-4000-a000-0000000000e2', '43000000-0000-4000-a000-0000000000e1', '30000000-0000-4000-a000-0000000000e3', date '2026-01-01', '30000000-0000-4000-a000-0000000000e1'),
  ('20000000-0000-4000-a000-00000000000e', '54000000-0000-4000-a000-0000000000e2', '43000000-0000-4000-a000-0000000000e2', '30000000-0000-4000-a000-0000000000e3', date '2026-01-01', '30000000-0000-4000-a000-0000000000e1');

-- 07-issue-lifecycle (D12): fixture issues. Must match ISSUES in scripts/fixtures-reset.ts (a Jest test checks this file against it).
-- Org U: a stopped-machine Critical, a High awaiting verification on the never-assigned FX-MU3, a closed Low. Org A: one open issue for supervisor A.
-- Read-only for e2e. Starter categories already exist (the tenant trigger seeded them).
do $$
declare
  f record;
  v_by uuid;
  v_cat uuid;
begin
  for f in
    select * from (values
      ('60000000-0000-4000-a000-0000000000e1'::uuid, '20000000-0000-4000-a000-00000000000e'::uuid, '43000000-0000-4000-a000-0000000000e1'::uuid, 'critical', 'open', true,
       '30000000-0000-4000-a000-0000000000e3'::uuid, 'Fixture issue: hydraulic pump failed, machine stopped', timestamptz '2026-01-02T08:00:00Z', null::timestamptz, null::text),
      ('60000000-0000-4000-a000-0000000000e2', '20000000-0000-4000-a000-00000000000e', '43000000-0000-4000-a000-0000000000e3', 'high', 'resolved', false,
       '30000000-0000-4000-a000-0000000000e3', 'Fixture issue: mould cooling line leaking', timestamptz '2026-01-02T08:30:00Z', timestamptz '2026-01-02T10:00:00Z', 'Fixture resolution: line re-sealed'),
      ('60000000-0000-4000-a000-0000000000e3', '20000000-0000-4000-a000-00000000000e', '43000000-0000-4000-a000-0000000000e2', 'low', 'closed', false,
       '30000000-0000-4000-a000-0000000000e3', 'Fixture issue: guard door sticks', timestamptz '2026-01-02T09:00:00Z', timestamptz '2026-01-02T11:00:00Z', 'Fixture resolution: hinge oiled'),
      ('60000000-0000-4000-a000-0000000000a1', '20000000-0000-4000-a000-00000000000a', '43000000-0000-4000-a000-0000000000a1', 'medium', 'open', false,
       '30000000-0000-4000-a000-0000000000a2', 'Fixture issue: oil mist near the nozzle', timestamptz '2026-01-02T08:00:00Z', null, null)
    ) as t(id, tenant_id, machine_id, priority, status, stopped, uid, description, reported_at, resolved_at, resolution)
  loop
    select c.id into v_cat from public.issue_category c where c.tenant_id = f.tenant_id and c.name = 'Mechanical';
    insert into public.machine_issue (id, tenant_id, machine_id, category_id, priority, description, machine_stopped, status, accountable_owner_id, reported_by, reported_at,
                                      resolved_by, resolved_at, resolution_notes, closed_at, closed_by)
    values (f.id, f.tenant_id, f.machine_id, v_cat, f.priority, f.description, f.stopped, f.status, f.uid, f.uid, f.reported_at,
            case when f.resolved_at is not null then f.uid end, f.resolved_at, f.resolution,
            case when f.status = 'closed' then f.resolved_at end, case when f.status = 'closed' then f.uid end);
    insert into public.issue_action (tenant_id, issue_id, actor_id, actor_role, type, status_after, at) values (f.tenant_id, f.id, f.uid, 'supervisor', 'report', 'open', f.reported_at);
    if f.resolved_at is not null then
      insert into public.issue_action (tenant_id, issue_id, actor_id, actor_role, type, notes, status_before, status_after, at)
      values (f.tenant_id, f.id, f.uid, 'supervisor', 'resolve', f.resolution, 'open', f.status, f.resolved_at);
    end if;
    insert into public.issue_ownership_history (tenant_id, issue_id, new_owner, source, actor_id, at) values (f.tenant_id, f.id, f.uid, 'report', f.uid, f.reported_at);
  end loop;
end $$;
