@tool
class_name FENodeDesignCard
extends GraphNode

signal card_delete_requested(node_id: String)
signal assembly_open_requested(assembly_id: String)
signal placement_changed(instance_id: String, transform: Dictionary)

const CoordinateAdapter = preload("res://addons/future_engine/core/coordinate_adapter.gd")
const FONT_REGULAR = preload("res://assets/fonts/SpaceMono_Regular.ttf")
const FONT_BOLD = preload("res://assets/fonts/SpaceMono_Bold.ttf")
const ICON_COMPONENT := "res://assets/icons/fe-component.svg"
const ICON_ASSEMBLY := "res://assets/icons/fe-assembly.svg"
const ICON_CHEVRON_RIGHT := "res://assets/icons/fe-chevron-right.svg"
const ICON_CHEVRON_DOWN := "res://assets/icons/fe-chevron-down.svg"
const ICON_TRASH := "res://assets/icons/fe-trash.svg"

const NODE_WIDTH := 280.0
const CONTENT_WIDTH := 272.0
const PAPER := Color("fcfbf8")
const PAPER_SUNKEN := Color("f2f0ec")
const PAPER_HOVER := Color("e9e6df")
const INK := Color("242322")
const MUTED := Color("74706b")
const BORDER_SOFT := Color("dfdcd5")
const PASS := Color("278447")
const PASS_SOFT := Color("dff3e4")
const WARN := Color("a36f0b")
const WARN_SOFT := Color("f8edc9")
const FAIL := Color("a33d35")
const FAIL_SOFT := Color("f7dfdc")
const CATEGORY_TONES := [
	Color("287e9d"),
	Color("358866"),
	Color("a34e96"),
	Color("a64e43"),
	Color("7358a5")
]
const DOMAIN_COLORS := {
	"mechanical": Color("252423"),
	"electrical": Color("b17a0d"),
	"signal": Color("287eaa"),
	"fluid": Color("5168b5"),
	"thermal": Color("ad4b3f"),
	"optical": Color("398a60")
}

var model := {}
var writable := false
var _input_ports := {}
var _output_ports := {}
var _parameters_open := false
var _ports_open := true
var _placement_open := false
var _placement_fields: Array[LineEdit] = []
var _port_column_cells: Array[Dictionary] = []
var _port_expansion_tween: Tween
var _hovered_port_side := 0
var _focused_port_side := 0
var _category_color := CATEGORY_TONES[0]
static var _icon_cache := {}

func configure(value: Dictionary, allow_writes: bool) -> void:
	model = value.duplicate(true)
	writable = allow_writes
	name = _safe_node_name(str(model.get("id", "node")))
	title = ""
	position_offset = model.get("position", Vector2.ZERO)
	custom_minimum_size = Vector2(NODE_WIDTH, 0)
	resizable = false
	selectable = true
	_category_color = _category_tone(_category_name())
	_apply_card_theme()
	_build_card()
	if has_signal("delete_request") and not delete_request.is_connected(_on_native_delete_request):
		delete_request.connect(_on_native_delete_request)

func endpoint_for_input(port: int) -> Dictionary:
	return _input_ports.get(port, {}).duplicate(true)

func endpoint_for_output(port: int) -> Dictionary:
	return _output_ports.get(port, {}).duplicate(true)

func input_port_for_handle(handle: String) -> int:
	for port in _input_ports:
		if _input_ports[port].get("handle") == handle:
			return int(port)
	return -1

func output_port_for_handle(handle: String) -> int:
	for port in _output_ports:
		if _output_ports[port].get("handle") == handle:
			return int(port)
	return -1

func select_card(selected: bool) -> void:
	set_selected(selected)

func port_column_ratios() -> Vector2:
	if _port_column_cells.is_empty():
		return Vector2.ONE
	var cells: Dictionary = _port_column_cells[0]
	return Vector2(cells.input.size_flags_stretch_ratio, cells.output.size_flags_stretch_ratio)

