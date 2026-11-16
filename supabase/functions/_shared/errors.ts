// Maps SQL outcomes (D13) to HTTP responses. Messages are user-facing and never contain internals.
export class HttpError extends Error {
  constructor(public status: number, public body: Record<string, unknown>) {
    super(String(body.message ?? 'error'));
  }
}

export const NOT_ALLOWED = 'Not allowed';
export const EXPIRED_MESSAGE = 'Your temporary password has expired. Ask your Unit Admin to reset it.';
export const GENERIC_ERROR = 'Something went wrong. Try again.';

type RpcError = { message?: string; details?: string | null; code?: string } | null;

/** PostgREST error from a `raise exception ... detail '{"code":..,"field":..}'` (validation | duplicate | guard). */
export function fromRpcError(error: NonNullable<RpcError>): HttpError {
  let detail: { code?: string; field?: string } = {};
  try {
    detail = error.details ? JSON.parse(error.details) : {};
  } catch {
    detail = {};
  }
  const body: Record<string, unknown> = { message: error.message ?? GENERIC_ERROR };
  if (detail.field) body.field = detail.field;
  switch (detail.code) {
    case 'validation':
      return new HttpError(400, body);
    case 'duplicate':
      return new HttpError(409, body);
    case 'guard':
      return new HttpError(422, body);
    default:
      // Unknown database error: log the code only (no message, it may hold data), answer generically.
      console.error('rpc_error', error.code ?? 'unknown');
      return new HttpError(500, { message: GENERIC_ERROR });
  }
}

/** Unwraps a `{data, error}` rpc result: throws for raised errors and returned denials; returns the ok payload. */
export function unwrap(res: { data: unknown; error: RpcError }): Record<string, unknown> {
  if (res.error) throw fromRpcError(res.error);
  const data = (res.data ?? {}) as Record<string, unknown>;
  if (data.ok === false) {
    if (data.code === 'expired') throw new HttpError(403, { message: EXPIRED_MESSAGE });
    throw new HttpError(403, { message: NOT_ALLOWED });
  }
  return data;
}
