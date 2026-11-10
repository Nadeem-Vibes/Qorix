extends Node

## Coordinates one debug session: adapter launch, breakpoints, paused state,
## call stack, scopes/variables, watches and the debug console.
##
## The manager owns state and never builds controls. DapClient speaks the
## protocol; DebugPanel renders what this class exposes, and FileManager routes
## navigation and breakpoint gutter clicks here.

signal state_changed
signal breakpoints_changed
signal session_started(info)
signal session_ended(info)
signal execution_line_changed(path, line)
signal navigate_requested(path, line, column)
signal log_updated
signal missing_adapter(help)

const DapConfig = preload("res://src/features/debug/dap_config.gd")
const DapClient = preload("res://src/features/debug/dap_client.gd")
const RuntimeCatalog = preload("res://src/features/run/runtime_catalog.gd")
const Paths = preload("res://src/base/path_utils.gd")

const MAX_CONSOLE_ENTRIES := 600
const MAX_CONSOLE_CHARS := 240_000
const MAX_WATCHES := 20
const MAX_PREFETCH_REQUESTS := 12
const STACK_FRAME_LIMIT := 40

var editor = null
var config = null
var catalog = null

## idle → starting → initializing → running ⇄ stopped → terminating → idle
var state: String = "idle"
var last_error: String = ""
var capabilities: Dictionary = {}
var client = null

var breakpoints: Dictionary = {}
var stack: Array = []
var scopes: Array = []
var selected_frame: int = 0
var watches: Array = []
var watch_results: Dictionary = {}
var console_entries: Array = []
var verbose_log: bool = false

var adapter_id: String = ""
var adapter_display: String = ""
var program_path: String = ""
var stop_reason: String = ""
var stop_description: String = ""
var thread_id: int = 0

var _workspace_root: String = ""
var _variables: Dictionary = {}
var _pending_variables: Dictionary = {}
var _prefetch_count: int = 0
var _frame_generation: int = 0
var _initialized_event_seen: bool = false
var _configuration_done_sent: bool = false
var _breakpoints_sent: bool = false
var _ending_session: bool = false
var _launch_result: Dictionary = {}
var _resolved: Dictionary = {}
var _execution_path: String = ""
var _execution_line: int = -1


func _ready() -> void:
	if editor == null:
		var parent = get_parent()
		# Duck-typed on purpose: naming FileManager here would make this script
		# depend on the whole editor scene at compile time, which the unit
		# tests cannot satisfy.
		if parent != null and parent.has_method("save_all_for_debug"):
			editor = parent
	if config == null:
		config = DapConfig.new()
	if catalog == null:
		catalog = RuntimeCatalog.new()
	if config.executable_resolver.is_valid() == false:
		config.executable_resolver = Callable(catalog, "find_executable")
	verbose_log = _setting_bool("debug_verbose_log", false)
	# Resolve the autoload by name: the manager is also preloaded by the unit
	# tests, where project autoloads do not exist.
	var lua = get_node_or_null("/root/LuaSingleton")
	if lua != null and lua.has_signal("on_settings_change") \
			and !lua.on_settings_change.is_connected(_on_settings_change):
		lua.on_settings_change.connect(_on_settings_change)
	_load_config()
	_log_console("system", "Debugger ready. Python files use debugpy; press F9 on a line to add a breakpoint.")


func _exit_tree() -> void:
	if client != null and is_instance_valid(client):
		client.force_stop()
		client = null


func _on_settings_change() -> void:
	verbose_log = _setting_bool("debug_verbose_log", false)


# ── CONFIG / WORKSPACE ──────────────────────────────────────────────────────

func set_workspace(root: String) -> void:
	var normalized := Paths.normalize(root)
	if normalized == _workspace_root:
		return
	if is_active():
		stop_debugging()
	_workspace_root = normalized
	_load_config()


func workspace_root() -> String:
	return _workspace_root


## Re-reads the project config after the user trusts a folder.
func reload_config() -> void:
	_load_config()


func _load_config() -> void:
	if config == null:
		return
	if editor != null and editor.has_method("is_workspace_trusted"):
		config.workspace_trust = Callable(editor, "is_workspace_trusted")
	var loaded: Dictionary = config.load_for_project(_workspace_root)
	for error in loaded.get("errors", []):
		if error is Dictionary:
			_log_console("error", "%s: %s" % [str(error.get("source", "debug.json")), str(error.get("error", ""))])
	state_changed.emit()


func adapter_rows() -> Array:
	return config.adapter_rows() if config != null else []


func adapter_for_path(path: String, language: String = "") -> Dictionary:
	return config.adapter_for_path(path, language) if config != null else {}


func supports(feature: String, fallback: bool = false) -> bool:
	return bool(capabilities.get(feature, fallback))


# ── SESSION LIFECYCLE ───────────────────────────────────────────────────────

func is_active() -> bool:
	return state != "idle" and state != "terminating"


func is_stopped() -> bool:
	return state == "stopped"


func is_running() -> bool:
	return state == "running"