func set_port_column_expansion(side: int, animated := true) -> void:
	var input_ratio := 3.0 if side < 0 else 1.0
	var output_ratio := 3.0 if side > 0 else 1.0
	if _port_expansion_tween != null and _port_expansion_tween.is_valid():
		_port_expansion_tween.kill()
	if animated and is_inside_tree():
		_port_expansion_tween = create_tween().set_parallel(true).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
		for cells in _port_column_cells:
			_port_expansion_tween.tween_property(cells.input, "size_flags_stretch_ratio", input_ratio, 0.18)
			_port_expansion_tween.tween_property(cells.output, "size_flags_stretch_ratio", output_ratio, 0.18)
	else:
		for cells in _port_column_cells:
			cells.input.size_flags_stretch_ratio = input_ratio
			cells.output.size_flags_stretch_ratio = output_ratio

func is_section_expanded(section: String) -> bool:
	match section:
		"parameters": return _parameters_open
		"ports": return _ports_open
		"placement": return _placement_open
	return false

func section_state() -> Dictionary:
	return {
		"parameters": _parameters_open,
		"ports": _ports_open,
		"placement": _placement_open
	}

func restore_section_state(state: Dictionary) -> void:
	_parameters_open = bool(state.get("parameters", _parameters_open))
	_ports_open = bool(state.get("ports", _ports_open))
	_placement_open = bool(state.get("placement", _placement_open))
	_build_card()
	_fit_to_content.call_deferred()

func set_section_expanded(section: String, expanded: bool) -> void:
	match section:
		"parameters": _parameters_open = expanded
		"ports": _ports_open = expanded
		"placement": _placement_open = expanded
		_: return
	_build_card()
	_fit_to_content.call_deferred()

func _build_card() -> void:
	if _port_expansion_tween != null and _port_expansion_tween.is_valid():
		_port_expansion_tween.kill()
	_clear_card()
	_input_ports.clear()
	_output_ports.clear()
	_placement_fields.clear()
	_port_column_cells.clear()
	_hovered_port_side = 0
	_focused_port_side = 0
	var kind := str(model.get("kind", "component"))
	var presentation: Dictionary = model.get("presentation", {})
	var release: Dictionary = presentation.get("release", {})
	if kind == "assembly":
		_add_metadata_header("ASSEMBLY", "EXTERNAL" if bool(model.get("external", false)) else "COLLAPSED", "external" if bool(model.get("external", false)) else "ready")
		_add_identity(str(model.get("title", "Assembly")), "Assembly interface")
		_add_ports(model.get("ports", []))
		_add_assembly_action()
		return

	_add_metadata_header(str(release.get("kind", "Component")), str(release.get("category", "Unresolved")), str(release.get("readiness_status", "unknown")))
	_add_identity(str(model.get("title", "Component")), _release_description(release))
	_add_parameters(presentation.get("resolved_configuration", {}))
	_add_ports(model.get("ports", []))
	_add_placement(presentation)
	_add_component_action(presentation)

func _clear_card() -> void:
	for child in get_children():
		remove_child(child)
		child.queue_free()

func _add_metadata_header(kind_text: String, category_text: String, readiness: String) -> void:
	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(CONTENT_WIDTH, 29)
	panel.add_theme_stylebox_override("panel", _flat_style(PAPER_SUNKEN, BORDER_SOFT, 0, 0, 0, 1, 6, 6, 3, 3))
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 5)
	panel.add_child(row)
	var icon := TextureRect.new()
	icon.name = "KindIcon"
	icon.custom_minimum_size = Vector2(13, 13)
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.texture = _load_svg_icon(ICON_ASSEMBLY if model.get("kind") == "assembly" else ICON_COMPONENT, 0.55)
	row.add_child(icon)
	var kind := _label(kind_text.to_upper(), MUTED, 10, true)
	kind.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	kind.clip_text = true
	kind.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	row.add_child(kind)
	var divider := VSeparator.new()
	divider.add_theme_constant_override("separation", 0)
	row.add_child(divider)
	var category := _label(category_text.to_upper(), _category_color, 10, true)
	category.custom_minimum_size.x = 72
	category.clip_text = true
	category.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	category.tooltip_text = category_text
	row.add_child(category)
	row.add_child(_status_badge(readiness))
	add_child(panel)

