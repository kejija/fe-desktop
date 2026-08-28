@tool
class_name FENodeDesignWorkspace
extends VBoxContainer

signal instance_selected(instance_id: String, additive: bool)
signal relationship_selected(edge: Dictionary)
signal assembly_requested(assembly_id: String)
signal profile_requested(profile_id: String)
signal connection_requested(endpoint_a: Dictionary, endpoint_b: Dictionary)
signal placement_changed(instance_id: String, transform: Dictionary)
signal layout_changed(changes: Dictionary)
signal delete_requested(node_ids: PackedStringArray)
signal save_requested
signal undo_requested
signal redo_requested
signal view_3d_requested
signal preview_apply_requested
signal preview_cancel_requested
signal preview_refresh_requested

const Card = preload("res://addons/future_engine/modules/system_design/graph_card.gd")
const Model = preload("res://addons/future_engine/modules/system_design/graph_model.gd")
const FONT_REGULAR = preload("res://assets/fonts/SpaceMono_Regular.ttf")
const FONT_BOLD = preload("res://assets/fonts/SpaceMono_Bold.ttf")
const PAPER := Color("fcfbf8")
const PAPER_SUNKEN := Color("f2f0ec")
const INK := Color("242322")
const MUTED := Color("74706b")
const BORDER := Color("c9c5bd")

var graph: GraphEdit
var _canvas_host: Control
var _edge_overlay: Control
var _toolbar: HBoxContainer
var _breadcrumbs: HBoxContainer
var _profile: OptionButton
var _state: Label
var _legend: Label
var _preview_panel: PanelContainer
var _preview_content: VBoxContainer
var _model := {}
var _cards := {}
var _edge_buttons := {}
var _edge_routes := {}
var _card_section_states := {}
var _selected_edge_id := ""
var _drag_origin := {}
var _read_only := true
var _registration_snap_enabled := true
var _active_assembly_id := ""
var _fit_after_rebuild := false

func _ready() -> void:
	if graph == null:
		_build_ui()

func configure() -> void:
	if graph == null:
		_build_ui()

func show_projection(model: Dictionary, profiles: Array, active_profile_id: String, read_only: bool, save_state: String) -> void:
	configure()
	_model = model.duplicate(true)
	var next_assembly_id := str(model.get("active_assembly_id", ""))
	_fit_after_rebuild = next_assembly_id != _active_assembly_id
	_active_assembly_id = next_assembly_id
	_read_only = read_only
	_state.text = save_state
	_build_breadcrumbs(model.get("breadcrumbs", []))
	_populate_profiles(profiles, active_profile_id)
	_rebuild_graph()

func set_save_state(value: String) -> void:
	if is_instance_valid(_state):
		_state.text = value

func select_instance(instance_id: String) -> void:
	for node_id in _cards:
		var card: Variant = _cards[node_id]
		card.select_card(str(card.model.get("instance_id", "")) == instance_id)

func select_relationship(relationship_id: String) -> void:
	for edge in _model.get("edges", []):
		for member in edge.get("members", []):
			if member.get("relationship_id") == relationship_id:
				_selected_edge_id = str(edge.get("id", ""))
				_update_edge_labels()
				relationship_selected.emit(edge)
				return

