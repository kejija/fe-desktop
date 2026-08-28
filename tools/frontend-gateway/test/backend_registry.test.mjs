import test from 'node:test';
import assert from 'node:assert/strict';
import { loadConfig } from '../src/config.mjs';
import { BackendRegistry } from '../src/backend_registry.mjs';
import { createGateway } from '../src/server.mjs';

const tailscaleServer = { id: 'tailscale:100.64.0.8', name: 'design-rig', dns_name: 'design-rig.example.ts.net', host: '100.64.0.8', source: 'tailscale', online: true };

test('auto selects live only when every FE service port is running', async () => {
  const config = loadConfig({ FE_BACKEND_MODE: 'auto' });
  const allRunning = new BackendRegistry(config, {
    discover: async () => ({ status: 'ready', servers: [tailscaleServer] }),
    probe: async () => true
  });
  const live = await allRunning.refresh(true);
  assert.equal(live.effective_mode, 'upstream');
  assert.equal(live.all_ports_available, true);
  assert.equal(live.services.length, 8);
  assert.ok(live.services.every((service) => service.status === 'running'));

  const oneMissing = new BackendRegistry(config, {
    discover: async () => ({ status: 'ready', servers: [tailscaleServer] }),
    probe: async (_host, port) => port !== 8138
  });
  const mock = await oneMissing.refresh(true);
  assert.equal(mock.effective_mode, 'mock');
  assert.equal(mock.services.find((service) => service.id === 'fea').status, 'offline');
});

test('selecting a Tailscale server rewrites service hosts without exposing tokens', async () => {
  const config = loadConfig({ FE_BACKEND_MODE: 'mock', FE_NODE_DESIGN_API_TOKEN: 'server-secret' });
  const registry = new BackendRegistry(config, {
    discover: async () => ({ status: 'ready', servers: [tailscaleServer] }),
    probe: async () => true
  });
  await registry.refresh(true);
  const state = await registry.select({ mode: 'live', server_id: tailscaleServer.id });
  assert.equal(state.effective_mode, 'upstream');
  assert.equal(state.selected_server.host, '100.64.0.8');
  assert.equal(new URL(registry.selectedRoute(config.targets.find((route) => route.id === 'node_design')).target).hostname, '100.64.0.8');
  assert.ok(!JSON.stringify(state).includes('server-secret'));
});

test('Tailscale IPv6 servers remain valid proxy targets', async () => {
  const ipv6 = { id: 'tailscale:fd7a:115c:a1e0::1', name: 'ipv6-rig', host: 'fd7a:115c:a1e0::1', source: 'tailscale', online: true };
  const config = loadConfig({ FE_BACKEND_MODE: 'mock' });
  const registry = new BackendRegistry(config, {
    discover: async () => ({ status: 'ready', servers: [ipv6] }),
    probe: async () => true
  });
  await registry.refresh(true);
  await registry.select({ mode: 'live', server_id: ipv6.id });
  const target = registry.selectedRoute(config.targets.find((route) => route.id === 'simulation')).target;
  assert.equal(target, 'http://[fd7a:115c:a1e0::1]:8136');
});

test('gateway configuration endpoint switches between mock and live', async (context) => {
  const config = loadConfig({ FE_BACKEND_MODE: 'mock', FE_GATEWAY_PORT: '0' });
  const gateway = await createGateway(config, { registryOptions: {
    discover: async () => ({ status: 'ready', servers: [tailscaleServer] }),
    probe: async () => true
  } });
  await new Promise((resolve) => gateway.server.listen(0, '127.0.0.1', resolve));
  context.after(() => new Promise((resolve) => gateway.server.close(resolve)));
  const port = gateway.server.address().port;
  const base = `http://127.0.0.1:${port}`;
  const initial = await fetch(`${base}/gateway/configuration`).then((response) => response.json());
  assert.equal(initial.effective_mode, 'mock');
  assert.ok(initial.servers.some((server) => server.source === 'tailscale'));
  const response = await fetch(`${base}/gateway/configuration`, {
    method: 'POST', headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ mode: 'auto', server_id: 'local' })
  });
  assert.equal(response.status, 200);
  const selected = await response.json();
  assert.equal(selected.requested_mode, 'auto');
  assert.equal(selected.effective_mode, 'upstream');
  assert.equal(selected.services.find((service) => service.id === 'cad').port, 8123);
});
