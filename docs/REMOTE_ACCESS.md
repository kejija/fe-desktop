# Private-network deployment

Desktop clients normally connect to a loopback gateway. For remote access, expose the gateway only through Tailscale or an existing authenticated TLS reverse proxy.

Set all three controls together:

```bash
FE_GATEWAY_HOST=0.0.0.0
FE_TRUSTED_PRIVATE_NETWORK=true
FE_ALLOWED_HOSTS=fe.internal.example
FE_ALLOWED_ORIGINS=https://fe.internal.example
```

The gateway refuses a broad bind if either allowlist is missing. Service bearer tokens remain gateway environment variables. Do not forward them from the access proxy and do not put them in Godot project settings.

The gateway's trusted-private-network setting only acknowledges that an external access layer exists. It does not authenticate users, authorize designs, or replace TLS.

## Backend discovery

When the `tailscale` CLI is installed and connected, the gateway exposes its peer list to the native Godot **Backend** screen. The response contains peer names, Tailscale addresses, online state, and FE port status; it never contains service tokens. Selecting a peer rewrites the configured service target host while preserving each service's protocol and port.

Static private hosts can be added without Tailscale discovery:

```bash
FE_BACKEND_SERVERS='Lab rig=10.0.0.20,Build server=fe-build.internal' npm run gateway
```

The gateway accepts only localhost, configured entries, and Tailscale-discovered IDs as runtime selections. Keep the gateway loopback-bound unless the trusted private-network controls above are in place.
