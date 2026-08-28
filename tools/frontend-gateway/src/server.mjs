import { createServer as createHttpServer, request as httpRequest } from 'node:http';
import { request as httpsRequest } from 'node:https';
import { createReadStream } from 'node:fs';
import { stat, readdir, readFile } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import { extname, relative, resolve, sep } from 'node:path';
import { createMockState, handleMock, acceptMockWebSocket } from './mock.mjs';
import { BackendRegistry } from './backend_registry.mjs';

const mime = new Map([
  ['.html', 'text/html; charset=utf-8'], ['.js', 'text/javascript; charset=utf-8'], ['.mjs', 'text/javascript; charset=utf-8'],
  ['.json', 'application/json; charset=utf-8'], ['.wasm', 'application/wasm'], ['.png', 'image/png'], ['.svg', 'image/svg+xml'],
  ['.ttf', 'font/ttf'], ['.woff2', 'font/woff2'], ['.zip', 'application/zip'], ['.glb', 'model/gltf-binary']
]);

function securityHeaders(reply) {
  reply.setHeader('cross-origin-opener-policy', 'same-origin');
  reply.setHeader('cross-origin-embedder-policy', 'require-corp');
  reply.setHeader('cross-origin-resource-policy', 'same-origin');
  reply.setHeader('x-content-type-options', 'nosniff');
  reply.setHeader('referrer-policy', 'no-referrer');
}

function json(reply, status, body) {
  const bytes = Buffer.from(JSON.stringify(body));
  reply.writeHead(status, { 'content-type': 'application/json; charset=utf-8', 'content-length': bytes.length });
  reply.end(bytes);
}

async function jsonBody(request, maximumBytes = 16 * 1024) {
  const chunks = [];
  let size = 0;
  for await (const chunk of request) {
    size += chunk.length;
    if (size > maximumBytes) throw new Error('Request body is too large.');
    chunks.push(chunk);
  }
  if (size === 0) return {};
  return JSON.parse(Buffer.concat(chunks).toString('utf8'));
}

function hostAllowed(request, config) {
  const host = String(request.headers.host ?? '').toLowerCase();
  if (config.allowedHosts.has(host)) return true;
  const hostname = host.startsWith('[') ? host.slice(0, host.indexOf(']') + 1) : host.split(':')[0];
  return config.allowedHosts.has(hostname);
}

function originAllowed(request, config) {
  const origin = String(request.headers.origin ?? '');
  if (!origin) return true;
  if (config.allowedOrigins.has(origin)) return true;
  try { return new URL(origin).host.toLowerCase() === String(request.headers.host ?? '').toLowerCase(); }
  catch { return false; }
}

function routeFor(path, config) {
  return config.targets.find((candidate) => path === candidate.prefix || path.startsWith(`${candidate.prefix}/`));
}

function upstreamPath(url, route) {
  if (!route.strip) return url;
  const parsed = new URL(url, 'http://gateway.local');
  parsed.pathname = parsed.pathname.slice(route.prefix.length) || '/';
  return `${parsed.pathname}${parsed.search}`;
}

function proxyHttp(request, reply, route) {
  const target = new URL(route.target);
  const headers = { ...request.headers, host: target.host };
  delete headers.origin;
  if (route.token) headers.authorization = `Bearer ${route.token}`;
  const transport = target.protocol === 'https:' ? httpsRequest : httpRequest;
  const upstream = transport({ protocol: target.protocol, hostname: target.hostname, port: target.port, method: request.method, path: upstreamPath(request.url, route), headers }, (response) => {
    const responseHeaders = { ...response.headers };
    delete responseHeaders['access-control-allow-origin'];
    reply.writeHead(response.statusCode ?? 502, responseHeaders);
    response.pipe(reply);
  });
  upstream.on('error', (error) => {
    if (!reply.headersSent) json(reply, 502, { error: { code: 'upstream_unavailable', message: error.message, retryable: true } });
    else reply.destroy(error);
  });
  request.pipe(upstream);
}

function proxyUpgrade(request, socket, head, route) {
  const target = new URL(route.target);
  const headers = { ...request.headers, host: target.host };
  if (route.token) headers.authorization = `Bearer ${route.token}`;
  const transport = target.protocol === 'https:' ? httpsRequest : httpRequest;
  const upstream = transport({ protocol: target.protocol, hostname: target.hostname, port: target.port, method: 'GET', path: upstreamPath(request.url, route), headers });
  upstream.on('upgrade', (response, upstreamSocket, upstreamHead) => {
    socket.write(`HTTP/1.1 101 Switching Protocols\r\n${Object.entries(response.headers).map(([key, value]) => `${key}: ${value}`).join('\r\n')}\r\n\r\n`);
    if (head.length) upstreamSocket.write(head);
    if (upstreamHead.length) socket.write(upstreamHead);
    upstreamSocket.pipe(socket).pipe(upstreamSocket);
  });
  upstream.on('response', (response) => { socket.end(`HTTP/1.1 ${response.statusCode ?? 502} Upstream rejected upgrade\r\n\r\n`); });
  upstream.on('error', () => socket.destroy());
  upstream.end();
}

async function serveFile(reply, root, requestPath, prefix, defaultFile = 'index.html') {
  if (!root) return false;
  let decoded;
  try { decoded = decodeURIComponent(requestPath.slice(prefix.length)); }
  catch { return false; }
  const relativePath = decoded.replace(/^\/+/, '') || defaultFile;
  const file = resolve(root, relativePath);
  const safeRoot = resolve(root);
  if (file !== safeRoot && !file.startsWith(`${safeRoot}${sep}`)) return false;
  try {
    const info = await stat(file);
    if (!info.isFile()) return false;
    reply.writeHead(200, { 'content-type': mime.get(extname(file)) ?? 'application/octet-stream', 'content-length': info.size, 'cache-control': relativePath.endsWith('.wasm') ? 'public, max-age=31536000, immutable' : 'no-cache' });
    createReadStream(file).pipe(reply);
    return true;
  } catch { return false; }
}

