@tool
class_name FESystemDesignModule
extends FEFrontendModule

const GraphModel = preload("res://addons/future_engine/modules/system_design/graph_model.gd")
const GraphWorkspace = preload("res://addons/future_engine/modules/system_design/graph_workspace.gd")

var _host: EditorPlugin
var _backend: FEBackendClient
var _projection: FESceneProjection
var _live: FELiveSession
var _requests := {}
var _document := {}
var _presentation := {}
var _revision := 0
var _design_id := ""
var _profile_id := ""
var _writes_blocked := true
var _dirty := false
var _undo_stack: Array[Dictionary] = []
var _redo_stack: Array[Dictionary] = []
var _save_timer: Timer
var _active_session_id := ""
var _pending_after_save := ""
var _pending_connection := {}
var _connection_preview := {}
var _selected_catalog := {}
var _selected_instance_id := ""
var _selected_instance_ids := PackedStringArray()
var _selected_relationship_id := ""
var _select_relationship_after_refresh := ""
var _active_assembly_id := ""
var _open_main_after_load := false
var _queued_preview := {}
var _last_graph_placement_instance := ""
var _last_graph_placement_edit_msec := 0

var _left_dock: VBoxContainer
var _right_dock: VBoxContainer
var _designs_list: VBoxContainer
var _design_items: VBoxContainer
var _assembly_tree: Tree
var _catalog_list: ItemList
var _workspace: FENodeDesignWorkspace
var _inspector: VBoxContainer
var _diagnostics: RichTextLabel
var _compile_output: RichTextLabel
var _telemetry: RichTextLabel
var _connection_state: Label

func _init() -> void:
	id = &"system_design"
	display_name = "System Design"
	required_services = PackedStringArray(["node-design", "components", "simulation"])

func register_ui(host: EditorPlugin) -> void:
	_host = host
	_backend = host.backend
	_projection = host.projection
	_live = host.live_session
	_build_left_dock()
	_build_right_dock()
	_build_bottom_panel()
	_workspace = GraphWorkspace.new()
	_workspace.configure()
	_workspace.instance_selected.connect(_on_workspace_instance_selected)
	_workspace.relationship_selected.connect(_show_relationship)
	_workspace.assembly_requested.connect(_open_assembly)
	_workspace.profile_requested.connect(_change_profile)
	_workspace.connection_requested.connect(_request_connection_preview)
	_workspace.placement_changed.connect(_on_graph_placement_changed)
	_workspace.layout_changed.connect(_on_graph_layout_changed)
	_workspace.delete_requested.connect(_delete_graph_items)
	_workspace.save_requested.connect(_save_now)
	_workspace.undo_requested.connect(_undo)
	_workspace.redo_requested.connect(_redo)
	_workspace.view_3d_requested.connect(_view_in_3d)
	_workspace.preview_apply_requested.connect(_apply_connection)
	_workspace.preview_cancel_requested.connect(_cancel_connection_preview)
	_workspace.preview_refresh_requested.connect(_repeat_connection_preview)
	host.mount_dock(EditorPlugin.DOCK_SLOT_LEFT_UL, _left_dock)
	host.mount_dock(EditorPlugin.DOCK_SLOT_RIGHT_UL, _right_dock)
	host.mount_bottom(_bottom_tabs(), "Future Engine")
	host.mount_main(_workspace)
	host.register_toolbar_action("Save", _save_now, "Persist the current Future Engine draft")
	host.register_toolbar_action("Checkpoint", _checkpoint, "Create a backend checkpoint")
	host.register_toolbar_action("Compile", _compile, "Compile the selected simulation profile")
	host.register_toolbar_action("Run", _run_live, "Compile and start live simulation")
	host.register_toolbar_action("Pause", _pause_live, "Pause live simulation")
	host.register_toolbar_action("Reset", _reset_live, "Reset live simulation")
	host.register_toolbar_action("Undo", _undo, "Undo the last anchor edit")
	host.register_toolbar_action("Redo", _redo, "Redo the last undone anchor edit")
	host.register_toolbar_action("System Design", host.show_system_design, "Return to the full System Design graph")
	host.register_toolbar_action("Profile", _show_profile_editor, "Edit the active simulation profile")
	host.register_toolbar_action("Hide", _hide_selected, "Hide the selected component in the local projection")
	host.register_toolbar_action("Isolate", _isolate_selected, "Show only the selected component")
	host.register_toolbar_action("Show all", _projection.show_all, "Restore component visibility")
	host.register_toolbar_action("Explode", _projection.set_explosion.bind(0.08), "Apply a local exploded view")
	host.register_toolbar_action("Collapse", _projection.set_explosion.bind(0.0), "Collapse the local exploded view")
	_save_timer = Timer.new()
	_save_timer.name = "FutureEngineAutosave"
	_save_timer.one_shot = true
	_save_timer.wait_time = 0.8
	host.add_child(_save_timer)
	_save_timer.timeout.connect(_save_now)
	_backend.response_completed.connect(_on_response)
	_backend.transport_failed.connect(_on_transport_failed)
	_projection.anchor_transform_changed.connect(_on_anchor_transform_changed)
	_live.state_received.connect(_on_live_state)
	_live.status_changed.connect(_on_live_status)
	_live.session_error.connect(_diagnostic_error)
	host.get_editor_interface().get_selection().selection_changed.connect(_on_editor_selection_changed)

func activate() -> void:
	_request("health", HTTPClient.METHOD_GET, "/healthz")
	_request("designs", HTTPClient.METHOD_GET, "/node-design/v1/designs")
	_request("templates", HTTPClient.METHOD_GET, "/node-design/v1/design-templates")
	_request("catalog", HTTPClient.METHOD_GET, "/components/v1/items")

func deactivate() -> void:
	_save_timer.stop()
	_live.close()

func backend_configuration_changed(configuration: Dictionary) -> void:
	if _dirty and not _design_id.is_empty():
		FERecoveryStore.save(_design_id, _revision, _design(), "Backend changed before draft save")
	_save_timer.stop()
	_live.close()
	_cancel_connection_preview()
	_writes_blocked = true
	_dirty = false
	if not _presentation.is_empty():
		_populate_graph()
	_requests.clear()
	_document = {}
	_presentation = {}
	_revision = 0
	_design_id = ""
	_profile_id = ""
	_selected_instance_id = ""
	_selected_instance_ids = PackedStringArray()
	_selected_relationship_id = ""
	_connection_state.text = "Switching to %s · %s…" % [str(configuration.get("effective_mode", "backend")).capitalize(), configuration.get("selected_server", {}).get("name", "server")]
	activate()

