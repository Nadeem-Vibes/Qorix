extends Node

## One language-server process and its JSON-RPC state.
##
## The process is started with non-blocking pipes, so nothing here may block the
## editor: writes are queued and flushed each frame, stdout/stderr are drained
## in small batches, and every request carries a deadline. The class knows the
## protocol and the process; it knows nothing about tabs, panels or themes.

signal initialized(client, capabilities)
signal failed(client, message)
signal exited(client, unexpected, exit_code)
signal stderr_received(client, text)
signal log_line(client, text)
signal publish_diagnostics(client, params)
signal apply_edit_requested(client, request_id, edit)

const Protocol = preload("res://src/features/lsp/lsp_protocol.gd")
const LspText = preload("res://src/features/lsp/lsp_text.gd")

const READ_CHUNK := 64 * 1024
const MAX_READS_PER_FRAME := 8
const MAX_WRITES_PER_FRAME := 24
const MAX_LOG_LINES := 400
const REQUEST_TIMEOUT_MSEC := 12_000
const INITIALIZE_TIMEOUT_MSEC := 25_000
const SHUTDOWN_GRACE_MSEC := 1_500
const EXIT_GRACE_MSEC := 400
const MAX_QUEUED_BYTES := 8 * 1024 * 1024

var editor = null
var profile: Dictionary = {}
var key: String = ""
var root: String = ""
var workspace_root: String = ""
var command: String = ""
var command_path: String = ""
var settings: Variant = null
var initialization_options: Variant = null

var pid: int = 0
var running: bool = false
var server_ready: bool = false
var capabilities: Dictionary = {}
var last_error: String = ""

var _stdio: FileAccess = null
var _stderr: FileAccess = null
var _parser = Protocol.new()

var _write_queue: Array[PackedByteArray] = []
var _queued_bytes: int = 0
var _next_id: int = 1
var _pending: Dictionary = {}
var _init_id: int = -1
var _initializing: bool = false
var _shutdown_requested: bool = false
var _exit_emitted: bool = false
var _kill_at_msec: int = 0
var _exit_code: int = -1

var _log_lines: Array[String] = []
var _stderr_text: String = ""


func configure(p_profile: Dictionary, p_root: String, p_workspace_root: String = "", p_editor = null) -> void:
	profile = p_profile.duplicate(true)
	key = str(profile.get("id", profile.get("language", "lsp"))) + "|" + p_root
	root = p_root
	workspace_root = p_workspace_root
	editor = p_editor
	command = str(profile.get("command", ""))
	command_path = str(profile.get("command_path", ""))
	settings = profile.get("settings")
	initialization_options = profile.get("initialization_options")
	name = "LspClient_" + str(profile.get("id", "server"))


func display_name() -> String:
	return str(profile.get("display", profile.get("id", "Language server")))


func start() -> Dictionary:
	if running:
		return {"ok": true, "error": ""}
	if command_path.is_empty():
		return {"ok": false, "error": "The language server command was not resolved."}

	var launch := _launch_spec()
	var result: Dictionary = OS.execute_with_pipe(launch["path"], launch["args"], false)
	if result.is_empty():
		last_error = "Could not start %s." % display_name()
		return {"ok": false, "error": last_error}

	_stdio = result.get("stdio")
	_stderr = result.get("stderr")
	pid = int(result.get("pid", 0))
	if _stdio == null:
		last_error = "%s started without a writable pipe." % display_name()
		_kill_process()
		return {"ok": false, "error": last_error}

	running = true
	server_ready = false
	_initializing = false
	_shutdown_requested = false
	_exit_emitted = false
	_exit_code = -1
	_parser.reset()
	_pending.clear()
	_next_id = 1
	_log("Started " + display_name() + " in " + root)
	call_deferred("_begin_initialize")
	return {"ok": true, "error": ""}


