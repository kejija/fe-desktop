@tool
class_name FESceneProjection
extends Node

signal anchor_transform_changed(instance_id: String, transform: Transform3D)
signal projection_opened(path: String)

const GENERATED_DIRECTORY := "res://.future_engine_generated"

var editor_interface: EditorInterface
var asset_cache: FEAssetCache
var _presentation := {}
var _last_anchor_transforms := {}
var _suppress_changes := false
var _preview_ghosts: Node3D

func configure(interface: EditorInterface, cache: FEAssetCache) -> void:
	editor_interface = interface
	asset_cache = cache
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(GENERATED_DIRECTORY))

func build(design: Dictionary, presentation: Dictionary) -> Error:
	_presentation = presentation.duplicate(true)
	var design_id := str(presentation.get("design_id", design.get("design_id", "design")))
	var root := Node3D.new()
	root.name = _node_name(str(design.get("name", "Future Engine Design")))
	root.set_meta("future_engine_design_id", design_id)
	root.set_meta("future_engine_generated", true)
	for value in presentation.get("instances", []):
		if value is Dictionary:
			_add_instance(root, value)
	var path := "%s/%s.tscn" % [GENERATED_DIRECTORY, design_id.validate_filename()]
	var packed := PackedScene.new()
	var pack_error := packed.pack(root)
	if pack_error != OK:
		root.free()
		return pack_error
	var save_error := ResourceSaver.save(packed, path)
	root.free()
	if save_error != OK:
		return save_error
	editor_interface.get_resource_filesystem().scan_sources()
	var edited_root := editor_interface.get_edited_scene_root()
	if edited_root != null and str(edited_root.get_meta("future_engine_design_id", "")) == design_id:
		editor_interface.reload_scene_from_path(path)
	else:
		editor_interface.open_scene_from_path(path)
	_capture_anchor_transforms.call_deferred()
	projection_opened.emit(path)
	return OK

func poll_anchor_changes() -> void:
	if _suppress_changes:
		return
	var root := editor_interface.get_edited_scene_root()
	if root == null or not root.has_meta("future_engine_design_id"):
		return
	for node in root.find_children("*", "Node3D", true, false):
		if not node.has_meta("future_engine_instance_id") or not bool(node.get_meta("future_engine_editable", false)):
			continue
		var instance_id := str(node.get_meta("future_engine_instance_id"))
		var previous: Transform3D = _last_anchor_transforms.get(instance_id, node.transform)
		if not previous.is_equal_approx(node.transform):
			_last_anchor_transforms[instance_id] = node.transform
			anchor_transform_changed.emit(instance_id, node.transform)

func apply_live_poses(poses: Array) -> void:
	var root := editor_interface.get_edited_scene_root()
	if root == null:
		return
	_suppress_changes = true
	for value in poses:
		if not value is Dictionary:
			continue
		var node := _instance_node(root, str(value.get("instance_id", "")))
		if node:
			node.transform = FECoordinateAdapter.fe_transform_to_godot(value)
			node.set_meta("future_engine_live_controlled", true)
	_suppress_changes = false

func clear_live_poses() -> void:
	var root := editor_interface.get_edited_scene_root()
	if root == null:
		return
	_suppress_changes = true
	for value in _presentation.get("instances", []):
		if not value is Dictionary:
			continue
		var node := _instance_node(root, str(value.get("instance_id", "")))
		if node:
			node.transform = FECoordinateAdapter.fe_transform_to_godot(value.get("world_transform", {}))
			node.remove_meta("future_engine_live_controlled")
	_suppress_changes = false
	_capture_anchor_transforms()

func show_connection_preview(proposed_transforms: Array) -> void:
	clear_connection_preview()
	var root := editor_interface.get_edited_scene_root()
	if root == null or proposed_transforms.is_empty():
		return
	_preview_ghosts = Node3D.new()
	_preview_ghosts.name = "ConnectionPreviewGhosts"
	_preview_ghosts.set_meta("future_engine_transient", true)
	root.add_child(_preview_ghosts)
	for proposed in proposed_transforms:
		if not proposed is Dictionary:
			continue
		var ghost := MeshInstance3D.new()
		ghost.name = "Proposed_%s" % str(proposed.get("instance_id", "instance")).validate_filename()
		ghost.transform = FECoordinateAdapter.fe_transform_to_godot(proposed.get("transform", {}))
		ghost.set_meta("future_engine_preview_instance_id", str(proposed.get("instance_id", "")))
		var mesh := BoxMesh.new()
		mesh.size = Vector3(0.075, 0.055, 0.075)
		ghost.mesh = mesh
		var material := StandardMaterial3D.new()
		material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		material.albedo_color = Color(0.35, 0.85, 1.0, 0.36)
		material.emission_enabled = true
		material.emission = Color("3ec9ff")
		material.emission_energy_multiplier = 0.55
		ghost.material_override = material
		_preview_ghosts.add_child(ghost)

func clear_connection_preview() -> void:
	if is_instance_valid(_preview_ghosts):
		_preview_ghosts.queue_free()
	_preview_ghosts = null