func shutdown() -> void:
	if _dirty and not _design_id.is_empty():
		FERecoveryStore.save(_design_id, _revision, _design(), "Plugin shutdown before draft save")
	if is_instance_valid(_save_timer):
		_save_timer.queue_free()

func open_context(context: Dictionary) -> void:
	var design_id := str(context.get("design_id", ""))
	if not design_id.is_empty():
		_open_design(design_id)

func _build_left_dock() -> void:
	_left_dock = VBoxContainer.new()
	_left_dock.name = "Future Engine"
	_left_dock.custom_minimum_size = Vector2(310, 420)
	var heading := Label.new()
	heading.text = "FUTURE ENGINE · SYSTEM DESIGN"
	_apply_brand_font(heading)
	_left_dock.add_child(heading)
	_connection_state = Label.new()
	_connection_state.text = "Connecting to gateway…"
	_left_dock.add_child(_connection_state)
	var tabs := TabContainer.new()
	tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_left_dock.add_child(tabs)

	_designs_list = VBoxContainer.new()
	_designs_list.name = "Designs"
	var create_button := Button.new()
	create_button.text = "+ New design"
	create_button.pressed.connect(_create_design)
	_designs_list.add_child(create_button)
	var designs_scroll := ScrollContainer.new()
	designs_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_design_items = VBoxContainer.new()
	_design_items.name = "DesignItems"
	_design_items.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	designs_scroll.add_child(_design_items)
	_designs_list.add_child(designs_scroll)
	tabs.add_child(_designs_list)

	_assembly_tree = Tree.new()
	_assembly_tree.name = "Assembly"
	_assembly_tree.hide_root = true
	_assembly_tree.item_selected.connect(_on_assembly_selected)
	tabs.add_child(_assembly_tree)

	var catalog_panel := VBoxContainer.new()
	catalog_panel.name = "Catalog"
	_catalog_list = ItemList.new()
	_catalog_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_catalog_list.item_selected.connect(_on_catalog_selected)
	catalog_panel.add_child(_catalog_list)
	var insert_button := Button.new()
	insert_button.text = "Insert selected release"
	insert_button.pressed.connect(_insert_catalog_selection)
	catalog_panel.add_child(insert_button)
	tabs.add_child(catalog_panel)


func _build_right_dock() -> void:
	_right_dock = VBoxContainer.new()
	_right_dock.name = "FE Inspector"
	_right_dock.custom_minimum_size = Vector2(320, 420)
	var heading := Label.new()
	heading.text = "INSPECT"
	_apply_brand_font(heading)
	_right_dock.add_child(heading)
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_inspector = VBoxContainer.new()
	_inspector.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_inspector)
	_right_dock.add_child(scroll)
	_show_inspector_message("Open a System Design to inspect its released components.")

func _build_bottom_panel() -> void:
	_diagnostics = RichTextLabel.new()
	_diagnostics.name = "Diagnostics"
	_diagnostics.fit_content = false
	_diagnostics.bbcode_enabled = true
	_diagnostics.text = "Future Engine diagnostics will appear here."
	_compile_output = RichTextLabel.new()
	_compile_output.name = "Compile"
	_compile_output.bbcode_enabled = true
	_compile_output.text = "No compilation has run."
	_telemetry = RichTextLabel.new()
	_telemetry.name = "Telemetry"
	_telemetry.bbcode_enabled = true
	_telemetry.text = "No live session is connected."

func _bottom_tabs() -> TabContainer:
	var tabs := TabContainer.new()
	tabs.name = "Future Engine"
	tabs.custom_minimum_size = Vector2(0, 190)
	tabs.add_child(_diagnostics)
	tabs.add_child(_compile_output)
	tabs.add_child(_telemetry)
	return tabs

func _request(action: String, method: HTTPClient.Method, path: String, payload: Variant = null, headers := PackedStringArray()) -> int:
	var request_id := _backend.request_json(method, path, payload, headers)
	_requests[request_id] = action
	return request_id

func _on_response(request_id: int, status: int, payload: Variant, _headers: Dictionary) -> void:
	if not _requests.has(request_id):
		return
	var action := str(_requests.get(request_id, "unknown"))
	_requests.erase(request_id)
	if status < 200 or status >= 300:
		_handle_error(action, status, payload)
		return
	match action:
		"health":
			var mode := str(payload.get("mode", "upstream")) if payload is Dictionary else "upstream"
			_connection_state.text = "%s gateway connected" % mode.capitalize()
			_host.set_backend_mode(mode)
		"designs":
			_populate_designs(payload)
		"catalog":
			_populate_catalog(payload)
		"templates":
			pass
		"create":
			if payload is Dictionary:
				_open_design(str(payload.get("summary", {}).get("design_id", "")))
		"document":
			_accept_document(payload)
		"presentation":
			_accept_presentation(payload)
		"save":
			_accept_saved_draft(payload)
		"checkpoint":
			_diagnostic_info("Checkpoint created at revision %s." % _revision)
		"compile", "compile_for_live":
			_accept_compile(payload, action == "compile_for_live")
		"session_create":
			_accept_session(payload)
		"session_control":
			if payload is Dictionary:
				_on_live_state(payload)
		"connection_preview":
			_accept_connection_preview(payload)
		"connection_apply":
			_accept_applied_connection(payload)
		"hydrate":
			_accept_hydrated_release(payload)

func _on_transport_failed(request_id: int, message: String) -> void:
	if not _requests.has(request_id):
		return
	var action := str(_requests.get(request_id, "request"))
	_requests.erase(request_id)
	_writes_blocked = true
	_connection_state.text = "Gateway disconnected"
	_host.set_backend_mode("offline")
	if not _presentation.is_empty():
		_populate_graph()
	_diagnostic_error("%s failed: %s" % [action, message])

func _handle_error(action: String, status: int, payload: Variant) -> void:
	var error: Dictionary = payload.get("error", {}) if payload is Dictionary else {}
	var code := str(error.get("code", "http_%s" % status))
	var message := str(error.get("message", "Request failed with HTTP %s." % status))
	if action == "presentation" and status in [404, 501]:
		_writes_blocked = true
		_host.set_backend_mode("unsupported")
		_connection_state.text = "Read-only · presentation graph required"
		_show_inspector_message("This backend does not implement future-engine.system-design-presentation.v1. Upstream editing is disabled.")
		if not _presentation.is_empty():
			_populate_graph()
		_diagnostic_error("Presentation API required: %s" % message)
		return
	if status == 409:
		_writes_blocked = true
		_cancel_connection_preview()
		if not _design_id.is_empty() and not _document.is_empty():
			FERecoveryStore.save(_design_id, _revision, _design(), "%s: %s" % [code, message])
		if not _presentation.is_empty():
			_populate_graph()
		_diagnostic_error("Revision conflict. Writes are stopped and a local recovery snapshot was saved. Reload the design to continue.")
		return
	_diagnostic_error("%s: %s" % [code, message])