func _add_identity(display_name: String, description: String) -> void:
	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(CONTENT_WIDTH, 52)
	panel.add_theme_stylebox_override("panel", _flat_style(PAPER, BORDER_SOFT, 0, 0, 0, 1, 7, 7, 6, 6))
	var content := VBoxContainer.new()
	content.add_theme_constant_override("separation", 1)
	panel.add_child(content)
	var heading := _label(display_name, INK, 14, true)
	heading.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	content.add_child(heading)
	var detail := _label(description, MUTED, 10)
	detail.clip_text = true
	detail.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	detail.tooltip_text = description
	content.add_child(detail)
	add_child(panel)

func _add_parameters(configuration: Dictionary) -> void:
	var parameters: Array = configuration.get("parameters", [])
	if parameters.is_empty():
		return
	_add_section_header("parameters", "PARAMETERS", str(parameters.size()), _parameters_open)
	if not _parameters_open:
		return
	for value in parameters:
		if not value is Dictionary:
			continue
		var row_panel := PanelContainer.new()
		row_panel.custom_minimum_size = Vector2(CONTENT_WIDTH, 24)
		row_panel.add_theme_stylebox_override("panel", _flat_style(PAPER, BORDER_SOFT, 0, 0, 0, 1, 7, 7, 2, 2))
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 6)
		row_panel.add_child(row)
		var name_label := _label(str(value.get("name", value.get("id", "Parameter"))), MUTED, 10)
		name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		name_label.clip_text = true
		name_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		name_label.tooltip_text = str(value.get("description", ""))
		row.add_child(name_label)
		var unit := str(value.get("unit", "")) if value.get("unit") != null else ""
		row.add_child(_label("%s%s" % [value.get("value", ""), " %s" % unit if not unit.is_empty() else ""], INK, 10, true))
		add_child(row_panel)

func _add_ports(ports: Array) -> void:
	if ports.is_empty():
		return
	var inputs: Array[Dictionary] = []
	var outputs: Array[Dictionary] = []
	for value in ports:
		if not value is Dictionary:
			continue
		var port: Dictionary = value
		var direction := str(port.get("direction", "bidirectional"))
		if direction in ["input", "bidirectional"]:
			inputs.append(port)
		if direction in ["output", "bidirectional"]:
			outputs.append(port)
	_add_section_header("ports", "PORTS", "%s IN · %s OUT" % [inputs.size(), outputs.size()], _ports_open)
	var row_count := maxi(inputs.size(), outputs.size())
	for index in row_count:
		var input: Dictionary = inputs[index] if index < inputs.size() else {}
		var output: Dictionary = outputs[index] if index < outputs.size() else {}
		_add_port_row(input, output, _ports_open)

func _add_port_row(input: Dictionary, output: Dictionary, expanded: bool) -> void:
	var row := HBoxContainer.new()
	row.custom_minimum_size = Vector2(CONTENT_WIDTH, 25 if expanded else 7)
	row.add_theme_constant_override("separation", 0)
	if expanded:
		var input_cell := _port_cell(input, true)
		var output_cell := _port_cell(output, false)
		row.add_child(input_cell)
		row.add_child(output_cell)
		_port_column_cells.append({"input": input_cell, "output": output_cell})
	else:
		row.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_child(_collapsed_port_cell(input))
		row.add_child(_collapsed_port_cell(output))
	add_child(row)
	var slot := get_child_count() - 1
	var input_endpoint := _endpoint(input)
	var output_endpoint := _endpoint(output)
	var input_enabled := not input.is_empty()
	var output_enabled := not output.is_empty()
	var input_domain := str(input.get("domain", "mechanical"))
	var output_domain := str(output.get("domain", "mechanical"))
	set_slot(slot, input_enabled, _domain_type(input_domain), DOMAIN_COLORS.get(input_domain, INK), output_enabled, _domain_type(output_domain), DOMAIN_COLORS.get(output_domain, INK))
	if input_enabled:
		_input_ports[_input_ports.size()] = input_endpoint
	if output_enabled:
		_output_ports[_output_ports.size()] = output_endpoint

