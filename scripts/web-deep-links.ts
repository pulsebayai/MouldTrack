/**
 * Deep-link fix for EAS Hosting (r1-release-prep D3). `expo export` writes directory routes (`users/index.html`) but EAS Hosting answers
 * 404 for `/users`. After the export, every `<dir>/index.html` (not the root one) also gets a sibling `<dir>.html`, unless that file exists.
 * Usage: `npx tsx scripts/web-deep-links.ts dist`.
 */
import { copyFileSync, existsSync, readdirSync, statSync } from 'node:fs';
import { join } from 'node:path';

/** Returns the files written, relative to `root`, sorted. Never overwrites. */
export function addDeepLinkFiles(root: string): string[] {
  const written: string[] = [];
  const walk = (dir: string, rel: string): void => {
    for (const name of readdirSync(dir)) {
      const full = join(dir, name);
      if (!statSync(full).isDirectory()) continue;
      const r = rel ? `${rel}/${name}` : name;
      const index = join(full, 'index.html');
      const sibling = join(dir, `${name}.html`);
      if (existsSync(index) && !existsSync(sibling)) {
        copyFileSync(index, sibling);
        written.push(`${r}.html`);
      }
      walk(full, r);
    }
  };
  walk(root, '');
  return written.sort();
}

if (require.main === module) {
  const root = process.argv[2];
  if (!root || !existsSync(root)) {
    console.error('Usage: web-deep-links.ts <export dir>');
    process.exit(1);
  }
  const files = addDeepLinkFiles(root);
  console.log(`deep links: wrote ${files.length} file(s)${files.length ? `: ${files.join(', ')}` : ''}`);
}
