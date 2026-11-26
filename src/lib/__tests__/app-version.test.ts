import { appVersionLabel } from '../app-version';

describe('appVersionLabel (OTA updates)', () => {
  it('is null on web and in development (no runtime version)', () => {
    expect(appVersionLabel({ runtimeVersion: null, updateId: null, isEmbeddedLaunch: true })).toBeNull();
  });
  it('shows the built-in code of the installed APK', () => {
    expect(appVersionLabel({ runtimeVersion: '1.0.0', updateId: 'abc', isEmbeddedLaunch: true })).toBe('Version 1.0.0 · built-in');
  });
  it('shows the first 8 characters of a downloaded update', () => {
    expect(appVersionLabel({ runtimeVersion: '1.0.0', updateId: '1a2b3c4d-5e6f', isEmbeddedLaunch: false })).toBe('Version 1.0.0 · update 1a2b3c4d');
  });
});
