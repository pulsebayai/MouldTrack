#!/usr/bin/env bash
# Publishes an over-the-air JS update to the EAS channel named by $EAS_PROFILE (preview = staging phones, production = prod phones).
# Only phones whose installed APK has the same runtime version (app.json expo.version, policy appVersion) receive it; a native change
# needs a version bump and a new APK instead. EXPO_PUBLIC_* come from the job env (the same GitHub secrets the build used).
set -euo pipefail
EAS="npx --yes ${EAS_CLI:-eas-cli@27.10.0}"
: "${UPDATE_MESSAGE:?UPDATE_MESSAGE is required}"
$EAS update --channel "$EAS_PROFILE" --environment "$EAS_PROFILE" --platform android \
  --message "$UPDATE_MESSAGE" --non-interactive --json > update.json 2> update.err || { tail -30 update.err; exit 1; }
tail -3 update.err
group=$(jq -r 'if type == "array" then .[0] else . end | .group // empty' update.json 2>/dev/null)
rt=$(jq -r 'if type == "array" then .[0] else . end | .runtimeVersion // empty' update.json 2>/dev/null)
{
  echo "### EAS update ($EAS_PROFILE)"
  echo "- Message: $UPDATE_MESSAGE"
  echo "- Update group: ${group:-unknown} · runtime ${rt:-unknown}"
  echo "- Phones pick it up on the next app launch and run it from the launch after that."
} >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
echo "update group: ${group:-unknown} runtime: ${rt:-unknown}"
[ -n "$group" ]
