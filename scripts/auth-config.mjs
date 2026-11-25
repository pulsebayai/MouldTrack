#!/usr/bin/env node
// Hosted Auth settings as code (02 D9). Usage: node scripts/auth-config.mjs --check|--apply --ref dev|staging
// Needs SUPABASE_ACCESS_TOKEN and DEV_/STAGING_SUPABASE_PROJECT_REF. Touches only the three fields below.
// Exit codes: 0 ok · 1 mismatch (--check), refusal or usage error · 2 BLOCKED (the API rejected a field).
// Never prints the token or any field outside DESIRED.
const LETTERS_DIGITS = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ:0123456789';
const DESIRED = { disable_signup: true, password_min_length: 10, password_required_characters: LETTERS_DIGITS };

const args = process.argv.slice(2);
const mode = args.includes('--apply') ? 'apply' : args.includes('--check') ? 'check' : '';
const refArg = args.includes('--ref') ? (args[args.indexOf('--ref') + 1] ?? '') : '';
const fail = (msg, code = 1) => {
  console.error(msg);
  process.exit(code);
};

if (!mode) fail('Usage: auth-config.mjs --check|--apply --ref dev|staging');
// `--ref prod` works only when deploy-prod.yml sets AUTH_CONFIG_ALLOW_PROD=1 (r1-release-prep D4); anywhere else it is refused as before.
const refs = { dev: 'DEV_SUPABASE_PROJECT_REF', staging: 'STAGING_SUPABASE_PROJECT_REF', ...(process.env.AUTH_CONFIG_ALLOW_PROD === '1' ? { prod: 'PROD_SUPABASE_PROJECT_REF' } : {}) };
const refVar = refs[refArg];
if (!refVar) fail(`Refusing: --ref must be "dev" or "staging" (got "${refArg}")`);
const ref = process.env[refVar];
const token = process.env.SUPABASE_ACCESS_TOKEN;
if (!ref) fail(`${refVar} is not set`);
if (!token) fail('SUPABASE_ACCESS_TOKEN is not set');

const base = (process.env.SUPABASE_API_URL || 'https://api.supabase.com').replace(/\/$/, '');
const url = `${base}/v1/projects/${ref}/config/auth`;
const headers = { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' };

async function get() {
  const res = await fetch(url, { headers });
  if (!res.ok) fail(`GET auth config failed: HTTP ${res.status}`);
  return res.json();
}
const diff = (cfg) => Object.keys(DESIRED).filter((k) => cfg[k] !== DESIRED[k]);
const show = (keys, cfg) => keys.map((k) => `  ${k}: have ${JSON.stringify(cfg[k])}, want ${JSON.stringify(DESIRED[k])}`).join('\n');

let cfg = await get();
let bad = diff(cfg);
if (bad.length === 0) {
  console.log(`auth config on ${refArg} matches (${Object.keys(DESIRED).join(', ')})`);
  process.exit(0);
}
if (mode === 'check') fail(`auth config on ${refArg} differs:\n${show(bad, cfg)}`);

const res = await fetch(url, { method: 'PATCH', headers, body: JSON.stringify(DESIRED) });
if (!res.ok) {
  let message = '';
  try {
    message = String((await res.json()).message ?? '');
  } catch {
    /* no body */
  }
  fail(`BLOCKED: the Management API rejected the auth config on ${refArg}: HTTP ${res.status} ${message}`.trim(), 2);
}
cfg = await get();
bad = diff(cfg);
if (bad.length) fail(`BLOCKED: applied, but the API still reports:\n${show(bad, cfg)}`, 2);
console.log(`auth config on ${refArg} applied and verified`);