func status_text() -> String:
	match state:
		"starting":
			return "Starting %s…" % (adapter_display if !adapter_display.is_empty() else "debug adapter")
		"initializing":
			return "Waiting for the debug adapter…"
		"running":
			return "Running" + (" — " + program_path.get_file() if !program_path.is_empty() else "")
		"stopped":
			var where := ""
			if !_execution_path.is_empty() and _execution_line >= 0:
				where = " at %s:%d" % [_execution_path.get_file(), _execution_line + 1]
			var reason := stop_reason if !stop_reason.is_empty() else "paused"
			return "Paused (%s)%s" % [reason, where]
		"terminating":
			return "Stopping…"
	return "Ready"


func session_info() -> Dictionary:
	return {
		"active": is_active(),
		"state": state,
		"adapter_id": adapter_id,
		"adapter_display": adapter_display,
		"program": program_path,
		"status": status_text(),
		"reason": stop_reason,
		"description": stop_description,
		"thread_id": thread_id,
		"capabilities": capabilities.duplicate(),
	}


## Starts a new session for the active saved file. Any modified saved buffers
## are written first; an untitled target is refused because a debug adapter
## cannot attach to a buffer that has no path on disk.
func start_debugging() -> Dictionary:
	if state == "stopped":
		continue_execution()
		return {"ok": true, "error": ""}
	if is_active() or state == "terminating":
		return {"ok": false, "error": "A debug session is already active."}
	if editor == null or editor.documents == null:
		return _start_failed("The editor is not ready.")

	var document = editor.documents.active_document()
	if document == null:
		return _start_failed("Open a file before starting the debugger.")
	if bool(document.untitled) or str(document.path).is_empty():
		return _start_failed("Save this buffer before debugging: a debug adapter needs a file on disk.")
	var path := Paths.normalize(str(document.path))
	if !FileAccess.file_exists(path):
		return _start_failed("The file does not exist on disk: " + path)

	# Save every modified saved buffer so the adapter runs the code on screen.
	if editor.has_method("save_all_for_debug"):
		var saved: Dictionary = editor.save_all_for_debug()
		if !bool(saved.get("ok", false)):
			return _start_failed(str(saved.get("error", "Could not save the open files before debugging.")))

	var language := _language_for_document(document)
	var adapter := adapter_for_path(path, language)
	if adapter.is_empty():
		var message := "No debug adapter is configured for this file type. Supported today: %s." % config.supported_display()
		_missing_help({})
		return _start_failed(message)

	var port := _pick_port()
	var resolved: Dictionary = config.resolve(adapter, path, _workspace_root, port)
	if !bool(resolved.get("ok", false)):
		_missing_help(resolved.get("install", {}))
		return _start_failed(str(resolved.get("error", "The debug adapter is unavailable.")))

	_reset_session()
	_resolved = resolved
	adapter_id = str(resolved.get("adapter_id", "debug"))
	adapter_display = str(resolved.get("display", adapter_id))
	program_path = path
	state = "starting"
	last_error = ""
	_log_console("system", "Starting %s for %s" % [adapter_display, path.get_file()])
	session_started.emit(session_info())
	state_changed.emit()

	client = DapClient.new()
	client.name = "DapAdapter"
	client.configure({
		"adapter_id": adapter_id,
		"display": adapter_display,
		"command_path": str(resolved.get("command_path", "")),
		"args": resolved.get("args", []),
		"host": "127.0.0.1",
		"port": port,
		"cwd": str(resolved.get("cwd", path.get_base_dir())),
		"editor": editor,
	})
	add_child(client)
	client.connected.connect(_on_client_connected)
	client.disconnected.connect(_on_client_disconnected)
	client.event_received.connect(_on_client_event)
	client.server_request.connect(_on_server_request)
	client.log_line.connect(_on_client_log)

	var started: Dictionary = client.start()
	if !bool(started.get("ok", false)):
		var message := str(started.get("error", "Could not start the debug adapter."))
		_missing_help(resolved.get("install", {}))
		return _start_failed(message)
	return {"ok": true, "error": ""}


func _start_failed(message: String) -> Dictionary:
	last_error = message
	_log_console("error", message)
	if editor != null and editor.has_method("warn"):
		editor.warn("[color=red]DEBUG[/color]: " + message)
	if client != null and is_instance_valid(client):
		var doomed = client
		client = null
		doomed.force_stop()
		doomed.queue_free()
	state = "idle"
	_clear_pause(true)
	state_changed.emit()
	return {"ok": false, "error": message}


func continue_execution() -> bool:
	if !is_stopped():
		return false
	var request_thread := thread_id if thread_id > 0 else _current_thread()
	_clear_pause(false)
	_set_state("running")
	var ok := _send_control("continue", request_thread)
	if !ok:
		_set_state("stopped")
	return ok


func step_over() -> bool:
	return _step("next")


func step_into() -> bool:
	return _step("stepIn")


func step_out() -> bool:
	return _step("stepOut")


func _step(command: String) -> bool:
	if !is_stopped():
		return false
	var request_thread := thread_id if thread_id > 0 else _current_thread()
	_clear_pause(false)
	_set_state("running")
	var ok := _send_control(command, request_thread)
	if !ok:
		_set_state("stopped")
	return ok


