@tool
class_name FELiveSession
extends Node

signal state_received(state: Dictionary)
signal status_changed(status: String)
signal session_error(message: String)

var _socket := WebSocketPeer.new()
var _status := "disconnected"
var _last_sequence := -1

func connect_session(gateway_url: String, session_id: String) -> void:
	close()
	var url := gateway_url.trim_suffix("/")
	if url.begins_with("https://"):
		url = "wss://%s" % url.trim_prefix("https://")
	else:
		url = "ws://%s" % url.trim_prefix("http://")
	var error := _socket.connect_to_url("%s/simulation/v1/sessions/%s/stream" % [url, session_id.uri_encode()])
	if error != OK:
		session_error.emit("WebSocket connection failed: %s" % error_string(error))
		return
	_set_status("connecting")
	set_process(true)

func send_command(command: Dictionary) -> void:
	if _socket.get_ready_state() != WebSocketPeer.STATE_OPEN:
		return
	_socket.send_text(JSON.stringify(command))

func close() -> void:
	if _socket.get_ready_state() == WebSocketPeer.STATE_OPEN:
		_socket.close(1000, "Future Engine session closed")
	_socket = WebSocketPeer.new()
	_last_sequence = -1
	set_process(false)
	_set_status("disconnected")

func _process(_delta: float) -> void:
	_socket.poll()
	match _socket.get_ready_state():
		WebSocketPeer.STATE_OPEN:
			_set_status("connected")
			while _socket.get_available_packet_count() > 0:
				var parsed := JSON.parse_string(_socket.get_packet().get_string_from_utf8())
				if parsed is Dictionary:
					var sequence := int(parsed.get("sequence", -1))
					if sequence > _last_sequence:
						_last_sequence = sequence
						state_received.emit(parsed)
		WebSocketPeer.STATE_CLOSED:
			var code := _socket.get_close_code()
			set_process(false)
			_set_status("disconnected")
			if code != 1000 and code != -1:
				session_error.emit("Live session closed with WebSocket code %s." % code)

func _set_status(value: String) -> void:
	if value == _status:
		return
	_status = value
	status_changed.emit(value)
