#!/usr/bin/env bash
# AC-12: fails if hosted dev is missing a migration from supabase/migrations (or has one we don't).
#   bash scripts/drift-check.sh            # queries dev via DEV_SUPABASE_DB_URL
#   bash scripts/drift-check.sh --parse    # parses `supabase migration list` output from stdin (used by tests)
set -euo pipefail

# Prints drift rows. Rows look like: "  `20261115000000` | `20261115000000` | `2026-11-15 00:00:00`";
# a side with no 14-digit version = drift. POSIX awk only (no {n} intervals: mawk lacks them).
parse() {
  awk -F'|' '
    function ver(x) { gsub(/[^0-9]/, "", x); return (length(x) == 14) ? x : "" }
    NF >= 3 {
      l = ver($1); r = ver($2)
      if (l == "" && r == "") next          # header / separator lines
      if (l == "" || r == "" || l != r) print
    }'
}

if [ "${1:-}" = "--parse" ]; then parse; exit 0; fi

: "${DEV_SUPABASE_DB_URL:?DEV_SUPABASE_DB_URL required}"
out="$(npx supabase migration list --db-url "$DEV_SUPABASE_DB_URL" 2>&1)" || { echo "$out" | sed -E 's#postgres(ql)?://[^ ]*#<redacted>#g'; exit 1; }
echo "$out" | sed -E 's#postgres(ql)?://[^ ]*#<redacted>#g'
rows=$(echo "$out" | grep -c '[0-9]\{14\}' || true)
[ "$rows" -gt 0 ] || { echo "❌ no migration rows parsed — refusing to report 'no drift'"; exit 1; }
drift=$(echo "$out" | parse)
if [ -n "$drift" ]; then echo "❌ migration drift between repo and dev:"; echo "$drift"; exit 1; fi
echo "✅ dev has exactly the repo's $rows migration(s)"