func _send_control(command: String, request_thread: int) -> bool:
	if client == null or !client.is_ready():
		return false
	var arguments := {"threadId": request_thread}
	if command != "continue":
		arguments["singleThread"] = false
	var sent: int = client.send_request(command, arguments, func(result: Dictionary) -> void:
		if !bool(result.get("ok", false)):
			_log_console("error", "%s failed: %s" % [command, str(result.get("error", "unknown error"))])
			if state == "running":
				_set_state("stopped")
				state_changed.emit()
	)
	return sent >= 0


func stop_debugging() -> void:
	if client == null:
		_finish_session("No debug session was running.", false)
		return
	if state == "terminating":
		return
	state = "terminating"
	_clear_pause(true)
	_log_console("system", "Stopping the debug session…")
	state_changed.emit()
	if client.is_ready():
		client.send_request("disconnect", {"restart": false, "terminateDebuggee": true},
			func(_result: Dictionary) -> void:
				if client != null and is_instance_valid(client):
					client.stop()
		, 3000)
		client.stop()
	else:
		client.force_stop()


func shutdown() -> void:
	if client != null and is_instance_valid(client):
		client.force_stop()
	client = null
	state = "idle"
	_clear_pause(true)
	_ending_session = false


# ── CLIENT SIGNALS ──────────────────────────────────────────────────────────

func _on_client_connected(_sender) -> void:
	if state != "starting":
		return
	state = "initializing"
	_log_console("system", "Connected. Initializing the debug adapter…")
	state_changed.emit()
	client.send_request("initialize", {
		"clientID": "griddycode",
		"clientName": "Qorix",
		"adapterID": adapter_id,
		"locale": "en",
		"linesStartAt1": true,
		"columnsStartAt1": true,
		"pathFormat": "path",
		"supportsVariableType": true,
		"supportsVariablePaging": true,
		"supportsRunInTerminalRequest": false,
		"supportsMemoryReferences": false,
		"supportsProgressReporting": false,
		"supportsInvalidatedEvent": false,
	}, _on_initialize_response, 15_000)


func _on_initialize_response(result: Dictionary) -> void:
	if !bool(result.get("ok", false)):
		_fail_session(str(result.get("error", "The debug adapter refused to initialize.")), true)
		return
	capabilities = result.get("body", {}).duplicate(true)
	state = "initializing"
	_log_console("system", "Adapter ready. Launching %s…" % program_path.get_file())
	state_changed.emit()

	var launch: Dictionary = _resolved.get("launch", {}).duplicate(true)
	if !launch.has("name"):
		launch["name"] = "Qorix: " + program_path.get_file()
	if verbose_log:
		_log_console("system", "launch " + JSON.stringify(launch))
	_launch_result = {}
	client.send_request("launch", launch, _on_launch_response, 20_000)


func _on_launch_response(result: Dictionary) -> void:
	_launch_result = result
	if !bool(result.get("ok", false)):
		_fail_session(str(result.get("error", "The launch request was rejected.")), true)
		return
	_log_console("system", "Debugger attached.")
	if state != "stopped":
		_set_state("running")
	state_changed.emit()


func _on_client_event(_sender, event_name: String, body: Variant) -> void:
	var payload: Dictionary = body if body is Dictionary else {}
	if verbose_log:
		_log_console("system", "event %s %s" % [event_name, JSON.stringify(payload)])
	match event_name:
		"initialized":
			_on_initialized_event()
		"stopped":
			_on_stopped_event(payload)
		"continued":
			if state != "terminating":
				_clear_pause(true)
				_set_state("running")
				_log_console("system", "Continued.")
		"terminated":
			_log_console("system", "The debuggee has terminated.")
			_finish_session("Debug session ended.", false)
		"exited":
			var code := int(payload.get("exitCode", 0))
			_log_console("system", "Program exited with code %d." % code)
		"output":
			var category := str(payload.get("category", "stdout"))
			var text := str(payload.get("output", ""))
			if !text.is_empty():
				_append_output(text, "error" if category == "stderr" else "output")
		"process":
			var process_name := str(payload.get("name", ""))
			if !process_name.is_empty():
				_log_console("system", "Process started: " + process_name)
		"breakpoint":
			_on_breakpoint_event(payload)
		"thread":
			if str(payload.get("reason", "")) == "exited" and int(payload.get("threadId", -1)) == thread_id:
				pass
		"error", "warning":
			_log_console("error" if event_name == "error" else "system", str(payload.get("message", event_name)))
		_:
			pass


func _on_initialized_event() -> void:
	if _initialized_event_seen:
		return
	_initialized_event_seen = true
	_breakpoints_sent = true
	_send_all_breakpoints()
	if supports("supportsConfigurationDoneRequest", true):
		_configuration_done_sent = true
		client.send_request("configurationDone", {}, func(result: Dictionary) -> void:
			if !bool(result.get("ok", false)):
				_log_console("error", "configurationDone failed: " + str(result.get("error", "")))
		)
	else:
		_log_console("system", "Adapter does not support configurationDone; the program starts after launch.")


func _on_stopped_event(payload: Dictionary) -> void:
	if state == "terminating":
		return
	thread_id = int(payload.get("threadId", thread_id))
	stop_reason = str(payload.get("reason", "paused"))
	stop_description = str(payload.get("description", payload.get("text", "")))
	state = "stopped"
	_frame_generation += 1
	stack.clear()
	scopes.clear()
	_variables.clear()
	_pending_variables.clear()
	_prefetch_count = 0
	watch_results.clear()
	_log_console("system", "Paused: " + stop_reason + (": " + stop_description if !stop_description.is_empty() else ""))
	state_changed.emit()
	_request_stack_trace(_frame_generation)


