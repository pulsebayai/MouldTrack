import * as ImageManipulator from 'expo-image-manipulator';
import * as ImagePicker from 'expo-image-picker';
import { createHash } from 'node:crypto';
import { MAX_BYTES, PhotoError, base64ToBytes, pickPhoto, preparePhoto, sha256Fallback, sha256Hex, signedPhotoUrl, uploadIssuePhoto, type Photo } from '@/lib/photos';

jest.mock('expo-image-manipulator', () => ({ manipulateAsync: jest.fn(), SaveFormat: { JPEG: 'jpeg' } }));
jest.mock('expo-image-picker', () => ({
  requestCameraPermissionsAsync: jest.fn(), launchCameraAsync: jest.fn(), launchImageLibraryAsync: jest.fn(),
}));

const manip = ImageManipulator.manipulateAsync as jest.Mock;
const ref = (b: Uint8Array) => createHash('sha256').update(b).digest('hex');

describe('sha256', () => {
  it.each([0, 1, 55, 56, 63, 64, 65, 1000, 70000])('fallback matches node for %i bytes', (n) => {
    const b = new Uint8Array(n).map((_, i) => (i * 31 + 7) & 255);
    expect(sha256Fallback(b)).toBe(ref(b));
  });
  it('sha256Hex agrees', async () => {
    const b = new TextEncoder().encode('mouldtrack');
    expect(await sha256Hex(b)).toBe(ref(b));
  });
});

describe('base64ToBytes', () => {
  it.each([0, 1, 2, 3, 4, 5, 100, 1001])('decodes %i bytes like node', (n) => {
    const b = new Uint8Array(n).map((_, i) => (i * 17 + 3) & 255);
    expect(Array.from(base64ToBytes(Buffer.from(b).toString('base64')))).toEqual(Array.from(b));
  });
});

describe('preparePhoto', () => {
  const bytes = new Uint8Array([1, 2, 3, 4, 5]);
  const b64 = Buffer.from(bytes).toString('base64');
  beforeEach(() => {
    manip.mockReset();
    manip.mockResolvedValue({ uri: 'file://out.jpg', base64: b64 });
  });
  it('resizes a landscape photo by width to 1600 and compresses at 0.7 as JPEG', async () => {
    const p = await preparePhoto('file://in.jpg', 4000, 3000);
    expect(manip).toHaveBeenCalledWith('file://in.jpg', [{ resize: { width: 1600 } }], { compress: 0.7, format: 'jpeg', base64: true });
    expect(p).toMatchObject({ uri: 'file://out.jpg', mime: 'image/jpeg', sha256: ref(bytes) });
    expect(Array.from(p.bytes)).toEqual(Array.from(bytes));
  });
  it('resizes a portrait photo by height and never upsizes', async () => {
    await preparePhoto('x', 3000, 4000);
    expect(manip).toHaveBeenLastCalledWith('x', [{ resize: { height: 1600 } }], expect.anything());
    await preparePhoto('x', 800, 600);
    expect(manip).toHaveBeenLastCalledWith('x', [{ resize: { width: 800 } }], expect.anything());
  });
  it('refuses an oversize result', async () => {
    manip.mockResolvedValue({ uri: 'u', base64: Buffer.alloc(MAX_BYTES + 1).toString('base64') });
    await expect(preparePhoto('x', 10, 10)).rejects.toMatchObject({ code: 'too_large' });
  });
  it('reports an unreadable result', async () => {
    manip.mockResolvedValue({ uri: 'u' });
    await expect(preparePhoto('x', 10, 10)).rejects.toBeInstanceOf(PhotoError);
  });
});