func _port_cell(port: Dictionary, is_input: bool) -> Control:
	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(0, 25)
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panel.size_flags_stretch_ratio = 1.0
	var side := -1 if is_input else 1
	panel.mouse_entered.connect(_on_port_cell_mouse_entered.bind(side))
	panel.mouse_exited.connect(_on_port_cell_mouse_exited.bind(side))
	var left_border := 0 if is_input else 1
	panel.add_theme_stylebox_override("panel", _flat_style(PAPER, BORDER_SOFT, left_border, 0, 0, 1, 9, 9, 1, 1))
	if port.is_empty():
		return panel
	panel.focus_mode = Control.FOCUS_ALL
	panel.focus_entered.connect(_on_port_cell_focus_entered.bind(side))
	panel.focus_exited.connect(_on_port_cell_focus_exited.bind(side))
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 4)
	panel.add_child(row)
	var indicator := ColorRect.new()
	indicator.custom_minimum_size = Vector2(3, 12)
	indicator.color = DOMAIN_COLORS.get(str(port.get("domain", "mechanical")), INK)
	var label := _label(str(port.get("name", port.get("interface_id", "Interface"))), MUTED, 10)
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	label.clip_text = true
	label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	label.tooltip_text = _port_tooltip(port)
	panel.tooltip_text = label.tooltip_text
	if is_input:
		row.add_child(indicator)
		row.add_child(label)
	else:
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		row.add_child(label)
		row.add_child(indicator)
	if not bool(port.get("connectable", false)):
		panel.modulate.a = 0.55
	return panel

func _collapsed_port_cell(port: Dictionary) -> Control:
	var spacer := Control.new()
	spacer.custom_minimum_size = Vector2(CONTENT_WIDTH * 0.5, 7)
	if not port.is_empty():
		spacer.tooltip_text = _port_tooltip(port)
	return spacer

func _add_placement(presentation: Dictionary) -> void:
	var component: Dictionary = model.get("component", {})
	if component.is_empty():
		return
	_add_section_header("placement", "PLACEMENT", "XYZ · RXYZ", _placement_open)
	if not _placement_open:
		return
	var transform: Dictionary = component.get("transform", {"translation_m": [0.0, 0.0, 0.0], "rotation_wxyz": [1.0, 0.0, 0.0, 0.0]})
	var position: Array = transform.get("translation_m", [0.0, 0.0, 0.0])
	var rotation: Array[float] = CoordinateAdapter.quaternion_to_euler_degrees(transform.get("rotation_wxyz", [1.0, 0.0, 0.0, 0.0]))
	var editable := writable and bool(presentation.get("editability", {}).get("editable", false))
	_add_placement_vector("POSITION", ["X", "Y", "Z"], position, "m", editable, -100000.0, 100000.0, 0.001)
	_add_placement_vector("ROTATION", ["RX", "RY", "RZ"], rotation, "°", editable, -360.0, 360.0, 0.1)
	if not editable:
		var reason := str(presentation.get("editability", {}).get("reason", "read_only")).replace("_", " ")
		var note_panel := PanelContainer.new()
		note_panel.custom_minimum_size = Vector2(CONTENT_WIDTH, 24)
		note_panel.add_theme_stylebox_override("panel", _flat_style(WARN_SOFT, WARN, 2, 0, 0, 0, 7, 7, 3, 3))
		var note := _label("MANAGED · %s" % reason.to_upper(), WARN, 9, true)
		note_panel.add_child(note)
		add_child(note_panel)