func select_instance(instance_id: String) -> void:
	var root := editor_interface.get_edited_scene_root()
	if root == null:
		return
	var node := _instance_node(root, instance_id)
	if node:
		var selection := editor_interface.get_selection()
		selection.clear()
		selection.add_node(node)

func set_instance_visible(instance_id: String, visible: bool) -> void:
	var root := editor_interface.get_edited_scene_root()
	if root == null:
		return
	var node := _instance_node(root, instance_id)
	if node:
		node.visible = visible

func isolate_instance(instance_id: String) -> void:
	var root := editor_interface.get_edited_scene_root()
	if root == null:
		return
	for node in root.find_children("*", "Node3D", true, false):
		if node.has_meta("future_engine_instance_id"):
			node.visible = str(node.get_meta("future_engine_instance_id")) == instance_id

func show_all() -> void:
	var root := editor_interface.get_edited_scene_root()
	if root == null:
		return
	for node in root.find_children("*", "Node3D", true, false):
		if node.has_meta("future_engine_instance_id"):
			node.visible = true

func set_explosion(amount: float) -> void:
	var root := editor_interface.get_edited_scene_root()
	if root == null:
		return
	_suppress_changes = true
	var transforms := {}
	var center := Vector3.ZERO
	for value in _presentation.get("instances", []):
		if value is Dictionary:
			var transform := FECoordinateAdapter.fe_transform_to_godot(value.get("world_transform", {}))
			transforms[str(value.get("instance_id", ""))] = transform
			center += transform.origin
	if not transforms.is_empty():
		center /= float(transforms.size())
	for instance_id in transforms:
		var node := _instance_node(root, instance_id)
		if node:
			var base: Transform3D = transforms[instance_id]
			var direction := (base.origin - center).normalized()
			node.transform = Transform3D(base.basis, base.origin + direction * amount)
	_suppress_changes = false
	_capture_anchor_transforms()

func _add_instance(root: Node3D, instance: Dictionary) -> void:
	var node := Node3D.new()
	node.name = _node_name(str(instance.get("name", instance.get("instance_id", "Component"))))
	node.transform = FECoordinateAdapter.fe_transform_to_godot(instance.get("world_transform", {}))
	node.set_meta("future_engine_instance_id", str(instance.get("instance_id", "")))
	var editability: Dictionary = instance.get("editability", {})
	node.set_meta("future_engine_editable", bool(editability.get("editable", false)))
	node.set_meta("future_engine_editability_reason", str(editability.get("reason", "joint_derived")))
	root.add_child(node)
	node.owner = root
	var visual := _model_visual(instance)
	node.add_child(visual)
	visual.owner = root
	_set_owner_recursive(visual, root)

func _model_visual(instance: Dictionary) -> Node3D:
	var model: Variant = instance.get("model")
	if model is Dictionary:
		var cache_path := asset_cache.ensure_asset(model)
		if FileAccess.file_exists(cache_path) and ResourceLoader.exists(cache_path):
			var resource := ResourceLoader.load(cache_path)
			if resource is PackedScene:
				var imported: Node = resource.instantiate()
				if imported is Node3D:
					imported.name = "ReleasedModel"
					imported.scale = FECoordinateAdapter.model_scale_to_godot(model)
					var inner: Array = model.get("inner_rotation_wxyz", [1.0, 0.0, 0.0, 0.0])
					imported.quaternion = FECoordinateAdapter.fe_quaternion_to_godot(inner)
					return imported
	var placeholder := MeshInstance3D.new()
	placeholder.name = "PresentationPlaceholder"
	var mesh := BoxMesh.new()
	mesh.size = Vector3(0.06, 0.04, 0.06)
	placeholder.mesh = mesh
	var material := StandardMaterial3D.new()
	material.albedo_color = Color("55bde8") if bool(instance.get("editability", {}).get("editable", false)) else Color("687c91")
	material.metallic = 0.35
	material.roughness = 0.45
	placeholder.material_override = material
	return placeholder

func _capture_anchor_transforms() -> void:
	_last_anchor_transforms.clear()
	var root := editor_interface.get_edited_scene_root()
	if root == null:
		return
	for node in root.find_children("*", "Node3D", true, false):
		if node.has_meta("future_engine_instance_id") and bool(node.get_meta("future_engine_editable", false)):
			_last_anchor_transforms[str(node.get_meta("future_engine_instance_id"))] = node.transform

func _instance_node(root: Node, instance_id: String) -> Node3D:
	for node in root.find_children("*", "Node3D", true, false):
		if str(node.get_meta("future_engine_instance_id", "")) == instance_id:
			return node
	return null

func _set_owner_recursive(node: Node, root: Node) -> void:
	for child in node.get_children():
		child.owner = root
		_set_owner_recursive(child, root)

func _node_name(value: String) -> String:
	var safe := value.strip_edges().replace("/", "_").replace(":", "_").replace("@", "_")
	return safe if not safe.is_empty() else "FutureEngineNode"