func _populate_designs(payload: Variant) -> void:
	for child in _design_items.get_children():
		child.queue_free()
	var items: Array = payload.get("data", []) if payload is Dictionary else []
	var first_design_id := ""
	for value in items:
		if not value is Dictionary:
			continue
		var button := Button.new()
		button.text = "%s\nDraft r%s" % [value.get("name", "Untitled"), value.get("draft_revision_number", "?")]
		button.alignment = HORIZONTAL_ALIGNMENT_LEFT
		button.pressed.connect(_open_design.bind(str(value.get("design_id", ""))))
		_design_items.add_child(button)
		if first_design_id.is_empty():
			first_design_id = str(value.get("design_id", ""))
	if items.is_empty():
		var empty := Label.new()
		empty.text = "No System Designs found."
		_design_items.add_child(empty)
	elif _design_id.is_empty() and not first_design_id.is_empty():
		_open_design.call_deferred(first_design_id, false)

func _populate_catalog(payload: Variant) -> void:
	_catalog_list.clear()
	var items: Array = payload.get("data", []) if payload is Dictionary else []
	for value in items:
		if value is Dictionary:
			var index := _catalog_list.add_item("%s · %s" % [value.get("name", value.get("item_key", "Component")), value.get("version", "")])
			_catalog_list.set_item_metadata(index, value)

func _create_design() -> void:
	_request("create", HTTPClient.METHOD_POST, "/node-design/v1/designs", {"name": "Untitled System Design", "description": "Created from Future Engine Desktop"})

func _open_design(design_id: String, focus_main_screen := true) -> void:
	if design_id.is_empty():
		return
	if _dirty and not _design_id.is_empty():
		FERecoveryStore.save(_design_id, _revision, _design(), "Design switched before draft save")
	_design_id = design_id
	_open_main_after_load = focus_main_screen
	_active_assembly_id = ""
	_writes_blocked = true
	_dirty = false
	_live.close()
	_request("document", HTTPClient.METHOD_GET, "/node-design/v1/designs/%s" % design_id.uri_encode())

func _accept_document(payload: Variant) -> void:
	var errors := FEContractValidator.validate_design_document(payload)
	if not errors.is_empty():
		_diagnostic_error("Invalid design document:\n%s" % "\n".join(errors))
		return
	_document = payload.duplicate(true)
	_design_id = str(_document.get("summary", {}).get("design_id", ""))
	_revision = int(_document.get("draft", {}).get("revision_number", 0))
	var profiles: Array = _design().get("profiles", [])
	_profile_id = str(profiles[0].get("profile_id", "default")) if not profiles.is_empty() else "default"
	_request("presentation", HTTPClient.METHOD_GET, "/node-design/v1/designs/%s/presentation?profile_id=%s" % [_design_id.uri_encode(), _profile_id.uri_encode()], null, PackedStringArray(["If-Match: %s" % _revision]))

func _accept_presentation(payload: Variant) -> void:
	var errors := FEContractValidator.validate_presentation(payload, _design_id, _revision)
	if not errors.is_empty():
		_writes_blocked = true
		_host.set_backend_mode("unsupported")
		_connection_state.text = "Read-only · presentation graph required"
		_show_inspector_message("Presentation graph required. The backend response is missing authoritative interfaces or relationships.")
		_diagnostic_error("Invalid presentation:\n%s" % "\n".join(errors))
		return
	_presentation = payload.duplicate(true)
	_writes_blocked = false
	FERecoveryStore.clear(_design_id)
	_populate_assembly()
	_populate_graph()
	_populate_diagnostics()
	var build_error := _projection.build(_design(), _presentation)
	if build_error != OK:
		_diagnostic_error("Generated scene could not be created: %s" % error_string(build_error))
	else:
		_connection_state.text = "%s · draft r%s" % [_document.get("summary", {}).get("name", "System Design"), _revision]
		_show_inspector_message("Select a component in the Assembly, Graph, or 3D workspace.")
		if _open_main_after_load:
			_open_main_after_load = false
			_host.show_system_design()
		if not _select_relationship_after_refresh.is_empty():
			_workspace.select_relationship(_select_relationship_after_refresh)
			_select_relationship_after_refresh = ""
		_resume_after_save()

func _accept_saved_draft(payload: Variant) -> void:
	if not payload is Dictionary or not payload.get("draft") is Dictionary:
		_diagnostic_error("The saved draft response must contain {draft}.")
		return
	var draft: Dictionary = payload.get("draft")
	if not draft.get("design") is Dictionary or int(draft.get("revision_number", 0)) <= _revision:
		_diagnostic_error("The saved draft response is invalid or stale.")
		return
	_document["draft"] = draft.duplicate(true)
	_document["summary"]["draft_revision_number"] = int(draft.get("revision_number"))
	_revision = int(draft.get("revision_number"))
	_dirty = false
	_writes_blocked = false
	_workspace.set_save_state("SAVED · r%s" % _revision)
	FERecoveryStore.clear(_design_id)
	_request("presentation", HTTPClient.METHOD_GET, "/node-design/v1/designs/%s/presentation?profile_id=%s" % [_design_id.uri_encode(), _profile_id.uri_encode()], null, PackedStringArray(["If-Match: %s" % _revision]))

func _accept_applied_connection(payload: Variant) -> void:
	if not payload is Dictionary or str(payload.get("connection_id", "")).is_empty():
		_diagnostic_error("Connection apply must return {draft, connection_id}.")
		return
	_select_relationship_after_refresh = str(payload.get("connection_id"))
	_cancel_connection_preview()
	_accept_saved_draft({"draft": payload.get("draft")})

func _save_now() -> void:
	if not _dirty or _writes_blocked or _design_id.is_empty():
		return
	_save_timer.stop()
	_workspace.set_save_state("SAVING · r%s" % _revision)
	_request("save", HTTPClient.METHOD_PUT, "/node-design/v1/designs/%s/draft" % _design_id.uri_encode(), {"design": _design()}, PackedStringArray(["If-Match: %s" % _revision]))

