import { resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const gatewayRoot = resolve(fileURLToPath(new URL('..', import.meta.url)));
const repositoryRoot = resolve(gatewayRoot, '../..');

function trimmed(value, fallback = '') {
  const result = String(value ?? '').trim();
  return result || fallback;
}

function list(value) {
  return trimmed(value).split(',').map((item) => item.trim()).filter(Boolean);
}

function isLoopback(host) {
  return host === '127.0.0.1' || host === '::1' || host === 'localhost';
}

export function loadConfig(env = process.env) {
  const host = trimmed(env.FE_GATEWAY_HOST, '127.0.0.1');
  const port = Number(trimmed(env.FE_GATEWAY_PORT, '8142'));
  const requestedMode = trimmed(env.FE_BACKEND_MODE, 'auto').toLowerCase();
  const mode = requestedMode === 'live' ? 'upstream' : requestedMode;
  const trustedPrivateNetwork = trimmed(env.FE_TRUSTED_PRIVATE_NETWORK, 'false') === 'true';
  const allowedHosts = list(env.FE_ALLOWED_HOSTS);
  const allowedOrigins = list(env.FE_ALLOWED_ORIGINS);

  if (!Number.isSafeInteger(port) || port < 0 || port > 65535) throw new Error('FE_GATEWAY_PORT must be an integer from 0 through 65535.');
  const discoveryTimeoutMs = Number(trimmed(env.FE_BACKEND_DISCOVERY_TIMEOUT_MS, '650'));
  if (!Number.isSafeInteger(discoveryTimeoutMs) || discoveryTimeoutMs < 50 || discoveryTimeoutMs > 10000) throw new Error('FE_BACKEND_DISCOVERY_TIMEOUT_MS must be an integer from 50 through 10000.');
  if (!['auto', 'upstream', 'mock'].includes(mode)) throw new Error('FE_BACKEND_MODE must be auto, upstream (or live), or mock.');
  if (!isLoopback(host) && !trustedPrivateNetwork) throw new Error('Non-loopback binding requires FE_TRUSTED_PRIVATE_NETWORK=true.');
  if (!isLoopback(host) && allowedHosts.length === 0) throw new Error('Non-loopback binding requires FE_ALLOWED_HOSTS.');
  if (!isLoopback(host) && allowedOrigins.length === 0) throw new Error('Non-loopback binding requires FE_ALLOWED_ORIGINS.');

  return {
    host,
    port,
    mode,
    trustedPrivateNetwork,
    allowedHosts: new Set(allowedHosts.length ? allowedHosts : ['127.0.0.1', '127.0.0.1:8142', 'localhost', 'localhost:8142', '[::1]', '[::1]:8142']),
    allowedOrigins: new Set(allowedOrigins),
    webEditorRoot: trimmed(env.FE_WEB_EDITOR_ROOT),
    projectRoot: resolve(trimmed(env.FE_GODOT_PROJECT_ROOT, resolve(repositoryRoot, 'godot-project'))),
    publicRoot: resolve(gatewayRoot, 'public'),
    selectedServer: trimmed(env.FE_BACKEND_SERVER, 'local'),
    configuredServers: list(env.FE_BACKEND_SERVERS),
    discoveryTimeoutMs,
    targets: [
      { id: 'engineering_schema', label: 'Engineering Schema', prefix: '/engineering-schema', target: trimmed(env.FE_ENGINEERING_SCHEMA_API_TARGET, 'http://127.0.0.1:8140'), strip: true },
      { id: 'node_design', label: 'Node Design', prefix: '/node-design', target: trimmed(env.FE_NODE_DESIGN_API_TARGET, 'http://127.0.0.1:8135'), strip: true, token: trimmed(env.FE_NODE_DESIGN_API_TOKEN) },
      { id: 'components', label: 'Components', prefix: '/components', target: trimmed(env.FE_COMPONENT_API_TARGET, 'http://127.0.0.1:8134'), strip: true, token: trimmed(env.FE_COMPONENT_API_TOKEN) },
      { id: 'simulation', label: 'Simulation', prefix: '/simulation', target: trimmed(env.FE_SIMULATION_API_TARGET, 'http://127.0.0.1:8136'), strip: true, token: trimmed(env.FE_SIMULATION_API_TOKEN) },
      { id: 'materials', label: 'Materials', prefix: '/materials', target: trimmed(env.FE_MATERIALS_API_TARGET, 'http://127.0.0.1:8141'), strip: true, token: trimmed(env.FE_MATERIALS_API_TOKEN) },
      { id: 'fea', label: 'FEA', prefix: '/fea', target: trimmed(env.FE_FEA_API_TARGET, 'http://127.0.0.1:8138'), strip: true, token: trimmed(env.FE_FEA_API_TOKEN) },
      { id: 'llm', label: 'LLM', prefix: '/llm', target: trimmed(env.FE_LLM_API_TARGET, 'http://127.0.0.1:8787'), strip: true, token: trimmed(env.FE_LLM_API_TOKEN) },
      { id: 'cad', label: 'CAD', prefix: '/api', target: trimmed(env.FE_CAD_API_TARGET, 'http://127.0.0.1:8123'), strip: false, token: trimmed(env.FE_CAD_API_TOKEN) }
    ]
  };
}

export { isLoopback, repositoryRoot };
