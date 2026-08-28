# Stock-addon migration

Future Engine Desktop was converted from a Godot product fork to a project-level editor addon. After qualification, the repository was reset to a standalone root commit and the inherited engine branches, tags, and source history were removed.

## Removed coupling

The active product no longer modifies editor registration, save routing, themes, branding, output names, or internal editor classes. It does not contain `SConstruct`, Godot modules, C++, or native libraries. The addon uses public editor APIs and accepts standard Godot chrome.

Generated scenes under `.future_engine_generated/` and imported assets under `.future_engine_cache/` are local projections. Neither is authoritative and both are ignored by Git.

## Feature boundary

The first module is System Design. It supplies native docks for design navigation, assembly/catalog/graph views, inspection, diagnostics, compilation, and telemetry. CAD, Firmware, Digital Twin, and Release remain later modules registered through the same module contract.

## Backend gate

Upstream mode never derives engineering presentation data locally. It requires the versioned presentation endpoint described in `contracts/BACKEND_HANDOFF.md`. The gateway defaults to Auto: live is selected only when every configured FE service port is reachable; otherwise the deterministic mock is selected and visibly labeled. Users can explicitly require Live or Mock and choose a configured or Tailscale-discovered backend from the native Godot Backend screen.
