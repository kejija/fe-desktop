import { test, expect } from '@playwright/test';

test('gateway shell identifies explicit mock mode and remains cross-origin isolated', async ({ page }) => {
  const response = await page.goto('/');
  expect(response.status()).toBe(200);
  expect(response.headers()['cross-origin-opener-policy']).toBe('same-origin');
  expect(response.headers()['cross-origin-embedder-policy']).toBe('require-corp');
  await expect(page.getByRole('heading', { name: 'Future Engine Desktop' })).toBeVisible();
  await expect(page.locator('#status')).toContainText('MOCK BACKEND');
  expect(await page.evaluate(() => crossOriginIsolated)).toBe(true);
});

test('project files are available from the same origin', async ({ request }) => {
  const response = await request.get('/project/project.godot');
  expect(response.status()).toBe(200);
  expect(await response.text()).toContain('Future Engine Desktop');

  const manifestResponse = await request.get('/project-manifest.json');
  expect(manifestResponse.status()).toBe(200);
  const manifest = await manifestResponse.json();
  expect(manifest.schema_version).toBe('future-engine.web-project-manifest.v1');
  expect(manifest.files.some((file) => file.path === 'addons/future_engine/plugin.gd')).toBe(true);
});

test('stock web editor bootstrap seeds the versioned addon project', async ({ page }) => {
  test.setTimeout(90_000);
  const response = await page.goto('/editor/', { waitUntil: 'domcontentloaded' });
  expect(response.status()).toBe(200);
  await page.waitForFunction(() => window.futureEngineProjectSeed?.fileCount > 0, null, { timeout: 75_000 });
  const seed = await page.evaluate(() => window.futureEngineProjectSeed);
  expect(seed.root).toContain('/home/web_user/FutureEngineDesktop-');
  expect(seed.fileCount).toBeGreaterThan(10);
  expect(await page.evaluate(() => localStorage.getItem('futureEngineWebProjectVersion'))).toBe(seed.version);
});

test('browser storage persists and live simulation streams over the gateway', async ({ page, request }) => {
  await page.goto('/');
  await page.evaluate(async () => {
    await new Promise((resolve, reject) => {
      const open = indexedDB.open('future-engine-desktop-test', 1);
      open.onupgradeneeded = () => open.result.createObjectStore('state');
      open.onerror = () => reject(open.error);
      open.onsuccess = () => {
        const transaction = open.result.transaction('state', 'readwrite');
        transaction.objectStore('state').put('persisted', 'status');
        transaction.oncomplete = resolve;
        transaction.onerror = () => reject(transaction.error);
      };
    });
  });
  await page.reload();
  const persisted = await page.evaluate(async () => await new Promise((resolve, reject) => {
    const open = indexedDB.open('future-engine-desktop-test', 1);
    open.onerror = () => reject(open.error);
    open.onsuccess = () => {
      const read = open.result.transaction('state').objectStore('state').get('status');
      read.onsuccess = () => resolve(read.result);
      read.onerror = () => reject(read.error);
    };
  }));
  expect(persisted).toBe('persisted');

  const created = await request.post('/simulation/v1/sessions', { data: { design_id: 'demo-drive', revision_number: 3, profile_id: 'default' } });
  const { session_id: sessionId } = await created.json();
  const state = await page.evaluate((session) => new Promise((resolve, reject) => {
    const socket = new WebSocket(`${location.origin.replace(/^http/, 'ws')}/simulation/v1/sessions/${session}/stream`);
    socket.onerror = () => reject(new Error('WebSocket failed'));
    socket.onmessage = (event) => { resolve(JSON.parse(event.data)); socket.close(); };
  }), sessionId);
  expect(state.type).toBe('state');
  expect(state.poses).toHaveLength(1);
});
