import {
  authEmailToPhone,
  formatPhone,
  generateTempPassword,
  maskPhone,
  normalisePhone,
  passwordPolicy,
  phoneToAuthEmail,
  TEMP_PASSWORD_ALPHABET,
} from '@/lib/identity';
import { randomBytes } from 'crypto';

const rnd = (n: number) => new Uint8Array(randomBytes(n));

describe('normalisePhone (AC-2)', () => {
  it.each(['98765 43210', '098765-43210', '+91 9876543210', '+91-98765-43210', '9876543210', '919876543210'])(
    'normalises "%s"',
    (input) => {
      expect(normalisePhone(input)).toEqual({ ok: true, e164: '+919876543210' });
    },
  );
  it.each(['5876543210', '987654321', '98765432100', '98765abc10', '', '   ', '+1 9876543210'])(
    'rejects "%s"',
    (input) => {
      expect(normalisePhone(input).ok).toBe(false);
    },
  );
  it('returns a message on error', () => {
    const r = normalisePhone('123');
    expect(r.ok).toBe(false);
    if (!r.ok) expect(r.message.length).toBeGreaterThan(0);
  });
});

describe('maskPhone', () => {
  it('masks all but the last four digits', () => {
    expect(maskPhone('+919876543210')).toBe('+91******3210');
  });
});

describe('auth email mapping', () => {
  it('maps phone to a non-deliverable address and back', () => {
    const email = phoneToAuthEmail('+919876543210');
    expect(email).toBe('9876543210@phone.mouldtrack.invalid');
    expect(authEmailToPhone(email)).toBe('+919876543210');
  });
  it('returns null for other addresses', () => {
    expect(authEmailToPhone('someone@example.test')).toBeNull();
  });
});

describe('passwordPolicy (AC-3)', () => {
  it('rejects fewer than 10 characters', () => {
    expect(passwordPolicy('abc12345').ok).toBe(false);
  });
  it('rejects no digit', () => {
    expect(passwordPolicy('abcdefghijk').ok).toBe(false);
  });
  it('rejects no letter', () => {
    expect(passwordPolicy('12345678901').ok).toBe(false);
  });
  it('rejects equal to the current password', () => {
    expect(passwordPolicy('abcdefgh12', 'abcdefgh12').ok).toBe(false);
  });
  it('accepts a valid, different password', () => {
    expect(passwordPolicy('abcdefgh12', 'zzzzzzzz99')).toEqual({ ok: true });
  });
  it('reports each rule as a checklist', () => {
    const r = passwordPolicy('abc');
    expect(r.ok).toBe(false);
    if (!r.ok) {
      expect(r.checks).toEqual({ length: false, letter: true, digit: false, different: true });
    }
  });
});

describe('generateTempPassword (FR-3)', () => {
  it('is 12 chars from the unambiguous alphabet with a letter and a digit', () => {
    for (let i = 0; i < 200; i++) {
      const p = generateTempPassword(rnd);
      expect(p).toHaveLength(12);
      for (const c of p) expect(TEMP_PASSWORD_ALPHABET).toContain(c);
      expect(/[A-Za-z]/.test(p)).toBe(true);
      expect(/[0-9]/.test(p)).toBe(true);
      expect(passwordPolicy(p).ok).toBe(true);
    }
  });
  it('alphabet excludes ambiguous characters', () => {
    for (const c of '0O1lI') expect(TEMP_PASSWORD_ALPHABET).not.toContain(c);
  });
  it('1000 samples are unique', () => {
    const s = new Set(Array.from({ length: 1000 }, () => generateTempPassword(rnd)));
    expect(s.size).toBe(1000);
  });
  it('forces a letter and a digit even with degenerate randomness', () => {
    const p = generateTempPassword((n) => new Uint8Array(n));
    expect(/[A-Za-z]/.test(p) && /[0-9]/.test(p)).toBe(true);
  });
});

describe('formatPhone', () => {
  it('shows the country code, a space, then the ten digits', () => {
    expect(formatPhone('+919876543210')).toBe('+91 9876543210');
  });
});