func _request_stack_trace(generation: int) -> void:
	if client == null or !client.is_ready():
		return
	client.send_request("stackTrace", {
		"threadId": thread_id,
		"startFrame": 0,
		"levels": STACK_FRAME_LIMIT,
	}, func(result: Dictionary) -> void:
		_on_stack_trace(result, generation)
	)


func _on_stack_trace(result: Dictionary, generation: int) -> void:
	if generation != _frame_generation or state != "stopped":
		return
	if !bool(result.get("ok", false)):
		_log_console("error", "Could not read the call stack: " + str(result.get("error", "")))
		state_changed.emit()
		_refresh_watches()
		return
	stack = _normalize_frames(result.get("body", {}).get("stackFrames", []))
	selected_frame = 0
	_show_frame(0, true)
	state_changed.emit()


func _show_frame(index: int, request_scopes_now: bool = true) -> void:
	if index < 0 or index >= stack.size():
		return
	selected_frame = index
	var frame: Dictionary = stack[index]
	var path := str(frame.get("path", ""))
	var line := int(frame.get("line", 1)) - 1
	if !path.is_empty() and line >= 0:
		_execution_path = path
		_execution_line = line
		execution_line_changed.emit(path, line)
		if _setting_bool("debug_auto_open_stopped_file", true):
			navigate_requested.emit(path, line, maxi(int(frame.get("column", 1)) - 1, 0))
	if request_scopes_now:
		_request_scopes(index)
	_refresh_watches()


func _request_scopes(frame_index: int) -> void:
	if frame_index < 0 or frame_index >= stack.size() or client == null or !client.is_ready():
		return
	var frame: Dictionary = stack[frame_index]
	var generation := _frame_generation
	client.send_request("scopes", {"frameId": int(frame.get("id", 0))}, func(result: Dictionary) -> void:
		if generation != _frame_generation:
			return
		_on_scopes(result, generation)
	)


func _on_scopes(result: Dictionary, generation: int) -> void:
	if generation != _frame_generation:
		return
	if !bool(result.get("ok", false)):
		_log_console("error", "Could not read scopes: " + str(result.get("error", "")))
		state_changed.emit()
		_refresh_watches()
		return
	scopes = []
	for raw in result.get("body", {}).get("scopes", []):
		if !(raw is Dictionary):
			continue
		var scope: Dictionary = raw
		var reference := int(scope.get("variablesReference", 0))
		var entry := {
			"name": str(scope.get("name", "Scope")),
			"variables_reference": reference,
			"expensive": bool(scope.get("expensive", false)),
			"presentation_hint": str(scope.get("presentationHint", "")),
		}
		scopes.append(entry)
		if reference > 0:
			_request_variables(reference, 0, true)
	state_changed.emit()
	_refresh_watches()


func _request_variables(reference: int, depth: int = 0, force: bool = false) -> void:
	if reference <= 0 or client == null or !client.is_ready() or state != "stopped":
		return
	if _variables.has(reference) and !force:
		return
	if _pending_variables.has(reference):
		return
	_pending_variables[reference] = true
	var generation := _frame_generation
	client.send_request("variables", {
		"variablesReference": reference,
		"start": 0,
		"count": 200,
	}, func(result: Dictionary) -> void:
		_pending_variables.erase(reference)
		if generation != _frame_generation:
			return
		_on_variables(result, reference, depth, generation)
	)


func _on_variables(result: Dictionary, reference: int, depth: int, generation: int) -> void:
	if generation != _frame_generation:
		return
	if !bool(result.get("ok", false)):
		_variables[reference] = []
		_log_console("error", "Could not read variables: " + str(result.get("error", "")))
		state_changed.emit()
		return
	var rows: Array = []
	var child_refs: Array = []
	for raw in result.get("body", {}).get("variables", []):
		if !(raw is Dictionary):
			continue
		var variable: Dictionary = raw
		var child_ref := int(variable.get("variablesReference", 0))
		rows.append({
			"name": str(variable.get("name", "")),
			"value": str(variable.get("value", "")),
			"type": str(variable.get("type", "")),
			"evaluate_name": str(variable.get("evaluateName", "")),
			"variables_reference": child_ref,
			"indexed": int(variable.get("indexedVariables", 0)),
			"named": int(variable.get("namedVariables", 0)),
		})
		if child_ref > 0:
			child_refs.append(child_ref)
	_variables[reference] = rows

	# One extra level makes locals useful at a glance (a list's first items, a
	# dict's keys) without asking the adapter for a whole object graph.
	if depth < 1 and _prefetch_count < MAX_PREFETCH_REQUESTS:
		for child_ref in child_refs:
			if _prefetch_count >= MAX_PREFETCH_REQUESTS:
				break
			_prefetch_count += 1
			_request_variables(int(child_ref), depth + 1)
	state_changed.emit()


func request_variables(reference: int) -> void:
	_request_variables(reference, 2, false)


# ── FRAME / VARIABLE VIEWS ──────────────────────────────────────────────────

