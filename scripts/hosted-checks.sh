#!/usr/bin/env bash
# Nightly hosted checks against DEV (02 step 10). Read-only. Writes test-results/hosted-checks.tap.
#   TARGET=dev (default): needs SUPABASE_ACCESS_TOKEN, DEV_SUPABASE_PROJECT_REF, SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, APP_ENV=development
#     1 Auth config (signup off, min length 10, letters+digits)  2 all four Edge Functions deployed (user-admin account platform platform-setup)
#     3 no orphan Auth users (D4)                                 4 CORS: dev web origin allowed, foreign origin never reflected (D8)
#     5 every membership's Auth email = its phone, inactive = banned, active = not banned (R7)
#     6 platform-setup refuses on dev (403 not_allowed: no usable token, no database access)  7 the configured token, if any, is not the local literal  8 dev has no PLATFORM_SETUP_TOKEN at all (03 step 9, D11)
#     9 Storage bucket `attachments` exists, is private, limited to 5 MB and to image/jpeg, image/png, image/webp (07, read-only)
#     10 (08, D1) every tenant other than the four fixture tenants A/B/S/U (demo, Console-registered, real) has handover_setting.required = true (read-only)
#   TARGET=staging: only check 1 (AC-15, R4), needs SUPABASE_ACCESS_TOKEN and STAGING_SUPABASE_PROJECT_REF. Read-only.
set -uo pipefail
TARGET="${TARGET:-dev}"
WEB_ORIGIN="${WEB_ORIGIN:-https://mouldtrack--dev.expo.app}"
FOREIGN_ORIGIN="https://evil.example"
OUT=test-results/hosted-checks.tap
mkdir -p test-results
fails=0; n=0
tap() { n=$((n+1)); if [ "$1" = 0 ]; then echo "ok $n - $2" >> "$OUT"; echo "PASS $2"; else echo "not ok $n - $2" >> "$OUT"; echo "FAIL $2"; fails=$((fails+1)); fi; }

if [ "$TARGET" = staging ]; then
  : "${STAGING_SUPABASE_PROJECT_REF:?}"
  printf 'TAP version 13\n1..1\n' > "$OUT"
  node scripts/auth-config.mjs --check --ref staging; tap $? "auth config on staging matches (signup off, min length 10, letters+digits)"
  exit $([ "$fails" = 0 ] && echo 0 || echo 1)
fi
[ "$TARGET" = dev ] || { echo "TARGET must be dev or staging"; exit 1; }
: "${DEV_SUPABASE_PROJECT_REF:?}"
printf 'TAP version 13\n1..10\n' > "$OUT"

node scripts/auth-config.mjs --check --ref dev; tap $? "auth config on dev matches (signup off, min length 10, letters+digits)"

fn="$(npx supabase functions list --project-ref "$DEV_SUPABASE_PROJECT_REF" 2>&1)"; echo "$fn" | sed -E 's#sbp_[A-Za-z0-9]+#<redacted>#g'
ok=0
for fnname in user-admin account platform platform-setup; do
  echo "$fn" | grep -qE "(^|[ |])${fnname}([ |]|\$)" || { echo "$fnname: not deployed"; ok=1; }
done
tap $ok "Edge Functions user-admin, account, platform and platform-setup are deployed"

npx tsx scripts/orphan-check.ts; tap $? "no Auth users without a membership (except nomember)"

ok=0
for fnname in user-admin account platform; do
  url="https://${DEV_SUPABASE_PROJECT_REF}.supabase.co/functions/v1/${fnname}"
  allowed="$(curl -s -i -X OPTIONS "$url" -H "Origin: $WEB_ORIGIN" -H 'Access-Control-Request-Method: POST' -H 'Access-Control-Request-Headers: authorization, content-type' | tr -d '\r')"
  foreign="$(curl -s -i -X OPTIONS "$url" -H "Origin: $FOREIGN_ORIGIN" -H 'Access-Control-Request-Method: POST' | tr -d '\r')"
  echo "$allowed" | head -1; echo "$foreign" | head -1
  echo "$allowed" | grep -iq "^access-control-allow-origin: ${WEB_ORIGIN}\$" || { echo "$fnname: dev web origin not allowed"; ok=1; }
  if echo "$foreign" | grep -iqE "^access-control-allow-origin: (\*|${FOREIGN_ORIGIN})\$"; then echo "$fnname: foreign origin reflected"; ok=1; fi
done
tap $ok "CORS: dev web origin allowed, foreign origin never reflected"

npx tsx scripts/consistency-check.ts; tap $? "memberships and Auth agree (email = phone, inactive banned, active not banned)"

