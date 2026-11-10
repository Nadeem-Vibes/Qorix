extends Node

## One debug-adapter process and its DAP socket.
##
## The transport is TCP, not stdio: an adapter such as debugpy is started with
## `--host 127.0.0.1 --port <port>` and then listens for the editor. The class
## owns the process, the socket, sequence numbers, request callbacks and
## deadlines. It knows nothing about breakpoints, tabs or panels; DapManager
## turns protocol messages into editor state.

signal connected(client)
signal disconnected(client, unexpected, reason)
signal server_request(client, request_seq, command, arguments)
signal event_received(client, event_name, body)
signal log_line(client, text)

const Protocol = preload("res://src/features/debug/dap_protocol.gd")

const CONNECT_TIMEOUT_MSEC := 10_000
const CONNECT_RETRY_MSEC := 100
const REQUEST_TIMEOUT_MSEC := 12_000
const MAX_QUEUED_BYTES := 4 * 1024 * 1024
const MAX_READS_PER_FRAME := 8
const MAX_LOG_LINES := 300
const STOP_GRACE_MSEC := 900

var editor = null
var adapter_id: String = ""
var display: String = ""
var command_path: String = ""
var args: Array = []
var host: String = "127.0.0.1"
var port: int = 0
var cwd: String = ""

var running: bool = false
var connected_to_adapter: bool = false
var last_error: String = ""

var pid: int = 0

var _peer: StreamPeerTCP = null
var _parser = Protocol.new()
var _read_buffer := PackedByteArray()
var _stdio: FileAccess = null
var _stderr: FileAccess = null
var _stderr_text: String = ""
var _write_queue: Array[PackedByteArray] = []
var _queued_bytes: int = 0
var _next_seq: int = 1
var _pending: Dictionary = {}
var _log_lines: Array[String] = []
var _connect_started_msec: int = 0
var _last_connect_attempt_msec: int = 0
var _kill_at_msec: int = 0
var _exit_emitted: bool = false
var _stopping: bool = false
var _exit_code: int = -1


func configure(options: Dictionary) -> void:
	adapter_id = str(options.get("adapter_id", "debug"))
	display = str(options.get("display", adapter_id.capitalize()))
	command_path = str(options.get("command_path", ""))
	args = options.get("args", []).duplicate()
	host = str(options.get("host", "127.0.0.1"))
	port = int(options.get("port", 0))
	cwd = str(options.get("cwd", ""))
	editor = options.get("editor")
	name = "DapClient_" + adapter_id


func start() -> Dictionary:
	if running:
		return {"ok": true, "error": ""}
	if command_path.is_empty():
		return {"ok": false, "error": "The debug adapter command was not resolved."}
	if port <= 0:
		return {"ok": false, "error": "The debug adapter port is invalid."}

	var launch := _launch_spec()
	# (execute_with_pipe in this Godot build accepts at most three arguments,
	# so stderr cannot be redirected into a separate pipe here.)
	var result: Dictionary = OS.execute_with_pipe(launch["path"], launch["args"], false)
	if result.is_empty():
		last_error = "Could not start %s." % display
		return {"ok": false, "error": last_error}

	_stdio = result.get("stdio")
	_stderr = result.get("stderr")
	pid = int(result.get("pid", 0))
	if _stdio == null:
		last_error = "%s started without pipes." % display
		_kill_process()
		return {"ok": false, "error": last_error}

	running = true
	connected_to_adapter = false
	_stopping = false
	_exit_emitted = false
	_exit_code = -1
	_parser.reset()
	_read_buffer = PackedByteArray()
	_write_queue.clear()
	_queued_bytes = 0
	_pending.clear()
	_next_seq = 1
	_stderr_text = ""
	_connect_started_msec = Time.get_ticks_msec()
	_last_connect_attempt_msec = 0
	_kill_at_msec = 0
	_log("Starting %s in %s" % [display, cwd if !cwd.is_empty() else "(default folder)"])
	_start_connect_attempt()
	return {"ok": true, "error": ""}


func _launch_spec() -> Dictionary:
	var raw_args: Array = []
	for argument in args:
		raw_args.append(str(argument))

	if OS.get_name() == "Windows":
		# OS.execute_with_pipe has no working-directory argument. Build one
		# quoted cmd line, which also lets a .cmd shim run through `call`.
		var script := ""
		if !cwd.is_empty():
			script = "cd /d " + _cmd_quote(cwd) + " && "
		if command_path.to_lower().ends_with(".cmd") or command_path.to_lower().ends_with(".bat"):
			script += "call "
		script += _cmd_quote(command_path)
		for argument in raw_args:
			script += " " + _cmd_quote(str(argument))
		return {"path": "cmd.exe", "args": ["/d", "/s", "/c", script]}

	var script := ""
	if !cwd.is_empty():
		script = "cd " + _shell_quote(cwd) + " && "
	script += "exec " + _shell_quote(command_path)
	for argument in raw_args:
		script += " " + _shell_quote(str(argument))
	return {"path": "/bin/sh", "args": ["-c", script]}


static func _cmd_quote(text: String) -> String:
	return "\"" + text.replace("\"", "\"\"") + "\""


