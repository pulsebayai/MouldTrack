import { createClient, type SupabaseClient } from '@supabase/supabase-js';

/**
 * 07 D16: throwaway issues that e2e runs leave open in persistent dev orgs (they pile up in the Unit Admin alerts) are closed through the
 * public RPCs, signed in as a Unit Admin of that org. History stays append-only; nothing is written to tables directly.
 */
export const THROWAWAY_PREFIX = 'E2E ';

export type IssueLite = { id: string; description: string; status: string };

/** The selection rule: an issue that is not closed and whose description starts with "E2E " (fixture issues start with "Fixture issue"). */
export function selectThrowaway(items: IssueLite[]): IssueLite[] {
  return items.filter((i) => i.status !== 'closed' && i.description.startsWith(THROWAWAY_PREFIX));
}

/** What to call for an issue: open work is resolved (Low closes at once); a resolved High/Critical awaits verification (Unit Admin fallback). */
export function nextCall(status: string): 'iss_resolve' | 'iss_verify' | null {
  if (status === 'open' || status === 'in_progress') return 'iss_resolve';
  if (status === 'resolved') return 'iss_verify';
  return null;
}

type Rpc = Pick<SupabaseClient, 'rpc'>;
const uuid = () => crypto.randomUUID();

async function listOpen(c: Rpc): Promise<IssueLite[]> {
  const found: IssueLite[] = [];
  for (let page = 1; page <= 40; page++) {
    const r = await c.rpc('issue_list', { p_filters: { status: 'not_closed' }, p_page: page });
    const d = r.data as { ok?: boolean; items?: IssueLite[]; total?: number; page_size?: number } | null;
    if (r.error || !d?.ok) throw new Error(`issue_list: ${r.error?.message ?? JSON.stringify(d)}`);
    found.push(...(d.items ?? []));
    if (page * (d.page_size ?? 25) >= (d.total ?? 0)) break;
  }
  return found;
}

/** Closes what it can; an issue that cannot be closed (for example a High awaiting a later supervisor's verification) is left and counted. */
export async function closeThrowawayIssues(c: Rpc): Promise<{ closed: number; left: number }> {
  let closed = 0;
  const todo = selectThrowaway(await listOpen(c));
  const left = new Set<string>();
  for (const i of todo) {
    const call = nextCall(i.status);
    if (!call) continue;
    let status = i.status;
    if (call === 'iss_resolve') {
      const r = await c.rpc('iss_resolve', { p_request_id: uuid(), p_issue_id: i.id, p_notes: 'E2E cleanup' });
      const d = r.data as { ok?: boolean; status?: string } | null;
      if (r.error || !d?.ok) { left.add(i.id); continue; }
      status = d.status ?? status;
    }
    if (status === 'resolved') {
      const r = await c.rpc('iss_verify', { p_request_id: uuid(), p_issue_id: i.id, p_confirm: true });
      const d = r.data as { ok?: boolean } | null;
      if (r.error || !d?.ok) { left.add(i.id); continue; }
    }
    closed++;
  }
  return { closed, left: left.size };
}

/** Signs in as the given Unit Admin (the service key is only the API key here: the session carries the user) and closes the throwaway issues. */
export async function closeAsUnitAdmin(url: string, apiKey: string, email: string, password: string) {
  const client = createClient(url, apiKey, { auth: { persistSession: false, autoRefreshToken: false } });
  const { error } = await client.auth.signInWithPassword({ email, password });
  if (error) throw new Error(`sign-in: ${error.message}`);
  try {
    return await closeThrowawayIssues(client);
  } finally {
    await client.auth.signOut();
  }
}
