-- Local/ephemeral databases ONLY (supabase start / db reset). Never applied to hosted projects:
-- hosted dev fixtures come from scripts/fixtures-reset.ts. All addresses use the reserved .test domain.
-- The password below is a non-secret local value (E2E_FIXTURE_PASSWORD in PR CI uses the same literal).
do $$
declare
  pw text := extensions.crypt('local-e2e-Passw0rd!', extensions.gen_salt('bf'));
  u record;
begin
  insert into public.tenant (id, name, status) values
    ('20000000-0000-4000-a000-00000000000a', 'e2e org A', 'active'),
    ('20000000-0000-4000-a000-00000000000b', 'e2e org B', 'active'),
    ('20000000-0000-4000-a000-00000000000d', 'e2e org S', 'suspended');

  for u in
    select * from (values
      ('30000000-0000-4000-a000-0000000000a1'::uuid, 'e2e-admin-a@example.test'),
      ('30000000-0000-4000-a000-0000000000a2'::uuid, 'e2e-sup-a@example.test'),
      ('30000000-0000-4000-a000-0000000000b2'::uuid, 'e2e-sup-b@example.test'),
      ('30000000-0000-4000-a000-0000000000c1'::uuid, 'e2e-nomember@example.test'),
      ('30000000-0000-4000-a000-0000000000d2'::uuid, 'e2e-suspended-s@example.test')
    ) as t(id, email)
  loop
    insert into auth.users (
      instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
      raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
      confirmation_token, recovery_token, email_change_token_new, email_change
    ) values (
      '00000000-0000-0000-0000-000000000000', u.id, 'authenticated', 'authenticated', u.email, pw, now(),
      '{"provider":"email","providers":["email"]}', '{}', now(), now(), '', '', '', ''
    );
    insert into auth.identities (id, user_id, provider_id, identity_data, provider, last_sign_in_at, created_at, updated_at)
    values (gen_random_uuid(), u.id, u.id::text,
            jsonb_build_object('sub', u.id::text, 'email', u.email, 'email_verified', true),
            'email', now(), now(), now());
  end loop;

  -- Profile columns added in 02 (step 2). Phones are in the canonical fixture block +91 90000 00001-00099;
  -- sign-in is still by email until step 5/6 switch fixtures to phone identities.
  insert into public.membership (tenant_id, user_id, role, full_name, employee_id, phone_e164, must_change_password) values
    ('20000000-0000-4000-a000-00000000000a', '30000000-0000-4000-a000-0000000000a1', 'unit_admin', 'Fixture Admin A', 'FX-A1', '+919000000001', false),
    ('20000000-0000-4000-a000-00000000000a', '30000000-0000-4000-a000-0000000000a2', 'supervisor', 'Fixture Supervisor A', 'FX-A2', '+919000000002', false),
    ('20000000-0000-4000-a000-00000000000b', '30000000-0000-4000-a000-0000000000b2', 'supervisor', 'Fixture Supervisor B', 'FX-B2', '+919000000003', false),
    ('20000000-0000-4000-a000-00000000000d', '30000000-0000-4000-a000-0000000000d2', 'supervisor', 'Fixture Suspended S', 'FX-S2', '+919000000004', false);
end $$;
