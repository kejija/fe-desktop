import { execFile as execFileCallback } from 'node:child_process';
import { connect } from 'node:net';
import { promisify } from 'node:util';

const execFile = promisify(execFileCallback);

function normalizeHost(value) {
  const host = String(value ?? '').trim();
  return host.startsWith('[') && host.endsWith(']') ? host.slice(1, -1) : host;
}

function configuredServer(value, index) {
  const raw = String(value ?? '').trim();
  const separator = raw.indexOf('=');
  const name = separator > 0 ? raw.slice(0, separator).trim() : raw;
  const host = normalizeHost(separator > 0 ? raw.slice(separator + 1) : raw);
  if (!host) return null;
  return { id: `configured:${index}`, name: name || host, host, source: 'configured', online: null };
}

function tailscaleEntries(status) {
  const peers = status && typeof status === 'object' && status.Peer && typeof status.Peer === 'object' ? Object.values(status.Peer) : [];
  return peers.flatMap((peer) => {
    const addresses = Array.isArray(peer?.TailscaleIPs) ? peer.TailscaleIPs : [];
    const host = normalizeHost(addresses[0] ?? '');
    if (!host) return [];
    const dnsName = String(peer?.DNSName ?? '').replace(/\.$/, '');
    return [{
      id: `tailscale:${host}`,
      name: String(peer?.HostName ?? dnsName ?? host) || host,
      dns_name: dnsName,
      host,
      source: 'tailscale',
      online: Boolean(peer?.Online)
    }];
  });
}

export async function discoverTailscaleServers(timeoutMs = 1500) {
  try {
    const { stdout } = await execFile('tailscale', ['status', '--json'], { timeout: timeoutMs, maxBuffer: 4 * 1024 * 1024 });
    return { status: 'ready', servers: tailscaleEntries(JSON.parse(stdout)) };
  } catch (error) {
    const code = error && typeof error === 'object' && 'code' in error ? String(error.code) : 'unavailable';
    return { status: code === 'ENOENT' ? 'not_installed' : 'unavailable', servers: [] };
  }
}

export function probePort(host, port, timeoutMs = 650) {
  return new Promise((resolve) => {
    const socket = connect({ host, port });
    let settled = false;
    const finish = (running) => {
      if (settled) return;
      settled = true;
      socket.destroy();
      resolve(running);
    };
    socket.setTimeout(timeoutMs);
    socket.once('connect', () => finish(true));
    socket.once('timeout', () => finish(false));
    socket.once('error', () => finish(false));
  });
}

function routeTarget(route, server) {
  if (server.id === 'local') return route.target;
  const target = new URL(route.target);
  target.hostname = server.host.includes(':') ? `[${server.host}]` : server.host;
  return target.toString().replace(/\/$/, '');
}

function publicServer(server) {
  return {
    id: server.id,
    name: server.name,
    host: server.host,
    source: server.source,
    online: server.online,
    ...(server.dns_name ? { dns_name: server.dns_name } : {})
  };
}

export class BackendRegistry {
  constructor(config, options = {}) {
    this.config = config;
    this.requestedMode = config.mode;
    this.selectedServerId = config.selectedServer;
    this.discover = options.discover ?? (() => discoverTailscaleServers());
    this.probe = options.probe ?? probePort;
    this.servers = [];
    this.discoveryStatus = 'pending';
    this.lastSnapshot = null;
    this.lastRefresh = 0;
  }

  async refresh(force = false) {
    if (!force && this.lastSnapshot && Date.now() - this.lastRefresh < 2500) return this.lastSnapshot;
    const configured = this.config.configuredServers.map(configuredServer).filter(Boolean);
    const discovered = await this.discover();
    this.discoveryStatus = discovered.status;
    const byHost = new Set(configured.map((server) => server.host));
    const tailscale = discovered.servers.filter((server) => !byHost.has(server.host));
    this.servers = [
      { id: 'local', name: 'This computer', host: '127.0.0.1', source: 'local', online: true },
      ...configured,
      ...tailscale
    ];
    let selected = this.servers.find((server) => server.id === this.selectedServerId || server.host === this.selectedServerId);
    if (!selected) selected = this.servers[0];
    this.selectedServerId = selected.id;
    const services = await Promise.all(this.config.targets.map(async (route) => {
      const target = new URL(routeTarget(route, selected));
      const port = Number(target.port || (target.protocol === 'https:' ? 443 : 80));
      const running = selected.online === false ? false : await this.probe(normalizeHost(target.hostname), port, this.config.discoveryTimeoutMs);
      return { id: route.id, label: route.label, prefix: route.prefix, port, status: running ? 'running' : 'offline' };
    }));
    const allPortsAvailable = services.every((service) => service.status === 'running');
    const effectiveMode = this.requestedMode === 'auto' ? (allPortsAvailable ? 'upstream' : 'mock') : this.requestedMode;
    this.lastSnapshot = {
      schema_version: 'future-engine.backend-configuration.v1',
      requested_mode: this.requestedMode,
      effective_mode: effectiveMode,
      selected_server_id: selected.id,
      selected_server: publicServer(selected),
      all_ports_available: allPortsAvailable,
      discovery: { tailscale: this.discoveryStatus },
      servers: this.servers.map(publicServer),
      services
    };
    this.lastRefresh = Date.now();
    return this.lastSnapshot;
  }

  async select(input) {
    const requested = String(input?.mode ?? this.requestedMode).toLowerCase();
    const mode = requested === 'live' ? 'upstream' : requested;
    if (!['auto', 'upstream', 'mock'].includes(mode)) throw new Error('Mode must be auto, upstream, or mock.');
    await this.refresh();
    const serverId = String(input?.server_id ?? this.selectedServerId);
    if (!this.servers.some((server) => server.id === serverId)) throw new Error('Selected backend server is not available.');
    this.requestedMode = mode;
    this.selectedServerId = serverId;
    this.lastSnapshot = null;
    return this.refresh(true);
  }

  selectedRoute(route) {
    const selected = this.servers.find((server) => server.id === this.selectedServerId) ?? { id: 'local', host: '127.0.0.1' };
    return { ...route, target: routeTarget(route, selected) };
  }
}