func show_preview(preview: Dictionary) -> void:
	for child in _preview_content.get_children():
		child.queue_free()
	_preview_panel.visible = true
	var heading := Label.new()
	heading.text = "CONNECTION PREVIEW · %s" % str(preview.get("compatibility", "unknown")).to_upper()
	heading.modulate = Color("6ee7a8") if preview.get("compatibility") in ["exact", "review"] else Color("ff7b72")
	_preview_content.add_child(heading)
	_add_preview_row("Kind", str(preview.get("inferred_kind", "unknown")))
	_add_preview_row("Endpoints", "%s:%s → %s:%s" % [preview.get("endpoint_a", {}).get("instance_id", ""), preview.get("endpoint_a", {}).get("interface_id", ""), preview.get("endpoint_b", {}).get("instance_id", ""), preview.get("endpoint_b", {}).get("interface_id", "")])
	_add_preview_row("Moved subtree", ", ".join(PackedStringArray(preview.get("moved_subtree", []))))
	_add_preview_row("Feature matches", str(preview.get("feature_matches", []).size()))
	_add_preview_row("Generated hardware", str(preview.get("hardware", []).size()))
	if preview.get("joint_type") != null:
		_add_preview_row("Mechanical joint", str(preview.get("joint_type")))
	for warning in preview.get("warnings", []):
		_add_preview_row("Warning", "%s · %s" % [warning.get("code", "warning"), warning.get("message", warning)] if warning is Dictionary else str(warning), Color("ffcf66"))
	for blocker in preview.get("blockers", []):
		_add_preview_row("Blocker", "%s · %s" % [blocker.get("code", "blocker"), blocker.get("message", blocker)] if blocker is Dictionary else str(blocker), Color("ff7b72"))
	for policy in preview.get("policy_overrides", {}):
		_add_preview_row("Mount policy", "%s = %s" % [policy, preview.get("policy_overrides", {})[policy]])
	var actions := HBoxContainer.new()
	var apply := Button.new()
	apply.text = "Apply atomically"
	apply.disabled = _read_only or preview.get("compatibility") == "incompatible" or not preview.get("blockers", []).is_empty()
	apply.pressed.connect(func(): preview_apply_requested.emit())
	actions.add_child(apply)
	var review := Button.new()
	review.text = "Review in 3D"
	review.pressed.connect(func(): view_3d_requested.emit())
	actions.add_child(review)
	var refresh := Button.new()
	refresh.text = "Re-preview"
	refresh.pressed.connect(func(): preview_refresh_requested.emit())
	actions.add_child(refresh)
	var cancel := Button.new()
	cancel.text = "Cancel"
	cancel.pressed.connect(func(): preview_cancel_requested.emit())
	actions.add_child(cancel)
	_preview_content.add_child(actions)

func hide_preview() -> void:
	if is_instance_valid(_preview_panel):
		_preview_panel.visible = false

func _build_ui() -> void:
	name = "System Design"
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	custom_minimum_size = Vector2(720, 540)
	_build_toolbar()
	_canvas_host = Control.new()
	_canvas_host.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_canvas_host.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_canvas_host.custom_minimum_size = Vector2(640, 480)
	add_child(_canvas_host)
	graph = GraphEdit.new()
	graph.name = "NodeDesignGraph"
	graph.minimap_enabled = true
	graph.show_zoom_label = true
	graph.snapping_enabled = true
	graph.snapping_distance = int(Model.MINOR_GRID)
	graph.zoom_min = Model.MIN_ZOOM
	graph.zoom_max = Model.MAX_ZOOM
	graph.zoom_step = 1.1
	graph.connection_lines_thickness = 1.25
	graph.connection_lines_curvature = 0.28
	graph.connection_lines_antialiased = true
	_apply_graph_theme()
	graph.connection_request.connect(_on_connection_request)
	graph.node_selected.connect(_on_node_selected)
	graph.node_deselected.connect(_on_node_deselected)
	if graph.has_signal("begin_node_move"):
		graph.begin_node_move.connect(_on_begin_node_move)
	if graph.has_signal("end_node_move"):
		graph.end_node_move.connect(_on_end_node_move)
	if graph.has_signal("delete_nodes_request"):
		graph.delete_nodes_request.connect(_on_delete_nodes_request)
	graph.gui_input.connect(_on_graph_input)
	_canvas_host.add_child(graph)
	graph.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_edge_overlay = Control.new()
	_edge_overlay.name = "RelationshipLabels"
	_edge_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_canvas_host.add_child(_edge_overlay)
	_edge_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_preview_panel = PanelContainer.new()
	_preview_panel.visible = false
	_preview_panel.custom_minimum_size = Vector2(0, 148)
	_preview_content = VBoxContainer.new()
	_preview_panel.add_child(_preview_content)
	add_child(_preview_panel)
	set_process(true)

