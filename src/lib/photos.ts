import type { SupabaseClient } from '@supabase/supabase-js';
import { File, Paths } from 'expo-file-system';
import * as ImageManipulator from 'expo-image-manipulator';
import * as ImagePicker from 'expo-image-picker';
import { Platform } from 'react-native';
import { call, type RpcClient } from './plant';

export const MAX_EDGE = 1600;
export const JPEG_QUALITY = 0.7;
export const MAX_BYTES = 5 * 1024 * 1024;
export const BUCKET = 'attachments';

export type Photo = { uri: string; bytes: Uint8Array; mime: 'image/jpeg'; sha256: string };

// ---- SHA-256 -----------------------------------------------------------------------------------------------------------------------------
// WebCrypto where it exists (web, Node); a small pure-TS implementation on Hermes (no extra native module, D7). Photos are resized to at most
// a few hundred KB first, so the fallback costs well under a second.
const K = new Uint32Array([
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe,
  0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da, 0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
  0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b,
  0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070, 0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
  0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
]);
const rotr = (x: number, n: number) => (x >>> n) | (x << (32 - n));

export function sha256Fallback(data: Uint8Array): string {
  const h = new Uint32Array([0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19]);
  const padded = new Uint8Array((((data.length + 9 + 63) >> 6) << 6));
  padded.set(data);
  padded[data.length] = 0x80;
  const view = new DataView(padded.buffer);
  view.setUint32(padded.length - 8, Math.floor(data.length / 0x20000000), false);
  view.setUint32(padded.length - 4, (data.length << 3) >>> 0, false);
  const w = new Uint32Array(64);
  for (let off = 0; off < padded.length; off += 64) {
    for (let i = 0; i < 16; i++) w[i] = view.getUint32(off + i * 4, false);
    for (let i = 16; i < 64; i++) {
      const s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >>> 3);
      const s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >>> 10);
      w[i] = (w[i - 16] + s0 + w[i - 7] + s1) >>> 0;
    }
    let [a, b, c, d, e, f, g, hh] = h;
    for (let i = 0; i < 64; i++) {
      const t1 = (hh + (rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)) + ((e & f) ^ (~e & g)) + K[i] + w[i]) >>> 0;
      const t2 = ((rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)) + ((a & b) ^ (a & c) ^ (b & c))) >>> 0;
      hh = g; g = f; f = e; e = (d + t1) >>> 0; d = c; c = b; b = a; a = (t1 + t2) >>> 0;
    }
    h[0] += a; h[1] += b; h[2] += c; h[3] += d; h[4] += e; h[5] += f; h[6] += g; h[7] += hh;
  }
  return Array.from(h, (x) => x.toString(16).padStart(8, '0')).join('');
}

export async function sha256Hex(data: Uint8Array): Promise<string> {
  const subtle = (globalThis as { crypto?: { subtle?: { digest: (a: string, d: Uint8Array) => Promise<ArrayBuffer> } } }).crypto?.subtle;
  if (subtle) {
    const buf = await subtle.digest('SHA-256', data);
    return Array.from(new Uint8Array(buf), (x) => x.toString(16).padStart(2, '0')).join('');
  }
  return sha256Fallback(data);
}

// ---- Picking and preparing -----------------------------------------------------------------------------------------------------------------
export class PhotoError extends Error {
  constructor(message: string, public code: 'permission' | 'too_large' | 'unreadable') {
    super(message);
    this.name = 'PhotoError';
  }
}

/** Resize so the longer edge is at most MAX_EDGE, re-encode as JPEG at quality 0.7 (this also drops EXIF), read the bytes and hash them. */
export function base64ToBytes(b64: string): Uint8Array {
  const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
  const clean = b64.replace(/[^A-Za-z0-9+/]/g, '');
  const out = new Uint8Array(Math.floor((clean.length * 3) / 4));
  let o = 0;
  for (let i = 0; i < clean.length; i += 4) {
    const n = [0, 1, 2, 3].map((k) => (i + k < clean.length ? chars.indexOf(clean[i + k]) : 0));
    const v = (n[0] << 18) | (n[1] << 12) | (n[2] << 6) | n[3];
    if (o < out.length) out[o++] = (v >> 16) & 255;
    if (o < out.length) out[o++] = (v >> 8) & 255;
    if (o < out.length) out[o++] = v & 255;
  }
  return out;
}