static func _shell_quote(text: String) -> String:
	return "'" + text.replace("'", "'\\''") + "'"


# ── CONNECTION ──────────────────────────────────────────────────────────────

func _start_connect_attempt() -> void:
	_last_connect_attempt_msec = Time.get_ticks_msec()
	_peer = StreamPeerTCP.new()
	var error := _peer.connect_to_host(host, port)
	if error != OK:
		_peer = null


func _poll_connection() -> void:
	if connected_to_adapter:
		return
	if Time.get_ticks_msec() - _connect_started_msec > CONNECT_TIMEOUT_MSEC:
		last_error = "%s did not accept a connection on %s:%d. %s" % [
			display, host, port, _stderr_hint(),
		]
		_fail_start(last_error)
		return

	if _peer == null:
		if Time.get_ticks_msec() - _last_connect_attempt_msec >= CONNECT_RETRY_MSEC:
			_start_connect_attempt()
		return

	# StreamPeerTCP only advances its handshake when it is polled; without
	# this the status stays CONNECTING until the timeout fires.
	_peer.poll()
	var status := _peer.get_status()
	if status == StreamPeerTCP.STATUS_CONNECTED:
		# Safe to configure now that the socket is open. Calling this before
		# the handshake logs a null-socket error and has no effect.
		_peer.set_no_delay(true)
		connected_to_adapter = true
		_log("Connected to %s on %s:%d" % [display, host, port])
		connected.emit(self)
		return
	if status == StreamPeerTCP.STATUS_ERROR or status == StreamPeerTCP.STATUS_NONE:
		_peer = null
		if Time.get_ticks_msec() - _last_connect_attempt_msec >= CONNECT_RETRY_MSEC:
			_start_connect_attempt()


func _fail_start(message: String) -> void:
	last_error = message
	_log(message)
	_stopping = true
	_kill_process()
	# A handshake/start failure is a failure, not a requested stop: the manager
	# uses this flag to record last_error and show a notice.
	_finish_exit(true, message)


func is_ready() -> bool:
	return running and connected_to_adapter


# ── FRAME PUMP ──────────────────────────────────────────────────────────────

func _process(_delta: float) -> void:
	if !running:
		return

	_drain_stderr()
	_poll_connection()
	if !running:
		return
	if connected_to_adapter:
		_drain_socket()
		_flush_writes()
	_expire_requests()

	if _kill_at_msec > 0 and Time.get_ticks_msec() >= _kill_at_msec:
		_kill_at_msec = 0
		_kill_process()
		_finish_exit(!_stopping, "The debug adapter did not close in time.")

	if running and pid > 0 and !OS.is_process_running(pid):
		# Give the socket one last chance to deliver a terminated event.
		_drain_stderr()
		if connected_to_adapter:
			_drain_socket()
		_finish_exit(!_stopping, _stderr_hint())


func _drain_stderr() -> void:
	if _stderr == null:
		return
	for i in range(MAX_READS_PER_FRAME):
		var chunk := _stderr.get_buffer(16 * 1024)
		if chunk.is_empty():
			break
		var text := chunk.get_string_from_utf8()
		_stderr_text += text
		if _stderr_text.length() > 16 * 1024:
			_stderr_text = _stderr_text.substr(_stderr_text.length() - 16 * 1024)
		for line in text.replace("\r\n", "\n").replace("\r", "\n").split("\n"):
			var trimmed := str(line).strip_edges()
			if !trimmed.is_empty():
				_log("[adapter] " + trimmed)


func _drain_socket() -> void:
	if _peer == null:
		return
	_peer.poll()
	for i in range(MAX_READS_PER_FRAME):
		var available := _peer.get_available_bytes()
		if available <= 0:
			break
		var result: Array = _peer.get_partial_data(mini(available, 64 * 1024))
		var error := int(result[0])
		if error != OK:
			_handle_socket_error(error)
			return
		var chunk: PackedByteArray = result[1]
		if chunk.is_empty():
			break
		_handle_bytes(chunk)

	if _peer != null and _peer.get_status() != StreamPeerTCP.STATUS_CONNECTED and connected_to_adapter:
		_handle_socket_error(ERR_CONNECTION_ERROR)


func _handle_bytes(chunk: PackedByteArray) -> void:
	var parsed: Dictionary = _parser.feed(chunk)
	for error in parsed.get("errors", []):
		_log(str(error))
	for message in parsed.get("messages", []):
		if message is Dictionary:
			_handle_message(message)


func _handle_socket_error(error: int) -> void:
	if _stopping or !running:
		return
	last_error = "Lost the connection to %s (error %d). %s" % [display, error, _stderr_hint()]
	_log(last_error)
	connected_to_adapter = false
	_finish_exit(true, last_error)


func _handle_message(message: Dictionary) -> void:
	if Protocol.is_response(message):
		_handle_response(message)
		return
	if Protocol.is_event(message):
		event_received.emit(self, str(message.get("event", "")), message.get("body"))
		return
	if Protocol.is_request(message):
		server_request.emit(
			self,
			int(message.get("seq", -1)),
			str(message.get("command", "")),
			message.get("arguments", {})
		)


