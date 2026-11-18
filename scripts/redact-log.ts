/** stdin -> stdout through the diagnostics redaction (tokens, JWTs, keys stripped; phones masked). Used for Maestro failure context in CI logs. */
import { redact } from '../e2e/diagnostics-format';

let data = '';
process.stdin.setEncoding('utf8');
process.stdin.on('data', (c) => (data += c));
process.stdin.on('end', () => process.stdout.write(redact(data)));
