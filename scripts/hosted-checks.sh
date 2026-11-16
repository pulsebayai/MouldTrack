#!/usr/bin/env bash
# Nightly hosted checks against DEV (02 step 10). Read-only. Writes test-results/hosted-checks.tap.
#   TARGET=dev (default): needs SUPABASE_ACCESS_TOKEN, DEV_SUPABASE_PROJECT_REF, SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, APP_ENV=development
#     1 Auth config (signup off, min length 10, letters+digits)  2 both Edge Functions deployed
#     3 no orphan Auth users (D4)                                 4 CORS: dev web origin allowed, foreign origin never reflected (D8)
#     5 every membership's Auth email = its phone, inactive = banned, active = not banned (R7)
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
printf 'TAP version 13\n1..5\n' > "$OUT"

node scripts/auth-config.mjs --check --ref dev; tap $? "auth config on dev matches (signup off, min length 10, letters+digits)"

fn="$(npx supabase functions list --project-ref "$DEV_SUPABASE_PROJECT_REF" 2>&1)"; echo "$fn" | sed -E 's#sbp_[A-Za-z0-9]+#<redacted>#g'
echo "$fn" | grep -qE '(^|[ |])user-admin([ |]|$)' && echo "$fn" | grep -qE '(^|[ |])account([ |]|$)'; tap $? "Edge Functions user-admin and account are deployed"

npx tsx scripts/orphan-check.ts; tap $? "no Auth users without a membership (except nomember)"

ok=0
for fnname in user-admin account; do
  url="https://${DEV_SUPABASE_PROJECT_REF}.supabase.co/functions/v1/${fnname}"
  allowed="$(curl -s -i -X OPTIONS "$url" -H "Origin: $WEB_ORIGIN" -H 'Access-Control-Request-Method: POST' -H 'Access-Control-Request-Headers: authorization, content-type' | tr -d '\r')"
  foreign="$(curl -s -i -X OPTIONS "$url" -H "Origin: $FOREIGN_ORIGIN" -H 'Access-Control-Request-Method: POST' | tr -d '\r')"
  echo "$allowed" | head -1; echo "$foreign" | head -1
  echo "$allowed" | grep -iq "^access-control-allow-origin: ${WEB_ORIGIN}\$" || { echo "$fnname: dev web origin not allowed"; ok=1; }
  if echo "$foreign" | grep -iqE "^access-control-allow-origin: (\*|${FOREIGN_ORIGIN})\$"; then echo "$fnname: foreign origin reflected"; ok=1; fi
done
tap $ok "CORS: dev web origin allowed, foreign origin never reflected"

npx tsx scripts/consistency-check.ts; tap $? "memberships and Auth agree (email = phone, inactive banned, active not banned)"

exit $([ "$fails" = 0 ] && echo 0 || echo 1)