func _launch_spec() -> Dictionary:
	var args: Array = []
	var raw_args: Variant = profile.get("args", [])
	if raw_args is Array:
		for argument in raw_args:
			args.append(str(argument))

	if OS.get_name() == "Windows":
		# OS.execute_with_pipe has no working-directory argument. cmd.exe also
		# lets the npm shims (.cmd) run, and taskkill /T below reaches the node
		# process that the shim starts.
		#
		# Build one quoted command line: Godot passes each argument through
		# verbatim, so a path such as
		# "C:/Users/Jane Doe/AppData/.../python.exe" would otherwise split at
		# the space and cmd would try to run "C:/Users/Jane".
		var script := "cd /d " + _cmd_quote(root) + " && "
		if command_path.to_lower().ends_with(".cmd") or command_path.to_lower().ends_with(".bat"):
			script += "call "
		script += _cmd_quote(command_path)
		for argument in args:
			script += " " + _cmd_quote(str(argument))
		return {"path": "cmd.exe", "args": ["/d", "/s", "/c", script]}

	var script := "cd " + _shell_quote(root) + " && exec " + _shell_quote(command_path)
	for argument in args:
		script += " " + _shell_quote(str(argument))
	return {"path": "/bin/sh", "args": ["-c", script]}


static func _cmd_quote(text: String) -> String:
	return "\"" + text.replace("\"", "\"\"") + "\""


static func _shell_quote(text: String) -> String:
	return "'" + text.replace("'", "'\\''") + "'"


# ── INITIALIZE ──────────────────────────────────────────────────────────────

func _begin_initialize() -> void:
	if !running or _initializing:
		return
	_initializing = true

	var root_uri := LspText.path_to_uri(root)
	var folders: Array = []
	if !workspace_root.is_empty():
		folders.append({
			"uri": LspText.path_to_uri(workspace_root),
			"name": workspace_root.get_file() if !workspace_root.get_file().is_empty() else workspace_root,
		})
	elif !root.is_empty():
		folders.append({"uri": root_uri, "name": root.get_file()})

	var params := {
		"processId": OS.get_process_id(),
		"clientInfo": {"name": "Qorix", "version": "1.0"},
		"locale": "en",
		"rootPath": root if !root.is_empty() else null,
		"rootUri": root_uri if !root_uri.is_empty() else null,
		"capabilities": _client_capabilities(),
		"workspaceFolders": folders if !folders.is_empty() else null,
	}
	if initialization_options != null:
		params["initializationOptions"] = initialization_options

	_init_id = send_request("initialize", params, _on_initialize_response, INITIALIZE_TIMEOUT_MSEC)


func _client_capabilities() -> Dictionary:
	return {
		"workspace": {
			"applyEdit": true,
			"workspaceEdit": {"documentChanges": true},
			"workspaceFolders": true,
			"configuration": true,
			"didChangeConfiguration": {"dynamicRegistration": false},
		},
		"textDocument": {
			"synchronization": {
				"dynamicRegistration": false,
				"willSave": false,
				"willSaveWaitUntil": false,
				"didSave": true,
			},
			"completion": {
				"dynamicRegistration": false,
				"contextSupport": false,
				"completionItem": {
					"snippetSupport": true,
					"documentationFormat": ["markdown", "plaintext"],
					"resolveSupport": {"properties": ["documentation", "detail", "additionalTextEdits"]},
					"insertReplaceSupport": false,
					"labelDetailsSupport": true,
				},
				"completionItemKind": {"valueSet": range(1, 26)},
			},
			"hover": {
				"dynamicRegistration": false,
				"contentFormat": ["markdown", "plaintext"],
			},
			"definition": {"dynamicRegistration": false, "linkSupport": true},
			"references": {"dynamicRegistration": false},
			"formatting": {"dynamicRegistration": false},
			"rename": {"dynamicRegistration": false, "prepareSupport": false},
			"codeAction": {
				"dynamicRegistration": false,
				"codeActionLiteralSupport": {
					"codeActionKind": {
						"valueSet": [
							"", "quickfix", "refactor", "refactor.extract",
							"refactor.inline", "refactor.rewrite", "source",
							"source.organizeImports", "source.fixAll",
						],
					},
				},
				"isPreferredSupport": true,
				"disabledSupport": true,
				"dataSupport": true,
				"resolveSupport": {"properties": ["edit"]},
			},
			"signatureHelp": {
				"dynamicRegistration": false,
				"signatureInformation": {
					"documentationFormat": ["markdown", "plaintext"],
					"parameterInformation": {"labelOffsetSupport": true},
					"activeParameterSupport": true,
				},
				"contextSupport": true,
			},
			"publishDiagnostics": {
				"relatedInformation": true,
				"versionSupport": true,
				"tagSupport": {"valueSet": [1, 2]},
			},
		},
		"window": {"workDoneProgress": false, "showMessage": {}},
		"general": {"positionEncodings": ["utf-16"]},
	}


