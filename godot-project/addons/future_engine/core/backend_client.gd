@tool
class_name FEBackendClient
extends Node

signal response_completed(request_id: int, status: int, payload: Variant, response_headers: Dictionary)
signal transport_failed(request_id: int, message: String)

var gateway_url := "http://127.0.0.1:8142"
var timeout_seconds := 15.0
var _next_request_id := 1

func configure() -> void:
	gateway_url = str(ProjectSettings.get_setting("future_engine/gateway_url", gateway_url)).trim_suffix("/")
	timeout_seconds = float(ProjectSettings.get_setting("future_engine/request_timeout_seconds", timeout_seconds))
	if OS.has_feature("web") and gateway_url.begins_with("/"):
		gateway_url = str(JavaScriptBridge.eval("window.location.origin", true)).trim_suffix("/")

func request_json(method: HTTPClient.Method, path: String, payload: Variant = null, headers := PackedStringArray()) -> int:
	var request_id := _next_request_id
	_next_request_id += 1
	var request := HTTPRequest.new()
	request.timeout = timeout_seconds
	add_child(request)
	request.request_completed.connect(_on_request_completed.bind(request_id, request), CONNECT_ONE_SHOT)
	var request_headers := PackedStringArray(headers)
	request_headers.append("Accept: application/json")
	var data := ""
	if payload != null:
		request_headers.append("Content-Type: application/json")
		data = JSON.stringify(payload)
	var error := request.request(_absolute(path), request_headers, method, data)
	if error != OK:
		request.queue_free()
		transport_failed.emit(request_id, "Request could not start: %s" % error_string(error))
	return request_id

func request_bytes(path: String, metadata: Dictionary = {}) -> HTTPRequest:
	var request := HTTPRequest.new()
	request.timeout = timeout_seconds
	request.set_meta("future_engine_metadata", metadata)
	add_child(request)
	var error := request.request(_absolute(path), PackedStringArray(["Accept: model/gltf-binary, application/octet-stream"]), HTTPClient.METHOD_GET)
	if error != OK:
		request.set_meta("future_engine_start_error", error_string(error))
	return request

func _absolute(path: String) -> String:
	return path if path.begins_with("http://") or path.begins_with("https://") else "%s/%s" % [gateway_url, path.trim_prefix("/")]

func _on_request_completed(result: int, response_code: int, raw_headers: PackedStringArray, body: PackedByteArray, request_id: int, request: HTTPRequest) -> void:
	var headers := {}
	for header in raw_headers:
		var separator := header.find(":")
		if separator > 0:
			headers[header.substr(0, separator).to_lower()] = header.substr(separator + 1).strip_edges()
	if result != HTTPRequest.RESULT_SUCCESS:
		transport_failed.emit(request_id, "Transport failed: %s" % result)
	else:
		var payload: Variant = null
		if not body.is_empty():
			var parsed := JSON.parse_string(body.get_string_from_utf8())
			payload = parsed if parsed != null else {"raw": body.get_string_from_utf8()}
		response_completed.emit(request_id, response_code, payload, headers)
	request.queue_free()
