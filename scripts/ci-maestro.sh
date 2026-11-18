#!/usr/bin/env bash
# Runs the Maestro flows one at a time (same order and same flows as `maestro test e2e/maestro`); right after a failing flow it prints the failure
# context into the job log (redacted): what is on screen (id | text per element), the flow's maestro.log tail and the screenshot names.
# Exit code: non-zero when any flow failed.
set -uo pipefail
mkdir -p test-results
fail=0
for flow in e2e/maestro/*.yaml; do
  name=$(basename "$flow" .yaml)
  dbg="test-results/maestro-debug/$name"
  mkdir -p "$dbg"
  maestro test "$flow" --env PASSWORD="${PASSWORD:-}" --format junit --output "test-results/junit-android-$name.xml" --debug-output "$dbg"
  if [ $? -ne 0 ]; then
    fail=1
    echo "================ MAESTRO FAILURE CONTEXT: $name (redacted) ================"
    echo "--- on screen now (resource-id | text | bounds) ---"
    (maestro hierarchy 2>/dev/null | npx tsx scripts/redact-log.ts --hierarchy) || echo "(hierarchy unavailable)"
    echo "--- maestro.log (last 60 lines) ---"
    (find "$dbg" -name 'maestro.log' | head -1 | xargs -r tail -n 60 | npx tsx scripts/redact-log.ts) || true
    echo "--- screenshots ---"
    find "$dbg" -name '*.png' | sort | tail -5
    echo "======================================================================"
  fi
done
exit "$fail"