async function buildProjectManifest(root) {
  const files = [];
  async function visit(directory) {
    for (const entry of await readdir(directory, { withFileTypes: true })) {
      if (['.godot', '.future_engine', '.future_engine_cache', '.future_engine_generated'].includes(entry.name)) continue;
      const path = resolve(directory, entry.name);
      if (entry.isDirectory()) await visit(path);
      else if (entry.isFile() && !entry.name.endsWith('.import')) {
        const bytes = await readFile(path);
        files.push({ path: relative(root, path).split(sep).join('/'), size_bytes: bytes.length, sha256: `sha256:${createHash('sha256').update(bytes).digest('hex')}` });
      }
    }
  }
  await visit(root);
  files.sort((left, right) => left.path.localeCompare(right.path));
  const version = createHash('sha256').update(JSON.stringify(files)).digest('hex').slice(0, 16);
  return { schema_version: 'future-engine.web-project-manifest.v1', version, project_directory: `FutureEngineDesktop-${version}`, files: files.map((file) => ({ ...file, url: `/project/${file.path.split('/').map(encodeURIComponent).join('/')}` })) };
}

async function readiness(registry) {
  const state = await registry.refresh();
  const services = Object.fromEntries(state.services.map((service) => [service.id, service.status]));
  const liveReady = state.effective_mode === 'upstream' && state.all_ports_available;
  return {
    status: state.effective_mode === 'mock' || liveReady ? 'ready' : 'degraded',
    mode: state.effective_mode,
    requested_mode: state.requested_mode,
    selected_server: state.selected_server,
    all_ports_available: state.all_ports_available,
    services
  };
}

export async function createGateway(config, options = {}) {
  const backendRegistry = options.backendRegistry ?? new BackendRegistry(config, options.registryOptions);
  await backendRegistry.refresh(true);
  const mockState = await createMockState();
  const projectManifest = await buildProjectManifest(config.projectRoot);
  const server = createHttpServer(async (request, reply) => {
    securityHeaders(reply);
    if (!hostAllowed(request, config)) return json(reply, 421, { error: { code: 'host_not_allowed', message: 'Host is not allowed.' } });
    if (!originAllowed(request, config)) return json(reply, 403, { error: { code: 'origin_not_allowed', message: 'Origin is not allowed.' } });
    if (request.method === 'OPTIONS') { reply.writeHead(204, { allow: 'GET,HEAD,POST,PUT,PATCH,DELETE,OPTIONS' }); return reply.end(); }
    const parsedUrl = new URL(request.url, 'http://gateway.local');
    const path = parsedUrl.pathname;
    if (path === '/healthz') {
      const state = await backendRegistry.refresh();
      return json(reply, 200, { status: 'ok', mode: state.effective_mode, requested_mode: state.requested_mode, selected_server: state.selected_server, version: '0.2.0', presentation_contract: 'future-engine.system-design-presentation.v1' });
    }
    if (path === '/readyz') {
      const state = await readiness(backendRegistry);
      return json(reply, state.status === 'ready' ? 200 : 503, state);
    }
    if (path === '/gateway/configuration' && request.method === 'GET') {
      return json(reply, 200, await backendRegistry.refresh(parsedUrl.searchParams.get('refresh') === '1'));
    }
    if (path === '/gateway/configuration' && request.method === 'POST') {
      try {
        return json(reply, 200, await backendRegistry.select(await jsonBody(request)));
      } catch (error) {
        return json(reply, 400, { error: { code: 'invalid_backend_configuration', message: error instanceof Error ? error.message : String(error), retryable: false } });
      }
    }
    if (path === '/project-manifest.json') return json(reply, 200, projectManifest);
    if (await serveFile(reply, config.publicRoot, path, '/')) return;
    if (path.startsWith('/editor/') && await serveFile(reply, config.webEditorRoot, path, '/editor/')) return;
    if (path.startsWith('/project/') && await serveFile(reply, config.projectRoot, path, '/project/')) return;
    const backendState = await backendRegistry.refresh();
    if (backendState.effective_mode === 'mock') {
      if (await handleMock(request, reply, mockState)) return;
      return json(reply, 404, { error: { code: 'mock_route_unavailable', message: 'This endpoint is not implemented by the explicit mock backend.' } });
    }
    const route = routeFor(path, config);
    if (route) return proxyHttp(request, reply, backendRegistry.selectedRoute(route));
    return json(reply, 404, { error: { code: 'not_found', message: 'Gateway route not found.' } });
  });
  server.on('upgrade', async (request, socket, head) => {
    if (!hostAllowed(request, config) || !originAllowed(request, config)) return socket.destroy();
    const backendState = await backendRegistry.refresh();
    if (backendState.effective_mode === 'mock') {
      if (acceptMockWebSocket(request, socket, mockState)) return;
      return socket.destroy();
    }
    const route = routeFor(new URL(request.url, 'http://gateway.local').pathname, config);
    if (!route) return socket.destroy();
    proxyUpgrade(request, socket, head, backendRegistry.selectedRoute(route));
  });
  return { server, mockState, backendRegistry };
}

export async function listenGateway(config) {
  const gateway = await createGateway(config);
  await new Promise((resolvePromise, reject) => {
    gateway.server.once('error', reject);
    gateway.server.listen(config.port, config.host, resolvePromise);
  });
  return gateway;
}
