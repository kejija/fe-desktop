# Frontend modules

`addons/future_engine/frontend_modules.json` is the reviewed module manifest. Every entry names a local GDScript implementing `FEFrontendModule` and declares the backend services it requires.

A module registers UI through the host's public mounting helpers, opens an optional context, activates its requests/signals, and releases resources during shutdown. The core plugin owns connectivity, asset verification, scene projection, recovery, live WebSockets, and backend-mode status so later modules do not duplicate those boundaries.

Modules are bundled with a signed/reviewed addon release and loaded on the next editor start. The backend cannot supply executable scripts. CAD, Firmware, Digital Twin, and Release can therefore evolve independently without an engine build while sharing the same stock Godot host.
