import test from 'node:test';
import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { loadConfig } from '../src/config.mjs';
import { createGateway } from '../src/server.mjs';

test('upstream proxy strips the service prefix and injects its token server-side', async (context) => {
  let observed = null;
  const upstream = createServer((request, reply) => {
    observed = { url: request.url, authorization: request.headers.authorization };
    if (request.url.startsWith('/v1/designs/demo/presentation')) {
      reply.writeHead(404, { 'content-type': 'application/json' });
      reply.end(JSON.stringify({ error: { code: 'not_found', message: 'Presentation endpoint is not implemented.' } }));
      return;
    }
    reply.writeHead(200, { 'content-type': 'application/json' });
    reply.end(JSON.stringify({ ok: true }));
  });
  await new Promise((resolve) => upstream.listen(0, '127.0.0.1', resolve));
  context.after(() => new Promise((resolve) => upstream.close(resolve)));
  const upstreamPort = upstream.address().port;
  const config = loadConfig({
    FE_BACKEND_MODE: 'upstream',
    FE_GATEWAY_PORT: '0',
    FE_NODE_DESIGN_API_TARGET: `http://127.0.0.1:${upstreamPort}`,
    FE_NODE_DESIGN_API_TOKEN: 'server-secret'
  });
  const gateway = await createGateway(config, { registryOptions: { discover: async () => ({ status: 'ready', servers: [] }), probe: async () => true } });
  await new Promise((resolve) => gateway.server.listen(0, '127.0.0.1', resolve));
  context.after(() => new Promise((resolve) => gateway.server.close(resolve)));
  const gatewayPort = gateway.server.address().port;
  const response = await fetch(`http://127.0.0.1:${gatewayPort}/node-design/v1/example?value=1`);
  assert.equal(response.status, 200);
  assert.deepEqual(observed, { url: '/v1/example?value=1', authorization: 'Bearer server-secret' });
  const healthText = await fetch(`http://127.0.0.1:${gatewayPort}/healthz`).then((item) => item.text());
  assert.ok(!healthText.includes('server-secret'));
  const missingPresentation = await fetch(`http://127.0.0.1:${gatewayPort}/node-design/v1/designs/demo/presentation?profile_id=default`, { headers: { 'if-match': '1' } });
  assert.equal(missingPresentation.status, 404);
  assert.equal((await missingPresentation.json()).error.code, 'not_found');
});
