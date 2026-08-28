# FE node-card parity design QA

final result: passed

## Evidence

- Reference: `/home/keji/.codex/attachments/be8ca9a0-27a1-4893-8c12-d34632c2c932/codex-clipboard-ba374fa0-7d9e-4483-b6c2-980eba96adea.png` (690 × 650)
- Full root graph: `/home/keji/fe-godot/screenshots/fe-node-card-parity-root-final.png` (1920 × 1080)
- Full nested assembly graph: `/home/keji/fe-godot/screenshots/fe-node-card-parity-drive-final.png` (1920 × 1080)
- Expanded placement and autosave state: `/home/keji/fe-godot/screenshots/fe-node-card-parity-placement-autosave-preserved.png` (1920 × 1080)
- Side-by-side normalized comparison: `/home/keji/fe-godot/screenshots/fe-node-card-parity-comparison.png` (1376 × 650)
- Annotated correction source: `/home/keji/.codex/attachments/ea110a2a-8179-4f25-bd42-bfc652696eea/codex-clipboard-c7c5a7a6-a180-4750-8386-0e5a41c03d84.png` (1920 × 1080)
- Corrected nested graph: `/home/keji/fe-godot/screenshots/fix-node-graph-03-drive-autofit-labels.png` (1920 × 1080)
- Full correction comparison: `/home/keji/fe-godot/screenshots/fix-node-graph-comparison-full.png` (1920 × 540; each 1920 × 1080 side normalized to 960 × 540 at density 1)
- Left-column hover: `/home/keji/fe-godot/screenshots/fix-node-graph-04-left-port-hover.png` (1920 × 1080)
- Right-column hover: `/home/keji/fe-godot/screenshots/fix-node-graph-05-right-port-hover.png` (1920 × 1080)
- Focused hover comparison: `/home/keji/fe-godot/screenshots/fix-node-graph-comparison-hover.png` (720 × 350; two 360 × 350 crops)

The focused implementation crop is 380 × 360 from the 1920 × 1080 root graph and is scaled to 650 px high beside the 690 × 650 reference. Both sides show the default graph state with Parameters collapsed, Ports expanded, and Placement collapsed.

## Visual assessment

- Card width, paper background, square outline, monospace typography, header hierarchy, section rules, port columns, compact placement row, and footer action now track the FE reference closely.
- Domain and readiness remain visible through text and restrained color; the card does not rely on color alone.
- Connections use a 1.25 px antialiased stroke, reduced curvature, a nearly transparent rim, and small domain/status labels so edges recede behind card content.
- Cards fit their content instead of retaining Godot's previous oversized blank body.
- The hidden native GraphNode title bar has a zero minimum height, eliminating the blank white strip that previously sat above every FE card.
- A newly opened assembly is fit once with a maximum zoom of 100%; subsequent presentation refreshes preserve the user's viewport.
- Relationship labels follow the midpoint of the visible public GraphEdit curve geometry and are suppressed when the corresponding curve is offscreen.
- Real FE design-system component, assembly, chevron, and trash assets are used rather than drawn substitutes.

## Interaction assessment

- Opened the nested Drive module from the root assembly proxy.
- Collapsed and expanded Ports while retaining exact input/output port metadata and routable handles.
- Expanded Placement, edited the authoritative X coordinate, observed draft revision advancement, and confirmed the section remains expanded after the autosave presentation refresh.
- Verified selected card state, nested assembly navigation, graph minimap, and connection labels on the virtual display.
- Verified the nested Drive assembly opens at 82% with every mock node visible and no detached relationship label.
- Verified 180 ms FE-equivalent port expansion: input hover/focus uses `3:1`, output hover/focus uses `1:3`, and mouse exit returns to `1:1` without changing card width.
- Native Godot stderr remained clear during interaction. Browser-console checks do not apply to this editor-native surface.

## Iterations and findings

1. P1: Cards initially retained oversized GraphNode height and large blank regions. Fixed by deferring content-size fitting after graph insertion and after section changes.
2. P1: Connection strokes and labels competed with card content. Fixed with 1.25 px lines, a softer rim, reduced curvature, and compact `MECH`/`ELEC`/`SIG` labels.
3. P2: Native SpinBox placement controls introduced dark editor fields inside the light card. Replaced with paper-styled coordinate cells backed by LineEdit controls.
4. P2: Expanded Placement closed after an autosave refresh. Fixed by retaining per-node section state across projection rebuilds.
5. P3 accepted constraint: stock GraphEdit exposes circular native connection handles rather than the FE web card's vertical handle rails. Exact interface routing, side, domain color, disabled state, and collapsed-port routing are preserved.
6. P1: The hidden GraphNode title bar still reserved a 23 px white strip above the actual card. Fixed by zeroing and hiding the internal title controls; post-fix evidence shows card content beginning at the node border.
7. P1: Edge status labels used the midpoint between node centers, leaving `SIG · REVIEW` visually detached. Fixed by resolving exact source/target port geometry, sampling `GraphEdit.get_connection_line`, and using the visible curve's arc-length midpoint. Offscreen curves now hide their labels.
8. P2: Port columns stayed at `1:1` and exposed truncated text only through a tooltip. Fixed with the FE source behavior: all rows animate to `3:1` or `1:3` on pointer hover or keyboard focus, then return to `1:1`.
9. P2: The nested assembly initially left important nodes outside the viewport. Fixed with a one-time assembly fit matching FE's `fitView` behavior; refreshes do not steal the user's pan or zoom.

No remaining P0, P1, or P2 visual or interaction issues were observed in the tested mock-design states.

## Verification

- Official Godot `4.7.2.stable` headless addon/control tests: passed.
- Gateway tests: 11 passed.
- Contract fixtures: passed.
- Repository verification: passed.
- `git diff --check`: passed.
