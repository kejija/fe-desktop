import test from 'node:test';
import assert from 'node:assert/strict';
import { loadConfig } from '../src/config.mjs';

test('defaults to a loopback auto-selecting gateway', () => {
  const config = loadConfig({});
  assert.equal(config.host, '127.0.0.1');
  assert.equal(config.port, 8142);
  assert.equal(config.mode, 'auto');
  assert.equal(config.selectedServer, 'local');
});

test('accepts live as the user-facing upstream mode alias', () => {
  assert.equal(loadConfig({ FE_BACKEND_MODE: 'live' }).mode, 'upstream');
});

test('rejects an untrusted non-loopback bind', () => {
  assert.throws(() => loadConfig({ FE_GATEWAY_HOST: '0.0.0.0' }), /trusted/i);
});

test('requires host and origin allowlists for private-network binds', () => {
  assert.throws(() => loadConfig({ FE_GATEWAY_HOST: '0.0.0.0', FE_TRUSTED_PRIVATE_NETWORK: 'true' }), /FE_ALLOWED_HOSTS/);
  assert.throws(() => loadConfig({ FE_GATEWAY_HOST: '0.0.0.0', FE_TRUSTED_PRIVATE_NETWORK: 'true', FE_ALLOWED_HOSTS: 'fe.local' }), /FE_ALLOWED_ORIGINS/);
  const config = loadConfig({ FE_GATEWAY_HOST: '0.0.0.0', FE_TRUSTED_PRIVATE_NETWORK: 'true', FE_ALLOWED_HOSTS: 'fe.local', FE_ALLOWED_ORIGINS: 'https://fe.local' });
  assert.equal(config.host, '0.0.0.0');
});