func _on_initialize_response(result: Dictionary) -> void:
	if !running:
		return
	if !bool(result.get("ok", false)):
		last_error = str(result.get("error", "The language server refused to initialize."))
		_log("Initialize failed: " + last_error)
		failed.emit(self, last_error)
		_stop_expected()
		return

	var value: Variant = result.get("result")
	if value is Dictionary:
		capabilities = value.get("capabilities", {})
	else:
		capabilities = {}
	server_ready = true
	_initializing = false
	_log("Ready (" + display_name() + ")")

	send_notification("initialized", {})
	send_notification("workspace/didChangeConfiguration", {"settings": settings if settings != null else {}})
	initialized.emit(self, capabilities)


func is_ready() -> bool:
	return running and server_ready


func supports(section: String, key: String = "") -> bool:
	var entry: Variant = capabilities.get(section)
	if entry == null:
		return false
	# Most LSP providers are either `true` or an options object; only a few
	# (completion, codeAction, …) use the object form with nested keys.
	if key.is_empty():
		return bool(entry) if entry is bool else entry is Dictionary
	if entry is Dictionary:
		return bool((entry as Dictionary).get(key, false))
	return false


func server_setting(section: String, fallback: Variant = null) -> Variant:
	if settings is Dictionary:
		return (settings as Dictionary).get(section, fallback)
	return fallback


# ── REQUESTS / NOTIFICATIONS ────────────────────────────────────────────────

func send_request(method: String, params: Variant = null, callback: Callable = Callable(), timeout_msec: int = REQUEST_TIMEOUT_MSEC) -> int:
	if !running:
		if callback.is_valid():
			callback.call({"ok": false, "result": null, "error": "The language server is not running.", "code": -1})
		return -1

	var id := _next_id
	_next_id += 1
	_queue_message(Protocol.request(id, method, params))
	_pending[id] = {
		"method": method,
		"callback": callback,
		"deadline": Time.get_ticks_msec() + maxi(timeout_msec, 1000),
	}
	return id


func cancel_request(id: int) -> void:
	if !running or !_pending.has(id):
		return
	var pending: Dictionary = _pending[id]
	_pending.erase(id)
	_queue_message(Protocol.notification_message("$/cancelRequest", {"id": id}))
	var callback: Variant = pending.get("callback")
	if callback is Callable and (callback as Callable).is_valid():
		(callback as Callable).call({"ok": false, "result": null, "error": "Request cancelled.", "code": -32800})


func send_notification(method: String, params: Variant = null) -> void:
	if !running:
		return
	_queue_message(Protocol.notification_message(method, params))


func send_response(id: Variant, result: Variant) -> void:
	if !running:
		return
	_queue_message(Protocol.response(id, result))


func send_error_response(id: Variant, code: int, message: String) -> void:
	if !running:
		return
	_queue_message(Protocol.error_response(id, code, message))


func _queue_message(message: Dictionary) -> void:
	var frame := Protocol.encode(message)
	if _queued_bytes + frame.size() > MAX_QUEUED_BYTES:
		_log("Dropped a message: the language server is not reading its input.")
		return
	_write_queue.append(frame)
	_queued_bytes += frame.size()


# ── FRAME PUMP ──────────────────────────────────────────────────────────────

func _process(_delta: float) -> void:
	if !running:
		return

	_drain(_stdio, false)
	_drain(_stderr, true)
	_flush_writes()
	_expire_requests()

	if _kill_at_msec > 0 and Time.get_ticks_msec() >= _kill_at_msec:
		_kill_at_msec = 0
		_kill_process()
		_finish_exit()

	if running and pid > 0 and !OS.is_process_running(pid):
		# Drain whatever the server wrote just before it died.
		_drain(_stdio, false)
		_flush_writes()
		_finish_exit()


func _drain(stream: FileAccess, is_stderr: bool) -> void:
	if stream == null:
		return

	for i in range(MAX_READS_PER_FRAME):
		var chunk := stream.get_buffer(READ_CHUNK)
		if chunk.is_empty():
			break
		if is_stderr:
			_handle_stderr(chunk)
		else:
			_handle_stdout(chunk)


