@tool
class_name FEEditorPlugin
extends EditorPlugin

const REQUIRED_VERSION := {"major": 4, "minor": 7, "patch": 2, "status": "stable"}
const MODULE_MANIFEST := "res://addons/future_engine/frontend_modules.json"
const BackendSettings = preload("res://addons/future_engine/core/backend_settings.gd")

var backend: FEBackendClient
var asset_cache: FEAssetCache
var projection: FESceneProjection
var live_session: FELiveSession
var _backend_settings: FEBackendSettings

var _toolbar: HBoxContainer
var _mode_badge: Label
var _main_screen: MarginContainer
var _main_content: Control
var _mounted_docks: Array[Control] = []
var _bottom_panels: Array[Control] = []
var _bottom_buttons: Array[Button] = []
var _modules: Array[FEFrontendModule] = []
var _enabled_for_version := false

func _enter_tree() -> void:
	_build_toolbar()
	_build_main_screen()
	_enabled_for_version = _version_supported()
	if not _enabled_for_version:
		set_backend_mode("version mismatch")
		push_error("Future Engine Desktop requires the unmodified Godot 4.7.2 stable editor.")
		return
	backend = FEBackendClient.new()
	backend.name = "FutureEngineBackend"
	add_child(backend)
	backend.configure()
	_backend_settings = BackendSettings.new()
	add_child(_backend_settings)
	_backend_settings.configure(backend)
	_backend_settings.configuration_observed.connect(_on_backend_configuration_observed)
	_backend_settings.backend_changed.connect(_on_backend_changed)
	register_toolbar_action("Backend", _backend_settings.show_settings, "Select mock/live mode, a local or Tailscale backend, and inspect FE service ports")
	asset_cache = FEAssetCache.new()
	asset_cache.name = "FutureEngineAssetCache"
	add_child(asset_cache)
	asset_cache.configure(backend, get_editor_interface())
	asset_cache.asset_failed.connect(_on_asset_failed)
	projection = FESceneProjection.new()
	projection.name = "FutureEngineSceneProjection"
	add_child(projection)
	projection.configure(get_editor_interface(), asset_cache)
	live_session = FELiveSession.new()
	live_session.name = "FutureEngineLiveSession"
	add_child(live_session)
	_load_frontend_modules()
	for module in _modules:
		module.register_ui(self)
		module.activate()
	set_process(true)

func _exit_tree() -> void:
	set_process(false)
	for module in _modules:
		module.deactivate()
		module.shutdown()
	_modules.clear()
	for panel in _bottom_panels:
		if is_instance_valid(panel):
			remove_control_from_bottom_panel(panel)
	for button in _bottom_buttons:
		if is_instance_valid(button):
			button.queue_free()
	for dock in _mounted_docks:
		if is_instance_valid(dock):
			remove_control_from_docks(dock)
			dock.queue_free()
	_bottom_panels.clear()
	_bottom_buttons.clear()
	_mounted_docks.clear()
	if is_instance_valid(_main_screen):
		_main_screen.queue_free()
	if is_instance_valid(_toolbar):
		remove_control_from_container(EditorPlugin.CONTAINER_TOOLBAR, _toolbar)
		_toolbar.queue_free()
	if is_instance_valid(live_session):
		live_session.close()
	for child in [projection, asset_cache, backend, live_session, _backend_settings]:
		if is_instance_valid(child):
			child.queue_free()

func _process(_delta: float) -> void:
	if is_instance_valid(projection):
		projection.poll_anchor_changes()

func mount_dock(slot: EditorPlugin.DockSlot, control: Control) -> void:
	add_control_to_dock(slot, control)
	_mounted_docks.append(control)

func mount_bottom(control: Control, title: String) -> Button:
	var button := add_control_to_bottom_panel(control, title)
	_bottom_panels.append(control)
	_bottom_buttons.append(button)
	return button

func mount_main(control: Control) -> void:
	if not is_instance_valid(_main_content):
		return
	for child in _main_content.get_children():
		_main_content.remove_child(child)
	_main_content.add_child(control)
	control.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

func show_system_design() -> void:
	get_editor_interface().set_main_screen_editor(_get_plugin_name())

func show_3d() -> void:
	get_editor_interface().set_main_screen_editor("3D")

func _has_main_screen() -> bool:
	return true

func _get_plugin_name() -> String:
	return "System Design"

func _get_plugin_icon() -> Texture2D:
	var base := get_editor_interface().get_base_control()
	return base.get_theme_icon("GraphEdit", "EditorIcons") if base else null

func _make_visible(visible: bool) -> void:
	if is_instance_valid(_main_screen):
		_main_screen.visible = visible