func _add_placement_vector(label_text: String, axes: Array, values: Array, unit: String, editable: bool, minimum: float, maximum: float, step: float) -> void:
	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(CONTENT_WIDTH, 58)
	panel.add_theme_stylebox_override("panel", _flat_style(PAPER, BORDER_SOFT, 0, 0, 0, 1, 7, 7, 3, 4))
	var content := VBoxContainer.new()
	content.add_theme_constant_override("separation", 3)
	panel.add_child(content)
	content.add_child(_label(label_text, MUTED, 9, true))
	var fields := HBoxContainer.new()
	fields.add_theme_constant_override("separation", 3)
	content.add_child(fields)
	for index in 3:
		var cell := PanelContainer.new()
		cell.custom_minimum_size = Vector2(83, 28)
		cell.add_theme_stylebox_override("panel", _flat_style(PAPER_SUNKEN if editable else PAPER, BORDER_SOFT, 1, 1, 1, 1, 3, 3, 1, 1))
		var coordinate := HBoxContainer.new()
		coordinate.add_theme_constant_override("separation", 2)
		cell.add_child(coordinate)
		coordinate.add_child(_label(str(axes[index]), MUTED, 8, true))
		var field := LineEdit.new()
		field.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		field.text = String.num(float(values[index]) if index < values.size() else 0.0, 3)
		field.editable = editable
		field.flat = true
		field.alignment = HORIZONTAL_ALIGNMENT_RIGHT
		field.tooltip_text = "%s %s (%s); range %s to %s, step %s" % [label_text.capitalize(), axes[index], unit, minimum, maximum, step]
		field.add_theme_font_override("font", FONT_REGULAR)
		field.add_theme_font_size_override("font_size", 8)
		field.add_theme_color_override("font_color", INK if editable else MUTED)
		field.add_theme_color_override("font_uneditable_color", MUTED)
		field.add_theme_color_override("caret_color", INK)
		field.add_theme_stylebox_override("normal", _flat_style(Color.TRANSPARENT, Color.TRANSPARENT))
		field.add_theme_stylebox_override("read_only", _flat_style(Color.TRANSPARENT, Color.TRANSPARENT))
		field.add_theme_stylebox_override("focus", _flat_style(PAPER, INK, 1, 1, 1, 1, 1, 1, 0, 0))
		field.text_changed.connect(_on_placement_text_changed)
		coordinate.add_child(field)
		coordinate.add_child(_label(unit, MUTED, 8))
		fields.add_child(cell)
		_placement_fields.append(field)
	add_child(panel)

func _add_section_header(section: String, label_text: String, count: String, expanded: bool) -> void:
	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(CONTENT_WIDTH, 27)
	panel.add_theme_stylebox_override("panel", _flat_style(PAPER, BORDER_SOFT, 0, 0, 0, 1, 4, 6, 1, 1))
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 4)
	panel.add_child(row)
	var toggle := Button.new()
	toggle.name = "Section_%s" % section.capitalize()
	toggle.text = label_text
	toggle.flat = true
	toggle.alignment = HORIZONTAL_ALIGNMENT_LEFT
	toggle.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	toggle.focus_mode = Control.FOCUS_ALL
	toggle.tooltip_text = "%s %s" % ["Collapse" if expanded else "Expand", label_text.to_lower()]
	toggle.set_meta("fe_section", section)
	toggle.icon = _load_svg_icon(ICON_CHEVRON_DOWN if expanded else ICON_CHEVRON_RIGHT, 0.42)
	_style_flat_button(toggle, MUTED, 10, true)
	toggle.pressed.connect(_toggle_section.bind(section))
	row.add_child(toggle)
	var count_label := _label(count, MUTED, 10)
	count_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	count_label.custom_minimum_size.x = 74
	row.add_child(count_label)
	add_child(panel)

