/** Playwright traces and screenshots capture typed credentials, so they are produced for local/ephemeral targets only (R3). */
export const isLocalUrl = (baseURL: string): boolean => /^https?:\/\/(localhost|127\.0\.0\.1)(:\d+)?(\/|$)/.test(baseURL);

export function evidenceSettings(baseURL: string): { trace: 'off' | 'retain-on-failure'; screenshot: 'off' | 'only-on-failure'; video: 'off' } {
  return isLocalUrl(baseURL)
    ? { trace: 'retain-on-failure', screenshot: 'only-on-failure', video: 'off' }
    : { trace: 'off', screenshot: 'off', video: 'off' };
}