func frame_items() -> Array:
	var rows: Array = []
	for index in range(stack.size()):
		var frame: Dictionary = stack[index]
		rows.append({
			"index": index,
			"name": str(frame.get("name", "?")),
			"file": str(frame.get("path", "")).get_file(),
			"path": str(frame.get("path", "")),
			"line": int(frame.get("line", 1)),
			"column": int(frame.get("column", 1)),
			"selected": index == selected_frame,
		})
	return rows


func select_frame(index: int) -> void:
	if !is_stopped() or index < 0 or index >= stack.size():
		return
	scopes.clear()
	_variables.clear()
	_pending_variables.clear()
	_prefetch_count = 0
	_selected_thread_frame(index)
	_show_frame(index, true)
	state_changed.emit()


func _selected_thread_frame(_index: int) -> void:
	pass


func scope_items() -> Array:
	return scopes.duplicate(true)


func variables_for(reference: int) -> Array:
	var rows: Variant = _variables.get(reference, [])
	return rows if rows is Array else []


func watch_items() -> Array:
	var rows: Array = []
	for expression in watches:
		var result: Dictionary = watch_results.get(expression, {})
		rows.append({
			"expression": str(expression),
			"value": str(result.get("value", "")),
			"type": str(result.get("type", "")),
			"error": str(result.get("error", "")),
			"pending": bool(result.get("pending", false)),
			"ok": bool(result.get("ok", false)),
			"variables_reference": int(result.get("variables_reference", 0)),
		})
	return rows


func add_watch(expression: String) -> bool:
	var text := expression.strip_edges()
	if text.is_empty() or watches.has(text):
		return false
	if watches.size() >= MAX_WATCHES:
		watches.pop_back()
	watches.append(text)
	_refresh_watches()
	state_changed.emit()
	return true


func remove_watch(index: int) -> void:
	if index < 0 or index >= watches.size():
		return
	var expression := str(watches[index])
	watches.remove_at(index)
	watch_results.erase(expression)
	state_changed.emit()


func set_watches(expressions: Array) -> void:
	watches.clear()
	for raw in expressions:
		var text := str(raw).strip_edges()
		if text.is_empty() or watches.has(text):
			continue
		watches.append(text)
		if watches.size() >= MAX_WATCHES:
			break
	_refresh_watches()
	state_changed.emit()


func _refresh_watches() -> void:
	if !is_stopped():
		for expression in watches:
			watch_results[expression] = {"ok": false, "pending": true, "value": "", "type": "", "error": ""}
		return
	for expression in watches:
		var pending: Dictionary = watch_results.get(expression, {})
		if bool(pending.get("pending", false)):
			continue
		if bool(pending.get("ok", false)):
			continue
		watch_results[expression] = {"ok": false, "pending": true, "value": "", "type": "", "error": ""}
		_evaluate(expression, "watch", true)
	state_changed.emit()


## Re-evaluates every watch expression in the current pause, even ones that
## already answered. The panel's refresh button uses this after a side effect.
func refresh_watches_now() -> void:
	if !is_stopped():
		return
	for expression in watches:
		watch_results[expression] = {"ok": false, "pending": true, "value": "", "type": "", "error": ""}
	_refresh_watches()
	state_changed.emit()


func _on_watch_result(expression: String, result: Dictionary, body: Dictionary, error: String) -> void:
	watch_results[expression] = {
		"ok": bool(result.get("ok", false)),
		"pending": false,
		"value": str(body.get("result", "")),
		"type": str(body.get("type", "")),
		"variables_reference": int(body.get("variablesReference", 0)),
		"error": error,
	}
	state_changed.emit()


# ── CONSOLE ─────────────────────────────────────────────────────────────────

func evaluate(expression: String, context: String = "repl", frame_id: int = -1) -> int:
	var text := expression.strip_edges()
	if text.is_empty():
		return -1
	if !is_active():
		_log_console("error", "Start a debug session before evaluating expressions.")
		return -1
	if !is_stopped():
		_log_console("error", "Pause the program (a breakpoint or step) before evaluating expressions.")
		return -1
	if context != "watch":
		_log_console("input", "> " + text)
	return _evaluate(text, context, false, frame_id)


func _evaluate(expression: String, context: String, watch: bool, frame_id: int = -1) -> int:
	if client == null or !client.is_ready():
		return -1
	# An explicit frame wins; otherwise evaluate in the selected frame.
	var frame := frame_id
	if frame <= 0 and selected_frame >= 0 and selected_frame < stack.size():
		frame = int(stack[selected_frame].get("id", 0))
	var arguments := {
		"expression": expression,
		"context": "watch" if watch else "repl",
	}
	if frame > 0:
		arguments["frameId"] = frame
	var generation := _frame_generation
	return client.send_request("evaluate", arguments, func(result: Dictionary) -> void:
		var body: Dictionary = result.get("body", {}) if result.get("body", {}) is Dictionary else {}
		var error := str(result.get("error", ""))
		if watch:
			if generation == _frame_generation:
				_on_watch_result(expression, result, body, error)
			return
		if bool(result.get("ok", false)):
			var value := str(body.get("result", ""))
			var type := str(body.get("type", ""))
			_log_console("result", value + ("  [" + type + "]" if !type.is_empty() else ""))
		else:
			_log_console("error", error)
	)


