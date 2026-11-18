/**
 * Failure diagnostics (chore/test-reliability step 1). Everything printed to a CI job log passes through `redact`:
 * the repository is public and its logs are readable, so no token, JWT, key or phone number may appear.
 * Network summaries carry path + status + duration only (never query strings, headers or bodies).
 */

const JWT = /eyJ[A-Za-z0-9_-]{5,}\.[A-Za-z0-9_-]{5,}(?:\.[A-Za-z0-9_-]*)?/g;
const BEARER = /\b(bearer|basic)\s+[A-Za-z0-9._~+/=-]{8,}/gi;
const KEYED = /\b(access_token|refresh_token|id_token|token|apikey|api_key|authorization|password|secret|service_role)(["']?\s*[:=]\s*["']?)[^\s"'&,;}]+/gi;
const SB_KEY = /\b(sb_(?:publishable|secret)_[A-Za-z0-9_-]+)\b/g;
const LONG_TOKEN = /\b[A-Za-z0-9_-]{40,}\b/g; // long opaque strings; UUIDs (36 chars with dashes) are not matched
const PHONE_INTL = /(\+91)[\s-]?(\d{5})[\s-]?(\d{1})(\d{4})\b/g;
const PHONE_LOCAL = /(?<![\d])([6-9]\d{5})(\d{4})(?![\d])/g;

export function maskPhone(phone: string): string {
  const d = phone.replace(/\D/g, '').slice(-10);
  return d.length === 10 ? `+91******${d.slice(-4)}` : phone;
}

export function redact(text: string): string {
  return text
    .replace(JWT, '[jwt]')
    .replace(BEARER, '$1 [token]')
    .replace(KEYED, '$1$2[redacted]')
    .replace(SB_KEY, '[key]')
    .replace(PHONE_INTL, (m) => maskPhone(m))
    .replace(PHONE_LOCAL, (_m, _a, last4: string) => `+91******${last4}`)
    .replace(LONG_TOKEN, '[token]');
}

export type NetCall = { method: string; path: string; status: number | 'failed'; ms: number };

/** Path only: the query string (which can hold tokens, phones, filters) is dropped. */
export function pathOf(url: string): string {
  try {
    const u = new URL(url);
    return `${u.host}${u.pathname}`;
  } catch {
    return redact(url.split('?')[0] ?? '');
  }
}

export function formatNetwork(calls: NetCall[], limit = 40): string {
  const last = calls.slice(-limit);
  if (last.length === 0) return '(no network calls recorded)';
  const lines = last.map((c) => redact(`${c.method.padEnd(6)} ${String(c.status).padEnd(6)} ${String(c.ms).padStart(5)} ms  ${c.path}`));
  return `${calls.length > limit ? `(last ${limit} of ${calls.length} calls)\n` : ''}${lines.join('\n')}`;
}

export function formatConsole(entries: string[], limit = 30): string {
  if (entries.length === 0) return '(no console errors)';
  const last = entries.slice(-limit).map((e) => redact(e.length > 400 ? `${e.slice(0, 400)}…` : e));
  return `${entries.length > limit ? `(last ${limit} of ${entries.length})\n` : ''}${last.join('\n')}`;
}

export function formatFailure(title: string, parts: { name: string; body: string }[]): string {
  const bar = '='.repeat(72);
  const out = [bar, `FAILURE CONTEXT: ${redact(title)}`, bar];
  for (const p of parts) out.push(`--- ${p.name} ---`, redact(p.body).trimEnd());
  out.push(bar);
  return out.join('\n');
}

type HNode = { attributes?: Record<string, string>; children?: HNode[] };

/** Maestro `hierarchy` JSON -> one line per element that has an id, text or accessibility label (what is on screen, not the layout tree). */
export function summarizeHierarchy(json: string): string {
  let root: HNode;
  try {
    root = JSON.parse(json) as HNode;
  } catch {
    return redact(json.slice(0, 4000));
  }
  const lines: string[] = [];
  const walk = (n: HNode) => {
    const a = n.attributes ?? {};
    const id = a['resource-id'] ?? '';
    const text = a.text ?? '';
    const label = a.accessibilityText ?? '';
    if (id || text || label) lines.push(`${id || '-'} | ${text || '-'}${label && label !== text ? ` | a11y: ${label}` : ''}${a.bounds ? ` | ${a.bounds}` : ''}`);
    (n.children ?? []).forEach(walk);
  };
  walk(root);
  return redact(lines.slice(0, 200).join('\n') || '(empty hierarchy)');
}
