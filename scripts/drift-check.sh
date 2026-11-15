#!/usr/bin/env bash
# AC-12: fails if hosted dev is missing a migration from supabase/migrations (or has one we don't).
set -euo pipefail
: "${DEV_SUPABASE_DB_URL:?DEV_SUPABASE_DB_URL required}"
out="$(npx supabase migration list --db-url "$DEV_SUPABASE_DB_URL" 2>&1)" || { echo "$out" | sed -E 's#postgres(ql)?://[^ ]*#<redacted>#g'; exit 1; }
echo "$out" | sed -E 's#postgres(ql)?://[^ ]*#<redacted>#g'
# Rows look like: "  20261115000000 | 20261115000000 | 2026-11-15 00:00:00". A blank side = drift.
drift=$(echo "$out" | awk -F'|' 'NF>=3 && $1 ~ /[0-9]{14}|^[[:space:]]*$/ && $2 ~ /[0-9]{14}|^[[:space:]]*$/ { l=$1; r=$2; gsub(/[[:space:]]/,"",l); gsub(/[[:space:]]/,"",r); if ((l=="" && r!="") || (l!="" && r=="")) print }')
if [ -n "$drift" ]; then echo "❌ migration drift between repo and dev:"; echo "$drift"; exit 1; fi
echo "✅ dev has exactly the repo's migrations"
