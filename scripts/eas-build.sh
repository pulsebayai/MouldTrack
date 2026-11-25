#!/usr/bin/env bash
# Runs the EAS build for $EAS_PROFILE and prints the build page / install URL into the job summary.
# If EAS needs interactive credential setup (first build: Android keystore), the build fails with a message: the owner runs
# `eas credentials -p android` once (see sdlc/releases/README.md).
set -uo pipefail
EAS="npx --yes ${EAS_CLI:-eas-cli@27.10.0}"
$EAS build -p android --profile "$EAS_PROFILE" --non-interactive --json > build.json 2> build.err || { tail -30 build.err; cat build.json; exit 1; }
tail -3 build.err
# eas-cli --json may print an array or a single object; read either shape. Run 45641985004 built fine but this lookup came back empty.
b='(if type == "array" then .[0] else . end)'
page=$(jq -r "$b | .buildDetailsPageUrl // empty" build.json 2>/dev/null)
apk=$(jq -r "$b | .artifacts.applicationArchiveUrl // .artifacts.buildUrl // empty" build.json 2>/dev/null)
ver=$(jq -r "$b | .appBuildVersion // empty" build.json 2>/dev/null)
id=$(jq -r "$b | .id // empty" build.json 2>/dev/null)
[ -n "$page" ] || page=$(grep -Eo 'https://expo\.dev/accounts/[^ ]+/builds/[0-9a-f-]+' build.json build.err 2>/dev/null | head -1 | cut -d: -f2-)
[ -n "$page" ] || { [ -n "$id" ] && page="https://expo.dev/accounts/mouldtrack/projects/mouldtrack/builds/$id"; }
[ -n "$page" ] || { echo "no build page found; build.json shape:"; jq -c "$b | keys" build.json 2>/dev/null || head -c 300 build.json; }
{
  echo "### EAS Android build ($EAS_PROFILE)"
  echo "- Build page (install link / QR): ${page:-unknown}"
  echo "- APK: ${apk:-unknown}"
  echo "- Android build number: ${ver:-unknown}"
} >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
echo "build page: $page"
[ -n "$page" ]