func _handle_stdout(chunk: PackedByteArray) -> void:
	var parsed: Dictionary = _parser.feed(chunk)
	for error in parsed.get("errors", []):
		_log(str(error))
	for message in parsed.get("messages", []):
		if message is Dictionary:
			_handle_message(message)


func _handle_stderr(chunk: PackedByteArray) -> void:
	var text := chunk.get_string_from_utf8()
	_stderr_text += text
	if _stderr_text.length() > 16 * 1024:
		_stderr_text = _stderr_text.substr(_stderr_text.length() - 16 * 1024)
	stderr_received.emit(self, text)

	for line in text.replace("\r\n", "\n").replace("\r", "\n").split("\n"):
		var trimmed := str(line).strip_edges()
		if !trimmed.is_empty():
			_log("[stderr] " + trimmed)


func _handle_message(message: Dictionary) -> void:
	if Protocol.is_response(message):
		_handle_response(message)
		return
	if Protocol.is_request(message):
		_handle_server_request(message)
		return
	if Protocol.is_notification(message):
		_handle_notification(message)


func _handle_response(message: Dictionary) -> void:
	var raw_id: Variant = message.get("id")
	var id := int(raw_id) if !(raw_id is String) else -1
	if id == -1:
		# Some servers echo string ids. Match those too.
		for candidate in _pending.keys():
			if str(candidate) == str(raw_id):
				id = int(candidate)
				break
	if !_pending.has(id):
		return

	var pending: Dictionary = _pending[id]
	_pending.erase(id)
	var result := Protocol.response_result(message)
	var method := str(pending.get("method", ""))
	# Initialize and shutdown carry their own lifecycle handlers. Calling the
	# callback as well would run them twice: two "initialized" notifications
	# and two exit requests.
	if method == "initialize":
		_on_initialize_response(result)
		return
	if method == "shutdown":
		_on_shutdown_response(result)
		return

	var callback: Variant = pending.get("callback")
	if callback is Callable and (callback as Callable).is_valid():
		(callback as Callable).call(result)


func _handle_notification(message: Dictionary) -> void:
	var method := str(message.get("method", ""))
	var params: Variant = message.get("params")

	match method:
		"textDocument/publishDiagnostics":
			publish_diagnostics.emit(self, params)
		"window/logMessage":
			if params is Dictionary:
				_log(str((params as Dictionary).get("message", "")))
		"window/showMessage":
			if params is Dictionary:
				var text := str((params as Dictionary).get("message", ""))
				_log("Server message: " + text)
		"$/progress":
			pass
		"telemetry/event":
			pass
		"workspace/diagnostics/refresh", "workspace/codeLens/refresh", "workspace/inlayHint/refresh", "workspace/semanticTokens/refresh":
			pass
		_:
			if !method.begins_with("$/"):
				_log("Unhandled server notification: " + method)


func _handle_server_request(message: Dictionary) -> void:
	var method := str(message.get("method", ""))
	var params: Variant = message.get("params")
	var id: Variant = message.get("id")

	match method:
		"workspace/configuration":
			var items: Array = []
			if params is Dictionary and (params as Dictionary).get("items") is Array:
				items = (params as Dictionary)["items"]
			var values: Array = []
			for item in items:
				var section := str((item as Dictionary).get("section", "")) if item is Dictionary else ""
				var value: Variant = null
				if settings is Dictionary:
					if section.is_empty():
						value = settings
					elif (settings as Dictionary).has(section):
						value = (settings as Dictionary)[section]
				elif section.is_empty():
					value = settings
				values.append(value if value != null else {})
			send_response(id, values)
		"workspace/workspaceFolders":
			var folders: Array = []
			if !workspace_root.is_empty():
				folders.append({"uri": LspText.path_to_uri(workspace_root), "name": workspace_root.get_file()})
			elif !root.is_empty():
				folders.append({"uri": LspText.path_to_uri(root), "name": root.get_file()})
			send_response(id, folders)
		"workspace/applyEdit":
			var edit: Variant = null
			if params is Dictionary:
				edit = (params as Dictionary).get("edit")
			apply_edit_requested.emit(self, id, edit)
		"window/workDoneProgress/create", "client/registerCapability", "client/unregisterCapability", "window/showMessageRequest", "workspace/codeLens/refresh", "workspace/inlayHint/refresh", "workspace/semanticTokens/refresh":
			send_response(id, null)
		"window/showDocument":
			send_response(id, {"success": false})
		_:
			_log("Unhandled server request: " + method)
			send_error_response(id, -32601, "Method not supported: " + method)


