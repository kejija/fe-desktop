# System Design parity matrix

| Workflow | Addon surface | Mock-qualified | Real-backend gate |
| --- | --- | --- | --- |
| List/create/open designs | Designs dock | Yes | Existing design API plus presentation v1 |
| Templates and checkpoints | Designs dock / toolbar | Yes | Existing Node Design APIs |
| Assembly hierarchy | Assembly tab and 3D scene | Yes | Presentation v1 |
| Catalog insertion/hydration | Catalog tab | Shell + contract | Catalog and draft APIs |
| Graph pan/zoom and selection | Graph tab | Yes | Canonical design document |
| Typed connection preview/apply | Graph and diagnostics | Contract-qualified | Existing connection APIs |
| Inspector and anchor editing | Inspector dock / gizmo | Yes | Presentation editability + conditional draft save |
| Presets, overrides, formulas | Inspector sections | Shell + contract | Canonical draft update |
| Undo/redo and recovery | Toolbar / local recovery | Yes | Conditional draft save |
| BOM, readiness, diagnostics | Inspector / diagnostics | Yes | Presentation v1 |
| Compile and artifacts | Bottom panel / toolbar | Yes | Existing compile API |
| Simulation profiles | Inspector | Shell + contract | Canonical draft update |
| Live poses and I/O | Telemetry panel / 3D scene | Yes | Simulation session API + WebSocket |
| Camera, fit, grid, explosion | Stock 3D workspace / toolbar | Native adaptation | None |

“Parity” means equivalent workflow and backend behavior, not pixel-identical React styling.