func _add_component_action(presentation: Dictionary) -> void:
	var component: Dictionary = model.get("component", {})
	var locked := component.get("generated") is Dictionary or not str(component.get("locked_by_assembly_id", "")).is_empty()
	var can_delete := writable and not locked
	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(CONTENT_WIDTH, 32)
	panel.add_theme_stylebox_override("panel", _flat_style(PAPER, BORDER_SOFT, 0, 0, 0, 0, 7, 7, 3, 3))
	var row := HBoxContainer.new()
	panel.add_child(row)
	var action := Button.new()
	action.name = "DeleteAction"
	action.text = "" if can_delete else "LOCKED"
	if can_delete:
		action.icon = _load_svg_icon(ICON_TRASH, 0.50)
		action.custom_minimum_size = Vector2(24, 24)
	action.flat = true
	action.disabled = not can_delete
	action.tooltip_text = "Delete component and dependent relationships" if can_delete else "This component is managed and cannot be deleted"
	_style_flat_button(action, FAIL if can_delete else MUTED, 9, true)
	if can_delete:
		action.pressed.connect(func(): card_delete_requested.emit(str(model.get("id", ""))))
	row.add_child(action)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(spacer)
	var editability: Dictionary = presentation.get("editability", {})
	var state := _label(str(editability.get("reason", "unknown")).replace("_", " ").to_upper(), MUTED, 9, true)
	row.add_child(state)
	add_child(panel)

func _add_assembly_action() -> void:
	var external := bool(model.get("external", false))
	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(CONTENT_WIDTH, 34)
	panel.add_theme_stylebox_override("panel", _flat_style(PAPER, BORDER_SOFT, 0, 0, 0, 0, 7, 7, 3, 3))
	var action := Button.new()
	action.text = "OPEN ASSEMBLY"
	action.disabled = external
	action.tooltip_text = "External assemblies are opened from their owning context" if external else "Navigate into this assembly"
	_style_flat_button(action, _category_color, 10, true)
	if not external:
		action.pressed.connect(func(): assembly_open_requested.emit(str(model.get("assembly_id", ""))))
	panel.add_child(action)
	add_child(panel)

func _status_badge(readiness: String) -> PanelContainer:
	var normalized := readiness.to_lower()
	var label_text := "PASS"
	var foreground := PASS
	var background := PASS_SOFT
	if normalized in ["warning", "warn", "stale", "external"]:
		label_text = "WARN" if normalized != "external" else "EXT"
		foreground = WARN
		background = WARN_SOFT
	elif normalized in ["blocked", "conflict", "fail", "error"]:
		label_text = "FAIL"
		foreground = FAIL
		background = FAIL_SOFT
	elif normalized not in ["ready", "pass", "reviewed", "collapsed"]:
		label_text = normalized.left(5).to_upper() if not normalized.is_empty() else "QUEUE"
		foreground = MUTED
		background = PAPER_HOVER
	var badge := PanelContainer.new()
	badge.custom_minimum_size = Vector2(47, 20)
	badge.add_theme_stylebox_override("panel", _flat_style(background, foreground, 1, 1, 1, 1, 5, 5, 1, 1))
	var label := _label(label_text, foreground, 9, true)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	badge.add_child(label)
	badge.tooltip_text = "Readiness: %s" % readiness
	return badge

