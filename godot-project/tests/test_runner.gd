extends SceneTree

const CoordinateAdapter = preload("res://addons/future_engine/core/coordinate_adapter.gd")
const ContractValidator = preload("res://addons/future_engine/core/contract_validator.gd")
const RecoveryStore = preload("res://addons/future_engine/core/recovery_store.gd")
const BackendSettings = preload("res://addons/future_engine/core/backend_settings.gd")
const GraphModel = preload("res://addons/future_engine/modules/system_design/graph_model.gd")
const GraphCard = preload("res://addons/future_engine/modules/system_design/graph_card.gd")
const GraphWorkspace = preload("res://addons/future_engine/modules/system_design/graph_workspace.gd")

var _failures := PackedStringArray()

func _init() -> void:
	_test_coordinates()
	_test_contracts()
	_test_graph_model()
	_test_graph_card()
	_test_backend_settings()
	_test_recovery()
	if _failures.is_empty():
		print("FE_DESKTOP_TESTS_OK")
		quit(0)
	else:
		for failure in _failures:
			push_error(failure)
		quit(1)

func _test_coordinates() -> void:
	var fe_position := [1.25, -2.5, 3.75]
	var godot_position: Vector3 = CoordinateAdapter.fe_position_to_godot(fe_position)
	_expect(godot_position.is_equal_approx(Vector3(1.25, 3.75, 2.5)), "FE position must map X/Z/-Y into Godot.")
	var round_trip: Array[float] = CoordinateAdapter.godot_position_to_fe(godot_position)
	_expect(_array_approx(round_trip, fe_position), "Position conversion must round-trip.")
	var fe_quaternion := Quaternion(Vector3(0.2, 0.5, 0.7).normalized(), 1.1)
	var wxyz := [fe_quaternion.w, fe_quaternion.x, fe_quaternion.y, fe_quaternion.z]
	var godot_quaternion: Quaternion = CoordinateAdapter.fe_quaternion_to_godot(wxyz)
	var quaternion_round_trip: Array[float] = CoordinateAdapter.godot_quaternion_to_fe(godot_quaternion)
	_expect(_quaternion_equivalent(wxyz, quaternion_round_trip), "Quaternion basis conversion must round-trip.")
	var transform := Transform3D(Basis(godot_quaternion), godot_position)
	var transform_round_trip: Transform3D = CoordinateAdapter.fe_transform_to_godot(CoordinateAdapter.godot_transform_to_fe(transform))
	_expect(transform.is_equal_approx(transform_round_trip), "Transform conversion must round-trip.")
	var euler := [35.0, -22.0, 147.0]
	var fe_rotation := CoordinateAdapter.euler_degrees_to_quaternion(euler)
	var euler_round_trip := CoordinateAdapter.quaternion_to_euler_degrees(fe_rotation)
	_expect(_array_approx(euler, euler_round_trip, 0.0001), "FE roll/pitch/yaw formulas must match the web frontend and round-trip.")

func _test_contracts() -> void:
	var root := ProjectSettings.globalize_path("res://..")
	var document: Variant = JSON.parse_string(FileAccess.get_file_as_string("%s/contracts/fixtures/design-document.json" % root))
	var presentation: Variant = JSON.parse_string(FileAccess.get_file_as_string("%s/contracts/fixtures/presentation.success.json" % root))
	_expect(ContractValidator.validate_design_document(document).is_empty(), "Canonical design fixture must validate.")
	_expect(ContractValidator.validate_presentation(presentation, "demo-drive", 3).is_empty(), "Canonical presentation fixture must validate.")
	var stale: Dictionary = presentation.duplicate(true)
	stale.draft_revision_number = 4
	_expect(ContractValidator.validate_presentation(stale, "demo-drive", 3).has("Presentation revision is stale."), "Stale presentations must be rejected.")
	var invalid_coordinates: Dictionary = presentation.duplicate(true)
	invalid_coordinates.coordinate_system.up_axis = "y"
	_expect(not ContractValidator.validate_presentation(invalid_coordinates).is_empty(), "Unsupported coordinates must be rejected.")

