# Future Engine desktop gateway

The gateway is the only network endpoint configured in the addon. It keeps internal service credentials outside Godot and browser storage, forwards HTTP/WebSocket traffic, serves the pinned web editor, and exposes the versioned addon project manifest.

## Modes

`auto` is the default. It selects `upstream` (shown as **Live** in Godot) only when every configured FE service port is reachable on the selected backend server. Otherwise it selects the visibly labeled deterministic mock. It re-evaluates the ports while the gateway is running.

`upstream` can be selected explicitly in the Godot **Backend** screen or with `FE_BACKEND_MODE=upstream` (`live` is accepted as an alias). It proxies real services even when some ports are offline and never calculates presentation data. If Node Design does not implement presentation v1, the addon displays the design list but refuses to open an authoritative editing session.

`mock` can be forced explicitly with `FE_BACKEND_MODE=mock`. It serves deterministic fixtures and an immutable minimal GLB. Whether selected explicitly or by Auto fallback, the addon displays a persistent **MOCK BACKEND** badge.

The native Backend screen calls `/gateway/configuration` to switch modes and backend hosts without restarting Godot or the gateway. Server-side tokens never appear in that response. The server dropdown always includes localhost, adds `FE_BACKEND_SERVERS`, and discovers Tailscale peers using `tailscale status --json`. Only discovered/configured server IDs can be selected; the client cannot submit an arbitrary proxy target.

## Network settings

| Variable | Default | Purpose |
| --- | --- | --- |
| `FE_GATEWAY_HOST` | `127.0.0.1` | Listen address |
| `FE_GATEWAY_PORT` | `8142` | Listen port |
| `FE_TRUSTED_PRIVATE_NETWORK` | `false` | Required for a non-loopback bind |
| `FE_ALLOWED_HOSTS` | loopback hosts | Comma-separated Host allowlist |
| `FE_ALLOWED_ORIGINS` | same-origin | Comma-separated browser Origin allowlist |
| `FE_WEB_EDITOR_ROOT` | unset | Staged official web-editor directory |
| `FE_BACKEND_MODE` | `auto` | `auto`, `upstream`/`live`, or `mock` |
| `FE_BACKEND_SERVER` | `local` | Initial discovered server ID or configured hostname |
| `FE_BACKEND_SERVERS` | unset | Comma-separated `Display name=host` entries appended to the dropdown |
| `FE_BACKEND_DISCOVERY_TIMEOUT_MS` | `650` | TCP timeout used for each service-port indicator |

Each proxied service has `FE_*_API_TARGET` and optional `FE_*_API_TOKEN` variables. Tokens are injected into upstream requests and are never returned by health endpoints or project files.

The screen probes CAD `8123`, Components `8134`, Node Design `8135`, Simulation `8136`, FEA `8138`, Engineering Schema `8140`, Materials `8141`, and LLM `8787`. A running indicator means the TCP port accepted a connection; application-level contract qualification is still enforced separately.

For remote use, terminate TLS and enforce identity in Tailscale or an authenticated reverse proxy. Trusted-private-network mode is not an identity system.