func _handle_response(message: Dictionary) -> void:
	var request_seq := int(message.get("request_seq", -1))
	if !_pending.has(request_seq):
		return
	var pending: Dictionary = _pending[request_seq]
	_pending.erase(request_seq)
	var result := Protocol.response_result(message)
	var callback: Variant = pending.get("callback")
	if callback is Callable and (callback as Callable).is_valid():
		(callback as Callable).call(result)


# ── REQUESTS / RESPONSES ────────────────────────────────────────────────────

func send_request(command: String, arguments: Variant = null, callback: Callable = Callable(),
		timeout_msec: int = REQUEST_TIMEOUT_MSEC) -> int:
	if !is_ready():
		if callback.is_valid():
			callback.call({"ok": false, "body": {}, "error": "The debug adapter is not ready.", "command": command})
		return -1

	var seq := _next_seq
	_next_seq += 1
	_queue_message(Protocol.request(seq, command, arguments))
	_pending[seq] = {
		"command": command,
		"callback": callback,
		"deadline": Time.get_ticks_msec() + maxi(timeout_msec, 1000),
	}
	return seq


func send_response(request_seq: int, command: String, success: bool = true,
		body: Variant = null, message: String = "") -> void:
	if !running:
		return
	_queue_message(Protocol.response(_next_seq, request_seq, command, success, body, message))
	_next_seq += 1


func _queue_message(message: Dictionary) -> void:
	var frame := Protocol.encode(message)
	if _queued_bytes + frame.size() > MAX_QUEUED_BYTES:
		_log("Dropped a DAP message: the adapter is not reading its socket.")
		return
	_write_queue.append(frame)
	_queued_bytes += frame.size()


func _flush_writes() -> void:
	if _write_queue.is_empty() or _peer == null:
		return
	var combined := PackedByteArray()
	for frame in _write_queue:
		combined.append_array(frame)
	_write_queue.clear()
	_queued_bytes = 0
	if combined.is_empty():
		return
	var error := _peer.put_data(combined)
	if error != OK:
		_handle_socket_error(error)


func _expire_requests() -> void:
	if _pending.is_empty():
		return
	var now := Time.get_ticks_msec()
	var expired: Array = []
	for seq in _pending.keys():
		if int(_pending[seq].get("deadline", 0)) <= now:
			expired.append(seq)
	for raw_seq in expired:
		var seq := int(raw_seq)
		if !_pending.has(seq):
			continue
		var pending: Dictionary = _pending[seq]
		_pending.erase(seq)
		var command := str(pending.get("command", ""))
		var result := {
			"ok": false, "body": {}, "command": command,
			"error": "The debug adapter did not answer %s in time." % command,
		}
		_log(str(result["error"]))
		var callback: Variant = pending.get("callback")
		if callback is Callable and (callback as Callable).is_valid():
			(callback as Callable).call(result)


## Stops after a short grace period so a disconnect response can arrive first.
func stop() -> void:
	if !running:
		return
	_stopping = true
	_kill_at_msec = Time.get_ticks_msec() + STOP_GRACE_MSEC


func force_stop() -> void:
	if !running:
		return
	_stopping = true
	_kill_process()
	_finish_exit(false, "Stopped.")


func _kill_process() -> void:
	if pid <= 0:
		return
	if OS.get_name() == "Windows":
		var output: Array = []
		OS.execute("taskkill", ["/F", "/T", "/PID", str(pid)], output, false)
	elif OS.is_process_running(pid):
		OS.kill(pid)
	if pid > 0 and !OS.is_process_running(pid):
		_exit_code = OS.get_process_exit_code(pid)
	pid = 0


func _finish_exit(unexpected: bool, reason: String) -> void:
	if _exit_emitted:
		return
	_exit_emitted = true
	if pid > 0 and !OS.is_process_running(pid):
		_exit_code = OS.get_process_exit_code(pid)
	pid = 0

	running = false
	connected_to_adapter = false
	_write_queue.clear()
	_queued_bytes = 0
	_pending.clear()
	if _peer != null:
		_peer.disconnect_from_host()
		_peer = null
	if _stdio != null:
		_stdio.close()
		_stdio = null
	if _stderr != null:
		_stderr.close()
		_stderr = null
	_parser.reset()
	disconnected.emit(self, unexpected, reason)


# ── LOG ─────────────────────────────────────────────────────────────────────

func _log(text: String) -> void:
	var line := str(text).strip_edges()
	if line.is_empty():
		return
	_log_lines.append("[%s] %s" % [display, line])
	if _log_lines.size() > MAX_LOG_LINES:
		_log_lines = _log_lines.slice(_log_lines.size() - MAX_LOG_LINES)
	log_line.emit(self, line)


func log_text() -> String:
	return "\n".join(_log_lines)


func stderr_text() -> String:
	return _stderr_text


func _stderr_hint() -> String:
	var text := _stderr_text.strip_edges()
	if text.is_empty():
		return ""
	var lines := text.split("\n")
	var tail := lines[lines.size() - 1] if !lines.is_empty() else text
	return tail.substr(0, 240)
