import { defineConfig } from '@playwright/test';

export default defineConfig({
  testDir: './tools/frontend-gateway/test-browser',
  timeout: 20_000,
  fullyParallel: false,
  use: {
    baseURL: 'http://127.0.0.1:8142',
    headless: true
  },
  webServer: {
    command: 'FE_WEB_EDITOR_ROOT=dist/web-editor npm run gateway:mock',
    url: 'http://127.0.0.1:8142/healthz',
    reuseExistingServer: true,
    timeout: 15_000
  }
});