func _test_graph_model() -> void:
	var root := ProjectSettings.globalize_path("res://..")
	var document: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("%s/contracts/fixtures/design-document.json" % root))
	var presentation: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("%s/contracts/fixtures/presentation.success.json" % root))
	var design: Dictionary = document.draft.design
	var root_projection: Dictionary = GraphModel.build(design, presentation, "root")
	var root_nodes := _items_by_id(root_projection.nodes)
	_expect(root_nodes.has("component:controller") and root_nodes.has("component:plate") and root_nodes.has("assembly:drive"), "Root graph must contain direct components and its direct child assembly proxy.")
	_expect(not root_nodes.has("component:motor") and root_projection.hidden_generated.has("bolt-1"), "Collapsed descendants and generated hardware must not appear as root graph nodes.")
	_expect(root_projection.edges.size() == 3, "Relationships internal to the collapsed drive assembly must be omitted while external relationships remain.")
	var drive_projection: Dictionary = GraphModel.build(design, presentation, "drive")
	var drive_nodes := _items_by_id(drive_projection.nodes)
	_expect(drive_nodes.has("component:motor") and drive_nodes.has("component:shaft") and drive_nodes.has("component:encoder"), "Nested assembly graph must expose its direct components.")
	_expect(drive_nodes.has("external:root"), "Relationships leaving the active assembly must project onto an external assembly proxy.")
	var mechanical_bundle := {}
	for edge in drive_projection.edges:
		if edge.get("domain") == "mechanical" and edge.get("source_node") in ["component:motor", "component:shaft"] and edge.get("target_node") in ["component:motor", "component:shaft"]:
			mechanical_bundle = edge
			break
	_expect(mechanical_bundle.get("members", []).size() == 4, "Parallel mechanical connections and joints must retain all bundle members.")
	_expect(mechanical_bundle.get("status") == "warning", "Bundle severity must select warning over unverified and compatible.")
	_expect(mechanical_bundle.get("members", []).any(func(member): return str(member.get("source_handle", "")).begins_with("body:") or str(member.get("target_handle", "")).begins_with("body:")), "Body-authored joints must use display anchors instead of invented interfaces.")
	var encoded: String = GraphModel.encode_proxy_handle("motor:axis", "front/bearing")
	_expect(GraphModel.decode_proxy_handle(encoded) == {"instance_id": "motor:axis", "interface_id": "front/bearing"}, "Assembly proxy handles must round-trip encoded endpoint IDs.")
	_expect(GraphModel.snap_position(Vector2(214, 279)) == Vector2(280, 280), "Registration snapping must use the 140 px grid.")
	var legacy_design: Dictionary = design.duplicate(true)
	legacy_design.extensions.node_design_layout = {"motor": [13, 27]}
	var legacy := GraphModel.layout_position(legacy_design, "component:motor", Vector2.ZERO)
	_expect(legacy.legacy and legacy.position == Vector2(13, 27), "Legacy bare component layout keys must remain readable.")
	GraphModel.write_layout(legacy_design, "component:motor", Vector2(140, 280))
	_expect(not legacy_design.extensions.node_design_layout.has("motor") and legacy_design.extensions.node_design_layout["component:motor"] == [140.0, 280.0], "A legacy layout key must migrate only when that node moves.")

func _test_graph_card() -> void:
	var root_path := ProjectSettings.globalize_path("res://..")
	var document: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("%s/contracts/fixtures/design-document.json" % root_path))
	var presentation: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("%s/contracts/fixtures/presentation.success.json" % root_path))
	var model: Dictionary = GraphModel.build(document.draft.design, presentation, "drive")
	var motor_model: Dictionary = _items_by_id(model.nodes).get("component:motor", {})
	var card: Variant = GraphCard.new()
	card.configure(motor_model, true)
	root.add_child(card)
	_expect(card.get_titlebar_hbox().get_combined_minimum_size().y == 0.0, "The hidden native GraphNode titlebar must not reserve a blank strip above FE card content.")
	_expect(not card.is_section_expanded("parameters") and card.is_section_expanded("ports") and not card.is_section_expanded("placement"), "FE cards must default to compact parameters and placement with the typed port table visible.")
	_expect(card.endpoint_for_input(0).interface_id == "power-in", "The first input slot must retain the exact power interface ID.")
	_expect(card.endpoint_for_output(0).interface_id == "shaft-output", "The first output slot must retain the exact shaft interface ID instead of falling back to the first interface.")
	_expect(card.endpoint_for_input(1).interface_id == "front-bearing" and card.endpoint_for_output(1).interface_id == "front-bearing", "Bidirectional ports must expose exact metadata on both handles.")
	_expect(not card.endpoint_for_input(0).connectable and card.endpoint_for_input(0).state == "capacity_reached", "Capacity-reached ports must remain visible but disabled for authoring.")
	card.set_section_expanded("ports", false)
	_expect(card.endpoint_for_input(0).interface_id == "power-in" and card.endpoint_for_output(0).interface_id == "shaft-output", "Collapsed FE port rails must preserve exact endpoint routing.")
	card.set_section_expanded("parameters", true)
	card.set_section_expanded("placement", true)
	_expect(card.is_section_expanded("parameters") and card.is_section_expanded("placement"), "Parameter and placement sections must expand independently.")
	card.set_section_expanded("ports", true)
	card.set_port_column_expansion(-1, false)
	_expect(card.port_column_ratios() == Vector2(3, 1), "Hovering or focusing an input port must expand the left column to the FE 3:1 ratio.")
	card.set_port_column_expansion(1, false)
	_expect(card.port_column_ratios() == Vector2(1, 3), "Hovering or focusing an output port must expand the right column to the FE 1:3 ratio.")
	card.set_port_column_expansion(0, false)
	_expect(card.port_column_ratios() == Vector2.ONE, "Port columns must return to an even split after hover or focus leaves.")
	var panel := card.get_theme_stylebox("panel") as StyleBoxFlat
	_expect(panel != null and panel.bg_color.is_equal_approx(Color("fcfbf8")), "Native graph cards must use the FE drafting-paper surface.")
	var line := PackedVector2Array([Vector2(-40, 50), Vector2(20, 50), Vector2(80, 50), Vector2(140, 50)])
	var visible_midpoint: Variant = GraphWorkspace.visible_path_midpoint(line, Rect2(0, 0, 100, 100))
	_expect(visible_midpoint != null and Vector2(visible_midpoint).is_equal_approx(Vector2(50, 50)), "Relationship labels must use the midpoint of the visible connection geometry.")
	_expect(GraphWorkspace.visible_path_midpoint(line, Rect2(0, 200, 100, 100)) == null, "Relationship labels must hide when their connection geometry is offscreen.")
	card.queue_free()

