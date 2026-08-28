import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { readFile } from 'node:fs/promises';
import { resolve } from 'node:path';

const root = resolve(import.meta.dirname, '..');
const tracked = execFileSync('git', ['ls-files'], { cwd: root, encoding: 'utf8' }).trim().split('\n').filter(Boolean);
const forbiddenFiles = new Set(['SConstruct', 'version.py']);
const forbiddenPrefixes = ['core/', 'drivers/', 'editor/', 'main/', 'modules/', 'platform/', 'scene/', 'servers/', 'thirdparty/'];

for (const file of tracked) {
  assert.ok(!forbiddenFiles.has(file), `${file} is an engine build file`);
  assert.ok(!forbiddenPrefixes.some((prefix) => file.startsWith(prefix)), `${file} is tracked Godot engine source`);
  assert.ok(!/\.(?:c|cc|cpp|cxx|h|hpp|a|so|dll|dylib)$/i.test(file), `${file} is a native source or library`);
}

const lock = JSON.parse(await readFile(resolve(root, 'godot-version.lock.json'), 'utf8'));
assert.equal(lock.version, '4.7.2');
assert.equal(lock.status, 'stable');
assert.match(lock.artifacts['linux-x86_64'].sha512, /^[a-f0-9]{128}$/);
assert.match(lock.artifacts['web-editor'].sha512, /^[a-f0-9]{128}$/);

const gdFiles = tracked.filter((file) => file.startsWith('godot-project/') && file.endsWith('.gd'));
for (const file of gdFiles) {
  const text = await readFile(resolve(root, file), 'utf8');
  assert.ok(!/FE_(?:COMPONENT|MATERIALS|LLM|SIMULATION|NODE_DESIGN)_API_TOKEN/.test(text), `${file} contains a service-token setting`);
}

process.stdout.write(`REPOSITORY_OK ${tracked.length} tracked files, ${gdFiles.length} GDScript files\n`);
