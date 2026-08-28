import test from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { loadConfig } from '../src/config.mjs';
import { createGateway } from '../src/server.mjs';

async function running() {
  const config = loadConfig({ FE_BACKEND_MODE: 'mock', FE_GATEWAY_PORT: '0' });
  const gateway = await createGateway(config, { registryOptions: { discover: async () => ({ status: 'not_installed', servers: [] }), probe: async () => false } });
  await new Promise((resolve) => gateway.server.listen(0, '127.0.0.1', resolve));
  const { port } = gateway.server.address();
  return { ...gateway, base: `http://127.0.0.1:${port}` };
}

test('mock gateway exposes health, design, presentation, and verified assets', async (context) => {
  const gateway = await running();
  context.after(() => new Promise((resolve) => gateway.server.close(resolve)));
  const health = await fetch(`${gateway.base}/healthz`).then((response) => response.json());
  assert.equal(health.mode, 'mock');
  const list = await fetch(`${gateway.base}/node-design/v1/designs`).then((response) => response.json());
  assert.equal(list.data[0].design_id, 'demo-drive');

  const missingPrecondition = await fetch(`${gateway.base}/node-design/v1/designs/demo-drive/presentation?profile_id=default`);
  assert.equal(missingPrecondition.status, 428);
  const response = await fetch(`${gateway.base}/node-design/v1/designs/demo-drive/presentation?profile_id=default`, { headers: { 'if-match': '3' } });
  assert.equal(response.status, 200);
  assert.equal(response.headers.get('etag'), '"3"');
  const presentation = await response.json();
  assert.equal(presentation.schema_version, 'future-engine.system-design-presentation.v1');
  assert.ok(presentation.relationships.length >= 7);
  assert.ok(presentation.instances.some((instance) => instance.interfaces.some((port) => port.interface_id === 'tool-output')));

  const assetResponse = await fetch(`${gateway.base}/components${presentation.instances[0].model.asset_path}`);
  const asset = Buffer.from(await assetResponse.arrayBuffer());
  assert.equal(`sha256:${createHash('sha256').update(asset).digest('hex')}`, presentation.instances[0].model.sha256);
  assert.equal(asset.length, presentation.instances[0].model.size_bytes);
});

test('mock draft updates require the loaded revision', async (context) => {
  const gateway = await running();
  context.after(() => new Promise((resolve) => gateway.server.close(resolve)));
  const document = await fetch(`${gateway.base}/node-design/v1/designs/demo-drive`).then((response) => response.json());
  const conflict = await fetch(`${gateway.base}/node-design/v1/designs/demo-drive/draft`, { method: 'PUT', headers: { 'content-type': 'application/json', 'if-match': '2' }, body: JSON.stringify({ design: document.draft.design }) });
  assert.equal(conflict.status, 409);
  const saved = await fetch(`${gateway.base}/node-design/v1/designs/demo-drive/draft`, { method: 'PUT', headers: { 'content-type': 'application/json', 'if-match': '3' }, body: JSON.stringify({ design: document.draft.design }) });
  assert.equal(saved.status, 200);
  const result = await saved.json();
  assert.deepEqual(Object.keys(result), ['draft']);
  assert.equal(result.draft.revision_number, 4);
});

test('responses use cross-origin isolation headers', async (context) => {
  const gateway = await running();
  context.after(() => new Promise((resolve) => gateway.server.close(resolve)));
  const response = await fetch(`${gateway.base}/healthz`);
  assert.equal(response.headers.get('cross-origin-opener-policy'), 'same-origin');
  assert.equal(response.headers.get('cross-origin-embedder-policy'), 'require-corp');
});

test('catalog hydration can be saved and appears in the next presentation', async (context) => {
  const gateway = await running();
  context.after(() => new Promise((resolve) => gateway.server.close(resolve)));
  const document = await fetch(`${gateway.base}/node-design/v1/designs/demo-drive`).then((response) => response.json());
  const hydrated = await fetch(`${gateway.base}/node-design/v1/catalog/hydrate`, {
    method: 'POST', headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ kind: 'component', slug: 'test-bearing', version: '1.0.0', parent_assembly_id: 'root' })
  }).then((response) => response.json());
  document.draft.design.component_instances.push(...hydrated.component_instances);
  const saved = await fetch(`${gateway.base}/node-design/v1/designs/demo-drive/draft`, {
    method: 'PUT', headers: { 'content-type': 'application/json', 'if-match': '3' },
    body: JSON.stringify({ design: document.draft.design })
  });
  assert.equal(saved.status, 200);
  const presentation = await fetch(`${gateway.base}/node-design/v1/designs/demo-drive/presentation?profile_id=default`, { headers: { 'if-match': '4' } }).then((response) => response.json());
  assert.ok(presentation.instances.some((instance) => instance.release.item_key === 'component/test-bearing'));
});

