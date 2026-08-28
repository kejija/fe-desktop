@tool
class_name FEAssetCache
extends Node

signal asset_ready(digest: String, resource_path: String)
signal asset_failed(digest: String, message: String)

const CACHE_DIRECTORY := "res://.future_engine_cache"

var backend: FEBackendClient
var editor_interface: EditorInterface
var _pending := {}

func configure(client: FEBackendClient, interface: EditorInterface) -> void:
	backend = client
	editor_interface = interface
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(CACHE_DIRECTORY))

func ensure_asset(model: Dictionary) -> String:
	var digest := str(model.get("sha256", ""))
	if not digest.begins_with("sha256:"):
		asset_failed.emit(digest, "Asset digest is missing or invalid.")
		return ""
	var resource_path := _path_for_digest(digest)
	if FileAccess.file_exists(resource_path):
		var bytes := FileAccess.get_file_as_bytes(resource_path)
		if _digest(bytes) == digest:
			asset_ready.emit.call_deferred(digest, resource_path)
			return resource_path
		DirAccess.remove_absolute(ProjectSettings.globalize_path(resource_path))
	if _pending.has(digest):
		return resource_path
	var asset_path := str(model.get("asset_path", ""))
	if asset_path.is_empty():
		asset_failed.emit(digest, "Asset path is missing.")
		return ""
	var request := backend.request_bytes("/components%s" % asset_path, {"digest": digest, "resource_path": resource_path, "size_bytes": int(model.get("size_bytes", -1))})
	_pending[digest] = request
	request.request_completed.connect(_on_download_completed.bind(request), CONNECT_ONE_SHOT)
	if request.has_meta("future_engine_start_error"):
		_pending.erase(digest)
		asset_failed.emit(digest, request.get_meta("future_engine_start_error"))
		request.queue_free()
	return resource_path

func _on_download_completed(result: int, status: int, _headers: PackedStringArray, body: PackedByteArray, request: HTTPRequest) -> void:
	var metadata: Dictionary = request.get_meta("future_engine_metadata", {})
	var digest := str(metadata.get("digest", ""))
	_pending.erase(digest)
	request.queue_free()
	if result != HTTPRequest.RESULT_SUCCESS or status != 200:
		asset_failed.emit(digest, "Asset download failed (transport %s, HTTP %s)." % [result, status])
		return
	var expected_size := int(metadata.get("size_bytes", -1))
	if expected_size >= 0 and body.size() != expected_size:
		asset_failed.emit(digest, "Asset byte size did not match the presentation contract.")
		return
	if _digest(body) != digest:
		asset_failed.emit(digest, "Asset SHA-256 did not match the presentation contract.")
		return
	var resource_path := str(metadata.get("resource_path", ""))
	var temporary_path := "%s.download" % resource_path
	var file := FileAccess.open(temporary_path, FileAccess.WRITE)
	if file == null:
		asset_failed.emit(digest, "Asset cache is not writable: %s" % error_string(FileAccess.get_open_error()))
		return
	file.store_buffer(body)
	file.close()
	var rename_error := DirAccess.rename_absolute(ProjectSettings.globalize_path(temporary_path), ProjectSettings.globalize_path(resource_path))
	if rename_error != OK:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(temporary_path))
		asset_failed.emit(digest, "Asset cache commit failed: %s" % error_string(rename_error))
		return
	editor_interface.get_resource_filesystem().scan_sources()
	asset_ready.emit(digest, resource_path)

func _path_for_digest(digest: String) -> String:
	return "%s/%s.glb" % [CACHE_DIRECTORY, digest.trim_prefix("sha256:")]

func _digest(bytes: PackedByteArray) -> String:
	var hashing := HashingContext.new()
	hashing.start(HashingContext.HASH_SHA256)
	hashing.update(bytes)
	return "sha256:%s" % hashing.finish().hex_encode()
