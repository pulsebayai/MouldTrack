#!/usr/bin/env bash
# Writes the three public EXPO_PUBLIC_* values into the EAS environment named by $EAS_PROFILE (preview|production).
# Values come from the workflow environment (GitHub secrets); `env:set` creates or updates. Plaintext visibility: all three are public by design.
set -euo pipefail
EAS="npx --yes ${EAS_CLI:-eas-cli@27.10.0}"
set_var() { # name value
  [ -n "$2" ] || { echo "empty value for $1"; exit 1; }
  $EAS env:set "$EAS_PROFILE" --name "$1" --value "$2" --visibility plaintext --scope project --non-interactive >/dev/null
  echo "EAS $EAS_PROFILE: $1 set"
}
set_var EXPO_PUBLIC_SUPABASE_URL "$SUPABASE_URL"
set_var EXPO_PUBLIC_SUPABASE_ANON_KEY "$SUPABASE_ANON_KEY"
[ -z "${SENTRY_DSN:-}" ] || set_var EXPO_PUBLIC_SENTRY_DSN "$SENTRY_DSN"
