#!/usr/bin/env bash
# Runs ALL Maestro flows in one invocation (same as `maestro test e2e/maestro`; one process, one driver start, so the job stays fast).
# Only when something failed: the maestro.log tail of the run is printed, then each failed flow is re-run ALONE as a diagnostic (its result is
# ignored; the exit code is the first run's) and the screen is dumped right after it, redacted: what is on screen (id | text | bounds).
set -uo pipefail
mkdir -p test-results
dbg="test-results/maestro-debug"
mkdir -p "$dbg"
maestro test scripts/maestro-warmup.yaml >/dev/null 2>&1 || echo "maestro warm-up did not see the sign-in screen (suite continues)"
maestro test e2e/maestro --env PASSWORD="${PASSWORD:-}" --format junit --output test-results/junit-android.xml --debug-output "$dbg"
code=$?
if [ "$code" -ne 0 ]; then
  echo "================ MAESTRO FAILURE CONTEXT (redacted) ================"
  echo "--- maestro.log (last 60 lines) ---"
  (find "$dbg" -name 'maestro.log' | head -1 | xargs -r tail -n 60 | npx tsx scripts/redact-log.ts) || true
  echo "--- screenshots ---"
  find "$dbg" -name '*.png' | sort | tail -5
  failed=$(python3 - <<'PY'
import re, xml.etree.ElementTree as ET
try:
    root = ET.parse("test-results/junit-android.xml").getroot()
    for tc in root.iter("testcase"):
        if tc.find("failure") is not None or tc.find("error") is not None:
            print(re.sub(r"[^A-Za-z0-9_.-]", "", tc.get("name") or tc.get("id") or ""))
except Exception:
    pass
PY
)
  for name in $failed; do
    flow="e2e/maestro/$name.yaml"
    [ -f "$flow" ] || continue
    echo "================ MAESTRO FAILURE CONTEXT: $name (diagnostic re-run, result ignored) ================"
    mkdir -p "$dbg/rerun-$name"
    maestro test "$flow" --env PASSWORD="${PASSWORD:-}" --debug-output "$dbg/rerun-$name" >/dev/null 2>&1 || true
    echo "--- on screen now (resource-id | text | bounds) ---"
    (maestro hierarchy 2>/dev/null | npx tsx scripts/redact-log.ts --hierarchy) || echo "(hierarchy unavailable)"
  done
fi
exit "$code"
