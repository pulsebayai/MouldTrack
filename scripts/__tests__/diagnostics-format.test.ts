import { formatConsole, formatFailure, formatNetwork, maskPhone, pathOf, redact, summarizeHierarchy } from '../../e2e/diagnostics-format';

const JWT = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c';

describe('failure diagnostics redaction', () => {
  it('strips JWTs, bearer tokens and keyed secrets', () => {
    const out = redact(`Authorization: Bearer ${JWT}\nbody {"access_token":"abcdefghijkl","refresh_token":"zzzzzzzz"} apikey=sb_publishable_abc123 ${JWT}`);
    expect(out).not.toContain('eyJ');
    expect(out).not.toContain('abcdefghijkl');
    expect(out).not.toContain('zzzzzzzz');
    expect(out).not.toContain('sb_publishable_abc123');
  });
  it('strips passwords and long opaque strings but keeps UUIDs', () => {
    const uuid = '43000000-0000-4000-a000-0000000000a1';
    const out = redact(`password=Sup3rSecretValue! id ${uuid} blob ${'A'.repeat(48)}`);
    expect(out).not.toContain('Sup3rSecretValue');
    expect(out).not.toContain('A'.repeat(48));
    expect(out).toContain(uuid);
  });
  it('masks phones as +91******1234 in every common form', () => {
    expect(maskPhone('+919000012345')).toBe('+91******2345');
    for (const p of ['+919000012345', '+91 90000 12345', '9000012345', '9000012345@phone.mouldtrack.invalid']) {
      const out = redact(`user ${p} signed in`);
      expect(out).toContain('+91******2345');
      expect(out).not.toMatch(/90000\s?12345/);
    }
  });
  it('keeps only host and path of a URL: the query string never reaches the log', () => {
    expect(pathOf('https://x.supabase.co/rest/v1/rpc/rd_correct?apikey=secret&phone=eq.%2B919000012345')).toBe('x.supabase.co/rest/v1/rpc/rd_correct');
  });
  it('formats the network summary with status and duration and redacts the rest', () => {
    const out = formatNetwork([{ method: 'POST', path: 'h/rest/v1/rpc/rd_correct', status: 200, ms: 123 }, { method: 'GET', path: 'h/x', status: 'failed', ms: 5 }]);
    expect(out).toMatch(/POST\s+200\s+123 ms\s+h\/rest\/v1\/rpc\/rd_correct/);
    expect(out).toMatch(/failed/);
    expect(formatNetwork([])).toMatch(/no network/);
  });
  it('bounds and redacts console entries and the assembled failure block', () => {
    expect(formatConsole(Array.from({ length: 50 }, (_, i) => `e${i}`))).toMatch(/last 30 of 50/);
    const block = formatFailure(`t ${JWT}`, [{ name: 'console errors', body: 'login +919000012345' }]);
    expect(block).toContain('FAILURE CONTEXT');
    expect(block).not.toContain('eyJ');
    expect(block).toContain('+91******2345');
  });
});

describe('Maestro hierarchy summary', () => {
  it('lists id, text and label of on-screen elements only, redacted', () => {
    const tree = { attributes: { 'resource-id': '', text: '' }, children: [
      { attributes: { 'resource-id': 'reading-state-s-m-d', text: 'Opening recorded', bounds: '[0,0][10,10]' }, children: [] },
      { attributes: { 'resource-id': '', text: '', accessibilityText: 'Save closing reading' }, children: [] },
      { attributes: { 'resource-id': 'phone', text: '9000012345' }, children: [] },
    ] };
    const out = summarizeHierarchy(JSON.stringify(tree));
    expect(out).toContain('reading-state-s-m-d | Opening recorded | [0,0][10,10]');
    expect(out).toContain('a11y: Save closing reading');
    expect(out).toContain('+91******2345');
    expect(out).not.toContain('9000012345');
    expect(summarizeHierarchy('not json')).toBe('not json');
  });
});
