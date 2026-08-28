@tool
class_name FEBackendSettings
extends Window

signal configuration_observed(configuration: Dictionary)
signal backend_changed(configuration: Dictionary)

var _backend: FEBackendClient
var _requests := {}
var _configuration := {}
var _routing_key := ""
var _updating := false
var _refresh_pending := false
var _mode: OptionButton
var _server: OptionButton
var _effective: Label
var _server_detail: Label
var _discovery: Label
var _services: GridContainer
var _poll_timer: Timer

func configure(client: FEBackendClient) -> void:
	_backend = client
	title = "Future Engine Backends"
	name = "FutureEngineBackendSettings"
	size = Vector2i(650, 590)
	min_size = Vector2i(560, 480)
	transient = true
	close_requested.connect(hide)
	_build_ui()
	_backend.response_completed.connect(_on_response)
	_backend.transport_failed.connect(_on_transport_failed)
	_poll_timer = Timer.new()
	_poll_timer.wait_time = 5.0
	_poll_timer.autostart = true
	_poll_timer.timeout.connect(refresh)
	add_child(_poll_timer)
	refresh.call_deferred()

func show_settings() -> void:
	popup_centered(size)
	refresh(true)

func refresh(force := false) -> void:
	if _refresh_pending or not is_instance_valid(_backend):
		return
	_refresh_pending = true
	var suffix := "?refresh=1" if force else ""
	var request_id := _backend.request_json(HTTPClient.METHOD_GET, "/gateway/configuration%s" % suffix)
	_requests[request_id] = "refresh"

func _build_ui() -> void:
	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 20)
	margin.add_theme_constant_override("margin_top", 18)
	margin.add_theme_constant_override("margin_right", 20)
	margin.add_theme_constant_override("margin_bottom", 18)
	add_child(margin)
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 12)
	margin.add_child(root)
	var heading := Label.new()
	heading.text = "BACKEND CONNECTION"
	heading.add_theme_font_size_override("font_size", 18)
	root.add_child(heading)
	var introduction := Label.new()
	introduction.text = "Auto uses live services only when every FE port on the selected server is reachable. Mock is always visibly identified."
	introduction.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	root.add_child(introduction)
	var form := GridContainer.new()
	form.columns = 2
	form.add_theme_constant_override("h_separation", 16)
	form.add_theme_constant_override("v_separation", 8)
	root.add_child(form)
	var mode_label := Label.new()
	mode_label.text = "Mode"
	form.add_child(mode_label)
	_mode = OptionButton.new()
	_mode.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_add_option(_mode, "Auto · live when all ports run", "auto")
	_add_option(_mode, "Live · require selected server", "upstream")
	_add_option(_mode, "Mock · deterministic fixtures", "mock")
	_mode.item_selected.connect(_on_selection_changed)
	form.add_child(_mode)
	var server_label := Label.new()
	server_label.text = "Backend server"
	form.add_child(server_label)
	_server = OptionButton.new()
	_server.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_server.item_selected.connect(_on_selection_changed)
	form.add_child(_server)
	_effective = Label.new()
	_effective.text = "CHECKING BACKEND…"
	root.add_child(_effective)
	_server_detail = Label.new()
	_server_detail.text = "Waiting for gateway discovery."
	root.add_child(_server_detail)
	_discovery = Label.new()
	_discovery.text = "Tailscale discovery: checking"
	root.add_child(_discovery)
	var divider := HSeparator.new()
	root.add_child(divider)
	var ports_heading := HBoxContainer.new()
	var ports_label := Label.new()
	ports_label.text = "SERVICE PORTS"
	ports_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	ports_heading.add_child(ports_label)
	var refresh_button := Button.new()
	refresh_button.text = "Refresh ports"
	refresh_button.pressed.connect(refresh.bind(true))
	ports_heading.add_child(refresh_button)
	root.add_child(ports_heading)
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(scroll)
	_services = GridContainer.new()
	_services.columns = 4
	_services.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_services.add_theme_constant_override("h_separation", 14)
	_services.add_theme_constant_override("v_separation", 7)
	scroll.add_child(_services)

func _add_option(control: OptionButton, label: String, metadata: String) -> void:
	control.add_item(label)
	control.set_item_metadata(control.item_count - 1, metadata)

func _on_selection_changed(_index: int) -> void:
	if _updating or _server.item_count == 0:
		return
	var payload := {
		"mode": str(_mode.get_item_metadata(_mode.selected)),
		"server_id": str(_server.get_item_metadata(_server.selected))
	}
	_effective.text = "APPLYING BACKEND SELECTION…"
	var request_id := _backend.request_json(HTTPClient.METHOD_POST, "/gateway/configuration", payload)
	_requests[request_id] = "select"

