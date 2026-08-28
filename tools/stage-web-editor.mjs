import { spawnSync } from 'node:child_process';
import { mkdir, readFile, rename, rm, writeFile } from 'node:fs/promises';
import { resolve } from 'node:path';

const root = resolve(import.meta.dirname, '..');
const download = spawnSync(process.execPath, [resolve(root, 'tools/download-godot.mjs'), 'web-editor'], { cwd: root, encoding: 'utf8', stdio: ['ignore', 'pipe', 'inherit'] });
if (download.status !== 0) process.exit(download.status ?? 1);
const archive = download.stdout.trim();
const staging = resolve(root, 'dist/web-editor.tmp');
const destination = resolve(root, 'dist/web-editor');
await rm(staging, { recursive: true, force: true });
await mkdir(staging, { recursive: true });
const extract = spawnSync('python3', ['-m', 'zipfile', '-e', archive, staging], { stdio: 'inherit' });
if (extract.status !== 0) process.exit(extract.status ?? 1);
await rm(destination, { recursive: true, force: true });
await rename(staging, destination);
const sourceHtml = resolve(destination, 'godot.editor.html');
let html = await readFile(sourceHtml, 'utf8');
const initMarker = "editor.init('godot.editor').then(function () {\n\t\t\tif (zip) {";
const initReplacement = `editor.init('godot.editor').then(async function () {
			let futureEngineProjectRoot = '';
			if (!zip) {
				const manifestResponse = await fetch('/project-manifest.json', { cache: 'no-store' });
				if (!manifestResponse.ok) throw new Error('Unable to load the Future Engine project manifest.');
				const manifest = await manifestResponse.json();
				if (manifest.schema_version !== 'future-engine.web-project-manifest.v1') throw new Error('Unsupported Future Engine project manifest.');
				futureEngineProjectRoot = '/home/web_user/' + manifest.project_directory;
				await Promise.all(manifest.files.map(async function (file) {
					const response = await fetch(file.url, { cache: 'no-store' });
					if (!response.ok) throw new Error('Unable to seed Future Engine project file ' + file.path);
					const bytes = await response.arrayBuffer();
					const digest = await crypto.subtle.digest('SHA-256', bytes);
					const actual = 'sha256:' + Array.from(new Uint8Array(digest), function (value) { return value.toString(16).padStart(2, '0'); }).join('');
					if (actual !== file.sha256) throw new Error('Future Engine project file digest mismatch for ' + file.path);
					editor.copyToFS(futureEngineProjectRoot + '/' + file.path, bytes);
				}));
				localStorage.setItem('futureEngineWebProjectVersion', manifest.version);
				window.futureEngineProjectSeed = { version: manifest.version, fileCount: manifest.files.length, root: futureEngineProjectRoot };
			}
			if (zip) {`;
if (!html.includes(initMarker)) throw new Error('Official web editor startup marker changed; refusing to create an unverified bootstrap shell.');
html = html.replace(initMarker, initReplacement);
const argsMarker = "const args = ['--project-manager', '--single-window'];\n\t\t\teditor.start({ 'args': args, 'persistentDrops': true }).then(function () {";
const argsReplacement = "const args = zip ? ['--project-manager', '--single-window'] : ['--editor', '--path', futureEngineProjectRoot, '--single-window'];\n\t\t\teditor.start({ 'args': args, 'persistentDrops': Boolean(zip) }).then(function () {";
if (!html.includes(argsMarker)) throw new Error('Official web editor argument marker changed; refusing to create an unverified bootstrap shell.');
html = html.replace(argsMarker, argsReplacement);
const startMarker = `document.getElementById('startButton').onclick = function () {
	preloadZip(document.getElementById('zip-file')).then(function (zip) {
		startEditor(zip);
	});
};`;
const startReplacement = `${startMarker}

// Future Engine's same-origin shell opens its pinned addon project directly.
window.addEventListener('load', function () {
	document.getElementById('startButton').disabled = true;
	startEditor();
}, { once: true });`;
if (!html.includes(startMarker)) throw new Error('Official web editor start-button marker changed; refusing to create an unverified bootstrap shell.');
html = html.replace(startMarker, startReplacement);
await writeFile(resolve(destination, 'index.html'), html);
process.stdout.write(`${destination}\n`);