func console_entries_copy() -> Array:
	return console_entries.duplicate(true)


func console_text() -> String:
	var lines: Array[String] = []
	for entry in console_entries:
		lines.append(str(entry.get("text", "")))
	return "".join(lines)


func clear_console() -> void:
	console_entries.clear()
	log_updated.emit()
	state_changed.emit()


func _log_console(kind: String, text: String) -> void:
	_append_output(text + ("" if text.ends_with("\n") else "\n"), kind)
	if kind == "error" and !text.strip_edges().is_empty():
		last_error = text.strip_edges()


func _append_output(text: String, kind: String) -> void:
	if text.is_empty():
		return
	if kind == "output" and !console_entries.is_empty():
		var last: Dictionary = console_entries[console_entries.size() - 1]
		if str(last.get("kind", "")) == "output":
			last["text"] = str(last.get("text", "")) + text
			_trim_console()
			log_updated.emit()
			return
	console_entries.append({"kind": kind, "text": text})
	_trim_console()
	log_updated.emit()


func _trim_console() -> void:
	while console_entries.size() > MAX_CONSOLE_ENTRIES:
		console_entries.pop_front()
	var total := 0
	for entry in console_entries:
		total += str(entry.get("text", "")).length()
	while total > MAX_CONSOLE_CHARS and console_entries.size() > 1:
		var removed: Dictionary = console_entries.pop_front()
		total -= str(removed.get("text", "")).length()


func _on_client_log(_sender, text: String) -> void:
	_log_console("system", text)


func _on_server_request(_sender, request_seq: int, command: String, _arguments: Variant) -> void:
	var message := ""
	if command == "runInTerminal":
		message = "Qorix's debugger uses the internal console, which cannot provide keyboard input. Run without debugging (F6) for interactive programs."
	elif command == "startDebugging":
		message = "Child debug sessions are not supported by this editor build."
	else:
		message = "The editor does not handle the adapter request \"%s\"." % command
	_log_console("system", message)
	if client != null and is_instance_valid(client):
		client.send_response(request_seq, command, false, null, message)


# ── BREAKPOINTS ─────────────────────────────────────────────────────────────

func toggle_breakpoint(path: String, line: int) -> bool:
	if path.is_empty() or line < 0:
		return false
	if has_breakpoint(path, line):
		remove_breakpoint(path, line)
		return false
	add_breakpoint(path, line)
	return true


## Adds one breakpoint. A file can hold as many breakpoints as it needs; they
## are kept sorted by line so the gutter and setBreakpoints request agree.
func add_breakpoint(path: String, line: int, condition: String = "") -> bool:
	var normalized := Paths.normalize(path)
	if normalized.is_empty() or line < 0:
		return false
	var key := _breakpoint_key(normalized)
	var rows: Array = breakpoints.get(key, [])
	for entry in rows:
		if int(entry.get("line", -1)) == line:
			entry["condition"] = str(condition)
			if _breakpoints_sent:
				_send_breakpoints(normalized)
			breakpoints_changed.emit()
			state_changed.emit()
			return true
	rows.append({
		"path": normalized,
		"line": line,
		"condition": str(condition),
		"verified": false,
		"id": 0,
		"actual_line": line,
		"message": "",
	})
	rows.sort_custom(func(a, b) -> bool: return int(a.line) < int(b.line))
	breakpoints[key] = rows
	breakpoints_changed.emit()
	if _breakpoints_sent:
		_send_breakpoints(normalized)
	state_changed.emit()
	return true


func remove_breakpoint(path: String, line: int) -> void:
	var key := _breakpoint_key(path)
	if !breakpoints.has(key):
		return
	var rows: Array = breakpoints[key]
	var normalized := Paths.normalize(path)
	for index in range(rows.size()):
		if int(rows[index].get("line", -1)) != line:
			continue
		normalized = str(rows[index].get("path", path))
		rows.remove_at(index)
		break
	if rows.is_empty():
		breakpoints.erase(key)
	else:
		breakpoints[key] = rows
	breakpoints_changed.emit()
	if _breakpoints_sent:
		_send_breakpoints(normalized)
	state_changed.emit()


func has_breakpoint(path: String, line: int) -> bool:
	for entry in breakpoints.get(_breakpoint_key(path), []):
		if int(entry.get("line", -1)) == line:
			return true
	return false


func breakpoint_lines(path: String) -> Array:
	var lines: Array = []
	for entry in breakpoints.get(_breakpoint_key(path), []):
		lines.append(int(entry.get("line", 0)))
	return lines


func breakpoints_for_path(path: String) -> Array:
	return (breakpoints.get(_breakpoint_key(path), []) as Array).duplicate(true)


func breakpoint_count() -> int:
	var total := 0
	for rows in breakpoints.values():
		total += (rows as Array).size()
	return total


func all_breakpoints() -> Array:
	var rows: Array = []
	for entries in breakpoints.values():
		for entry in entries:
			rows.append(entry.duplicate(true))
	rows.sort_custom(func(a, b) -> bool:
		if str(a.path) != str(b.path):
			return str(a.path).naturalnocasecmp_to(str(b.path)) < 0
		return int(a.line) < int(b.line)
	)
	return rows


