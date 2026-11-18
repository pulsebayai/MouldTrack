#!/usr/bin/env bash
# Runs the Maestro flows; on failure prints the failure context into the job log (redacted): the UI hierarchy of the screen where the
# run stopped, each failed command, the tail of maestro.log and the screenshot names. Exit code is Maestro's.
set -uo pipefail
mkdir -p test-results/maestro-debug
maestro test e2e/maestro --env PASSWORD="${PASSWORD:-}" --format junit --output test-results/junit-android.xml --debug-output test-results/maestro-debug
rc=$?
if [ "$rc" -ne 0 ]; then
  redact() { npx tsx scripts/redact-log.ts; }
  echo "================ MAESTRO FAILURE CONTEXT (redacted) ================"
  echo "--- hierarchy at stop ---"
  (maestro hierarchy 2>&1 | head -c 60000 | redact) || echo "(hierarchy unavailable)"
  echo "--- failed commands ---"
  for f in $(find test-results/maestro-debug -name 'commands-*.json' 2>/dev/null); do
    echo "# $f"
    (grep -B3 -A12 -i '"FAILED"' "$f" | head -c 8000 | redact) || true
  done
  echo "--- maestro.log (tail) ---"
  (find test-results/maestro-debug -name 'maestro.log' -exec tail -n 80 {} + 2>/dev/null | redact) || true
  echo "--- screenshots ---"
  find test-results/maestro-debug -name '*.png' 2>/dev/null | sort | tail -20
  echo "===================================================================="
fi
exit "$rc"
