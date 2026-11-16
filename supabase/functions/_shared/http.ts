import { GENERIC_ERROR, HttpError } from './errors.ts';

const LOCAL_ORIGINS = ['http://localhost:8081', 'http://127.0.0.1:8081'];

function allowedOrigins(): string[] {
  const extra = (Deno.env.get('ALLOWED_ORIGINS') ?? '').split(',').map((s) => s.trim()).filter(Boolean);
  return [...LOCAL_ORIGINS, ...extra];
}

export function corsHeaders(req: Request): Record<string, string> {
  const headers: Record<string, string> = {
    'Access-Control-Allow-Headers': 'authorization, content-type, apikey, x-client-info',
    'Access-Control-Allow-Methods': 'POST, OPTIONS',
    'Access-Control-Max-Age': '600',
    Vary: 'Origin',
  };
  const origin = req.headers.get('origin');
  if (origin && allowedOrigins().includes(origin)) headers['Access-Control-Allow-Origin'] = origin;
  return headers;
}

export function json(req: Request, status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders(req), 'Content-Type': 'application/json', 'Cache-Control': 'no-store' },
  });
}

export type Handler = (req: Request, body: Record<string, unknown>) => Promise<Record<string, unknown>>;

/** POST + JSON only. Errors become `{message, field?}`; request bodies and thrown messages are never logged. */
export function serveJson(handler: Handler): void {
  Deno.serve(async (req) => {
    if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: corsHeaders(req) });
    if (req.method !== 'POST') return json(req, 405, { message: 'Method not allowed' });
    try {
      let body: Record<string, unknown>;
      try {
        const parsed = await req.json();
        if (parsed === null || typeof parsed !== 'object' || Array.isArray(parsed)) throw new Error('shape');
        body = parsed as Record<string, unknown>;
      } catch {
        throw new HttpError(400, { message: 'Send a JSON object' });
      }
      return json(req, 200, await handler(req, body));
    } catch (e) {
      if (e instanceof HttpError) return json(req, e.status, e.body);
      console.error('unhandled', e instanceof Error ? e.name : typeof e);
      return json(req, 500, { message: GENERIC_ERROR });
    }
  });
}

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export function requireUuid(body: Record<string, unknown>, field: string): string {
  const v = body[field];
  if (typeof v !== 'string' || !UUID.test(v)) throw new HttpError(400, { field, message: `${field} must be a UUID` });
  return v.toLowerCase();
}

export function optionalString(body: Record<string, unknown>, field: string): string | null {
  const v = body[field];
  if (v === undefined || v === null) return null;
  if (typeof v !== 'string') throw new HttpError(400, { field, message: `${field} must be text` });
  return v;
}

export function requireString(body: Record<string, unknown>, field: string): string {
  const v = optionalString(body, field);
  if (v === null) throw new HttpError(400, { field, message: `${field} is required` });
  return v;
}