func _flush_writes() -> void:
	if _write_queue.is_empty() or _stdio == null:
		return

	var combined := PackedByteArray()
	var writes := mini(_write_queue.size(), MAX_WRITES_PER_FRAME)
	for i in range(writes):
		combined.append_array(_write_queue[i])
	if writes > 0:
		_write_queue = _write_queue.slice(writes)
		_queued_bytes = maxi(0, _queued_bytes - combined.size())

	if combined.is_empty():
		return
	_stdio.store_buffer(combined)
	_stdio.flush()
	if _stdio.get_error() != OK:
		_log("Could not write to the language server (error %d)." % _stdio.get_error())
		_stop_expected()


func _expire_requests() -> void:
	if _pending.is_empty():
		return
	var now := Time.get_ticks_msec()
	var expired: Array = []
	for id in _pending.keys():
		var pending: Dictionary = _pending[id]
		if int(pending.get("deadline", 0)) <= now:
			expired.append(id)

	for raw_id in expired:
		var id := int(raw_id)
		var pending: Dictionary = _pending[id]
		_pending.erase(id)
		var method := str(pending.get("method", ""))
		var result := {
			"ok": false, "result": null,
			"error": "The language server did not answer %s in time." % method,
			"code": -32001,
		}
		_log(str(result["error"]))
		if method == "initialize":
			failed.emit(self, str(result["error"]))
			_stop_expected()
		var callback: Variant = pending.get("callback")
		if callback is Callable and (callback as Callable).is_valid():
			(callback as Callable).call(result)


# ── SHUTDOWN ────────────────────────────────────────────────────────────────

func stop() -> void:
	if !running:
		return
	if _shutdown_requested:
		_kill_at_msec = Time.get_ticks_msec() + EXIT_GRACE_MSEC
		return
	_shutdown_requested = true
	if !server_ready:
		_stop_expected()
		return

	send_request("shutdown", null, _on_shutdown_response, 3000)
	_kill_at_msec = Time.get_ticks_msec() + SHUTDOWN_GRACE_MSEC


func _on_shutdown_response(_result: Dictionary) -> void:
	if !running:
		return
	send_notification("exit", null)
	_kill_at_msec = Time.get_ticks_msec() + EXIT_GRACE_MSEC


func force_stop() -> void:
	if !running:
		return
	_stop_expected()


func _stop_expected() -> void:
	_shutdown_requested = true
	_kill_process()
	_finish_exit()


func _kill_process() -> void:
	if pid <= 0:
		return
	if OS.get_name() == "Windows":
		var output: Array = []
		OS.execute("taskkill", ["/F", "/T", "/PID", str(pid)], output, false)
	elif OS.is_process_running(pid):
		OS.kill(pid)
	pid = 0


func _finish_exit() -> void:
	if _exit_emitted:
		return
	_exit_emitted = true

	var unexpected := !_shutdown_requested
	if _exit_code < 0 and pid > 0 and !OS.is_process_running(pid):
		_exit_code = OS.get_process_exit_code(pid)

	running = false
	server_ready = false
	_initializing = false
	_shutdown_requested = true
	_write_queue.clear()
	_queued_bytes = 0
	_pending.clear()

	if _stdio != null:
		_stdio.close()
		_stdio = null
	if _stderr != null:
		_stderr.close()
		_stderr = null
	_parser.reset()

	exited.emit(self, unexpected, _exit_code)


func _exit_code_for(pid_value: int) -> int:
	if pid_value <= 0:
		return -1
	if OS.is_process_running(pid_value):
		return -1
	return OS.get_process_exit_code(pid_value)


# ── LOG ─────────────────────────────────────────────────────────────────────

func _log(text: String) -> void:
	var line := str(text).strip_edges()
	if line.is_empty():
		return
	_log_lines.append("[%s] %s" % [display_name(), line])
	if _log_lines.size() > MAX_LOG_LINES:
		_log_lines = _log_lines.slice(_log_lines.size() - MAX_LOG_LINES)
	log_line.emit(self, line)


func log_text() -> String:
	return "\n".join(_log_lines)


func stderr_text() -> String:
	return _stderr_text