describe('pickPhoto', () => {
  beforeEach(() => {
    jest.clearAllMocks();
    manip.mockResolvedValue({ uri: 'file://out.jpg', base64: Buffer.from([9]).toString('base64') });
  });
  it('asks for camera permission and stops when refused', async () => {
    (ImagePicker.requestCameraPermissionsAsync as jest.Mock).mockResolvedValue({ granted: false });
    await expect(pickPhoto('camera')).rejects.toMatchObject({ code: 'permission' });
    expect(ImagePicker.launchCameraAsync).not.toHaveBeenCalled();
  });
  it('returns null when cancelled', async () => {
    (ImagePicker.launchImageLibraryAsync as jest.Mock).mockResolvedValue({ canceled: true, assets: null });
    expect(await pickPhoto('library')).toBeNull();
  });
  it('prepares the chosen asset', async () => {
    (ImagePicker.requestCameraPermissionsAsync as jest.Mock).mockResolvedValue({ granted: true });
    (ImagePicker.launchCameraAsync as jest.Mock).mockResolvedValue({ canceled: false, assets: [{ uri: 'file://a', width: 2000, height: 1000 }] });
    const p = await pickPhoto('camera');
    expect(p?.mime).toBe('image/jpeg');
  });
});

describe('uploadIssuePhoto', () => {
  const photo: Photo = { uri: 'u', bytes: new Uint8Array([1, 2, 3]), mime: 'image/jpeg', sha256: 'ab'.repeat(32) };
  const ids = { begin: 'b1', commit: 'c1' };
  function client(opts: { status?: string; uploadError?: unknown } = {}) {
    const upload = jest.fn().mockResolvedValue({ error: opts.uploadError ?? null });
    const rpc = jest.fn(async (fn: string) =>
      fn === 'iss_attachment_begin'
        ? { data: { ok: true, id: 'a1', path: 'tenant/t/issue/i/a1.jpg', action_id: 'x1', status: opts.status ?? 'pending' }, error: null, status: 200 }
        : { data: { ok: true }, error: null, status: 200 });
    return { rpc, upload, c: { rpc, storage: { from: jest.fn(() => ({ upload })) } } as never };
  }
  it('begins, uploads to the returned path, then commits', async () => {
    const { rpc, upload, c } = client();
    expect(await uploadIssuePhoto(c, 'i', photo, ids)).toEqual({ attachmentId: 'a1', actionId: 'x1' });
    expect(rpc).toHaveBeenNthCalledWith(1, 'iss_attachment_begin', { p_request_id: 'b1', p_issue_id: 'i', p_mime: 'image/jpeg', p_size: 3, p_sha256: photo.sha256 });
    expect(upload).toHaveBeenCalledWith('tenant/t/issue/i/a1.jpg', photo.bytes, { contentType: 'image/jpeg', upsert: false });
    expect(rpc).toHaveBeenNthCalledWith(2, 'iss_attachment_commit', { p_request_id: 'c1', p_attachment_id: 'a1' });
  });
  it('does nothing more when the attachment is already ready (replay)', async () => {
    const { rpc, upload, c } = client({ status: 'ready' });
    await uploadIssuePhoto(c, 'i', photo, ids);
    expect(upload).not.toHaveBeenCalled();
    expect(rpc).toHaveBeenCalledTimes(1);
  });
  it('commits when the object is already in Storage (retry)', async () => {
    const { rpc, c } = client({ uploadError: { statusCode: '409', message: 'The resource already exists' } });
    await uploadIssuePhoto(c, 'i', photo, ids);
    expect(rpc).toHaveBeenCalledTimes(2);
  });
  it('does not commit when the upload fails', async () => {
    const { rpc, c } = client({ uploadError: { statusCode: '500', message: 'boom' } });
    await expect(uploadIssuePhoto(c, 'i', photo, ids)).rejects.toMatchObject({ message: 'boom' });
    expect(rpc).toHaveBeenCalledTimes(1);
  });
});

describe('signedPhotoUrl', () => {
  it('asks for a 300 s URL and returns null on error', async () => {
    const createSignedUrl = jest.fn().mockResolvedValueOnce({ data: { signedUrl: 'https://s/x' }, error: null }).mockResolvedValueOnce({ data: null, error: { message: 'no' } });
    const c = { storage: { from: () => ({ createSignedUrl }) } } as never;
    expect(await signedPhotoUrl(c, 'p')).toBe('https://s/x');
    expect(createSignedUrl).toHaveBeenCalledWith('p', 300);
    expect(await signedPhotoUrl(c, 'p')).toBeNull();
  });
});
