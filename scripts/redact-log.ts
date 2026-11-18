/** stdin -> stdout through the diagnostics redaction (tokens, JWTs, keys stripped; phones masked). `--hierarchy` first turns a Maestro hierarchy JSON into one line per on-screen element. */
import { redact, summarizeHierarchy } from '../e2e/diagnostics-format';

let data = '';
process.stdin.setEncoding('utf8');
process.stdin.on('data', (c) => (data += c));
process.stdin.on('end', () => process.stdout.write(process.argv.includes('--hierarchy') ? summarizeHierarchy(data) : redact(data)));
