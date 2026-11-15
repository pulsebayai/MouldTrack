#!/usr/bin/env bash
# Verifies the Android native project can be generated, without touching the repo:
# prebuild rewrites package.json and creates ./android, so it runs on a throwaway copy.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
cp -r "$ROOT/package.json" "$ROOT/app.json" "$ROOT/tsconfig.json" "$ROOT/assets" "$ROOT/src" "$TMP/"
ln -s "$(readlink -f "$ROOT/node_modules")" "$TMP/node_modules"
cd "$TMP"
npx expo prebuild -p android --no-install --clean > prebuild.log 2>&1 || { cat prebuild.log; exit 1; }
test -f android/app/build.gradle
echo "android prebuild OK"