func clear_breakpoints() -> void:
	if breakpoints.is_empty():
		return
	var paths: Array = []
	for rows in breakpoints.values():
		if !(rows as Array).is_empty():
			paths.append(str(rows[0].get("path", "")))
	breakpoints.clear()
	breakpoints_changed.emit()
	if _breakpoints_sent:
		for path in paths:
			if !str(path).is_empty():
				_send_breakpoints(str(path))
	state_changed.emit()


func _send_all_breakpoints() -> void:
	for key in breakpoints.keys():
		var rows: Array = breakpoints[key]
		if rows.is_empty():
			continue
		_send_breakpoints(str(rows[0].get("path", key)))


func _send_breakpoints(path: String) -> void:
	if client == null or !client.is_ready():
		return
	var key := _breakpoint_key(path)
	var rows: Array = breakpoints.get(key, [])
	var list: Array = []
	var sent_lines: Array = []
	for entry in rows:
		var request := {"line": int(entry.get("line", 0)) + 1}
		var condition := str(entry.get("condition", "")).strip_edges()
		if !condition.is_empty():
			request["condition"] = condition
		list.append(request)
		sent_lines.append(int(entry.get("line", 0)))
	client.send_request("setBreakpoints", {
		"source": {"path": path},
		"breakpoints": list,
		"sourceModified": false,
	}, func(result: Dictionary) -> void:
		_on_set_breakpoints_response(result, key, sent_lines)
	)


func _on_set_breakpoints_response(result: Dictionary, key: String, sent_lines: Array = []) -> void:
	if !breakpoints.has(key):
		return
	var rows: Array = breakpoints[key]
	if !bool(result.get("ok", false)):
		for entry in rows:
			entry["verified"] = false
			entry["message"] = str(result.get("error", "setBreakpoints failed."))
		breakpoints_changed.emit()
		state_changed.emit()
		return
	var responses: Variant = result.get("body", {}).get("breakpoints", [])
	if responses is Array:
		for index in range((responses as Array).size()):
			if index >= sent_lines.size():
				break
			var line := int(sent_lines[index])
			for entry in rows:
				if int(entry.get("line", -1)) != line:
					continue
				var response: Dictionary = (responses as Array)[index]
				entry["verified"] = bool(response.get("verified", false))
				entry["id"] = int(response.get("id", 0))
				entry["message"] = str(response.get("message", ""))
				if response.has("line"):
					entry["actual_line"] = maxi(0, int(response.get("line", 1)) - 1)
				break
	breakpoints_changed.emit()
	state_changed.emit()


func _on_breakpoint_event(payload: Dictionary) -> void:
	var event_breakpoint: Variant = payload.get("breakpoint")
	if !(event_breakpoint is Dictionary):
		return
	var data: Dictionary = event_breakpoint
	var id := int(data.get("id", -1))
	if id < 0:
		return
	for entries in breakpoints.values():
		for entry in entries:
			if int(entry.get("id", -1)) != id:
				continue
			entry["verified"] = bool(data.get("verified", entry.get("verified", false)))
			entry["message"] = str(data.get("message", entry.get("message", "")))
			if data.has("line"):
				entry["actual_line"] = maxi(0, int(data.get("line", 1)) - 1)
			breakpoints_changed.emit()
			state_changed.emit()
			return


# ── SESSION STATE ───────────────────────────────────────────────────────────

## Data the editor persists between launches. Breakpoints keep their path and
## condition (not their adapter ids, which are meaningless next session).
func capture_session() -> Dictionary:
	var saved: Array = []
	for entry in all_breakpoints():
		saved.append({
			"path": str(entry.get("path", "")),
			"line": int(entry.get("line", 0)),
			"condition": str(entry.get("condition", "")),
		})
	return {
		"watches": watches.duplicate(),
		"breakpoints": saved,
		"verbose_log": verbose_log,
	}


func restore_session(data: Dictionary) -> void:
	watches.clear()
	for raw in data.get("watches", []):
		var text := str(raw).strip_edges()
		if text.is_empty() or watches.has(text) or watches.size() >= MAX_WATCHES:
			continue
		watches.append(text)
	watch_results.clear()

	breakpoints.clear()
	var raw_breakpoints: Variant = data.get("breakpoints", [])
	if raw_breakpoints is Array:
		for raw in raw_breakpoints:
			if !(raw is Dictionary):
				continue
			var entry: Dictionary = raw
			var path := Paths.normalize(str(entry.get("path", "")))
			var line := int(entry.get("line", -1))
			if path.is_empty() or line < 0 or breakpoint_count() >= 500:
				continue
			var key := _breakpoint_key(path)
			var rows: Array = breakpoints.get(key, [])
			var duplicate := false
			for existing in rows:
				if int(existing.get("line", -1)) == line:
					duplicate = true
					break
			if duplicate:
				continue
			rows.append({
				"path": path,
				"line": line,
				"condition": str(entry.get("condition", "")),
				"verified": false,
				"id": 0,
				"actual_line": line,
				"message": "",
			})
			rows.sort_custom(func(a, b) -> bool: return int(a.line) < int(b.line))
			breakpoints[key] = rows
	if data.has("verbose_log"):
		verbose_log = bool(data.get("verbose_log", verbose_log))
	breakpoints_changed.emit()
	state_changed.emit()


