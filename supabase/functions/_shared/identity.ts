// Shared identity helpers (02-tenancy-and-roles D1). Pure TS: no imports, no Deno or Node APIs,
// so the app (Jest, React Native, web) and the Edge Functions use the same code.

export type PhoneResult = { ok: true; e164: string } | { ok: false; message: string };

export const PHONE_ERROR = 'Enter a valid 10-digit Indian mobile number';

/** Accepts spaces, dashes, a leading 0 or +91/91; returns +91 followed by 10 digits starting 6-9. */
export function normalisePhone(input: string): PhoneResult {
  const raw = (input ?? '').trim();
  if (!/^[+0-9 \-()]*$/.test(raw)) return { ok: false, message: PHONE_ERROR };
  let digits = raw.replace(/[^0-9]/g, '');
  if (raw.startsWith('+') && !digits.startsWith('91')) return { ok: false, message: PHONE_ERROR };
  if (digits.length === 12 && digits.startsWith('91')) digits = digits.slice(2);
  else if (digits.length === 11 && digits.startsWith('0')) digits = digits.slice(1);
  if (!/^[6-9][0-9]{9}$/.test(digits)) return { ok: false, message: PHONE_ERROR };
  return { ok: true, e164: `+91${digits}` };
}

/** `+919876543210` -> `+91 9876543210` (display). */
export function formatPhone(e164: string): string {
  return `${e164.slice(0, 3)} ${e164.slice(3)}`;
}

/** `+919876543210` -> `+91******3210` (audit events never hold a full phone). */
export function maskPhone(e164: string): string {
  return `${e164.slice(0, 3)}******${e164.slice(-4)}`;
}

const AUTH_DOMAIN = 'phone.mouldtrack.invalid';

/** Non-deliverable Auth email (RFC 2606 `.invalid`) for a normalised +91 phone. */
export function phoneToAuthEmail(e164: string): string {
  return `${e164.replace(/^\+91/, '')}@${AUTH_DOMAIN}`;
}

export function authEmailToPhone(email: string): string | null {
  const m = /^([6-9][0-9]{9})@phone\.mouldtrack\.invalid$/.exec(email);
  return m ? `+91${m[1]}` : null;
}

export type PolicyChecks = { length: boolean; letter: boolean; digit: boolean; different: boolean };
export type PolicyResult = { ok: true } | { ok: false; checks: PolicyChecks; message: string };

export const PASSWORD_POLICY_MESSAGE =
  'Use at least 10 characters with a letter and a digit, different from the current password';

export function passwordPolicy(pw: string, current?: string): PolicyResult {
  const checks: PolicyChecks = {
    length: pw.length >= 10,
    letter: /[A-Za-z]/.test(pw),
    digit: /[0-9]/.test(pw),
    different: current === undefined || pw !== current,
  };
  if (checks.length && checks.letter && checks.digit && checks.different) return { ok: true };
  return { ok: false, checks, message: PASSWORD_POLICY_MESSAGE };
}

const LETTERS = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz'; // no I, O, l
const DIGITS = '23456789'; // no 0, 1
export const TEMP_PASSWORD_ALPHABET = LETTERS + DIGITS;

/**
 * 12 chars, CSPRNG injected (crypto.getRandomValues in Deno, node crypto in tests).
 * Rejection sampling avoids modulo bias; one letter and one digit are guaranteed.
 */
export function generateTempPassword(randomBytes: (n: number) => Uint8Array): string {
  const pick = (alphabet: string): string => {
    const limit = 256 - (256 % alphabet.length);
    for (;;) {
      for (const b of randomBytes(16)) if (b < limit) return alphabet[b % alphabet.length];
    }
  };
  for (;;) {
    let out = '';
    for (let i = 0; i < 12; i++) out += pick(TEMP_PASSWORD_ALPHABET);
    if (/[A-Za-z]/.test(out) && /[0-9]/.test(out)) return out;
    // Degenerate randomness (e.g. all-zero test double): force the missing classes deterministically.
    const bytes = randomBytes(2);
    out = LETTERS[bytes[0] % LETTERS.length] + DIGITS[bytes[1] % DIGITS.length] + out.slice(2);
    if (/[A-Za-z]/.test(out) && /[0-9]/.test(out)) return out;
  }
}