func register_toolbar_action(label: String, callback: Callable, tooltip := "") -> Button:
	var button := Button.new()
	button.text = label
	button.tooltip_text = tooltip
	button.flat = true
	button.pressed.connect(callback)
	_toolbar.add_child(button)
	return button

func set_backend_mode(mode: String) -> void:
	if not is_instance_valid(_mode_badge):
		return
	_mode_badge.text = mode.to_upper()
	match mode:
		"mock":
			_mode_badge.text = "MOCK BACKEND"
			_mode_badge.modulate = Color("ffcf66")
		"upstream":
			_mode_badge.text = "LIVE BACKEND"
			_mode_badge.modulate = Color("6ee7a8")
		"offline":
			_mode_badge.modulate = Color("ff7b72")
		"unsupported":
			_mode_badge.text = "PRESENTATION API REQUIRED"
			_mode_badge.modulate = Color("ff7b72")
		_:
			_mode_badge.modulate = Color("ff7b72")

func _on_backend_configuration_observed(configuration: Dictionary) -> void:
	var mode := str(configuration.get("effective_mode", "offline"))
	set_backend_mode(mode)
	if is_instance_valid(_mode_badge):
		var server: Dictionary = configuration.get("selected_server", {})
		var services: Array = configuration.get("services", [])
		var running: int = services.filter(func(service): return service is Dictionary and service.get("status") == "running").size()
		_mode_badge.tooltip_text = "%s · %s/%s service ports running · click Backend to configure" % [server.get("name", "Backend"), running, services.size()]

func _on_backend_changed(configuration: Dictionary) -> void:
	for module in _modules:
		module.backend_configuration_changed(configuration)

func _build_toolbar() -> void:
	_toolbar = HBoxContainer.new()
	_toolbar.name = "FutureEngineToolbar"
	var brand := Label.new()
	brand.text = "FE"
	brand.tooltip_text = "Future Engine Desktop · stock Godot addon"
	_apply_brand_font(brand)
	_toolbar.add_child(brand)
	var separator := VSeparator.new()
	_toolbar.add_child(separator)
	_mode_badge = Label.new()
	_mode_badge.text = "STARTING"
	_apply_brand_font(_mode_badge)
	_toolbar.add_child(_mode_badge)
	add_control_to_container(EditorPlugin.CONTAINER_TOOLBAR, _toolbar)

func _build_main_screen() -> void:
	_main_screen = MarginContainer.new()
	_main_screen.name = "FutureEngineSystemDesignMain"
	_main_screen.visible = false
	_main_screen.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_main_screen.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_main_content = Control.new()
	_main_content.name = "ModuleContent"
	_main_content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_main_content.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_main_screen.add_child(_main_content)
	_main_content.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	get_editor_interface().get_editor_main_screen().add_child(_main_screen)
	_main_screen.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

func _apply_brand_font(control: Control) -> void:
	if not ResourceLoader.exists("res://assets/fonts/SpaceMono_Bold.ttf"):
		return
	var font: Resource = load("res://assets/fonts/SpaceMono_Bold.ttf")
	if font is Font:
		control.add_theme_font_override("font", font)

func _version_supported() -> bool:
	var version := Engine.get_version_info()
	return int(version.get("major", 0)) == REQUIRED_VERSION.major \
		and int(version.get("minor", 0)) == REQUIRED_VERSION.minor \
		and int(version.get("patch", 0)) == REQUIRED_VERSION.patch \
		and str(version.get("status", "")) == REQUIRED_VERSION.status

func _load_frontend_modules() -> void:
	var parsed := JSON.parse_string(FileAccess.get_file_as_string(MODULE_MANIFEST))
	if not parsed is Dictionary or parsed.get("schema_version") != "future-engine.desktop-frontends.v1":
		push_error("Future Engine frontend module manifest is invalid.")
		return
	for entry in parsed.get("modules", []):
		if not entry is Dictionary:
			continue
		var script_path := str(entry.get("script", ""))
		var script := load(script_path)
		if script == null:
			push_error("Future Engine frontend module could not load: %s" % script_path)
			continue
		var module: Variant = script.new()
		if not module is FEFrontendModule:
			push_error("Future Engine frontend module does not implement FEFrontendModule: %s" % script_path)
			continue
		if str(module.id) != str(entry.get("id", "")):
			push_error("Future Engine frontend module ID does not match its manifest entry: %s" % script_path)
			continue
		_modules.append(module)

func _on_asset_failed(digest: String, message: String) -> void:
	push_error("Future Engine asset %s failed: %s" % [digest, message])