func _checkpoint() -> void:
	if _writes_blocked or _design_id.is_empty():
		return
	if _dirty:
		_pending_after_save = "checkpoint"
		_save_now()
		return
	_request("checkpoint", HTTPClient.METHOD_POST, "/node-design/v1/designs/%s/checkpoints" % _design_id.uri_encode(), {"label": "Manual checkpoint"}, PackedStringArray(["If-Match: %s" % _revision]))

func _compile() -> void:
	if _writes_blocked or _design_id.is_empty():
		return
	if _dirty:
		_pending_after_save = "compile"
		_save_now()
		return
	_request("compile", HTTPClient.METHOD_POST, "/node-design/v1/designs/%s/compile" % _design_id.uri_encode(), {"revision_number": _revision, "profile_id": _profile_id})

func _accept_compile(payload: Variant, start_live: bool) -> void:
	_compile_output.text = "[b]Compilation complete[/b]\nRevision: %s\nProfile: %s\nPackage: %s" % [_revision, _profile_id, payload.get("package_digest", "unknown")]
	if start_live:
		_request("session_create", HTTPClient.METHOD_POST, "/simulation/v1/sessions", {"design_id": _design_id, "revision_number": _revision, "profile_id": _profile_id, "package_digest": payload.get("package_digest")})

func _run_live() -> void:
	if _writes_blocked or _design_id.is_empty():
		return
	if _active_session_id.is_empty():
		if _dirty:
			_pending_after_save = "run"
			_save_now()
			return
		_request("compile_for_live", HTTPClient.METHOD_POST, "/node-design/v1/designs/%s/compile" % _design_id.uri_encode(), {"revision_number": _revision, "profile_id": _profile_id})
		return
	_control_live("run")

func _accept_session(payload: Variant) -> void:
	_active_session_id = str(payload.get("session_id", ""))
	if _active_session_id.is_empty():
		_diagnostic_error("Simulation service returned no session_id.")
		return
	_live.connect_session(_backend.gateway_url, _active_session_id)
	_populate_graph()
	_control_live("run")

func _pause_live() -> void:
	_control_live("pause")

func _reset_live() -> void:
	_control_live("reset")
	_projection.clear_live_poses()

func _control_live(command: String) -> void:
	if _active_session_id.is_empty():
		return
	_live.send_command({"command": command})
	_request("session_control", HTTPClient.METHOD_POST, "/simulation/v1/sessions/%s/control" % _active_session_id.uri_encode(), {"command": command})

func _on_live_state(state: Dictionary) -> void:
	var poses: Array = state.get("poses", [])
	_projection.apply_live_poses(poses)
	_telemetry.text = "[b]Live session[/b] %s\nStatus: %s\nSequence: %s\nRealtime factor: %s\nLag: %s s\nPoses: %s\nActuators: %s\nSensors: %s" % [_active_session_id, state.get("status", "connected"), state.get("sequence", "?"), state.get("realtime_factor", "?"), state.get("lag_s", "?"), poses.size(), state.get("actuators", []).size(), state.get("sensors", []).size()]

func _on_live_status(status: String) -> void:
	_diagnostic_info("Live simulation %s." % status)

func _on_anchor_transform_changed(instance_id: String, transform: Transform3D) -> void:
	if _writes_blocked or _active_session_id:
		return
	_push_undo()
	for instance in _design().get("component_instances", []):
		if instance is Dictionary and instance.get("instance_id") == instance_id:
			instance["transform"] = FECoordinateAdapter.godot_transform_to_fe(transform)
			_dirty = true
			_save_timer.start()
			_show_instance(instance_id)
			return

func _on_graph_placement_changed(instance_id: String, transform: Dictionary) -> void:
	if _writes_blocked or not _active_session_id.is_empty():
		return
	var presentation := _presentation_instance(instance_id)
	if not bool(presentation.get("editability", {}).get("editable", false)):
		return
	var instance := _design_instance(instance_id)
	if instance.is_empty():
		return
	var now := Time.get_ticks_msec()
	if instance_id != _last_graph_placement_instance or now - _last_graph_placement_edit_msec > 800:
		_push_undo()
	_last_graph_placement_instance = instance_id
	_last_graph_placement_edit_msec = now
	instance["transform"] = transform.duplicate(true)
	_mark_dirty("Anchor placement changed")
	_show_instance(instance_id)

func _push_undo() -> void:
	_undo_stack.append(_design().duplicate(true))
	if _undo_stack.size() > 50:
		_undo_stack.pop_front()
	_redo_stack.clear()

func _mark_dirty(message := "") -> void:
	_dirty = true
	_workspace.set_save_state("UNSAVED · autosave 800 ms")
	_save_timer.start()
	if not message.is_empty():
		_diagnostic_info("%s; autosave scheduled." % message)

func _undo() -> void:
	if _undo_stack.is_empty() or _writes_blocked:
		return
	_redo_stack.append(_design().duplicate(true))
	_document.draft.design = _undo_stack.pop_back()
	_dirty = true
	_save_timer.start()
	_diagnostic_info("Anchor edit undone; autosave scheduled.")

func _redo() -> void:
	if _redo_stack.is_empty() or _writes_blocked:
		return
	_undo_stack.append(_design().duplicate(true))
	_document.draft.design = _redo_stack.pop_back()
	_dirty = true
	_save_timer.start()
	_diagnostic_info("Anchor edit redone; autosave scheduled.")

func _populate_assembly() -> void:
	_assembly_tree.clear()
	var hidden_root := _assembly_tree.create_item()
	var assembly_items := {}
	for assembly in _design().get("assemblies", []):
		if assembly is Dictionary:
			var parent: TreeItem = assembly_items.get(str(assembly.get("parent_assembly_id", "")), hidden_root)
			var item := _assembly_tree.create_item(parent)
			item.set_text(0, str(assembly.get("name", "Assembly")))
			item.set_metadata(0, {"kind": "assembly", "id": assembly.get("assembly_id")})
			assembly_items[assembly.get("assembly_id")] = item
	for instance in _presentation.get("instances", []):
		if not instance is Dictionary:
			continue
		var design_instance := _design_instance(str(instance.get("instance_id", "")))
		if design_instance.get("generated") is Dictionary:
			continue
		var parent: TreeItem = assembly_items.get(design_instance.get("parent_assembly_id"), hidden_root)
		var item := _assembly_tree.create_item(parent)
		item.set_text(0, "%s · %s · %s" % [instance.get("name", "Component"), instance.get("release", {}).get("category", ""), instance.get("editability", {}).get("reason", "")])
		item.set_metadata(0, {"kind": "instance", "id": instance.get("instance_id")})