func _build_toolbar() -> void:
	_toolbar = HBoxContainer.new()
	add_child(_toolbar)
	var brand := Label.new()
	brand.text = "SYSTEM DESIGN"
	brand.modulate = Color("68d9ff")
	_toolbar.add_child(brand)
	_toolbar.add_child(VSeparator.new())
	_breadcrumbs = HBoxContainer.new()
	_breadcrumbs.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_toolbar.add_child(_breadcrumbs)
	_profile = OptionButton.new()
	_profile.tooltip_text = "Active presentation/simulation profile"
	_profile.item_selected.connect(_on_profile_selected)
	_toolbar.add_child(_profile)
	_toolbar.add_child(_button("Fit", _fit_graph, "Fit graph to the workspace"))
	_toolbar.add_child(_button("Arrange", _arrange, "Arrange and snap nodes"))
	_toolbar.add_child(_button("−", _zoom.bind(-0.1), "Zoom out"))
	_toolbar.add_child(_button("+", _zoom.bind(0.1), "Zoom in"))
	var snap := CheckButton.new()
	snap.text = "Snap 140"
	snap.button_pressed = true
	snap.toggled.connect(func(enabled): _registration_snap_enabled = enabled; graph.snapping_enabled = enabled)
	_toolbar.add_child(snap)
	var minimap := CheckButton.new()
	minimap.text = "Minimap"
	minimap.button_pressed = true
	minimap.toggled.connect(func(enabled): graph.minimap_enabled = enabled)
	_toolbar.add_child(minimap)
	_toolbar.add_child(_button("Save", func(): save_requested.emit(), "Save draft"))
	_toolbar.add_child(_button("View in 3D", func(): view_3d_requested.emit(), "Open the stock Godot 3D editor"))
	_state = Label.new()
	_state.text = "NO DESIGN"
	_state.modulate = Color("8ea6ba")
	_toolbar.add_child(_state)
	_legend = Label.new()
	_legend.text = "MECHANICAL ●  ELECTRICAL ●  SIGNAL ●   STATUS: compatible / warning / unverified / incompatible"
	_legend.modulate = Color("9fb4c7")
	add_child(_legend)

func _button(text: String, callback: Callable, tooltip: String) -> Button:
	var button := Button.new()
	button.text = text
	button.tooltip_text = tooltip
	button.pressed.connect(callback)
	return button

func _build_breadcrumbs(values: Array) -> void:
	for child in _breadcrumbs.get_children():
		child.queue_free()
	for index in values.size():
		if index > 0:
			var separator := Label.new()
			separator.text = "›"
			_breadcrumbs.add_child(separator)
		var value: Dictionary = values[index]
		var button := Button.new()
		button.text = str(value.get("name", "Assembly"))
		button.flat = true
		button.pressed.connect(func(): assembly_requested.emit(str(value.get("assembly_id", ""))))
		_breadcrumbs.add_child(button)

func _populate_profiles(profiles: Array, active_profile_id: String) -> void:
	_profile.clear()
	for profile in profiles:
		if profile is Dictionary:
			_profile.add_item(str(profile.get("name", profile.get("profile_id", "Profile"))))
			_profile.set_item_metadata(_profile.item_count - 1, str(profile.get("profile_id", "")))
			if profile.get("profile_id") == active_profile_id:
				_profile.select(_profile.item_count - 1)

func _on_profile_selected(index: int) -> void:
	if index >= 0:
		profile_requested.emit(str(_profile.get_item_metadata(index)))

func _rebuild_graph() -> void:
	graph.clear_connections()
	for node_id in _cards:
		var card: Variant = _cards[node_id]
		if is_instance_valid(card):
			_card_section_states[str(node_id)] = card.section_state()
			card.queue_free()
	_cards.clear()
	for child in _edge_overlay.get_children():
		child.queue_free()
	_edge_buttons.clear()
	_edge_routes.clear()
	for value in _model.get("nodes", []):
		if not value is Dictionary:
			continue
		var card: Variant = Card.new()
		card.configure(value, not _read_only)
		var node_id := str(value.get("id", ""))
		if _card_section_states.has(node_id):
			card.restore_section_state(_card_section_states[node_id])
		card.position_offset_changed.connect(_on_card_moved.bind(card))
		card.card_delete_requested.connect(func(node_id): delete_requested.emit(PackedStringArray([node_id])))
		card.assembly_open_requested.connect(func(assembly_id): assembly_requested.emit(assembly_id))
		card.placement_changed.connect(func(instance_id, transform): placement_changed.emit(instance_id, transform))
		graph.add_child(card)
		card.reset_size()
		_cards[node_id] = card
	for edge in _model.get("edges", []):
		_connect_edge(edge)
		_add_edge_button(edge)
	_fit_card_sizes.call_deferred()
	_update_edge_labels.call_deferred()

func _fit_card_sizes() -> void:
	for card in _cards.values():
		if is_instance_valid(card):
			card.size = card.get_combined_minimum_size()
	if _fit_after_rebuild:
		_fit_after_rebuild = false
		_fit_graph()
	_update_edge_positions()