func _endpoint(port: Dictionary) -> Dictionary:
	if port.is_empty():
		return {}
	var direction := str(port.get("direction", "bidirectional"))
	var domain := str(port.get("domain", "mechanical"))
	var state := str(port.get("state", "available"))
	return {
		"node_id": str(model.get("id", "")),
		"instance_id": str(model.get("instance_id", port.get("original_endpoint", {}).get("instance_id", ""))),
		"interface_id": port.get("original_endpoint", {}).get("interface_id", port.get("interface_id")),
		"handle": str(port.get("interface_id", "")),
		"domain": domain,
		"direction": direction,
		"compatibility_key": str(port.get("compatibility_key", "")),
		"connectable": writable and bool(port.get("connectable", false)),
		"state": state,
		"state_message": str(port.get("state_message", "")),
		"body_anchor": bool(port.get("body_anchor", false))
	}

func _port_tooltip(port: Dictionary) -> String:
	if port.is_empty():
		return ""
	var capacity: Dictionary = port.get("capacity", {})
	return "%s\n%s · %s\n%s · %s/%s\n%s" % [
		port.get("name", port.get("interface_id", "Interface")),
		str(port.get("domain", "mechanical")).to_upper(),
		str(port.get("direction", "bidirectional")).to_upper(),
		str(port.get("state", "available")).replace("_", " ").to_upper(),
		capacity.get("used", 0),
		capacity.get("maximum", "?"),
		port.get("state_message", port.get("description", ""))
	]

func _toggle_section(section: String) -> void:
	set_section_expanded(section, not is_section_expanded(section))

func _on_port_cell_mouse_entered(side: int) -> void:
	_hovered_port_side = side
	_sync_port_column_expansion()

func _on_port_cell_mouse_exited(side: int) -> void:
	if _hovered_port_side == side:
		_hovered_port_side = 0
	_sync_port_column_expansion.call_deferred()

func _on_port_cell_focus_entered(side: int) -> void:
	_focused_port_side = side
	_sync_port_column_expansion()

func _on_port_cell_focus_exited(side: int) -> void:
	if _focused_port_side == side:
		_focused_port_side = 0
	_sync_port_column_expansion.call_deferred()

func _sync_port_column_expansion() -> void:
	set_port_column_expansion(_focused_port_side if _focused_port_side != 0 else _hovered_port_side)

func _on_placement_text_changed(_value: String) -> void:
	if _placement_fields.size() != 6:
		return
	var presentation: Dictionary = model.get("presentation", {})
	if not writable or not bool(presentation.get("editability", {}).get("editable", false)):
		return
	var values: Array[float] = []
	for field in _placement_fields:
		if not field.text.is_valid_float():
			return
		values.append(float(field.text))
	placement_changed.emit(str(model.get("instance_id", "")), {
		"translation_m": [values[0], values[1], values[2]],
		"rotation_wxyz": CoordinateAdapter.euler_degrees_to_quaternion([values[3], values[4], values[5]])
	})

func _on_native_delete_request() -> void:
	card_delete_requested.emit(str(model.get("id", "")))

func _apply_card_theme() -> void:
	var base := _flat_style(PAPER, _category_color, 2, 2, 2, 2, 2, 2, 2, 2)
	var selected_style := _flat_style(PAPER, _category_color, 2, 2, 2, 2, 2, 2, 2, 2)
	selected_style.shadow_color = Color(INK, 0.78)
	selected_style.shadow_size = 3
	selected_style.shadow_offset = Vector2(3, 3)
	add_theme_stylebox_override("panel", base)
	add_theme_stylebox_override("panel_selected", selected_style)
	add_theme_stylebox_override("titlebar", _flat_style(PAPER, _category_color, 0, 0, 0, 0))
	add_theme_stylebox_override("titlebar_selected", _flat_style(PAPER, _category_color, 0, 0, 0, 0))
	add_theme_font_override("title_font", FONT_BOLD)
	add_theme_font_size_override("title_font_size", 1)
	add_theme_color_override("title_color", PAPER)
	var titlebar := get_titlebar_hbox()
	if titlebar:
		titlebar.visible = false
		titlebar.custom_minimum_size = Vector2.ZERO
		for child in titlebar.get_children():
			if child is Control:
				child.visible = false
				child.custom_minimum_size = Vector2.ZERO