test('connection preview uses exact interfaces and apply is atomic', async (context) => {
  const gateway = await running();
  context.after(() => new Promise((resolve) => gateway.server.close(resolve)));
  const hydrated = await fetch(`${gateway.base}/node-design/v1/catalog/hydrate`, {
    method: 'POST', headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ kind: 'component', slug: 'tool-coupler', version: '1.0.0', parent_assembly_id: 'drive' })
  }).then((response) => response.json());
  const document = await fetch(`${gateway.base}/node-design/v1/designs/demo-drive`).then((response) => response.json());
  document.draft.design.component_instances.push(...hydrated.component_instances);
  await fetch(`${gateway.base}/node-design/v1/designs/demo-drive/draft`, {
    method: 'PUT', headers: { 'content-type': 'application/json', 'if-match': '3' }, body: JSON.stringify({ design: document.draft.design })
  });
  const endpoints = { endpoint_a: { instance_id: 'shaft', interface_id: 'tool-output' }, endpoint_b: { instance_id: 'tool-coupler-1', interface_id: 'mount' } };
  const previewResponse = await fetch(`${gateway.base}/node-design/v1/designs/demo-drive/connections/preview`, {
    method: 'POST', headers: { 'content-type': 'application/json', 'if-match': '4' }, body: JSON.stringify(endpoints)
  });
  assert.equal(previewResponse.status, 200);
  const preview = await previewResponse.json();
  assert.equal(preview.compatibility, 'review');
  assert.equal(preview.endpoint_a.interface_id, 'tool-output');
  assert.equal(preview.endpoint_b.interface_id, 'mount');
  assert.deepEqual(preview.moved_subtree, ['tool-coupler-1']);
  assert.equal(preview.joint_type, 'fixed');
  assert.ok(preview.warnings.every((warning) => warning.code && warning.message));

  const appliedResponse = await fetch(`${gateway.base}/node-design/v1/designs/demo-drive/connections/apply`, {
    method: 'POST', headers: { 'content-type': 'application/json', 'if-match': '4' }, body: JSON.stringify({ ...endpoints, input_hash: preview.input_hash })
  });
  assert.equal(appliedResponse.status, 200);
  const applied = await appliedResponse.json();
  assert.equal(applied.connection_id, 'connection-1');
  assert.equal(applied.draft.revision_number, 5);
  assert.ok(applied.draft.design.connections.some((connection) => connection.connection_id === 'connection-1'));
});

test('connection preview reports blockers without inventing compatibility', async (context) => {
  const gateway = await running();
  context.after(() => new Promise((resolve) => gateway.server.close(resolve)));
  const response = await fetch(`${gateway.base}/node-design/v1/designs/demo-drive/connections/preview`, {
    method: 'POST', headers: { 'content-type': 'application/json', 'if-match': '3' },
    body: JSON.stringify({ endpoint_a: { instance_id: 'controller', interface_id: 'motor-power' }, endpoint_b: { instance_id: 'encoder', interface_id: 'power-in' } })
  });
  const preview = await response.json();
  assert.equal(preview.compatibility, 'incompatible');
  assert.ok(preview.blockers.length >= 2);
  assert.ok(preview.blockers.every((blocker) => blocker.code && blocker.message));
});

test('checkpoint response matches the SDK envelope and IDs are deterministic', async (context) => {
  const gateway = await running();
  context.after(() => new Promise((resolve) => gateway.server.close(resolve)));
  const response = await fetch(`${gateway.base}/node-design/v1/designs/demo-drive/checkpoints`, {
    method: 'POST', headers: { 'content-type': 'application/json', 'if-match': '3' }, body: JSON.stringify({ label: 'Review' })
  });
  assert.equal(response.status, 201);
  assert.deepEqual(await response.json(), { checkpoint: { checkpoint_id: 'checkpoint-1', revision_number: 3, label: 'Review', created_at: '2026-08-27T12:00:00.000Z' } });
});