func _connect_edge(edge: Dictionary) -> void:
	var source: Variant = _cards.get(str(edge.get("source_node", "")))
	var target: Variant = _cards.get(str(edge.get("target_node", "")))
	if source == null or target == null:
		return
	var source_port: int = source.output_port_for_handle(str(edge.get("source_handle", "")))
	var target_port: int = target.input_port_for_handle(str(edge.get("target_handle", "")))
	if source_port < 0 or target_port < 0:
		var reverse_source: int = target.output_port_for_handle(str(edge.get("target_handle", "")))
		var reverse_target: int = source.input_port_for_handle(str(edge.get("source_handle", "")))
		if reverse_source >= 0 and reverse_target >= 0:
			graph.connect_node(target.name, reverse_source, source.name, reverse_target)
			_edge_routes[str(edge.get("id", ""))] = {"source": target, "source_port": reverse_source, "target": source, "target_port": reverse_target}
		return
	graph.connect_node(source.name, source_port, target.name, target_port)
	_edge_routes[str(edge.get("id", ""))] = {"source": source, "source_port": source_port, "target": target, "target_port": target_port}

func _add_edge_button(edge: Dictionary) -> void:
	var button := Button.new()
	button.name = str(edge.get("id", "edge")).replace(".", "_").replace(":", "_").replace("@", "_").replace("/", "_").replace("%", "_")
	button.text = _edge_label(edge, false)
	button.tooltip_text = _edge_tooltip(edge)
	button.mouse_filter = Control.MOUSE_FILTER_STOP
	button.custom_minimum_size = Vector2(58, 22)
	button.add_theme_font_override("font", FONT_BOLD)
	button.add_theme_font_size_override("font_size", 9)
	button.add_theme_color_override("font_color", MUTED)
	button.add_theme_color_override("font_hover_color", INK)
	button.add_theme_color_override("font_pressed_color", INK)
	button.add_theme_stylebox_override("normal", _edge_label_style(PAPER))
	button.add_theme_stylebox_override("hover", _edge_label_style(PAPER_SUNKEN))
	button.add_theme_stylebox_override("pressed", _edge_label_style(PAPER_SUNKEN))
	button.add_theme_stylebox_override("focus", _edge_label_style(PAPER_SUNKEN, INK))
	button.pressed.connect(_on_edge_pressed.bind(edge))
	_edge_overlay.add_child(button)
	_edge_buttons[str(edge.get("id", ""))] = button

func _on_edge_pressed(edge: Dictionary) -> void:
	_selected_edge_id = str(edge.get("id", ""))
	_update_edge_labels()
	relationship_selected.emit(edge)

func _edge_label(edge: Dictionary, expanded: bool) -> String:
	if expanded:
		return "%s · %s · %s member%s" % [edge.get("domain", "relationship"), edge.get("status", "unverified"), edge.get("members", []).size(), "s" if edge.get("members", []).size() != 1 else ""]
	var abbreviations := {"mechanical": "MECH", "electrical": "ELEC", "signal": "SIG", "fluid": "FLUID", "thermal": "THERM", "optical": "OPT"}
	var domain := str(edge.get("domain", "relationship"))
	var status := str(edge.get("status", "unverified"))
	var short_domain := str(abbreviations.get(domain, domain.to_upper().left(5)))
	return short_domain if status == "compatible" else "%s · %s" % [short_domain, "REVIEW" if status == "warning" else status.to_upper()]

func _edge_tooltip(edge: Dictionary) -> String:
	var lines := PackedStringArray([str(edge.get("label", "Relationship"))])
	for member in edge.get("members", []):
		lines.append("%s · %s:%s → %s:%s" % [member.get("relationship_id", ""), member.get("source", {}).get("instance_id", ""), member.get("source", {}).get("interface_id", "body"), member.get("target", {}).get("instance_id", ""), member.get("target", {}).get("interface_id", "body")])
	return "\n".join(lines)

func _process(_delta: float) -> void:
	if visible and not _edge_buttons.is_empty():
		_update_edge_positions()

func _update_edge_positions() -> void:
	for edge in _model.get("edges", []):
		var button: Button = _edge_buttons.get(str(edge.get("id", "")))
		var route: Dictionary = _edge_routes.get(str(edge.get("id", "")), {})
		if button == null or route.is_empty():
			continue
		var source: GraphNode = route.source
		var target: GraphNode = route.target
		var source_port := int(route.source_port)
		var target_port := int(route.target_port)
		if source_port >= source.get_output_port_count() or target_port >= target.get_input_port_count():
			button.visible = false
			continue
		var from_position := source.position_offset + source.get_output_port_position(source_port)
		var to_position := target.position_offset + target.get_input_port_position(target_port)
		var display_path := PackedVector2Array()
		for point in graph.get_connection_line(from_position, to_position):
			display_path.append(point * graph.zoom - graph.scroll_offset)
		var label_bounds := Rect2(Vector2(12, 48), graph.size - Vector2(24, 60))
		var midpoint: Variant = visible_path_midpoint(display_path, label_bounds)
		button.visible = midpoint != null
		if midpoint != null:
			button.position = Vector2(midpoint) - button.size * 0.5