/**
 * Resize so the longer edge is at most MAX_EDGE, re-encode as JPEG at quality 0.7 (this also drops EXIF), take the bytes and hash them.
 * The bytes come from the manipulator's base64 output rather than fetch(uri): the web CSP does not allow fetching data: URLs (connect-src).
 */
export async function preparePhoto(uri: string, width: number, height: number): Promise<Photo> {
  const resize = width >= height ? { width: Math.min(width, MAX_EDGE) } : { height: Math.min(height, MAX_EDGE) };
  const out = await ImageManipulator.manipulateAsync(uri, [{ resize }], { compress: JPEG_QUALITY, format: ImageManipulator.SaveFormat.JPEG, base64: true });
  if (!out.base64) throw new PhotoError('That photo could not be read. Try another.', 'unreadable');
  const bytes = base64ToBytes(out.base64);
  if (bytes.length > MAX_BYTES) throw new PhotoError('That photo is too large. Try a smaller one.', 'too_large');
  return { uri: out.uri, bytes, mime: 'image/jpeg', sha256: await sha256Hex(bytes) };
}

/** Opens the camera (Android) or the file chooser (web) and returns a prepared photo, or null when the person cancels. */
export async function pickPhoto(source: 'camera' | 'library'): Promise<Photo | null> {
  if (source === 'camera') {
    const perm = await ImagePicker.requestCameraPermissionsAsync();
    if (!perm.granted) throw new PhotoError('Allow camera access to take a photo, or choose one from your files.', 'permission');
  }
  const opts: ImagePicker.ImagePickerOptions = { mediaTypes: ['images'], quality: 1, allowsMultipleSelection: false };
  const res = source === 'camera' ? await ImagePicker.launchCameraAsync(opts) : await ImagePicker.launchImageLibraryAsync(opts);
  if (res.canceled || !res.assets?.[0]) return null;
  const a = res.assets[0];
  return preparePhoto(a.uri, a.width, a.height);
}

// ---- Upload (two phases, D7) ---------------------------------------------------------------------------------------------------------------
type StorageClient = Pick<SupabaseClient, 'storage'>;
type Begin = { ok: true; id: string; path: string; action_id: string; status: 'pending' | 'ready'; already?: boolean };

function isAlreadyThere(e: { message?: string; statusCode?: string | number; status?: number }): boolean {
  return String(e.statusCode ?? e.status) === '409' || /already exists|duplicate/i.test(e.message ?? '');
}

/**
 * begin (server records a pending row and the path) -> upload to the private bucket -> commit (server checks size and type of the stored
 * object). The same two request ids are reused on retry, so a half-finished upload resumes instead of duplicating.
 */
export async function uploadIssuePhoto(
  client: RpcClient & StorageClient,
  issueId: string,
  photo: Photo,
  ids: { begin: string; commit: string },
): Promise<{ attachmentId: string; actionId: string }> {
  const b = (await call(client, 'iss_attachment_begin', {
    p_request_id: ids.begin, p_issue_id: issueId, p_mime: photo.mime, p_size: photo.bytes.length, p_sha256: photo.sha256,
  })) as unknown as Begin;
  if (b.status !== 'ready') {
    const { error } = await client.storage.from(BUCKET).upload(b.path, photo.bytes, { contentType: photo.mime, upsert: false });
    // A retry after the object arrived but commit did not: the object exists already (no UPDATE policy by design), so go on to commit.
    if (error && !isAlreadyThere(error)) throw error;
    await call(client, 'iss_attachment_commit', { p_request_id: ids.commit, p_attachment_id: b.id });
  }
  return { attachmentId: b.id, actionId: b.action_id };
}

export type LoadedPhoto = { uri: string; release: () => void };

/**
 * Reads a photo through an authenticated download, so Storage RLS is evaluated on every view (a signed URL would keep working after the
 * person lost access). Web: an object URL (revoked by `release`). Native: a file in the cache directory (no release needed).
 */
export async function downloadPhoto(client: StorageClient, path: string, key: string): Promise<LoadedPhoto | null> {
  const { data, error } = await client.storage.from(BUCKET).download(path);
  if (error || !data) return null;
  if (Platform.OS === 'web') {
    const url = URL.createObjectURL(data);
    return { uri: url, release: () => URL.revokeObjectURL(url) };
  }
  const file = new File(Paths.cache, `issue-photo-${key}.jpg`);
  file.create({ overwrite: true });
  await file.write(new Uint8Array(await data.arrayBuffer()));
  return { uri: file.uri, release: () => {} };
}
