/** Chainable PostgREST stand-in for screen tests: records every call and resolves with what the handler returns. */
export type Query = {
  table: string;
  select?: [string, unknown];
  filters: [string, ...unknown[]][];
  order?: unknown[];
  range?: [number, number];
  single?: boolean;
};
type Result = { data: unknown; count?: number | null; error: unknown };

export function fakeDb(handler: (q: Query) => Result | Promise<Result>) {
  const queries: Query[] = [];
  function builder(table: string) {
    const q: Query = { table, filters: [] };
    const self: Record<string, unknown> = {};
    const chain = (name: string) => (...args: unknown[]) => {
      if (name === 'select') q.select = [args[0] as string, args[1]];
      else if (name === 'order') q.order = args;
      else if (name === 'range') q.range = [args[0] as number, args[1] as number];
      else if (name === 'maybeSingle') {
        q.single = true;
        queries.push(q);
        return Promise.resolve(handler(q));
      } else q.filters.push([name, ...args]);
      return self;
    };
    for (const n of ['select', 'eq', 'or', 'ilike', 'order', 'range', 'maybeSingle']) self[n] = chain(n);
    self.then = (res: (v: Result) => unknown, rej: (e: unknown) => unknown) => {
      queries.push(q);
      return Promise.resolve(handler(q)).then(res, rej);
    };
    return self;
  }
  return {
    queries,
    client: {
      from: (table: string) => builder(table),
      auth: {
        getSession: async () => ({ data: { session: { access_token: 'jwt' } } }),
        signOut: jest.fn(async () => ({ error: null })),
      },
    },
  };
}
