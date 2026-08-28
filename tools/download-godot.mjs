import { createHash } from 'node:crypto';
import { mkdir, readFile, writeFile } from 'node:fs/promises';
import { basename, resolve } from 'node:path';

const root = resolve(import.meta.dirname, '..');
const lock = JSON.parse(await readFile(resolve(root, 'godot-version.lock.json'), 'utf8'));
const key = process.argv[2];
if (!key || !lock.artifacts[key]) throw new Error(`Usage: node tools/download-godot.mjs <${Object.keys(lock.artifacts).join('|')}>`);

const artifact = lock.artifacts[key];
const asset = artifact.file;
const base = `https://github.com/godotengine/godot/releases/download/${lock.version}-${lock.status}`;
const [manifestResponse, assetResponse] = await Promise.all([fetch(lock.checksum_manifest), fetch(`${base}/${asset}`)]);
if (!manifestResponse.ok) throw new Error(`Checksum manifest download failed: HTTP ${manifestResponse.status}`);
if (!assetResponse.ok) throw new Error(`Artifact download failed: HTTP ${assetResponse.status}`);
const manifest = await manifestResponse.text();
const published = manifest.split('\n').map((line) => line.trim().split(/\s+/)).find((parts) => parts.at(-1) === asset)?.[0];
if (!published) throw new Error(`No SHA-512 entry for ${asset}`);
if (published !== artifact.sha512) throw new Error(`Published SHA-512 no longer matches the lock for ${asset}`);
const bytes = Buffer.from(await assetResponse.arrayBuffer());
const actual = createHash('sha512').update(bytes).digest('hex');
if (actual !== artifact.sha512) throw new Error(`SHA-512 mismatch for ${asset}`);
const directory = resolve(root, 'downloads', key);
await mkdir(directory, { recursive: true });
const output = resolve(directory, basename(asset));
await writeFile(output, bytes);
process.stdout.write(`${output}\n`);
