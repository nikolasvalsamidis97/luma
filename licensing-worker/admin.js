// Generates private admin files; never exposes an admin HTTP endpoint or prints keys.
import { mkdir, writeFile } from 'node:fs/promises';
import { resolve } from 'node:path';
import { random, digest } from './src/worker.js';
const [command, arg, other] = process.argv.slice(2);
const directory = resolve(import.meta.dirname, 'private');
await mkdir(directory, { recursive: true, mode: 0o700 });
let sql, id;
if (command === 'issue') {
  const seats = Number(arg || 2), label = other || 'Developer';
  if (!Number.isInteger(seats) || seats < 1 || seats > 100 || label.length > 120) throw new Error('Use: node admin.js issue [1–100 Macs] [label]');
  id = random(16);
  const key = 'LUMA-' + random(24).toUpperCase();
  const keyFile = resolve(directory, id + '.key.txt');
  await writeFile(keyFile, `Luma developer key: ${key}\nLicense ID: ${id}\nMac limit: ${seats}\n`, { mode: 0o600, flag: 'wx' });
  sql = `INSERT INTO licenses(id,key_hash,kind,trial_end,seats,label) VALUES('${id}','${await digest(key)}','developer',0,${seats},'${label.replaceAll("'", "''")}');\n`;
  console.log('Private key saved to: ' + keyFile);
} else if (command === 'revoke' || command === 'release-device') {
  id = arg;
  if (!/^[a-f0-9]{32}$/.test(id || '')) throw new Error('A 32-character license ID is required.');
  if (command === 'revoke') sql = `UPDATE licenses SET revoked=1 WHERE id='${id}';\n`;
  else {
    if (!/^[a-f0-9]{64}$/.test(other || '')) throw new Error('A 64-character device hash is required.');
    sql = `DELETE FROM devices WHERE license_id='${id}' AND device='${other}';\n`;
  }
} else throw new Error('Use: node admin.js issue [Macs] [label] | revoke LICENSE_ID | release-device LICENSE_ID DEVICE_HASH');
const sqlFile = resolve(directory, `${command}-${id}-${Date.now()}.sql`);
await writeFile(sqlFile, sql, { mode: 0o600, flag: 'wx' });
console.log('SQL prepared (not yet applied): ' + sqlFile);
console.log('Apply with Wrangler d1 execute to the intended test or production database. Keep the key file private.');