func _test_recovery() -> void:
	var design := {"schema_version": "future-engine.system-design.v2", "design_id": "test-recovery"}
	var error: Error = RecoveryStore.save("test-recovery", 7, design, "test")
	_expect(error == OK, "Recovery snapshot must be writable.")
	var recovered: Dictionary = RecoveryStore.load("test-recovery")
	_expect(recovered.get("base_revision") == 7, "Recovery snapshot must retain its base revision.")
	_expect(recovered.get("design", {}).get("design_id") == "test-recovery", "Recovery snapshot must retain its design.")
	_expect(RecoveryStore.clear("test-recovery") == OK, "Recovery snapshot must be removable.")

func _test_backend_settings() -> void:
	var settings: Variant = BackendSettings.new()
	root.add_child(settings)
	settings._build_ui()
	settings._apply_configuration({
		"requested_mode": "auto",
		"effective_mode": "upstream",
		"selected_server_id": "tailscale:100.64.0.8",
		"selected_server": {"id": "tailscale:100.64.0.8", "name": "design-rig", "host": "100.64.0.8", "source": "tailscale", "online": true},
		"all_ports_available": true,
		"discovery": {"tailscale": "ready"},
		"servers": [
			{"id": "local", "name": "This computer", "host": "127.0.0.1", "source": "local", "online": true},
			{"id": "tailscale:100.64.0.8", "name": "design-rig", "host": "100.64.0.8", "source": "tailscale", "online": true}
		],
		"services": [
			{"id": "cad", "label": "CAD", "port": 8123, "status": "running"},
			{"id": "components", "label": "Components", "port": 8134, "status": "running"},
			{"id": "node_design", "label": "Node Design", "port": 8135, "status": "running"},
			{"id": "simulation", "label": "Simulation", "port": 8136, "status": "running"},
			{"id": "fea", "label": "FEA", "port": 8138, "status": "running"},
			{"id": "engineering_schema", "label": "Engineering Schema", "port": 8140, "status": "running"},
			{"id": "materials", "label": "Materials", "port": 8141, "status": "running"},
			{"id": "llm", "label": "LLM", "port": 8787, "status": "running"}
		]
	})
	_expect(settings._mode.item_count == 3 and settings._mode.get_item_metadata(settings._mode.selected) == "auto", "Backend screen must expose Auto, Live, and Mock modes.")
	_expect(settings._server.item_count == 2 and settings._server.get_item_metadata(settings._server.selected) == "tailscale:100.64.0.8", "Backend screen must select a discovered Tailscale server by opaque ID.")
	_expect(settings._services.get_child_count() == 36, "Backend screen must render a status row for every FE service port.")
	_expect(settings._effective.text == "LIVE BACKEND · ALL PORTS RUNNING", "Backend screen must identify live auto-selection when all ports run.")
	settings.queue_free()

func _array_approx(left: Array, right: Array, tolerance := 0.00001) -> bool:
	if left.size() != right.size():
		return false
	for index in left.size():
		if absf(float(left[index]) - float(right[index])) > tolerance:
			return false
	return true

func _quaternion_equivalent(left: Array, right: Array) -> bool:
	var direct := _array_approx(left, right)
	var negated: Array = right.map(func(value): return -float(value))
	return direct or _array_approx(left, negated)

func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)

func _items_by_id(values: Array) -> Dictionary:
	var result := {}
	for value in values:
		if value is Dictionary:
			result[str(value.get("id", ""))] = value
	return result
