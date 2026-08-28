@tool
class_name FERecoveryStore
extends RefCounted

const DIRECTORY := "user://future_engine/recovery"

static func save(design_id: String, revision: int, design: Dictionary, reason: String) -> Error:
	var absolute := ProjectSettings.globalize_path(DIRECTORY)
	var directory_error := DirAccess.make_dir_recursive_absolute(absolute)
	if directory_error != OK:
		return directory_error
	var file := FileAccess.open("%s/%s.json" % [DIRECTORY, design_id.validate_filename()], FileAccess.WRITE)
	if file == null:
		return FileAccess.get_open_error()
	file.store_string(JSON.stringify({
		"schema_version": "future-engine.desktop-recovery.v1",
		"design_id": design_id,
		"base_revision": revision,
		"reason": reason,
		"saved_unix_time": Time.get_unix_time_from_system(),
		"design": design
	}, "  "))
	return OK

static func load(design_id: String) -> Dictionary:
	var path := "%s/%s.json" % [DIRECTORY, design_id.validate_filename()]
	if not FileAccess.file_exists(path):
		return {}
	var parsed := JSON.parse_string(FileAccess.get_file_as_string(path))
	return parsed if parsed is Dictionary else {}

static func clear(design_id: String) -> Error:
	var path := "%s/%s.json" % [DIRECTORY, design_id.validate_filename()]
	if not FileAccess.file_exists(path):
		return OK
	return DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
