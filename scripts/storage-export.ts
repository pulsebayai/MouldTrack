/**
 * Nightly copy of prod photos (Storage bucket `attachments`) to an S3 bucket in ap-south-1 (R1, owner 2026-11-26).
 * Supabase Pro backups cover the database only; this is the photo half of the backup.
 *
 * Read-only on prod: lists and downloads with the service role, never writes, moves or deletes there.
 * Add-only on S3: copies objects the bucket does not hold yet (same key and size), never deletes or overwrites a different object
 * silently (a size mismatch is uploaded again; S3 versioning keeps the older copy).
 * Logs counts only, never object names, keys or URLs.
 *
 * Usage (storage-export.yml): PROD_SUPABASE_URL, PROD_SUPABASE_SERVICE_ROLE_KEY, PROD_SUPABASE_PROJECT_REF, DEV_SUPABASE_PROJECT_REF,
 * STAGING_SUPABASE_PROJECT_REF, BACKUP_S3_BUCKET, AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY  →  `npx tsx scripts/storage-export.ts`
 */
import { createClient } from '@supabase/supabase-js';

export const SOURCE_BUCKET = 'attachments';
export const REGION = 'ap-south-1';
const REF_RE = /^[a-z0-9]{20}$/;

export type Env = Record<string, string | undefined>;
export type Obj = { key: string; size: number };

const refuse = (why: string): never => {
  throw new Error(`Refusing: ${why}`);
};

/** The source must be exactly the prod project (never dev or staging); the destination bucket name must be set. */
export function assertExportTarget(env: Env): { url: string; ref: string; bucket: string } {
  const ref = env.PROD_SUPABASE_PROJECT_REF ?? '';
  if (!REF_RE.test(ref)) refuse('the prod project ref is not configured');
  for (const o of ['DEV', 'STAGING']) {
    const other = env[`${o}_SUPABASE_PROJECT_REF`] ?? '';
    if (!REF_RE.test(other)) refuse(`the ${o.toLowerCase()} project ref is not configured, so prod cannot be told apart from it`);
    if (other === ref) refuse(`the prod project ref equals the ${o.toLowerCase()} project ref`);
  }
  let host = '';
  try {
    host = new URL(env.PROD_SUPABASE_URL ?? '').hostname;
  } catch {
    host = '';
  }
  if (host !== `${ref}.supabase.co`) refuse('the API URL is not the prod project');
  if (!env.PROD_SUPABASE_SERVICE_ROLE_KEY) refuse('the prod service role key is missing');
  const bucket = env.BACKUP_S3_BUCKET ?? '';
  if (!/^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$/.test(bucket)) refuse('the backup bucket name is missing or invalid');
  return { url: `https://${ref}.supabase.co`, ref, bucket };
}

/** Objects to copy: present in the source and absent from the backup, or present with a different size. */
export function toCopy(source: Obj[], backup: Map<string, number>): Obj[] {
  return source.filter((o) => backup.get(o.key) !== o.size);
}

type Lister = (prefix: string, offset: number) => Promise<{ name: string; id: string | null; size: number | null }[]>;

/** Walks the bucket depth-first (folders have id null), 1000 entries per page. Bounded by `maxObjects`. */
export async function listAll(list: Lister, maxObjects = 500_000): Promise<Obj[]> {
  const out: Obj[] = [];
  const stack = [''];
  while (stack.length) {
    const prefix = stack.pop() as string;
    for (let offset = 0; ; offset += 1000) {
      const page = await list(prefix, offset);
      for (const e of page) {
        const path = prefix ? `${prefix}/${e.name}` : e.name;
        if (e.id === null) stack.push(path);
        else out.push({ key: path, size: e.size ?? 0 });
        if (out.length > maxObjects) refuse(`more than ${maxObjects} objects: raise the bound deliberately`);
      }
      if (page.length < 1000) break;
    }
  }
  return out;
}

async function main(): Promise<void> {
  const t = assertExportTarget(process.env);
  // Loaded here so the pure helpers above can be unit-tested without the AWS SDK (its ESM build does not load under Jest).
  const { ListObjectsV2Command, PutObjectCommand, S3Client } = await import('@aws-sdk/client-s3');
  const sb = createClient(t.url, process.env.PROD_SUPABASE_SERVICE_ROLE_KEY as string, { auth: { persistSession: false } });
  const s3 = new S3Client({ region: REGION });

  const source = await listAll(async (prefix, offset) => {
    const { data, error } = await sb.storage.from(SOURCE_BUCKET).list(prefix, { limit: 1000, offset, sortBy: { column: 'name', order: 'asc' } });
    if (error) throw new Error(`listing the prod bucket failed: ${error.message}`);
    return (data ?? []).map((e) => ({ name: e.name, id: e.id, size: (e.metadata as { size?: number } | null)?.size ?? null }));
  });

  const backup = new Map<string, number>();
  let token: string | undefined;
  do {
    const r = await s3.send(new ListObjectsV2Command({ Bucket: t.bucket, ContinuationToken: token }));
    for (const o of r.Contents ?? []) if (o.Key) backup.set(o.Key, o.Size ?? 0);
    token = r.IsTruncated ? r.NextContinuationToken : undefined;
  } while (token);

  const copy = toCopy(source, backup);
  let bytes = 0;
  for (const o of copy) {
    const { data, error } = await sb.storage.from(SOURCE_BUCKET).download(o.key);
    if (error || !data) throw new Error(`a download from the prod bucket failed: ${error?.message ?? 'no data'}`);
    const body = Buffer.from(await data.arrayBuffer());
    await s3.send(new PutObjectCommand({ Bucket: t.bucket, Key: o.key, Body: body, ContentType: data.type || undefined }));
    bytes += body.length;
  }
  const line = `photo backup: ${source.length} object(s) in prod, ${backup.size} already in the backup, copied ${copy.length} (${(bytes / 1048576).toFixed(1)} MB)`;
  console.log(line);
  if (process.env.GITHUB_STEP_SUMMARY) {
    const { appendFileSync } = await import('node:fs');
    appendFileSync(process.env.GITHUB_STEP_SUMMARY, `### Prod photo backup\n- ${line}\n`);
  }
}

if (require.main === module) {
  main().catch((e: unknown) => {
    console.error(e instanceof Error ? e.message : String(e));
    process.exit(1);
  });
}