func _populate_graph() -> void:
	var model := GraphModel.build(_design(), _presentation, _active_assembly_id)
	_active_assembly_id = str(model.get("active_assembly_id", ""))
	_workspace.show_projection(model, _design().get("profiles", []), _profile_id, _writes_blocked or not _active_session_id.is_empty(), "UNSAVED" if _dirty else "SAVED · r%s" % _revision)
	if not _selected_instance_id.is_empty():
		_workspace.select_instance(_selected_instance_id)

func _request_connection_preview(endpoint_a: Dictionary, endpoint_b: Dictionary) -> void:
	if _writes_blocked:
		_diagnostic_error("Authoritative editing is unavailable while the graph is read-only.")
		return
	_pending_connection = {"endpoint_a": endpoint_a.duplicate(true), "endpoint_b": endpoint_b.duplicate(true)}
	_connection_preview.clear()
	if _dirty:
		_queued_preview = _pending_connection.duplicate(true)
		_pending_after_save = "connection_preview"
		_save_now()
		return
	_dispatch_connection_preview()

func _dispatch_connection_preview() -> void:
	if _pending_connection.is_empty() or _writes_blocked:
		return
	_request("connection_preview", HTTPClient.METHOD_POST, "/node-design/v1/designs/%s/connections/preview" % _design_id.uri_encode(), _pending_connection, PackedStringArray(["If-Match: %s" % _revision]))

func _accept_connection_preview(payload: Variant) -> void:
	if not payload is Dictionary or str(payload.get("input_hash", "")).is_empty() or str(payload.get("compatibility", "")) not in ["exact", "review", "incompatible"]:
		_connection_preview.clear()
		_diagnostic_error("Connection preview response is invalid.")
		return
	_connection_preview = payload.duplicate(true)
	_workspace.show_preview(_connection_preview)
	_projection.show_connection_preview(_connection_preview.get("proposed_transforms", []))
	if payload.get("compatibility") == "incompatible" or not payload.get("blockers", []).is_empty():
		_diagnostic_error("Connection preview is blocked. Review the authoritative blocker details in System Design.")
	else:
		_diagnostic_info("Connection preview is %s and ready for review." % payload.get("compatibility"))

func _apply_connection() -> void:
	if _writes_blocked or _pending_connection.is_empty() or _connection_preview.is_empty():
		return
	if _connection_preview.get("compatibility") == "incompatible" or not _connection_preview.get("blockers", []).is_empty():
		return
	var payload := _pending_connection.duplicate(true)
	payload["input_hash"] = _connection_preview.get("input_hash")
	if _connection_preview.get("policy_overrides") is Dictionary and not _connection_preview.get("policy_overrides").is_empty():
		payload["policy_overrides"] = _connection_preview.get("policy_overrides")
	_request("connection_apply", HTTPClient.METHOD_POST, "/node-design/v1/designs/%s/connections/apply" % _design_id.uri_encode(), payload, PackedStringArray(["If-Match: %s" % _revision]))

func _cancel_connection_preview() -> void:
	_pending_connection.clear()
	_queued_preview.clear()
	_connection_preview.clear()
	_workspace.hide_preview()
	_projection.clear_connection_preview()

func _repeat_connection_preview() -> void:
	if not _pending_connection.is_empty():
		_request_connection_preview(_pending_connection.get("endpoint_a", {}), _pending_connection.get("endpoint_b", {}))

func _resume_after_save() -> void:
	var action := _pending_after_save
	_pending_after_save = ""
	match action:
		"checkpoint":
			_checkpoint()
		"compile":
			_compile()
		"run":
			_run_live()
		"connection_preview":
			_pending_connection = _queued_preview.duplicate(true)
			_queued_preview.clear()
			_dispatch_connection_preview()

func _on_assembly_selected() -> void:
	var selected := _assembly_tree.get_selected()
	if selected == null:
		return
	var metadata: Variant = selected.get_metadata(0)
	if metadata is Dictionary and metadata.get("kind") == "instance":
		_select_instance(str(metadata.get("id", "")))
	elif metadata is Dictionary and metadata.get("kind") == "assembly":
		_open_assembly(str(metadata.get("id", "")))

func _on_catalog_selected(index: int) -> void:
	var value: Variant = _catalog_list.get_item_metadata(index)
	if value is Dictionary:
		_selected_catalog = value.duplicate(true)
		_show_key_values("Catalog release", value)

func _insert_catalog_selection() -> void:
	if _writes_blocked or _selected_catalog.is_empty() or _design_id.is_empty():
		return
	var assemblies: Array = _design().get("assemblies", [])
	if assemblies.is_empty():
		_diagnostic_error("A target assembly is required before catalog insertion.")
		return
	_request("hydrate", HTTPClient.METHOD_POST, "/node-design/v1/catalog/hydrate", {
		"kind": _selected_catalog.get("kind", "component"),
		"slug": _selected_catalog.get("slug", str(_selected_catalog.get("item_key", "component")).get_slice("/", 1)),
		"version": _selected_catalog.get("version", "1.0.0"),
		"parent_assembly_id": assemblies[0].get("assembly_id")
	})

func _accept_hydrated_release(payload: Variant) -> void:
	if not payload is Dictionary:
		_diagnostic_error("Catalog hydration returned an invalid payload.")
		return
	_push_undo()
	var design := _design()
	for key in ["assemblies", "component_instances", "connections", "joints"]:
		var existing: Array = design.get(key, [])
		existing.append_array(payload.get(key, []))
		design[key] = existing
	_dirty = true
	_save_timer.start()
	_diagnostic_info("Catalog release hydrated into the draft; autosave scheduled.")

func _on_editor_selection_changed() -> void:
	var nodes := _host.get_editor_interface().get_selection().get_selected_nodes()
	if nodes.size() == 1 and nodes[0].has_meta("future_engine_instance_id"):
		var instance_id := str(nodes[0].get_meta("future_engine_instance_id"))
		_selected_instance_id = instance_id
		_workspace.select_instance(instance_id)
		_show_instance(instance_id)

func _select_instance(instance_id: String) -> void:
	_selected_instance_id = instance_id
	_selected_instance_ids = PackedStringArray([instance_id])
	_projection.select_instance(instance_id)
	_workspace.select_instance(instance_id)
	_show_instance(instance_id)

