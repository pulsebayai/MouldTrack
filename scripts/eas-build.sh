#!/usr/bin/env bash
# Runs the EAS build for $EAS_PROFILE and prints the build page / install URL into the job summary.
# If EAS needs interactive credential setup (first build: Android keystore), the build fails with a message: the owner runs
# `eas credentials -p android` once (see sdlc/releases/README.md).
set -uo pipefail
EAS="npx --yes ${EAS_CLI:-eas-cli@27.10.0}"
$EAS build -p android --profile "$EAS_PROFILE" --non-interactive --json > build.json 2> build.err || { tail -30 build.err; cat build.json; exit 1; }
tail -3 build.err
page=$(jq -r '.[0].buildDetailsPageUrl // empty' build.json)
apk=$(jq -r '.[0].artifacts.buildUrl // empty' build.json)
ver=$(jq -r '.[0].appBuildVersion // empty' build.json)
{
  echo "### EAS Android build ($EAS_PROFILE)"
  echo "- Build page (install link / QR): ${page:-unknown}"
  echo "- APK: ${apk:-unknown}"
  echo "- Android build number: ${ver:-unknown}"
} >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
echo "build page: $page"
[ -n "$page" ]
