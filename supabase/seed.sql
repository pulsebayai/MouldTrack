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
      ('30000000-0000-4000-a000-0000000000e4'::uuid, '9000000009')
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
end $$;