func _on_workspace_instance_selected(instance_id: String, additive: bool) -> void:
	_selected_instance_id = instance_id
	if additive:
		if _selected_instance_ids.has(instance_id):
			_selected_instance_ids.remove_at(_selected_instance_ids.find(instance_id))
		else:
			_selected_instance_ids.append(instance_id)
	else:
		_selected_instance_ids = PackedStringArray([instance_id])
	_projection.select_instance(instance_id)
	_show_instance(instance_id)

func _view_in_3d() -> void:
	_host.show_3d()
	if not _selected_instance_id.is_empty():
		_projection.select_instance(_selected_instance_id)

func _open_assembly(assembly_id: String) -> void:
	if assembly_id.is_empty() or _presentation.is_empty():
		return
	_active_assembly_id = assembly_id
	_populate_graph()

func _change_profile(profile_id: String) -> void:
	if profile_id.is_empty() or profile_id == _profile_id or _design_id.is_empty():
		return
	_profile_id = profile_id
	_request("presentation", HTTPClient.METHOD_GET, "/node-design/v1/designs/%s/presentation?profile_id=%s" % [_design_id.uri_encode(), _profile_id.uri_encode()], null, PackedStringArray(["If-Match: %s" % _revision]))

func _show_relationship(edge: Dictionary) -> void:
	_selected_relationship_id = str(edge.get("id", ""))
	_clear_inspector()
	_add_inspector_heading("Relationship")
	_add_inspector_row("Domain", str(edge.get("domain", "")))
	_add_inspector_row("Status", str(edge.get("status", "unverified")))
	_add_inspector_row("Bundle", "%s member(s)" % edge.get("members", []).size())
	for member in edge.get("members", []):
		if not member is Dictionary:
			continue
		_add_inspector_heading(str(member.get("label", member.get("relationship_id", "Relationship"))))
		_add_inspector_row("Identity", str(member.get("relationship_id", "")))
		_add_inspector_row("Kind", str(member.get("kind", "")))
		_add_inspector_row("Endpoints", "%s:%s → %s:%s" % [member.get("source", {}).get("instance_id", ""), member.get("source", {}).get("interface_id", "body"), member.get("target", {}).get("instance_id", ""), member.get("target", {}).get("interface_id", "body")])
		_add_inspector_row("Resolver", str(member.get("resolver_status", "")))
		_add_inspector_row("Description", str(member.get("description", "")))

func _show_instance(instance_id: String) -> void:
	_selected_instance_id = instance_id
	var value := _presentation_instance(instance_id)
	if value.is_empty():
		return
	_clear_inspector()
	_add_inspector_heading(str(value.get("name", instance_id)))
	_add_inspector_row("Instance", instance_id)
	_add_inspector_row("Release", "%s @ %s" % [value.get("release", {}).get("item_key", ""), value.get("release", {}).get("version", "")])
	_add_inspector_row("Category", str(value.get("release", {}).get("category", "")))
	_add_inspector_row("Readiness", str(value.get("release", {}).get("readiness_status", "")))
	_add_inspector_row("Package", str(value.get("release", {}).get("package_digest", "")))
	_add_inspector_row("Placement", str(value.get("editability", {}).get("reason", "")))
	_add_placement_editor(instance_id, value)
	_add_inspector_heading("Resolved configuration")
	_add_inspector_row("Preset", str(value.get("resolved_configuration", {}).get("preset", "")))
	for parameter in value.get("resolved_configuration", {}).get("parameters", []):
		if parameter is Dictionary:
			_add_inspector_row(str(parameter.get("name", parameter.get("id", "Parameter"))), "%s %s" % [parameter.get("value", ""), parameter.get("unit", "") if parameter.get("unit") != null else ""])
	_add_inspector_heading("Interfaces")
	for interface in value.get("interfaces", []):
		if interface is Dictionary:
			_add_inspector_row(str(interface.get("name", interface.get("interface_id", "Interface"))), "%s · %s · %s · %s/%s\n%s" % [interface.get("domain", ""), interface.get("direction", ""), interface.get("state", ""), interface.get("capacity", {}).get("used", 0), interface.get("capacity", {}).get("maximum", "?"), interface.get("state_message", "")])
	_add_inspector_heading("Draft configuration")
	var configuration_editor := TextEdit.new()
	configuration_editor.custom_minimum_size = Vector2(0, 150)
	configuration_editor.text = JSON.stringify(_design_instance(instance_id).get("configuration", {}), "  ")
	configuration_editor.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	_inspector.add_child(configuration_editor)
	var apply_configuration := Button.new()
	apply_configuration.text = "Apply configuration JSON"
	apply_configuration.disabled = _writes_blocked
	apply_configuration.pressed.connect(_apply_configuration_json.bind(instance_id, configuration_editor))
	_inspector.add_child(apply_configuration)

func _add_placement_editor(instance_id: String, presentation: Dictionary) -> void:
	_add_inspector_heading("FE placement")
	var instance := _design_instance(instance_id)
	var transform: Dictionary = instance.get("transform", {"translation_m": [0.0, 0.0, 0.0], "rotation_wxyz": [1.0, 0.0, 0.0, 0.0]})
	var position: Array = transform.get("translation_m", [0.0, 0.0, 0.0])
	var rotation := FECoordinateAdapter.quaternion_to_euler_degrees(transform.get("rotation_wxyz", [1.0, 0.0, 0.0, 0.0]))
	var editable := bool(presentation.get("editability", {}).get("editable", false)) and not _writes_blocked and _active_session_id.is_empty()
	var fields: Array[SpinBox] = []
	for index in 6:
		var field := SpinBox.new()
		field.min_value = -100000.0 if index < 3 else -360.0
		field.max_value = 100000.0 if index < 3 else 360.0
		field.step = 0.001 if index < 3 else 0.1
		field.suffix = " m" if index < 3 else " deg"
		field.value = float(position[index]) if index < 3 else float(rotation[index - 3])
		field.editable = editable
		field.tooltip_text = ["X position", "Y position", "Z position", "Roll", "Pitch", "Yaw"][index]
		_inspector.add_child(field)
		fields.append(field)
	var apply := Button.new()
	apply.text = "Apply authoritative anchor"
	apply.disabled = not editable
	apply.pressed.connect(_apply_anchor_fields.bind(instance_id, fields))
	_inspector.add_child(apply)
	if not editable:
		var managed := Label.new()
		managed.text = "Managed placement: %s" % presentation.get("editability", {}).get("reason", "unsupported")
		managed.modulate = Color("ffcf66")
		_inspector.add_child(managed)

