#!/usr/bin/env bash
# Exports the LOCAL Supabase URL/key (CLI defaults, not secrets) as EXPO_PUBLIC_* for the web build.
set -euo pipefail
eval "$(npx supabase status -o env 2>/dev/null | grep -E '^[A-Z_]+=')"
KEY="${ANON_KEY:-${PUBLISHABLE_KEY:-}}"
: "${API_URL:?supabase status did not return API_URL}"
: "${KEY:?supabase status did not return ANON_KEY/PUBLISHABLE_KEY}"
{
  echo "EXPO_PUBLIC_SUPABASE_URL=$API_URL"
  echo "EXPO_PUBLIC_SUPABASE_ANON_KEY=$KEY"
  echo "EXPO_PUBLIC_APP_ENV=local"
} >> "${GITHUB_ENV:-/dev/stdout}"