static func visible_path_midpoint(points: PackedVector2Array, visible_rect: Rect2) -> Variant:
	if points.size() < 2 or visible_rect.size.x <= 0 or visible_rect.size.y <= 0:
		return null
	var segments: Array[Dictionary] = []
	var visible_length := 0.0
	for index in range(points.size() - 1):
		var start := points[index]
		var finish := points[index + 1]
		var center := (start + finish) * 0.5
		if not visible_rect.has_point(start) and not visible_rect.has_point(finish) and not visible_rect.has_point(center):
			continue
		var length := start.distance_to(finish)
		if length <= 0.0:
			continue
		segments.append({"start": start, "finish": finish, "length": length})
		visible_length += length
	if segments.is_empty():
		return null
	var target_length := visible_length * 0.5
	var walked := 0.0
	for segment in segments:
		var next := walked + float(segment.length)
		if next >= target_length:
			return Vector2(segment.start).lerp(Vector2(segment.finish), (target_length - walked) / float(segment.length))
		walked = next
	return Vector2(segments[-1].finish)

func _update_edge_labels() -> void:
	for edge in _model.get("edges", []):
		var button: Button = _edge_buttons.get(str(edge.get("id", "")))
		if button:
			var selected := str(edge.get("id", "")) == _selected_edge_id
			button.text = _edge_label(edge, selected)
			button.custom_minimum_size = Vector2(220, 26) if selected else Vector2(58, 22)
			var status_color := _status_color(str(edge.get("status", "unverified")))
			button.modulate = Color.WHITE
			button.add_theme_color_override("font_color", INK if edge.get("status") == "compatible" else status_color)
			button.add_theme_stylebox_override("normal", _edge_label_style(PAPER, status_color))

func _on_connection_request(from_node: StringName, from_port: int, to_node: StringName, to_port: int) -> void:
	if _read_only:
		return
	var source: Variant = _card_by_graph_name(from_node)
	var target: Variant = _card_by_graph_name(to_node)
	if source == null or target == null:
		return
	var endpoint_a: Dictionary = source.endpoint_for_output(from_port)
	var endpoint_b: Dictionary = target.endpoint_for_input(to_port)
	if endpoint_a.is_empty() or endpoint_b.is_empty():
		return
	if endpoint_a.instance_id == endpoint_b.instance_id or not endpoint_a.connectable or not endpoint_b.connectable:
		return
	if endpoint_a.domain != endpoint_b.domain:
		return
	if not endpoint_a.compatibility_key.is_empty() and not endpoint_b.compatibility_key.is_empty() and endpoint_a.compatibility_key != endpoint_b.compatibility_key:
		return
	connection_requested.emit({"instance_id": endpoint_a.instance_id, "interface_id": endpoint_a.interface_id}, {"instance_id": endpoint_b.instance_id, "interface_id": endpoint_b.interface_id})

func _on_node_selected(node: Node) -> void:
	if node is GraphNode and node.has_method("endpoint_for_input"):
		var instance_id := str(node.model.get("instance_id", ""))
		if not instance_id.is_empty():
			instance_selected.emit(instance_id, Input.is_key_pressed(KEY_SHIFT))

func _on_node_deselected(_node: Node) -> void:
	pass

func _on_begin_node_move() -> void:
	_drag_origin.clear()
	for node_id in _cards:
		var card: Variant = _cards[node_id]
		if card.selected:
			_drag_origin[node_id] = card.position_offset

func _on_end_node_move() -> void:
	var changes := {}
	for node_id in _drag_origin:
		var card: Variant = _cards.get(node_id)
		if card == null:
			continue
		var snapped: Vector2 = Model.snap_position(card.position_offset) if _registration_snap_enabled else card.position_offset
		card.position_offset = snapped
		if not snapped.is_equal_approx(_drag_origin[node_id]):
			changes[node_id] = {"before": _drag_origin[node_id], "after": snapped}
	if not changes.is_empty():
		layout_changed.emit(changes)
	_drag_origin.clear()

func _on_card_moved(_card: GraphNode) -> void:
	_update_edge_positions()