func _apply_anchor_fields(instance_id: String, fields: Array[SpinBox]) -> void:
	if _writes_blocked or not _active_session_id.is_empty() or fields.size() != 6:
		return
	var presentation := _presentation_instance(instance_id)
	if not bool(presentation.get("editability", {}).get("editable", false)):
		return
	var instance := _design_instance(instance_id)
	if instance.is_empty():
		return
	_push_undo()
	instance["transform"] = {
		"translation_m": [fields[0].value, fields[1].value, fields[2].value],
		"rotation_wxyz": FECoordinateAdapter.euler_degrees_to_quaternion([fields[3].value, fields[4].value, fields[5].value])
	}
	_mark_dirty("Anchor placement changed")

func _show_profile_editor() -> void:
	if _document.is_empty():
		_show_inspector_message("Open a System Design before editing a simulation profile.")
		return
	var profiles: Array = _design().get("profiles", [])
	if profiles.is_empty():
		_show_inspector_message("This design has no simulation profile.")
		return
	var profile: Dictionary = profiles[0]
	_clear_inspector()
	_add_inspector_heading("Simulation profile")
	_add_inspector_row("Profile", str(profile.get("name", profile.get("profile_id", "default"))))
	var duration := _profile_number("Duration (s)", float(profile.get("duration_s", 5.0)), 0.001, 86400.0, 0.1)
	var timestep := _profile_number("Timestep (s)", float(profile.get("timestep_s", 0.002)), 0.000001, 1.0, 0.0001)
	var gravity: Array = profile.get("gravity_m_s2", [0.0, 0.0, -9.80665])
	var gravity_z := _profile_number("Gravity Z (m/s²)", float(gravity[2]) if gravity.size() == 3 else -9.80665, -100.0, 100.0, 0.01)
	_add_inspector_row("Variables", str(_design().get("variables", []).size()))
	_add_inspector_row("Formula bindings", str(_design().get("formula_bindings", []).size()))
	_add_inspector_row("Actuator commands", str(profile.get("actuator_commands", []).size()))
	_add_inspector_row("Sensor measurements", str(profile.get("sensor_measurements", []).size()))
	var apply := Button.new()
	apply.text = "Apply profile settings"
	apply.disabled = _writes_blocked
	apply.pressed.connect(_apply_profile_values.bind(duration, timestep, gravity_z))
	_inspector.add_child(apply)
	_add_inspector_heading("Full profile contract")
	var profile_editor := TextEdit.new()
	profile_editor.custom_minimum_size = Vector2(0, 220)
	profile_editor.text = JSON.stringify(profile, "  ")
	profile_editor.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	_inspector.add_child(profile_editor)
	var apply_profile_json := Button.new()
	apply_profile_json.text = "Apply profile JSON"
	apply_profile_json.disabled = _writes_blocked
	apply_profile_json.pressed.connect(_apply_profile_json.bind(profile_editor))
	_inspector.add_child(apply_profile_json)
	_add_inspector_heading("Variables and formulas")
	var formulas_editor := TextEdit.new()
	formulas_editor.custom_minimum_size = Vector2(0, 180)
	formulas_editor.text = JSON.stringify({"variables": _design().get("variables", []), "formula_bindings": _design().get("formula_bindings", [])}, "  ")
	formulas_editor.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	_inspector.add_child(formulas_editor)
	var apply_formulas := Button.new()
	apply_formulas.text = "Apply variables/formulas JSON"
	apply_formulas.disabled = _writes_blocked
	apply_formulas.pressed.connect(_apply_formulas_json.bind(formulas_editor))
	_inspector.add_child(apply_formulas)

func _profile_number(label_text: String, value: float, minimum: float, maximum: float, step: float) -> SpinBox:
	var label := Label.new()
	label.text = label_text
	_inspector.add_child(label)
	var field := SpinBox.new()
	field.min_value = minimum
	field.max_value = maximum
	field.step = step
	field.value = value
	field.allow_greater = false
	field.allow_lesser = false
	_inspector.add_child(field)
	return field

func _apply_profile_values(duration: SpinBox, timestep: SpinBox, gravity_z: SpinBox) -> void:
	if _writes_blocked:
		return
	_push_undo()
	var profiles: Array = _design().get("profiles", [])
	if profiles.is_empty():
		return
	profiles[0]["duration_s"] = duration.value
	profiles[0]["timestep_s"] = timestep.value
	var gravity: Array = profiles[0].get("gravity_m_s2", [0.0, 0.0, -9.80665])
	if gravity.size() != 3:
		gravity = [0.0, 0.0, -9.80665]
	gravity[2] = gravity_z.value
	profiles[0]["gravity_m_s2"] = gravity
	_design()["profiles"] = profiles
	_dirty = true
	_save_timer.start()
	_diagnostic_info("Simulation profile updated; autosave scheduled.")

func _apply_profile_json(editor: TextEdit) -> void:
	var parsed: Variant = JSON.parse_string(editor.text)
	if not parsed is Dictionary or str(parsed.get("profile_id", "")).is_empty():
		_diagnostic_error("Profile JSON must be an object with profile_id.")
		return
	_push_undo()
	var profiles: Array = _design().get("profiles", [])
	var replaced := false
	for index in profiles.size():
		if profiles[index] is Dictionary and profiles[index].get("profile_id") == parsed.get("profile_id"):
			profiles[index] = parsed
			replaced = true
			break
	if not replaced:
		profiles.append(parsed)
	_design()["profiles"] = profiles
	_profile_id = str(parsed.get("profile_id"))
	_dirty = true
	_save_timer.start()
	_diagnostic_info("Simulation profile contract updated; autosave scheduled.")

func _apply_formulas_json(editor: TextEdit) -> void:
	var parsed: Variant = JSON.parse_string(editor.text)
	if not parsed is Dictionary or not parsed.get("variables", []) is Array or not parsed.get("formula_bindings", []) is Array:
		_diagnostic_error("Variables/formulas JSON must contain arrays named variables and formula_bindings.")
		return
	_push_undo()
	_design()["variables"] = parsed.get("variables")
	_design()["formula_bindings"] = parsed.get("formula_bindings")
	_dirty = true
	_save_timer.start()
	_diagnostic_info("Variables and formulas updated; autosave scheduled.")

func _apply_configuration_json(instance_id: String, editor: TextEdit) -> void:
	var parsed: Variant = JSON.parse_string(editor.text)
	if not parsed is Dictionary:
		_diagnostic_error("Component configuration JSON must be an object.")
		return
	_push_undo()
	var instance := _design_instance(instance_id)
	if instance.is_empty():
		return
	instance["configuration"] = parsed
	_dirty = true
	_save_timer.start()
	_diagnostic_info("Component configuration updated; autosave scheduled.")

