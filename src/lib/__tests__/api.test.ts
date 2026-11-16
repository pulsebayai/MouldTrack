import { ApiError, accountApi, callFunction, newRequestId, userAdminApi } from '@/lib/api';

const deps = (fetchImpl: jest.Mock) => ({ baseUrl: 'http://api.test', anonKey: 'anon', fetchImpl: fetchImpl as never });
const client = (token: string | null) => ({ auth: { getSession: async () => ({ data: { session: token ? { access_token: token } : null } }) } }) as never;
const reply = (status: number, body: unknown) => jest.fn(async () => ({ ok: status >= 200 && status < 300, status, json: async () => body }));

describe('newRequestId', () => {
  it('returns RFC 4122 v4 ids that differ each time', () => {
    const ids = Array.from({ length: 50 }, newRequestId);
    for (const id of ids) expect(id).toMatch(/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/);
    expect(new Set(ids).size).toBe(50);
  });
});

describe('callFunction', () => {
  it('POSTs JSON with the user token and the anon key', async () => {
    const f = reply(200, { ok: true });
    await expect(callFunction(client('jwt-1'), 'account', { action: 'x' }, deps(f))).resolves.toEqual({ ok: true });
    expect(f).toHaveBeenCalledWith('http://api.test/functions/v1/account', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', apikey: 'anon', Authorization: 'Bearer jwt-1' },
      body: JSON.stringify({ action: 'x' }),
    });
  });

  it('throws a 401 ApiError without a session and sends nothing', async () => {
    const f = reply(200, {});
    await expect(callFunction(client(null), 'account', {}, deps(f))).rejects.toMatchObject({ status: 401 });
    expect(f).not.toHaveBeenCalled();
  });

  it.each([
    [400, { field: 'phone', message: 'Enter a valid 10-digit Indian mobile number' }],
    [409, { field: 'phone', message: 'This phone number is already registered' }],
    [422, { field: 'self', message: 'You cannot do this to your own account' }],
    [403, { message: 'Not allowed' }],
  ])('maps %i to an ApiError carrying the server field and message', async (status, body) => {
    const err = await callFunction(client('t'), 'user-admin', {}, deps(reply(status, body))).catch((e) => e);
    expect(err).toBeInstanceOf(ApiError);
    expect(err).toMatchObject({ status, field: (body as { field?: string }).field, message: body.message });
  });

  it('never shows raw server text for 5xx or unreadable bodies', async () => {
    const f = jest.fn(async () => ({ ok: false, status: 500, json: async () => { throw new Error('<html>boom</html>'); } }));
    const err = await callFunction(client('t'), 'user-admin', {}, deps(f)).catch((e) => e);
    expect(err).toMatchObject({ status: 500, message: 'Something went wrong. Please try again.' });
  });

  it('lets network failures propagate for the network message', async () => {
    const f = jest.fn(async () => { throw new TypeError('Network request failed'); });
    await expect(callFunction(client('t'), 'user-admin', {}, deps(f as never))).rejects.toThrow('Network request failed');
  });
});

describe('typed wrappers', () => {
  it('userAdmin.create sends the action, the request id and the fields', async () => {
    const f = reply(200, { user_id: 'u9', temp_password: 'Abcdefgh2345' });
    const out = await userAdminApi.create(client('t'), { full_name: 'A', employee_id: 'E1', phone: '9876543210', role: 'supervisor' }, 'rid-1', deps(f));
    expect(out).toEqual({ user_id: 'u9', temp_password: 'Abcdefgh2345' });
    expect(JSON.parse((f.mock.calls[0] as unknown as [string, { body: string }])[1].body)).toEqual({
      action: 'create', request_id: 'rid-1', full_name: 'A', employee_id: 'E1', phone: '9876543210', role: 'supervisor',
    });
  });
  it('update, setStatus and resetPassword use their actions', async () => {
    const f = reply(200, { ok: true });
    await userAdminApi.update(client('t'), 'u1', { full_name: 'B' }, 'r2', deps(f));
    await userAdminApi.setStatus(client('t'), 'u1', 'inactive', 'r3', deps(f));
    await userAdminApi.resetPassword(client('t'), 'u1', 'r4', deps(f));
    const bodies = f.mock.calls.map((c) => JSON.parse((c as unknown as [string, { body: string }])[1].body));
    expect(bodies).toEqual([
      { action: 'update', request_id: 'r2', user_id: 'u1', full_name: 'B' },
      { action: 'set_status', request_id: 'r3', user_id: 'u1', status: 'inactive' },
      { action: 'reset_password', request_id: 'r4', user_id: 'u1' },
    ]);
  });
  it('account.changePassword calls the account function', async () => {
    const f = reply(200, { ok: true });
    await accountApi.changePassword(client('t'), 'old-pass-1', 'new-pass-22', deps(f));
    expect((f.mock.calls[0] as unknown as [string])[0]).toBe('http://api.test/functions/v1/account');
    expect(JSON.parse((f.mock.calls[0] as unknown as [string, { body: string }])[1].body)).toEqual({
      action: 'change_password', current_password: 'old-pass-1', new_password: 'new-pass-22',
    });
  });
});
