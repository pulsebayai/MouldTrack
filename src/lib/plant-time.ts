import type { SupabaseClient } from '@supabase/supabase-js';
import { fetchSite, fetchTenantTimezone } from './plant';

export const FALLBACK_TIMEZONE = 'Asia/Kolkata';

/** The plant's IANA timezone: the site's, else the tenant's default, else India (the only market in R1). */
export async function fetchPlantTimezone(client: Pick<SupabaseClient, 'from'>): Promise<string> {
  const site = await fetchSite(client);
  if (site?.timezone) return site.timezone;
  return (await fetchTenantTimezone(client)) ?? FALLBACK_TIMEZONE;
}

function parts(iso: string, timeZone: string): Record<string, string> | null {
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return null;
  const out: Record<string, string> = {};
  for (const p of new Intl.DateTimeFormat('en-GB', { timeZone, year: 'numeric', month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit', hourCycle: 'h23' }).formatToParts(d)) {
    out[p.type] = p.value;
  }
  return out;
}

/** "18 Nov 2026 00:00" in the plant's timezone (never the device's, never UTC): a 23:59 UTC reading belongs to the next plant day. */
export function formatPlantDateTime(iso: string, timeZone: string): string {
  const p = parts(iso, timeZone);
  return p ? `${p.day} ${p.month} ${p.year} ${p.hour}:${p.minute}` : iso;
}

/** "18 Nov 2026" in the plant's timezone. */
export function formatPlantDay(iso: string, timeZone: string): string {
  const p = parts(iso, timeZone);
  return p ? `${p.day} ${p.month} ${p.year}` : iso;
}
