import * as Updates from 'expo-updates';

/**
 * "Version 1.0.0 · built-in" or "Version 1.0.0 · update 1a2b3c4d" on a release APK; null on web and in development.
 * Shown on the sign-in screen so a supervisor can say which code a phone runs (R1 OTA updates; support during the pilot).
 */
export function appVersionLabel(u: Pick<typeof Updates, 'runtimeVersion' | 'updateId' | 'isEmbeddedLaunch'> = Updates): string | null {
  if (!u.runtimeVersion) return null;
  const build = u.isEmbeddedLaunch || !u.updateId ? 'built-in' : `update ${u.updateId.slice(0, 8)}`;
  return `Version ${u.runtimeVersion} · ${build}`;
}