func _on_graph_layout_changed(changes: Dictionary) -> void:
	if _document.is_empty() or _writes_blocked or changes.is_empty():
		return
	_push_undo()
	for node_id in changes:
		GraphModel.write_layout(_design(), str(node_id), changes[node_id].get("after", Vector2.ZERO))
	_mark_dirty("Graph layout changed")

func _delete_graph_items(node_ids: PackedStringArray) -> void:
	if _writes_blocked or node_ids.is_empty():
		return
	var component_ids := PackedStringArray()
	var relationship_ids := PackedStringArray()
	for node_id in node_ids:
		if node_id.begins_with("component:"):
			var instance_id := node_id.trim_prefix("component:")
			var presentation := _presentation_instance(instance_id)
			if bool(presentation.get("editability", {}).get("editable", false)):
				component_ids.append(instance_id)
			else:
				_diagnostic_error("%s cannot be deleted: %s." % [instance_id, presentation.get("editability", {}).get("reason", "managed")])
		elif node_id.begins_with("relationship:"):
			relationship_ids.append(node_id.trim_prefix("relationship:"))
	if component_ids.is_empty() and relationship_ids.is_empty():
		return
	_push_undo()
	var design := _design()
	var removed_connections := {}
	var retained_connections := []
	for connection in design.get("connections", []):
		if not connection is Dictionary:
			continue
		var connection_id := str(connection.get("connection_id", ""))
		var endpoint_a := str(connection.get("endpoint_a", {}).get("instance_id", ""))
		var endpoint_b := str(connection.get("endpoint_b", {}).get("instance_id", ""))
		if relationship_ids.has(connection_id) or component_ids.has(endpoint_a) or component_ids.has(endpoint_b):
			removed_connections[connection_id] = connection
		else:
			retained_connections.append(connection)
	design["connections"] = retained_connections
	var removed_joints := {}
	var retained_joints := []
	for joint in design.get("joints", []):
		if not joint is Dictionary:
			continue
		var joint_id := str(joint.get("joint_id", ""))
		var resolved_owner_removed := false
		for connection in removed_connections.values():
			if connection.get("resolved_joint_id") == joint_id:
				resolved_owner_removed = true
				break
		if relationship_ids.has(joint_id) or resolved_owner_removed or component_ids.has(str(joint.get("parent_instance_id", ""))) or component_ids.has(str(joint.get("child_instance_id", ""))):
			removed_joints[joint_id] = true
		else:
			retained_joints.append(joint)
	design["joints"] = retained_joints
	var generated_owned := PackedStringArray()
	for component in design.get("component_instances", []):
		if component is Dictionary and component.get("generated") is Dictionary and removed_connections.has(str(component.get("generated", {}).get("owner_connection_id", ""))):
			generated_owned.append(str(component.get("instance_id", "")))
	var retained_components := []
	for component in design.get("component_instances", []):
		if component is Dictionary and not component_ids.has(str(component.get("instance_id", ""))) and not generated_owned.has(str(component.get("instance_id", ""))):
			retained_components.append(component)
	design["component_instances"] = retained_components
	for profile in design.get("profiles", []):
		if not profile is Dictionary:
			continue
		var retained_bindings := []
		for binding in profile.get("device_bindings", []):
			if not binding is Dictionary or not component_ids.has(str(binding.get("instance_id", ""))):
				retained_bindings.append(binding)
		profile["device_bindings"] = retained_bindings
	_selected_instance_id = ""
	_selected_relationship_id = ""
	_mark_dirty("Deleted graph selection and dependent relationships")

func _hide_selected() -> void:
	if not _selected_instance_id.is_empty():
		_projection.set_instance_visible(_selected_instance_id, false)

func _isolate_selected() -> void:
	if not _selected_instance_id.is_empty():
		_projection.isolate_instance(_selected_instance_id)

func _populate_diagnostics() -> void:
	var lines := PackedStringArray(["[b]Readiness[/b] %s" % _presentation.get("readiness", {}).get("status", "unknown"), "[b]Bill of materials[/b] %s released line items" % _presentation.get("bom", []).size(), ""])
	for item in _presentation.get("diagnostics", []):
		if item is Dictionary:
			lines.append("[%s] %s · %s" % [str(item.get("severity", "info")).to_upper(), item.get("code", ""), item.get("message", "")])
	_diagnostics.text = "\n".join(lines)

func _show_key_values(title: String, value: Dictionary) -> void:
	_clear_inspector()
	_add_inspector_heading(title)
	for key in value:
		if not value[key] is Array and not value[key] is Dictionary:
			_add_inspector_row(str(key), str(value[key]))

func _show_inspector_message(message: String) -> void:
	_clear_inspector()
	var label := Label.new()
	label.text = message
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_inspector.add_child(label)

func _clear_inspector() -> void:
	for child in _inspector.get_children():
		child.queue_free()

func _add_inspector_heading(text: String) -> void:
	var label := Label.new()
	label.text = text.to_upper()
	_apply_brand_font(label)
	_inspector.add_child(label)

func _apply_brand_font(control: Control) -> void:
	if not ResourceLoader.exists("res://assets/fonts/SpaceMono_Bold.ttf"):
		return
	var font: Resource = load("res://assets/fonts/SpaceMono_Bold.ttf")
	if font is Font:
		control.add_theme_font_override("font", font)

func _add_inspector_row(label_text: String, value_text: String) -> void:
	var row := VBoxContainer.new()
	var label := Label.new()
	label.text = label_text
	label.modulate = Color("90a9bd")
	row.add_child(label)
	var value := LineEdit.new()
	value.text = value_text
	value.editable = false
	row.add_child(value)
	_inspector.add_child(row)

func _diagnostic_info(message: String) -> void:
	_diagnostics.append_text("\n[INFO] %s" % message)

func _diagnostic_error(message: String) -> void:
	_diagnostics.append_text("\n[ERROR] %s" % message)
	push_error("Future Engine: %s" % message)

func _design() -> Dictionary:
	return _document.get("draft", {}).get("design", {})

func _design_instance(instance_id: String) -> Dictionary:
	for value in _design().get("component_instances", []):
		if value is Dictionary and value.get("instance_id") == instance_id:
			return value
	return {}

func _presentation_instance(instance_id: String) -> Dictionary:
	for value in _presentation.get("instances", []):
		if value is Dictionary and value.get("instance_id") == instance_id:
			return value
	return {}