func _on_delete_nodes_request(nodes: Array[StringName]) -> void:
	var ids := PackedStringArray()
	for graph_name in nodes:
		var card: Variant = _card_by_graph_name(graph_name)
		if card:
			ids.append(str(card.model.get("id", "")))
	if not ids.is_empty():
		delete_requested.emit(ids)

func _on_graph_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and event.keycode in [KEY_DELETE, KEY_BACKSPACE] and not _selected_edge_id.is_empty():
		var ids := PackedStringArray()
		for edge in _model.get("edges", []):
			if edge.get("id") == _selected_edge_id:
				for member in edge.get("members", []):
					ids.append("relationship:%s" % member.get("relationship_id", ""))
				break
		if not ids.is_empty():
			delete_requested.emit(ids)
		accept_event()
		return
	if event is InputEventKey and event.pressed and (event.ctrl_pressed or event.meta_pressed):
		if event.keycode == KEY_Z and event.shift_pressed:
			redo_requested.emit()
			accept_event()
		elif event.keycode == KEY_Z:
			undo_requested.emit()
			accept_event()
		elif event.keycode == KEY_Y:
			redo_requested.emit()
			accept_event()

func _card_by_graph_name(graph_name: StringName) -> Variant:
	for card in _cards.values():
		if card.name == graph_name:
			return card
	return null

func _fit_graph() -> void:
	if _cards.is_empty():
		return
	if graph.size.x <= 1.0 or graph.size.y <= 1.0:
		_fit_after_rebuild = true
		return
	var bounds := Rect2()
	var first := true
	for card in _cards.values():
		var rect := Rect2(card.position_offset, card.size)
		bounds = rect if first else bounds.merge(rect)
		first = false
	var available := graph.size - Vector2(96, 96)
	var scale := minf(available.x / maxf(bounds.size.x, 1), available.y / maxf(bounds.size.y, 1))
	graph.zoom = clampf(scale, Model.MIN_ZOOM, minf(1.0, Model.MAX_ZOOM))
	graph.scroll_offset = bounds.get_center() * graph.zoom - graph.size * 0.5
	_update_edge_positions.call_deferred()

func _arrange() -> void:
	_on_begin_node_move()
	graph.arrange_nodes()
	for card in _cards.values():
		card.position_offset = Model.snap_position(card.position_offset)
	_on_end_node_move()

func _zoom(delta: float) -> void:
	graph.zoom = clampf(graph.zoom + delta, Model.MIN_ZOOM, Model.MAX_ZOOM)

func _add_preview_row(label_text: String, value: String, color := Color("dbe7f2")) -> void:
	var label := Label.new()
	label.text = "%s · %s" % [label_text.to_upper(), value]
	label.modulate = color
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_preview_content.add_child(label)

func _status_color(status: String) -> Color:
	match status:
		"compatible": return Color("278447")
		"warning": return Color("a36f0b")
		"incompatible": return Color("a33d35")
	return MUTED

func _apply_graph_theme() -> void:
	graph.add_theme_font_override("font", FONT_REGULAR)
	graph.add_theme_font_size_override("font_size", 10)
	graph.add_theme_color_override("grid_minor", Color(INK, 0.075))
	graph.add_theme_color_override("grid_major", Color(INK, 0.18))
	graph.add_theme_color_override("selection_fill", Color("287e9d33"))
	graph.add_theme_color_override("selection_stroke", Color("287e9d"))
	graph.add_theme_color_override("activity", Color("287e9d"))
	graph.add_theme_color_override("connection_rim_color", Color(INK, 0.04))
	graph.add_theme_color_override("connection_hover_tint_color", Color(INK, 0.16))
	graph.add_theme_constant_override("connection_hover_thickness", 2)
	var panel := StyleBoxFlat.new()
	panel.bg_color = PAPER_SUNKEN
	panel.border_color = BORDER
	panel.border_width_left = 1
	panel.border_width_top = 1
	panel.border_width_right = 1
	panel.border_width_bottom = 1
	graph.add_theme_stylebox_override("panel", panel)
	graph.add_theme_stylebox_override("menu_panel", panel)

func _edge_label_style(background: Color, border_color := BORDER) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = background
	style.border_color = border_color
	style.border_width_left = 2
	style.border_width_top = 1
	style.border_width_right = 1
	style.border_width_bottom = 1
	style.content_margin_left = 6
	style.content_margin_right = 6
	style.content_margin_top = 2
	style.content_margin_bottom = 2
	return style
