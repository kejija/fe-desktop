extends SceneTree

const BackendClient = preload("res://addons/future_engine/core/backend_client.gd")
const ContractValidator = preload("res://addons/future_engine/core/contract_validator.gd")
const LiveSession = preload("res://addons/future_engine/core/live_session.gd")

var _client: FEBackendClient
var _live: FELiveSession
var _actions := {}
var _revision := 0
var _expected_asset_digest := ""
var _finished := false

func _init() -> void:
	_client = BackendClient.new()
	root.add_child(_client)
	_client.configure()
	_client.response_completed.connect(_on_response)
	_client.transport_failed.connect(_on_transport_failed)
	_start.call_deferred()

func _start() -> void:
	_request("health", HTTPClient.METHOD_GET, "/healthz")
	var timeout := create_timer(12.0)
	timeout.timeout.connect(_fail.bind("Gateway integration test timed out."))

func _request(action: String, method: HTTPClient.Method, path: String, payload: Variant = null, headers := PackedStringArray()) -> void:
	var request_id := _client.request_json(method, path, payload, headers)
	_actions[request_id] = action

func _on_response(request_id: int, status: int, payload: Variant, _headers: Dictionary) -> void:
	var action := str(_actions.get(request_id, "unknown"))
	_actions.erase(request_id)
	if status < 200 or status >= 300:
		_fail("%s returned HTTP %s: %s" % [action, status, payload])
		return
	match action:
		"health":
			if payload.get("mode") != "mock":
				_fail("Integration tests require the explicit mock gateway.")
				return
			_request("document", HTTPClient.METHOD_GET, "/node-design/v1/designs/demo-drive")
		"document":
			var errors := ContractValidator.validate_design_document(payload)
			if not errors.is_empty():
				_fail("Design document failed validation: %s" % errors)
				return
			_revision = int(payload.get("draft", {}).get("revision_number"))
			_request("presentation", HTTPClient.METHOD_GET, "/node-design/v1/designs/demo-drive/presentation?profile_id=default", null, PackedStringArray(["If-Match: %s" % _revision]))
		"presentation":
			var errors := ContractValidator.validate_presentation(payload, "demo-drive", _revision)
			if not errors.is_empty():
				_fail("Presentation failed validation: %s" % errors)
				return
			var model: Dictionary = payload.get("instances", [])[0].get("model", {})
			_expected_asset_digest = str(model.get("sha256", ""))
			var asset_request := _client.request_bytes("/components%s" % model.get("asset_path", ""))
			asset_request.request_completed.connect(_on_asset.bind(asset_request), CONNECT_ONE_SHOT)
		"session":
			var session_id := str(payload.get("session_id", ""))
			if session_id.is_empty():
				_fail("Simulation mock returned no session ID.")
				return
			_live = LiveSession.new()
			root.add_child(_live)
			_live.state_received.connect(_on_live_state, CONNECT_ONE_SHOT)
			_live.session_error.connect(_fail)
			_live.connect_session(_client.gateway_url, session_id)

func _on_asset(result: int, status: int, _headers: PackedStringArray, body: PackedByteArray, request: HTTPRequest) -> void:
	request.queue_free()
	if result != HTTPRequest.RESULT_SUCCESS or status != 200:
		_fail("Mock GLB download failed.")
		return
	var hashing := HashingContext.new()
	hashing.start(HashingContext.HASH_SHA256)
	hashing.update(body)
	var digest := "sha256:%s" % hashing.finish().hex_encode()
	if digest != _expected_asset_digest:
		_fail("Mock GLB digest did not match presentation.")
		return
	_request("session", HTTPClient.METHOD_POST, "/simulation/v1/sessions", {"design_id": "demo-drive", "revision_number": _revision, "profile_id": "default", "package_digest": "sha256:4444444444444444444444444444444444444444444444444444444444444444"})

func _on_live_state(state: Dictionary) -> void:
	if int(state.get("sequence", -1)) < 0 or state.get("poses", []).is_empty():
		_fail("Live simulation state is incomplete.")
		return
	_finished = true
	_live.close()
	print("FE_GATEWAY_INTEGRATION_OK")
	quit(0)

func _on_transport_failed(_request_id: int, message: String) -> void:
	_fail(message)

func _fail(message: String) -> void:
	if _finished:
		return
	_finished = true
	push_error(message)
	quit(1)
