import { loadConfig } from './config.mjs';
import { listenGateway } from './server.mjs';

try {
  const config = loadConfig();
  const { server, backendRegistry } = await listenGateway(config);
  const address = server.address();
  const boundPort = typeof address === 'object' && address ? address.port : config.port;
  const state = await backendRegistry.refresh();
  process.stdout.write(`Future Engine desktop gateway listening on http://${config.host}:${boundPort} (${state.requested_mode} -> ${state.effective_mode}, ${state.selected_server.name})\n`);
} catch (error) {
  process.stderr.write(`Gateway startup failed: ${error instanceof Error ? error.message : String(error)}\n`);
  process.exitCode = 1;
}