func _breakpoint_key(path: String) -> String:
	var normalized := Paths.normalize(path)
	if OS.get_name() == "Windows":
		return normalized.to_lower()
	return normalized


# ── HELPERS ─────────────────────────────────────────────────────────────────

func _pick_port() -> int:
	var offset := int(Time.get_ticks_usec() % 18_000)
	return 42_000 + offset


func _language_for_document(document) -> String:
	if document == null:
		return ""
	var override := str(document.language_override).strip_edges()
	if override.is_empty():
		override = str(document.language_highlight).strip_edges()
	if !override.is_empty():
		return override
	return str(document.path).get_extension().to_lower()


func _normalize_frames(raw_frames: Variant) -> Array:
	var rows: Array = []
	if !(raw_frames is Array):
		return rows
	for raw in raw_frames:
		if !(raw is Dictionary):
			continue
		var frame: Dictionary = raw
		var source: Variant = frame.get("source", {})
		var path := ""
		if source is Dictionary:
			path = Paths.normalize(str((source as Dictionary).get("path", "")))
		rows.append({
			"id": int(frame.get("id", 0)),
			"name": str(frame.get("name", "?")),
			"path": path,
			"line": maxi(1, int(frame.get("line", 1))),
			"column": maxi(1, int(frame.get("column", 1))),
			"source_reference": int((source as Dictionary).get("sourceReference", 0)) if source is Dictionary else 0,
		})
	return rows


func _current_thread() -> int:
	if thread_id > 0:
		return thread_id
	if !stack.is_empty():
		return 1
	return 1


func _clear_pause(clear_execution: bool) -> void:
	_frame_generation += 1
	stack.clear()
	scopes.clear()
	_variables.clear()
	_pending_variables.clear()
	_prefetch_count = 0
	thread_id = 0
	stop_reason = ""
	stop_description = ""
	if clear_execution and !_execution_path.is_empty():
		_execution_path = ""
		_execution_line = -1
		execution_line_changed.emit("", -1)
	state_changed.emit()


func _set_state(next: String) -> void:
	if state == next:
		state_changed.emit()
		return
	state = next
	state_changed.emit()


func _reset_session() -> void:
	state = "idle"
	last_error = ""
	capabilities.clear()
	stack.clear()
	scopes.clear()
	_variables.clear()
	_pending_variables.clear()
	watch_results.clear()
	thread_id = 0
	stop_reason = ""
	stop_description = ""
	adapter_id = ""
	adapter_display = ""
	program_path = ""
	_resolved = {}
	_launch_result = {}
	_initialized_event_seen = false
	_configuration_done_sent = false
	_breakpoints_sent = false
	_ending_session = false
	_execution_path = ""
	_execution_line = -1
	execution_line_changed.emit("", -1)


func _fail_session(message: String, notify_help: bool) -> void:
	last_error = message
	_log_console("error", message)
	if notify_help:
		_missing_help(_resolved.get("install", {}))
	if client != null and is_instance_valid(client):
		client.force_stop()
	_finish_session(message, true)


func _finish_session(reason: String, failed: bool) -> void:
	if _ending_session:
		return
	_ending_session = true
	_clear_pause(true)
	state = "idle"
	if failed and !reason.strip_edges().is_empty():
		last_error = reason
		if editor != null and editor.has_method("warn"):
			editor.warn("[color=red]DEBUG[/color]: " + reason)
	elif !reason.strip_edges().is_empty():
		_log_console("system", reason)

	var ended := session_info()
	ended["reason"] = reason
	ended["failed"] = failed
	if client != null and is_instance_valid(client):
		var doomed = client
		client = null
		doomed.queue_free()
	adapter_id = ""
	adapter_display = ""
	program_path = ""
	_ending_session = false
	session_ended.emit(ended)
	state_changed.emit()


func _on_client_disconnected(_sender, unexpected: bool, reason: String) -> void:
	var text := reason if !reason.strip_edges().is_empty() else ("The debug adapter disconnected unexpectedly." if unexpected else "Debug adapter disconnected.")
	if state == "terminating":
		_finish_session("Debug session stopped.", false)
		return
	# A failure before the adapter ever answered initialize usually means the
	# command started but the package is missing (for example debugpy is not
	# installed in that interpreter). Offer the same install card a resolution
	# failure would show. A crash mid-session is reported without it.
	if unexpected and (state == "starting" or state == "initializing"):
		_missing_help(_resolved.get("install", {}))
	_finish_session(text, unexpected)


func _missing_help(help: Variant) -> void:
	if help is Dictionary and !(help as Dictionary).is_empty():
		missing_adapter.emit((help as Dictionary).duplicate(true))
	else:
		missing_adapter.emit({
			"title": "Debug adapter not available",
			"hint": "Python debugging uses the debugpy package. Install it with the command below, then reopen Qorix.",
			"commands": ["python -m pip install debugpy"],
			"url": "https://github.com/microsoft/debugpy",
			"url_label": "Open the debugpy installation guide",
		})


func _setting_bool(key: String, fallback: bool) -> bool:
	var lua = get_node_or_null("/root/LuaSingleton")
	if lua == null:
		return fallback
	var found = lua.get_setting(key)
	if found is Array and found.size() >= 2 and int(found[1]) != -1:
		return bool(found[0].get("value", fallback))
	return fallback
