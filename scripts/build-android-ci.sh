#!/usr/bin/env bash
# Builds a release APK on the CI runner (no EAS Build credits). Signed with the template's debug keystore:
# for CI/emulator use only, never distributed. EXPO_PUBLIC_* must be set by the caller.
set -euo pipefail
: "${EXPO_PUBLIC_SUPABASE_URL:?}" "${EXPO_PUBLIC_SUPABASE_ANON_KEY:?}" "${EXPO_PUBLIC_APP_ENV:?}"
npx expo prebuild -p android --no-install --clean
cd android
./gradlew --no-daemon -q assembleRelease -PreactNativeArchitectures=x86_64
ls -la app/build/outputs/apk/release/app-release.apk