func _fit_to_content() -> void:
	size = get_combined_minimum_size()

func _label(text_value: String, color: Color, size: int, bold := false) -> Label:
	var label := Label.new()
	label.text = text_value
	label.add_theme_font_override("font", FONT_BOLD if bold else FONT_REGULAR)
	label.add_theme_font_size_override("font_size", size)
	label.add_theme_color_override("font_color", color)
	return label

static func _load_svg_icon(path: String, scale: float) -> Texture2D:
	var key := "%s@%s" % [path, scale]
	if _icon_cache.has(key):
		return _icon_cache[key]
	var image := Image.new()
	var error := image.load_svg_from_string(FileAccess.get_file_as_string(path), scale)
	if error != OK:
		return null
	var texture := ImageTexture.create_from_image(image)
	_icon_cache[key] = texture
	return texture

func _style_flat_button(button: Button, color: Color, size: int, bold := false) -> void:
	button.add_theme_font_override("font", FONT_BOLD if bold else FONT_REGULAR)
	button.add_theme_font_size_override("font_size", size)
	button.add_theme_color_override("font_color", color)
	button.add_theme_color_override("font_hover_color", INK)
	button.add_theme_color_override("font_pressed_color", INK)
	button.add_theme_color_override("font_focus_color", INK)
	button.add_theme_stylebox_override("normal", _flat_style(Color.TRANSPARENT, Color.TRANSPARENT, 0, 0, 0, 0, 2, 2, 0, 0))
	button.add_theme_stylebox_override("hover", _flat_style(PAPER_HOVER, Color.TRANSPARENT, 0, 0, 0, 0, 2, 2, 0, 0))
	button.add_theme_stylebox_override("pressed", _flat_style(PAPER_HOVER, Color.TRANSPARENT, 0, 0, 0, 0, 2, 2, 0, 0))
	button.add_theme_stylebox_override("focus", _flat_style(Color.TRANSPARENT, INK, 1, 1, 1, 1, 2, 2, 0, 0))

func _flat_style(background: Color, border_color: Color, left := 0, top := 0, right := 0, bottom := 0, margin_left := 0.0, margin_right := 0.0, margin_top := 0.0, margin_bottom := 0.0) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = background
	style.border_color = border_color
	style.border_width_left = left
	style.border_width_top = top
	style.border_width_right = right
	style.border_width_bottom = bottom
	style.content_margin_left = margin_left
	style.content_margin_right = margin_right
	style.content_margin_top = margin_top
	style.content_margin_bottom = margin_bottom
	style.corner_radius_top_left = 0
	style.corner_radius_top_right = 0
	style.corner_radius_bottom_left = 0
	style.corner_radius_bottom_right = 0
	return style

func _release_description(release: Dictionary) -> String:
	var item_key := str(release.get("item_key", "unreleased"))
	if item_key.contains("/"):
		item_key = item_key.get_slice("/", item_key.get_slice_count("/") - 1)
	return "%s@%s" % [item_key, release.get("version", "?")]

func _category_name() -> String:
	if model.get("kind") == "assembly":
		return "assembly"
	return str(model.get("presentation", {}).get("release", {}).get("category", "component"))

func _category_tone(category: String) -> Color:
	var hash_value := 0
	for index in category.length():
		hash_value = ((hash_value << 5) - hash_value + category.unicode_at(index))
	return CATEGORY_TONES[absi(hash_value) % CATEGORY_TONES.size()]

func _domain_type(domain: String) -> int:
	match domain:
		"mechanical": return 1
		"electrical": return 2
		"signal": return 3
		"fluid": return 4
		"thermal": return 5
		"optical": return 6
	return 0

func _safe_node_name(value: String) -> String:
	return value.replace(".", "_").replace(":", "_").replace("@", "_").replace("/", "_").replace("\"", "_").replace("%", "_")
