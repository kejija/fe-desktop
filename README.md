# Future Engine Desktop

Future Engine Desktop is a stock Godot 4.7.2 editor addon for mechanical system design. The active branch contains no Godot engine source and does not compile the engine. It runs as a GDScript `EditorPlugin` inside an official Godot editor binary.

The repository was reset to a standalone-addon history after the source-based product fork was retired. It intentionally contains no archived Godot source or inherited Godot branches/tags; official editor binaries are obtained from the pinned release in `godot-version.lock.json`.

## Current qualification

The addon is **mock-qualified**. Its complete System Design shell and client data flow can be developed against the deterministic gateway mock. Authoritative editing against a real Future Engine backend fails closed until that backend implements `future-engine.system-design-presentation.v1`; see [the backend handoff](contracts/BACKEND_HANDOFF.md).

## Run

Start the gateway in automatic mode:

```bash
npm run gateway
```

Automatic mode selects the live backend when all eight FE service ports are reachable on the selected server. It falls back to the visibly labeled mock backend when the live stack is incomplete. To force deterministic mock mode instead:

```bash
npm run gateway:mock
```

Open the project with an official Godot 4.7.2 Standard editor:

```bash
godot --editor --path godot-project
```

The addon is enabled in `project.godot`. Use the **Backend** toolbar action to choose Auto, Live, or Mock; select localhost, a configured server, or any server discovered through Tailscale; and inspect the running/offline state of every FE service port. A persistent **MOCK BACKEND** badge is shown whenever mock mode is active.

For a real private-network deployment, configure upstream service URLs or choose a discovered Tailscale server in Godot. The gateway binds to `127.0.0.1:8142` unless trusted private-network mode is explicitly enabled.

## Verify and package

```bash
npm test
godot --headless --path godot-project --script res://tests/test_runner.gd
npm run package:addon
```

The package command writes a platform-neutral project archive under `dist/`. Godot binaries are downloaded independently from the pinned release described by `godot-version.lock.json`.

## Repository layout

- `godot-project/` — the stock-editor project and GDScript addon.
- `tools/frontend-gateway/` — upstream proxy, explicit mock backend, and web-editor host.
- `contracts/` — the future presentation API contract and deterministic fixtures.

No `.feproject` importer is provided. `SystemDesignV2` remains the authoritative backend document and generated Godot scenes are disposable projections.