# 6 (03, AC-2, D9): dev has Super Admins and no PLATFORM_SETUP_TOKEN, so the setup endpoint refuses without touching the database (403 not_allowed).
# The local literal from supabase/config.toml is sent as the token: it must not open anything on a hosted project. Nothing is created either way (a Super Admin exists).
LOCAL_SETUP_TOKEN="local-setup-token-not-a-secret-0123456789"
setup_url="https://${DEV_SUPABASE_PROJECT_REF}.supabase.co/functions/v1/platform-setup"
setup_out="$(curl -s -w '\n%{http_code}' -X POST "$setup_url" -H 'Content-Type: application/json' -H "x-setup-token: ${LOCAL_SETUP_TOKEN}" -d '{"full_name":"Hosted Check","phone":"+919000099999"}')"
setup_code="$(echo "$setup_out" | tail -1)"; setup_body="$(echo "$setup_out" | head -n -1)"
echo "platform-setup: HTTP $setup_code"
[ "$setup_code" = 403 ] && echo "$setup_body" | grep -q '"code":"not_allowed"'; tap $? "platform-setup refuses on dev (403 not_allowed, no usable token)"

# 7: if a PLATFORM_SETUP_TOKEN secret exists at all, its digest must not be the digest of the local literal (values are never printed).
local_digest="$(printf '%s' "$LOCAL_SETUP_TOKEN" | sha256sum | cut -d' ' -f1)"
secrets_json="$(npx supabase secrets list --project-ref "$DEV_SUPABASE_PROJECT_REF" -o json 2>/dev/null)"
if echo "$secrets_json" | jq -e 'type == "array"' >/dev/null 2>&1; then
  echo "setup token secret present on dev: $(echo "$secrets_json" | jq -r '[.[] | select(.name == "PLATFORM_SETUP_TOKEN")] | length')"
  # Metadata only (never the digest or the value): when it was set and whether it equals the local literal.
  echo "$secrets_json" | jq -c --arg d "$local_digest" '.[] | select(.name == "PLATFORM_SETUP_TOKEN") | del(.value) + {equals_local_literal: (((.value // "") | ascii_downcase) == $d)}'
  echo "$secrets_json" | jq -e --arg d "$local_digest" '[.[] | select(.name == "PLATFORM_SETUP_TOKEN" and ((.value // "") | ascii_downcase) == $d)] | length == 0' >/dev/null; tap $? "the configured setup token (if any) is not the local literal"
  # 8 (D11): dev uses fixture Super Admins and never has a pending setup, so no setup token may exist there at all.
  echo "$secrets_json" | jq -e '[.[] | select(.name == "PLATFORM_SETUP_TOKEN")] | length == 0' >/dev/null; tap $? "dev has no PLATFORM_SETUP_TOKEN secret"
else
  echo "could not list secrets"; tap 1 "the configured setup token (if any) is not the local literal"; tap 1 "dev has no PLATFORM_SETUP_TOKEN secret"
fi

# 9 (07): the private photo bucket exists as the migration defines it (read-only Storage API call with the service role).
bucket="$(curl -s -w '\n%{http_code}' "${SUPABASE_URL%/}/storage/v1/bucket/attachments" -H "apikey: ${SUPABASE_SERVICE_ROLE_KEY}" -H "Authorization: Bearer ${SUPABASE_SERVICE_ROLE_KEY}")"
bucket_code="$(echo "$bucket" | tail -1)"; bucket_body="$(echo "$bucket" | head -n -1)"
echo "attachments bucket: HTTP $bucket_code"
[ "$bucket_code" = 200 ] && echo "$bucket_body" | jq -e '.id == "attachments" and .public == false and .file_size_limit == 5242880 and ((.allowed_mime_types // []) | sort) == ["image/jpeg","image/png","image/webp"]' >/dev/null; tap $? "Storage bucket attachments exists, is private, 5 MB limit, MIME list jpeg/png/webp"

# 10 (08, D1): handover is enforced for every tenant except the four fixture tenants that tests insert directly. A Console-registered tenant always gets
# required = true (app.pa_tenant_create) and the migration backfilled the existing ones; this catches a tenant that slipped through (read-only REST call).
tenants="$(curl -s -w '\n%{http_code}' "${SUPABASE_URL%/}/rest/v1/tenant?select=name,handover_setting(required)" -H "apikey: ${SUPABASE_SERVICE_ROLE_KEY}" -H "Authorization: Bearer ${SUPABASE_SERVICE_ROLE_KEY}")"
tenants_code="$(echo "$tenants" | tail -1)"; tenants_body="$(echo "$tenants" | head -n -1)"
echo "tenants with handover setting: HTTP $tenants_code"
[ "$tenants_code" = 200 ] && echo "$tenants_body" | jq -e '[.[] | select(.name as $n | ["e2e org A","e2e org B","e2e org S","e2e org U"] | index($n) | not) | select((.handover_setting.required // false) | not) | .name] | length == 0' >/dev/null; tap $? "every non-fixture tenant has handover required = true"

exit $([ "$fails" = 0 ] && echo 0 || echo 1)