func _on_response(request_id: int, status: int, payload: Variant, _headers: Dictionary) -> void:
	if not _requests.has(request_id):
		return
	var action := str(_requests.get(request_id))
	_requests.erase(request_id)
	if action == "refresh":
		_refresh_pending = false
	if status < 200 or status >= 300 or not payload is Dictionary:
		var message := str(payload.get("error", {}).get("message", "Gateway configuration request failed.")) if payload is Dictionary else "Gateway configuration request failed."
		_effective.text = "BACKEND CONFIGURATION ERROR · %s" % message
		_effective.modulate = Color("ff7b72")
		return
	_apply_configuration(payload)

func _on_transport_failed(request_id: int, message: String) -> void:
	if not _requests.has(request_id):
		return
	var action := str(_requests.get(request_id))
	_requests.erase(request_id)
	if action == "refresh":
		_refresh_pending = false
	_effective.text = "GATEWAY OFFLINE · %s" % message
	_effective.modulate = Color("ff7b72")

func _apply_configuration(value: Dictionary) -> void:
	var previous_key := _routing_key
	_configuration = value.duplicate(true)
	_updating = true
	_select_metadata(_mode, str(value.get("requested_mode", "auto")))
	_server.clear()
	var selected_id := str(value.get("selected_server_id", "local"))
	for server_value in value.get("servers", []):
		if not server_value is Dictionary:
			continue
		var source := str(server_value.get("source", ""))
		var suffix := " · Tailscale" if source == "tailscale" else (" · configured" if source == "configured" else "")
		if server_value.get("online") == false:
			suffix += " · offline"
		_server.add_item("%s%s" % [server_value.get("name", server_value.get("host", "Server")), suffix])
		_server.set_item_metadata(_server.item_count - 1, str(server_value.get("id", "")))
	_select_metadata(_server, selected_id)
	_updating = false
	var effective := str(value.get("effective_mode", "mock"))
	var all_ports := bool(value.get("all_ports_available", false))
	if effective == "upstream":
		_effective.text = "LIVE BACKEND · ALL PORTS RUNNING" if all_ports else "LIVE REQUESTED · SOME PORTS ARE OFFLINE"
		_effective.modulate = Color("6ee7a8") if all_ports else Color("ffcf66")
	else:
		_effective.text = "MOCK BACKEND · %s" % ("SELECTED" if value.get("requested_mode") == "mock" else "AUTO FALLBACK — LIVE PORTS INCOMPLETE")
		_effective.modulate = Color("ffcf66")
	var selected: Dictionary = value.get("selected_server", {})
	_server_detail.text = "%s · %s" % [selected.get("name", "Backend"), selected.get("host", "unknown host")]
	_discovery.text = "Tailscale discovery: %s · %s server(s) visible" % [str(value.get("discovery", {}).get("tailscale", "unavailable")).replace("_", " "), value.get("servers", []).size()]
	_rebuild_services(value.get("services", []))
	_routing_key = "%s|%s|%s" % [value.get("requested_mode", ""), effective, selected_id]
	configuration_observed.emit(_configuration)
	if not previous_key.is_empty() and previous_key != _routing_key:
		backend_changed.emit(_configuration)

func _select_metadata(control: OptionButton, value: String) -> void:
	for index in control.item_count:
		if str(control.get_item_metadata(index)) == value:
			control.select(index)
			return

func _rebuild_services(values: Array) -> void:
	for child in _services.get_children():
		_services.remove_child(child)
		child.queue_free()
	for heading in ["", "SERVICE", "PORT", "STATE"]:
		var label := Label.new()
		label.text = heading
		label.modulate = Color("aaa7a1")
		_services.add_child(label)
	for service_value in values:
		if not service_value is Dictionary:
			continue
		var running := str(service_value.get("status", "offline")) == "running"
		var color := Color("6ee7a8") if running else Color("ff7b72")
		var dot := Label.new()
		dot.text = "●"
		dot.modulate = color
		_services.add_child(dot)
		var service := Label.new()
		service.text = str(service_value.get("label", service_value.get("id", "Service")))
		service.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_services.add_child(service)
		var port := Label.new()
		port.text = str(service_value.get("port", "—"))
		_services.add_child(port)
		var state := Label.new()
		state.text = "RUNNING" if running else "OFFLINE"
		state.modulate = color
		_services.add_child(state)
