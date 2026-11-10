extends Node

## Coordinates language servers, documents and the LSP features the editor
## exposes.
##
## One client is kept per language family and project root, started lazily for
## the active tab. Documents are synchronized with full text: it is a little
## more bandwidth than incremental sync, but it makes the client and the server
## agree after undo, reloads and multi-edit operations without maintaining a
## mirror of every buffer. The manager owns no UI logic; it emits state and the
## HUD panels render it.

signal diagnostics_updated
signal log_updated
signal servers_updated
signal missing_server(help)
signal server_failed(display, message)

const LspConfig = preload("res://src/features/lsp/lsp_config.gd")
const LspClient = preload("res://src/features/lsp/lsp_client.gd")
const LspText = preload("res://src/features/lsp/lsp_text.gd")
const RuntimeCatalog = preload("res://src/features/run/runtime_catalog.gd")
const Paths = preload("res://src/base/path_utils.gd")

const CHANGE_DEBOUNCE := 0.12
const HOVER_DEBOUNCE := 0.18
const SIGNATURE_DEBOUNCE := 0.28
const ACTIONS_DEBOUNCE := 0.45
const MAX_LOG_LINES := 600
const MAX_CRASHES_PER_MINUTE := 3

var editor = null
var config = null
var catalog = null

var _enabled: bool = true
var _config_loaded: bool = false
var _workspace_root: String = ""
var _shutting_down: bool = false
var _stopping_all: bool = false

var _clients: Dictionary = {}
var _specs: Dictionary = {}
var _doc_states: Dictionary = {}
var _diagnostics: Dictionary = {}
var _log_lines: Array[String] = []
var _config_errors: Array = []

var _missing_notified: Dictionary = {}
var _failed_notified: Dictionary = {}
var _crash_history: Dictionary = {}
var _restart_timers: Dictionary = {}

var _change_timer: Timer
var _hover_timer: Timer
var _signature_timer: Timer
var _actions_timer: Timer

var _pending_changes: Dictionary = {}
var _pending_hover: Dictionary = {}
var _pending_signature: Dictionary = {}
var _pending_actions: Dictionary = {}

var _completion_ids: Dictionary = {}
var _hover_request_id: int = -1
var _hover_uri: String = ""
var _signature_request_id: int = -1
var _signature_uri: String = ""
var _actions_request_id: int = -1
var _actions_uri: String = ""
var _action_hint_actions: Dictionary = {}
var _action_hint_line: int = -1

var _rename_dialog = null
var _workspace_preview = null
var _pending_workspace_edit: Dictionary = {}
var _pending_workspace_title: String = ""
var _pending_rename: Dictionary = {}


func _ready() -> void:
	if editor == null:
		editor = get_parent() if get_parent() is FileManager else null
	if config == null:
		config = LspConfig.new()
	if catalog == null:
		catalog = RuntimeCatalog.new()
	config.executable_resolver = Callable(catalog, "find_executable")

	_make_timers()
	_build_dialogs()
	LuaSingleton.on_settings_change.connect(_on_settings_change)
	_enabled = _setting_bool("lsp_enabled", true)
	_load_config()
	_append_log("", "Language support ready. Open a Python, TypeScript, Rust, C/C++ or Go file to start a server.")


func _make_timers() -> void:
	_change_timer = _make_timer("LspChangeTimer", CHANGE_DEBOUNCE, _flush_changes)
	_hover_timer = _make_timer("LspHoverTimer", HOVER_DEBOUNCE, _flush_hover)
	_signature_timer = _make_timer("LspSignatureTimer", SIGNATURE_DEBOUNCE, _flush_signature)
	_actions_timer = _make_timer("LspActionsTimer", ACTIONS_DEBOUNCE, _flush_actions)


func _make_timer(timer_name: String, wait: float, callback: Callable) -> Timer:
	var timer := Timer.new()
	timer.name = timer_name
	timer.one_shot = true
	timer.wait_time = wait
	timer.timeout.connect(callback)
	add_child(timer)
	return timer


func _build_dialogs() -> void:
	if editor == null:
		return
	# The HUD is screen space; adding the windows under the world-space
	# FileManager would scale them with the camera. `editor.hud` is set by
	# FileManager._setup_hud().
	var parent = editor.hud if editor.hud != null else editor
	var rename_script = load("res://src/features/lsp/lsp_rename_dialog.gd")
	if rename_script != null:
		_rename_dialog = rename_script.new()
		_rename_dialog.submitted.connect(_on_rename_submitted)
		parent.add_child(_rename_dialog)
	var preview_script = load("res://src/features/lsp/workspace_edit_preview.gd")
	if preview_script != null:
		_workspace_preview = preview_script.new()
		_workspace_preview.applied.connect(_apply_pending_workspace_edit)
		parent.add_child(_workspace_preview)


func _exit_tree() -> void:
	if !_shutting_down:
		_stop_all_clients(true)


func _process(_delta: float) -> void:
	pass


# ── CONFIG / WORKSPACE ─────────────────────────────────────────────────────

## Applies the editor's workspace-trust verdict to every config load. Without
## this, opening a cloned repository would be enough to name a process.
func _sync_workspace_trust() -> void:
	if config == null:
		return
	if editor != null and editor.has_method("is_workspace_trusted"):
		config.workspace_trust = Callable(editor, "is_workspace_trusted")


func _load_config() -> void:
	if config == null:
		return
	_sync_workspace_trust()
	var loaded: Dictionary = config.load_for_project(_workspace_root, "user://lsp.json")
	_config_loaded = true
	_config_errors = loaded.get("errors", [])
	for error in _config_errors:
		if error is Dictionary:
			_append_log("config", "%s: %s" % [str(error.get("source", "")), str(error.get("error", ""))])
	servers_updated.emit()


## Re-reads the project config after the user trusts a folder. Existing
## clients are left alone: nothing project-owned was loaded before, so there
## is no stale process to replace.
func reload_config() -> void:
	_load_config()


func set_workspace(root: String) -> void:
	var normalized := Paths.normalize(root)
	if normalized == _workspace_root and _config_loaded:
		return
	_workspace_root = normalized
	_stop_all_clients(true)
	_doc_states.clear()
	_missing_notified.clear()
	_failed_notified.clear()
	_crash_history.clear()
	_load_config()
	sync_open_documents()
	ensure_active_client()
	_append_log("", "Workspace root: " + (normalized if !normalized.is_empty() else "(file folder)"))


func workspace_root() -> String:
	return _workspace_root


func config_errors() -> Array:
	return _config_errors.duplicate(true)


# ── DOCUMENT SYNC ───────────────────────────────────────────────────────────

func sync_open_documents() -> void:
	if editor == null or editor.documents == null:
		return

	var desired: Dictionary = {}
	for document in editor.documents.documents:
		if document == null or bool(document.untitled) or str(document.path).is_empty():
			continue
		var path := Paths.normalize(str(document.path))
		if path.is_empty():
			continue
		var uri := LspText.path_to_uri(path)
		if uri.is_empty():
			continue
		var language := _language_for(document)
		if language.is_empty():
			continue
		var profile: Dictionary = config.profile_for_language(language, path) if config != null else {}
		if profile.is_empty():
			continue
		var root: String = str(config.root_for(profile, path, _workspace_root))
		var key: String = str(profile.get("id", language)) + "|" + root
		desired[uri] = {
			"path": path,
			"language": language,
			"language_id": str(profile.get("language_id", language)),
			"profile": profile,
			"root": root,
			"key": key,
			"document": document,
		}

	for uri in _doc_states.keys():
		var state: Dictionary = _doc_states[uri]
		if !desired.has(uri):
			_close_state(str(uri), "closed")
			continue
		var wanted: Dictionary = desired[uri]
		if str(state.get("key", "")) != str(wanted.get("key", "")) \
			or str(state.get("language", "")) != str(wanted.get("language", "")):
			_close_state(str(uri), "language changed")

	for uri in desired.keys():
		var wanted: Dictionary = desired[uri]
		var state: Dictionary = _doc_states.get(uri, {})
		if state.is_empty():
			state = {
				"uri": str(uri),
				"path": str(wanted.get("path", "")),
				"language": str(wanted.get("language", "")),
				"language_id": str(wanted.get("language_id", "")),
				"profile": wanted.get("profile", {}),
				"root": str(wanted.get("root", "")),
				"key": str(wanted.get("key", "")),
				"version": 0,
				"opened": false,
				"text": str(wanted.get("document").text()) if wanted.get("document") != null else "",
			}
			_doc_states[str(uri)] = state
		else:
			state["path"] = str(wanted.get("path", ""))
			state["profile"] = wanted.get("profile", {})
			state["root"] = str(wanted.get("root", ""))
			state["key"] = str(wanted.get("key", ""))
			state["language_id"] = str(wanted.get("language_id", ""))
			state["language"] = str(wanted.get("language", ""))
			var document = wanted.get("document")
			if document != null:
				state["text"] = str(document.text())

	# A server that is already running can take every matching document now,
	# including the background tabs that did not start a server themselves.
	for uri in _doc_states.keys():
		var state: Dictionary = _doc_states[uri]
		var client = _clients.get(str(state.get("key", "")))
		if client != null and client.is_ready() and !bool(state.get("opened", false)):
			_open_state(str(uri))

	servers_updated.emit()


func active_document_changed(document) -> void:
	hide_hover()
	hide_signature()
	_action_hint_actions.clear()
	_action_hint_line = -1
	if document == null:
		return
	sync_open_documents()
	ensure_active_client()
	var state := _state_for_path(str(document.path))
	if state.is_empty():
		return
	if !state.get("opened", false):
		_open_state(str(state.get("uri", "")))
	if bool(document.modified):
		# DidOpen already carries the current text; a later didChange would be
		# redundant unless the server came up after the edit.
		pass


func document_changed(document) -> void:
	if document == null or config == null:
		return
	var path := Paths.normalize(str(document.path))
	if path.is_empty():
		return
	var state := _state_for_path(path)
	if state.is_empty():
		sync_open_documents()
		state = _state_for_path(path)
	if state.is_empty():
		return

	state["text"] = str(document.text())
	var uri := str(state.get("uri", ""))
	if !state.get("opened", false):
		return

	var client = _clients.get(str(state.get("key", "")))
	if client == null or !client.is_ready():
		return
	state["version"] = int(state.get("version", 0)) + 1
	_pending_changes[uri] = true
	if _change_timer != null:
		_change_timer.start()

	if document.view != null and is_instance_valid(document.view):
		document.view.clear_diagnostic_marks()
	hide_hover()
	hide_signature()


func document_saved(document) -> void:
	if document == null:
		return
	var state := _state_for_path(str(document.path))
	if state.is_empty() or !state.get("opened", false):
		return
	var client = _clients.get(str(state.get("key", "")))
	if client == null or !client.is_ready():
		return
	var uri := str(state.get("uri", ""))
	client.send_notification("textDocument/didSave", {
		"textDocument": {"uri": uri},
		"text": str(document.text()),
	})


func _flush_changes() -> void:
	if _pending_changes.is_empty():
		return
	var uris := _pending_changes.keys()
	_pending_changes.clear()
	for raw_uri in uris:
		var uri := str(raw_uri)
		var state: Dictionary = _doc_states.get(uri, {})
		if state.is_empty() or !state.get("opened", false):
			continue
		var client = _clients.get(str(state.get("key", "")))
		if client == null or !client.is_ready():
			continue
		var document = _document_for_state(state)
		if document == null:
			continue
		var text := str(document.text())
		state["text"] = text
		client.send_notification("textDocument/didChange", {
			"textDocument": {"uri": uri, "version": int(state.get("version", 1))},
			"contentChanges": [{"text": text}],
		})


func _open_state(uri: String) -> void:
	var state: Dictionary = _doc_states.get(uri, {})
	if state.is_empty() or bool(state.get("opened", false)):
		return
	var client = _clients.get(str(state.get("key", "")))
	if client == null or !client.is_ready():
		return
	var document = _document_for_state(state)
	if document == null:
		return
	state["opened"] = true
	state["version"] = 1
	state["text"] = str(document.text())
	client.send_notification("textDocument/didOpen", {
		"textDocument": {
			"uri": uri,
			"languageId": str(state.get("language_id", "plaintext")),
			"version": 1,
			"text": str(state.get("text", "")),
		},
	})
	_append_log(client.display_name(), "Opened " + str(state.get("path", "")).get_file())


func _close_state(uri: String, reason: String = "") -> void:
	var state: Dictionary = _doc_states.get(uri, {})
	if state.is_empty():
		return
	var client = _clients.get(str(state.get("key", "")))
	if client != null and bool(state.get("opened", false)) and client.running:
		client.send_notification("textDocument/didClose", {"textDocument": {"uri": uri}})
		if !reason.is_empty():
			_append_log(client.display_name(), "Closed " + str(state.get("path", "")).get_file() + " (" + reason + ")")

	var document = _document_for_state(state)
	if document != null and document.view != null and is_instance_valid(document.view):
		document.view.clear_diagnostic_marks()

	if _completion_ids.has(uri):
		var completion_client = _clients.get(str(state.get("key", "")))
		if completion_client != null:
			completion_client.cancel_request(int(_completion_ids[uri]))
		_completion_ids.erase(uri)

	_diagnostics.erase(uri)
	_doc_states.erase(uri)
	diagnostics_updated.emit()


func _document_for_state(state: Dictionary):
	if editor == null or editor.documents == null or state.is_empty():
		return null
	return editor.documents.find_by_path(str(state.get("path", "")))


func _state_for_path(path: String) -> Dictionary:
	if path.is_empty():
		return {}
	for uri in _doc_states.keys():
		var state: Dictionary = _doc_states[uri]
		if Paths.same_file(str(state.get("path", "")), path):
			return state
	return {}


func _language_for(document) -> String:
	if document == null or config == null:
		return ""
	var override := str(document.language_override)
	if override.is_empty():
		override = str(document.language_highlight)
	return config.language_for_document(str(document.path), override)


# ── CLIENTS ─────────────────────────────────────────────────────────────────

func ensure_active_client() -> void:
	if !_enabled or _shutting_down or editor == null or editor.documents == null:
		return
	var document = editor.documents.active_document()
	if document == null:
		return
	ensure_document_client(document)


func ensure_document_client(document) -> void:
	if !_enabled or document == null or config == null:
		return
	var state := _state_for_path(str(document.path))
	if state.is_empty():
		sync_open_documents()
		state = _state_for_path(str(document.path))
	if state.is_empty():
		return
	var key := str(state.get("key", ""))
	if _clients.has(key):
		if _clients[key].is_ready() and !bool(state.get("opened", false)):
			_open_state(str(state.get("uri", "")))
		return
	_start_client_for_state(state)


func _start_client_for_state(state: Dictionary) -> void:
	if _clients.has(str(state.get("key", ""))):
		return
	var status: Dictionary = config.server_status(
		str(state.get("language", "")),
		str(state.get("path", "")),
		_workspace_root
	)
	var profile: Dictionary = status.get("profile", {})
	if profile.is_empty():
		return
	if !bool(status.get("ok", false)):
		_notify_missing(str(state.get("language", "")), status.get("install", {}), profile)
		return

	profile["command_path"] = str(status.get("command_path", ""))
	profile["language"] = str(state.get("language", ""))
	var root := str(status.get("root", state.get("root", "")))
	var key := str(profile.get("id", state.get("language", ""))) + "|" + root
	state["key"] = key
	state["root"] = root
	state["profile"] = profile
	state["language_id"] = str(profile.get("language_id", state.get("language", "")))

	if _clients.has(key):
		return
	_specs[key] = {
		"profile": profile.duplicate(true),
		"root": root,
		"workspace_root": _workspace_root,
	}
	_start_client(key, profile, root)


func _start_client(key: String, profile: Dictionary, root: String) -> void:
	var client = LspClient.new()
	client.configure(profile, root, _workspace_root, editor)
	add_child(client)
	_clients[key] = client

	client.initialized.connect(_on_client_initialized)
	client.failed.connect(_on_client_failed)
	client.exited.connect(_on_client_exited)
	client.log_line.connect(_on_client_log)
	client.publish_diagnostics.connect(_on_client_diagnostics)
	client.apply_edit_requested.connect(_on_apply_edit_requested)

	servers_updated.emit()
	var started: Dictionary = client.start()
	if !bool(started.get("ok", false)):
		var message := str(started.get("error", "Could not start the language server."))
		_append_log(client.display_name(), message)
		_failed_notified.erase(key)
		server_failed.emit(client.display_name(), message)
		_clients.erase(key)
		client.queue_free()
		servers_updated.emit()
		return
	_append_log(client.display_name(), "Starting in " + root)


func _on_client_initialized(client, _capabilities: Dictionary) -> void:
	_append_log(client.display_name(), "Ready.")
	_failed_notified.erase(client.key)
	for uri in _doc_states.keys():
		var state: Dictionary = _doc_states[uri]
		if str(state.get("key", "")) == client.key and !bool(state.get("opened", false)):
			_open_state(str(uri))
	servers_updated.emit()


func _on_client_failed(client, message: String) -> void:
	_append_log(client.display_name(), str(message))
	if !_failed_notified.has(client.key):
		_failed_notified[client.key] = true
		server_failed.emit(client.display_name(), str(message))
	servers_updated.emit()


func _on_client_log(client, line: String) -> void:
	_append_log(client.display_name(), line)


func _on_client_exited(client, unexpected: bool, exit_code: int) -> void:
	if _stopping_all or _shutting_down:
		return
	var key: String = str(client.key)
	var was_current: bool = _clients.get(key) == client
	if was_current:
		_clients.erase(key)
	for uri in _doc_states.keys():
		var state: Dictionary = _doc_states[uri]
		if str(state.get("key", "")) == key:
			state["opened"] = false
	_clear_diagnostics_for_key(key)
	client.queue_free()
	servers_updated.emit()

	if unexpected:
		_append_log(client.display_name(), "Exited unexpectedly (code %d)." % exit_code)
		_schedule_restart(key)
	else:
		_append_log(client.display_name(), "Stopped.")


func _schedule_restart(key: String) -> void:
	if !_enabled or _shutting_down or !_specs.has(key):
		return
	var spec: Dictionary = _specs[key]
	var now := Time.get_ticks_msec()
	var history: Array = _crash_history.get(key, [])
	var recent: Array = []
	for stamp in history:
		if now - int(stamp) <= 60_000:
			recent.append(int(stamp))
	recent.append(now)
	_crash_history[key] = recent
	if recent.size() > MAX_CRASHES_PER_MINUTE:
		_append_log(str(spec.get("profile", {}).get("display", key)), "Stopped after %d crashes in a minute. Use \"LSP: Restart Servers\" to try again." % MAX_CRASHES_PER_MINUTE)
		return

	var delay := 1.0 * float(recent.size())
	if _restart_timers.has(key):
		var old_timer = _restart_timers[key]
		if is_instance_valid(old_timer):
			old_timer.queue_free()
		_restart_timers.erase(key)

	var timer := Timer.new()
	timer.one_shot = true
	timer.wait_time = delay
	add_child(timer)
	timer.timeout.connect(func() -> void:
		_restart_timers.erase(key)
		timer.queue_free()
		_restart_client(key)
	)
	_restart_timers[key] = timer
	if is_inside_tree():
		timer.start()
	_append_log(str(spec.get("profile", {}).get("display", key)), "Restarting in %.0f second(s)…" % delay)


func _restart_client(key: String) -> void:
	if !_enabled or _shutting_down or _clients.has(key) or !_specs.has(key):
		return
	var spec: Dictionary = _specs[key]
	var profile: Dictionary = spec.get("profile", {}).duplicate(true)
	var resolved: Dictionary = config.resolve_command(profile)
	if !bool(resolved.get("ok", false)):
		_notify_missing(str(profile.get("language", profile.get("id", ""))), config.install_help(str(profile.get("id", "")), profile), profile)
		return
	profile["command_path"] = str(resolved.get("path", ""))
	_specs[key]["profile"] = profile.duplicate(true)
	_start_client(key, profile, str(spec.get("root", "")))


func restart_servers() -> void:
	_stop_all_clients(true)
	_specs.clear()
	_crash_history.clear()
	_missing_notified.clear()
	_failed_notified.clear()
	_append_log("", "Restarting language servers.")
	_load_config()
	sync_open_documents()
	ensure_active_client()
	servers_updated.emit()


func _stop_all_clients(clear_diagnostics: bool) -> void:
	_stopping_all = true
	for timer in _restart_timers.values():
		if is_instance_valid(timer):
			timer.queue_free()
	_restart_timers.clear()

	for key in _clients.keys():
		var client = _clients[key]
		if is_instance_valid(client):
			client.force_stop()
			client.queue_free()
	_clients.clear()
	if clear_diagnostics:
		_diagnostics.clear()
	for uri in _doc_states.keys():
		_doc_states[uri]["opened"] = false
	_stopping_all = false
	servers_updated.emit()
	diagnostics_updated.emit()


func shutdown() -> void:
	_shutting_down = true
	if _change_timer != null:
		_change_timer.stop()
	if _hover_timer != null:
		_hover_timer.stop()
	if _signature_timer != null:
		_signature_timer.stop()
	if _actions_timer != null:
		_actions_timer.stop()
	_stop_all_clients(true)


func client_count() -> int:
	var count := 0
	for client in _clients.values():
		if is_instance_valid(client) and client.running:
			count += 1
	return count


# ── DIAGNOSTICS ─────────────────────────────────────────────────────────────

func _on_client_diagnostics(client, params: Variant) -> void:
	if !_enabled or !_setting_bool("lsp_diagnostics", true):
		return
	var parsed: Dictionary = LspText.normalize_publish_diagnostics(params)
	var raw_uri := str(parsed.get("uri", ""))
	if raw_uri.is_empty():
		return
	var state: Dictionary = _doc_states.get(raw_uri, {})
	if state.is_empty():
		# Servers do not have to echo the exact URI we sent. Pyright, for one,
		# lowercases a Windows drive letter ("file:///c%3A/..." vs our
		# "file:///C%3A/..."). Resolve by the real path before dropping the
		# publish as foreign.
		state = _state_for_path(LspText.uri_to_path(raw_uri))
	if state.is_empty() or str(state.get("key", "")) != client.key:
		return
	var uri := str(state.get("uri", raw_uri))

	var diagnostics: Array = parsed.get("diagnostics", [])
	_diagnostics[uri] = diagnostics
	var document = _document_for_state(state)
	if document != null and document.view != null and is_instance_valid(document.view):
		document.view.set_diagnostics(diagnostics)
	diagnostics_updated.emit()

	if _is_active_document(document):
		_schedule_action_hint()


func _clear_diagnostics_for_key(key: String) -> void:
	var changed := false
	for uri in _diagnostics.keys():
		var state: Dictionary = _doc_states.get(uri, {})
		if str(state.get("key", "")) == key:
			_diagnostics.erase(uri)
			changed = true
	if changed:
		diagnostics_updated.emit()


func clear_diagnostics() -> void:
	_diagnostics.clear()
	for uri in _doc_states.keys():
		var document = _document_for_state(_doc_states[uri])
		if document != null and document.view != null and is_instance_valid(document.view):
			document.view.clear_diagnostic_marks()
	diagnostics_updated.emit()


func diagnostics_for_uri(uri: String) -> Array:
	var list: Variant = _diagnostics.get(uri, [])
	return list if list is Array else []


func problem_counts() -> Dictionary:
	var counts := {"error": 0, "warning": 0, "information": 0, "hint": 0, "total": 0}
	for uri in _diagnostics.keys():
		for diagnostic in _diagnostics[uri]:
			var severity := int(diagnostic.get("severity", 3))
			var name := LspText.severity_name(severity)
			if counts.has(name):
				counts[name] = int(counts[name]) + 1
			counts["total"] = int(counts["total"]) + 1
	return counts


## One flat list for the Problems tab, sorted by file and line.
func problem_items() -> Array:
	var items: Array = []
	for uri in _diagnostics.keys():
		var state: Dictionary = _doc_states.get(uri, {})
		if state.is_empty():
			continue
		var path := str(state.get("path", ""))
		for diagnostic in _diagnostics[uri]:
			if !(diagnostic is Dictionary):
				continue
			var severity := int(diagnostic.get("severity", 3))
			var line := int(LspText.diagnostic_line(diagnostic))
			items.append({
				"uri": str(uri),
				"path": path,
				"file": path.get_file(),
				"line": line,
				"character": int(LspText.diagnostic_column(diagnostic)),
				"severity": severity,
				"severity_name": LspText.severity_name(severity),
				"symbol": LspText.severity_symbol(severity),
				"message": str(diagnostic.get("message", "Problem")),
				"source": str(diagnostic.get("source", "")),
				"code": str(diagnostic.get("code", "")),
				"label": LspText.diagnostic_label(diagnostic),
				"diagnostic": diagnostic,
			})
	items.sort_custom(func(a, b) -> bool:
		var a_path := str(a.path)
		var b_path := str(b.path)
		if a_path != b_path:
			return a_path.naturalnocasecmp_to(b_path) < 0
		if int(a.line) != int(b.line):
			return int(a.line) < int(b.line)
		return LspText.severity_rank(int(a.severity)) < LspText.severity_rank(int(b.severity))
	)
	return items


func activate_problem(item: Dictionary) -> void:
	var path := str(item.get("path", ""))
	if path.is_empty():
		return
	var text := _text_for_path(path)
	var line_text := LspText.line_at(text, int(item.get("line", 0)))
	var column := LspText.utf16_to_column(line_text, int(item.get("character", 0)))
	if editor != null:
		editor.open_search_result(path, int(item.get("line", 0)), column)


func problems_on_line(document, line: int) -> Array:
	if document == null:
		return []
	var state := _state_for_path(str(document.path))
	if state.is_empty():
		return []
	var uri := str(state.get("uri", ""))
	var out: Array = []
	for diagnostic in diagnostics_for_uri(uri):
		var start := int(LspText.diagnostic_line(diagnostic))
		var end := start
		var range: Variant = diagnostic.get("range", {})
		if range is Dictionary:
			var end_pos: Variant = (range as Dictionary).get("end", {})
			if end_pos is Dictionary:
				end = int((end_pos as Dictionary).get("line", start))
		if line >= start and line <= end:
			out.append(diagnostic)
	return out


func show_problems_at_line(document, line: int) -> void:
	var diagnostics := problems_on_line(document, line)
	if diagnostics.is_empty():
		return
	var parts: Array[String] = []
	for diagnostic in diagnostics:
		var severity := int(diagnostic.get("severity", 3))
		parts.append("[color=#%s]%s[/color] %s" % [
			_color_hex(LspText.severity_color_key(severity)),
			LspText.severity_symbol(severity),
			LspText.diagnostic_label(diagnostic).replace("[", "[lb]"),
		])
	if editor != null and editor.lsp_hover_panel != null:
		var view = document.view if document != null else null
		editor.lsp_hover_panel.show_message("\n".join(parts), view, line, 0)


# ── HOVER / SIGNATURE / COMPLETION ─────────────────────────────────────────

func hover_symbol(view, line: int, column: int) -> void:
	if !_enabled or !_setting_bool("lsp_hover", true) or view == null or view.document == null:
		return
	_pending_hover = {"view": view, "line": line, "column": column}
	if _hover_timer != null:
		_hover_timer.start()


func hover_at_caret(view, explicit: bool = true) -> void:
	if view == null or view.document == null:
		return
	hide_signature()
	request_hover(view, view.get_caret_line(), view.get_caret_column(), explicit)


func request_hover(view, line: int, column: int, explicit: bool = false) -> void:
	if !_enabled:
		return
	if !explicit and !_setting_bool("lsp_hover", true):
		return
	var document = view.document if view != null else null
	if document == null:
		return
	var context := _client_for_document(document)
	if context.is_empty():
		if explicit:
			_warn_unavailable("Hover")
		return
	var client = context.get("client")
	var state: Dictionary = context.get("state", {})
	if _hover_request_id >= 0 and _hover_uri == str(state.get("uri", "")):
		client.cancel_request(_hover_request_id)
	_hover_uri = str(state.get("uri", ""))
	var params := _position_params(document, line, column)
	_hover_request_id = client.send_request("textDocument/hover", params, func(result: Dictionary) -> void:
		if !bool(result.get("ok", false)):
			if explicit:
				_warn(str(result.get("error", "Hover failed.")))
			return
		var hover: Dictionary = LspText.normalize_hover(result.get("result"))
		if !bool(hover.get("ok", false)):
			hide_hover()
			return
		if editor != null and editor.lsp_hover_panel != null:
			editor.lsp_hover_panel.show_hover(str(hover.get("bbcode", "")), view, line, column)
	, 6000)


func _flush_hover() -> void:
	if _pending_hover.is_empty():
		return
	var pending := _pending_hover
	_pending_hover = {}
	var view = pending.get("view")
	if !is_instance_valid(view) or view.document == null:
		return
	if editor == null or editor.documents == null or editor.documents.active_document() != view.document:
		return
	request_hover(view, int(pending.get("line", 0)), int(pending.get("column", 0)), false)


func hide_hover() -> void:
	_hover_request_id = -1
	_hover_uri = ""
	_pending_hover.clear()
	if _hover_timer != null:
		_hover_timer.stop()
	if editor != null and editor.lsp_hover_panel != null:
		editor.lsp_hover_panel.hide_now()


func schedule_signature(view, manual: bool = false) -> void:
	if !_enabled or view == null or view.document == null:
		return
	if !_setting_bool("lsp_signature_help", true):
		hide_signature()
		return
	_pending_signature = {
		"view": view,
		"line": view.get_caret_line(),
		"column": view.get_caret_column(),
		"manual": manual,
	}
	if _signature_timer != null:
		_signature_timer.start(0.01 if manual else SIGNATURE_DEBOUNCE)


func _flush_signature() -> void:
	if _pending_signature.is_empty():
		return
	var pending := _pending_signature
	_pending_signature = {}
	var view = pending.get("view")
	if !is_instance_valid(view) or view.document == null:
		return
	if editor == null or editor.documents == null or editor.documents.active_document() != view.document:
		hide_signature()
		return
	var line := int(pending.get("line", 0))
	var column := int(pending.get("column", 0))
	var manual := bool(pending.get("manual", false))
	if !manual:
		var context: Dictionary = LspText.call_context(str(view.text), line, column)
		if !bool(context.get("inside", false)):
			hide_signature()
			return

	var document = view.document
	var client_context := _client_for_document(document)
	if client_context.is_empty():
		hide_signature()
		return
	var client = client_context.get("client")
	var state: Dictionary = client_context.get("state", {})
	var uri := str(state.get("uri", ""))
	if _signature_request_id >= 0 and _signature_uri == uri:
		client.cancel_request(_signature_request_id)
	_signature_uri = uri
	var params := _position_params(document, line, column)
	params["context"] = {"triggerKind": 1, "isRetrigger": false}
	_signature_request_id = client.send_request("textDocument/signatureHelp", params, func(result: Dictionary) -> void:
		if !bool(result.get("ok", false)):
			hide_signature()
			return
		var parsed: Dictionary = LspText.normalize_signature_help(result.get("result"))
		if !bool(parsed.get("ok", false)):
			hide_signature()
			return
		if !is_instance_valid(view) or view.document == null or editor == null:
			return
		if editor.documents.active_document() != view.document:
			return
		if editor.lsp_signature_panel != null:
			editor.lsp_signature_panel.show_for(view, line, column, parsed)
	, 6000)


func hide_signature() -> void:
	_signature_request_id = -1
	_signature_uri = ""
	_pending_signature.clear()
	if _signature_timer != null:
		_signature_timer.stop()
	if editor != null and editor.lsp_signature_panel != null:
		editor.lsp_signature_panel.hide_now()


func request_completion(view, line: int, column: int, on_items: Callable) -> bool:
	if !_enabled or !_setting_bool("lsp_completion", true):
		return false
	if view == null or view.document == null or !on_items.is_valid():
		return false
	var document = view.document
	var context := _client_for_document(document)
	if context.is_empty():
		return false
	var client = context.get("client")
	var state: Dictionary = context.get("state", {})
	if !client.supports("completionProvider"):
		return false
	var uri := str(state.get("uri", ""))
	if _completion_ids.has(uri):
		client.cancel_request(int(_completion_ids[uri]))
	var params := _position_params(document, line, column)
	params["context"] = {"triggerKind": 1}
	_completion_ids[uri] = client.send_request("textDocument/completion", params, func(result: Dictionary) -> void:
		_completion_ids.erase(uri)
		if !bool(result.get("ok", false)):
			return
		var parsed: Dictionary = LspText.normalize_completion(result.get("result"))
		var items: Array = parsed.get("items", [])
		if items.is_empty():
			return
		if !is_instance_valid(view) or view.document == null:
			return
		if editor == null or editor.documents.active_document() != view.document:
			return
		on_items.call(items)
	, 8000)
	return true


# ── NAVIGATION / ACTIONS / EDITS ───────────────────────────────────────────

func request_definition(view) -> void:
	if view == null or view.document == null:
		return
	var context := _client_for_document(view.document)
	if context.is_empty():
		_warn_unavailable("Go to definition")
		return
	var client = context.get("client")
	var document = view.document
	var params := _position_params(document, view.get_caret_line(), view.get_caret_column())
	client.send_request("textDocument/definition", params, func(result: Dictionary) -> void:
		if !bool(result.get("ok", false)):
			_warn(str(result.get("error", "Definition failed.")))
			return
		var locations: Array = LspText.normalize_locations(result.get("result"))
		if locations.is_empty():
			_warn("No definition found.")
			return
		var items := _location_items(locations)
		if items.size() == 1:
			_activate_location(items[0])
		elif editor != null and editor.lsp_picker != null:
			editor.lsp_picker.show_locations("Definitions", items)
	, 8000)


func request_references(view) -> void:
	if view == null or view.document == null:
		return
	var context := _client_for_document(view.document)
	if context.is_empty():
		_warn_unavailable("Find references")
		return
	var client = context.get("client")
	var document = view.document
	var params := _position_params(document, view.get_caret_line(), view.get_caret_column())
	params["context"] = {"includeDeclaration": true}
	client.send_request("textDocument/references", params, func(result: Dictionary) -> void:
		if !bool(result.get("ok", false)):
			_warn(str(result.get("error", "References failed.")))
			return
		var locations: Array = LspText.normalize_locations(result.get("result"))
		if locations.is_empty():
			_warn("No references found.")
			return
		var items := _location_items(locations)
		if editor != null and editor.lsp_picker != null:
			editor.lsp_picker.show_locations("References (%d)" % items.size(), items)
	, 10000)


func request_formatting(view) -> void:
	if view == null or view.document == null:
		return
	var context := _client_for_document(view.document)
	if context.is_empty():
		_warn_unavailable("Format document")
		return
	var client = context.get("client")
	if !client.supports("documentFormattingProvider"):
		_warn(str(client.display_name()) + " does not format documents.")
		return
	var document = view.document
	var params := {
		"textDocument": {"uri": LspText.path_to_uri(str(document.path))},
		"options": {
			"tabSize": _setting_int("indentation_size", 4),
			"insertSpaces": _setting_bool("indentation_use_spaces", false),
		},
	}
	client.send_request("textDocument/formatting", params, func(result: Dictionary) -> void:
		if !bool(result.get("ok", false)):
			_warn(str(result.get("error", "Formatting failed.")))
			return
		var value: Variant = result.get("result")
		if !(value is Array) or (value as Array).is_empty():
			_warn("Nothing to format.")
			return
		if _apply_edits_to_document(document, value):
			_warn("[color=#8bd5ff]LSP[/color]: Formatted %s." % str(document.title()))
	, 15000)


func request_rename(view) -> void:
	if view == null or view.document == null:
		return
	var context := _client_for_document(view.document)
	if context.is_empty():
		_warn_unavailable("Rename symbol")
		return
	var line: int = view.get_caret_line()
	var column: int = view.get_caret_column()
	var word := ""
	if view.has_method("get_word_under_caret"):
		word = str(view.get_word_under_caret())
	if word.is_empty():
		var line_text := LspText.line_at(str(view.text), line)
		word = line_text
	# Remember the exact document and position the dialog was opened from: the
	# user may switch tabs while typing the new name, and the request must
	# still rename the symbol they right-clicked, not the new active tab's.
	_pending_rename = {
		"document": view.document,
		"path": str(view.document.path),
		"line": line,
		"column": column,
	}
	if _rename_dialog != null:
		_rename_dialog.open_for(word, str(view.document.path), line + 1)
	else:
		_warn("Rename dialog is unavailable.")


func _on_rename_submitted(new_name: String) -> void:
	# The dialog normally hides itself before emitting `submitted`. Hide it
	# again here so a programmatic submit (tests, future callers) cannot leave
	# two exclusive windows open when the workspace preview arrives.
	if _rename_dialog != null:
		_rename_dialog.hide()
	var pending := _pending_rename
	_pending_rename = {}
	var document = pending.get("document")
	var path := str(pending.get("path", ""))
	if editor != null and editor.documents != null and !path.is_empty():
		var current = editor.documents.find_by_path(path)
		if current != null:
			document = current
	if document == null:
		return
	var name := new_name.strip_edges()
	if name.is_empty():
		return
	var context := _client_for_document(document)
	if context.is_empty():
		_warn_unavailable("Rename symbol")
		return
	var client = context.get("client")
	var params := _position_params(document, int(pending.get("line", 0)), int(pending.get("column", 0)))
	params["newName"] = name
	client.send_request("textDocument/rename", params, func(result: Dictionary) -> void:
		if !bool(result.get("ok", false)):
			_warn(str(result.get("error", "Rename failed.")))
			return
		var edit: Variant = result.get("result")
		if edit == null:
			_warn("The language server returned no rename edits.")
			return
		_preview_workspace_edit(edit, "Rename to \"%s\"" % name)
	, 15000)


func request_code_actions(view, line: int = -1, column: int = -1, explicit: bool = true) -> void:
	if view == null or view.document == null:
		return
	if line < 0:
		line = view.get_caret_line()
	if column < 0:
		column = view.get_caret_column()
	var context := _client_for_document(view.document)
	if context.is_empty():
		if explicit:
			_warn_unavailable("Code actions")
		return
	var client = context.get("client")
	var document = view.document
	if !client.supports("codeActionProvider"):
		if explicit:
			_warn(str(client.display_name()) + " does not offer code actions.")
		return

	var uri := LspText.path_to_uri(str(document.path))
	var overlapping: Array = []
	for diagnostic in diagnostics_for_uri(uri):
		var start := int(LspText.diagnostic_line(diagnostic))
		var end := start
		var range: Variant = diagnostic.get("range", {})
		if range is Dictionary:
			var end_pos: Variant = (range as Dictionary).get("end", {})
			if end_pos is Dictionary:
				end = int((end_pos as Dictionary).get("line", start))
		if line >= start and line <= end:
			var raw: Variant = diagnostic.get("raw")
			if raw is Dictionary:
				overlapping.append(raw)

	var position := LspText.caret_to_position(str(view.text), line, column)
	var range := {
		"start": position,
		"end": position,
	}
	var params := {
		"textDocument": {"uri": uri},
		"range": range,
		"context": {"diagnostics": overlapping, "triggerKind": 1},
	}

	if _actions_request_id >= 0 and _actions_uri == uri:
		client.cancel_request(_actions_request_id)
	_actions_uri = uri
	_actions_request_id = client.send_request("textDocument/codeAction", params, func(result: Dictionary) -> void:
		_actions_request_id = -1
		if !bool(result.get("ok", false)):
			if explicit:
				_warn(str(result.get("error", "Code actions failed.")))
			return
		var actions: Array = LspText.normalize_code_actions(result.get("result"))
		for action in actions:
			action["client_key"] = client.key
			action["uri"] = uri
		if actions.is_empty():
			if explicit:
				_warn("No code actions available here.")
			if view != null and is_instance_valid(view):
				view.set_action_available(false)
			return
		_action_hint_actions = {"uri": uri, "line": line, "actions": actions}
		_action_hint_line = line
		if view != null and is_instance_valid(view):
			view.set_action_available(true, line)
		if explicit and editor != null and editor.lsp_picker != null:
			editor.lsp_picker.show_actions("Code Actions", actions)
	, 8000)


func apply_code_action(action: Dictionary, allow_resolve: bool = true) -> void:
	if action.is_empty():
		return
	var disabled: Variant = action.get("disabled")
	if disabled is String and !str(disabled).is_empty():
		_warn(str(disabled))
		return
	var edit: Variant = action.get("edit")
	if edit is Dictionary:
		_preview_or_apply_workspace_edit(edit, str(action.get("title", "Code action")))
		return
	var command: Variant = action.get("command")
	if command is Dictionary:
		var client = _clients.get(str(action.get("client_key", "")))
		if client == null or !client.is_ready():
			_warn("The language server is not running.")
			return
		var command_name := str((command as Dictionary).get("command", ""))
		var arguments: Variant = (command as Dictionary).get("arguments", [])
		client.send_request("workspace/executeCommand", {
			"command": command_name,
			"arguments": arguments,
		}, func(result: Dictionary) -> void:
			if !bool(result.get("ok", false)):
				_warn(str(result.get("error", "The command failed.")))
				return
			var value: Variant = result.get("result")
			if value is Dictionary and ((value as Dictionary).has("changes") or (value as Dictionary).has("documentChanges")):
				_preview_or_apply_workspace_edit(value, str(action.get("title", "Code action")))
		, 15000)
		return
	if allow_resolve and action.get("data") != null:
		_resolve_code_action(action)
		return
	_warn("This code action has nothing to apply.")


## Some servers return a code action with `data` and no edit until the client
## calls codeAction/resolve. Ask once, then apply the completed action.
func _resolve_code_action(action: Dictionary) -> void:
	var client = _clients.get(str(action.get("client_key", "")))
	if client == null or !client.is_ready():
		_warn("The language server is not running.")
		return
	if !client.supports("codeActionProvider", "resolveProvider"):
		_warn("This code action needs a server that supports codeAction/resolve.")
		return
	var raw: Variant = action.get("raw")
	if !(raw is Dictionary):
		_warn("This code action has nothing to apply.")
		return
	client.send_request("codeAction/resolve", raw, func(result: Dictionary) -> void:
		if !bool(result.get("ok", false)):
			_warn(str(result.get("error", "The code action could not be resolved.")))
			return
		var resolved: Array = LspText.normalize_code_actions([result.get("result")])
		if resolved.is_empty():
			_warn("The language server returned an empty code action.")
			return
		var next: Dictionary = resolved[0]
		next["client_key"] = str(action.get("client_key", ""))
		next["uri"] = str(action.get("uri", ""))
		apply_code_action(next, false)
	, 10000)


func _schedule_action_hint() -> void:
	if !_enabled or !_setting_bool("lsp_lightbulb", true):
		return
	var view = _active_view()
	if view == null or view.document == null:
		return
	var line: int = view.get_caret_line()
	var column: int = view.get_caret_column()
	_pending_actions = {"view": view, "line": line, "column": column}
	if _actions_timer != null:
		_actions_timer.start()


func _flush_actions() -> void:
	if _pending_actions.is_empty():
		return
	var pending := _pending_actions
	_pending_actions = {}
	var view = pending.get("view")
	if !is_instance_valid(view) or view.document == null:
		return
	if editor == null or editor.documents.active_document() != view.document:
		return
	var context := _client_for_document(view.document)
	if context.is_empty():
		return
	var client = context.get("client")
	if !client.supports("codeActionProvider"):
		return
	var uri := LspText.path_to_uri(str(view.document.path))
	if _action_hint_actions.get("uri", "") == uri and int(_action_hint_actions.get("line", -1)) == int(pending.get("line", -2)):
		return
	request_code_actions(view, int(pending.get("line", 0)), int(pending.get("column", 0)), false)


func show_code_actions_at_line(view, line: int) -> void:
	if view == null or view.document == null:
		return
	var uri := LspText.path_to_uri(str(view.document.path))
	var cached: Dictionary = _action_hint_actions
	if str(cached.get("uri", "")) == uri and int(cached.get("line", -1)) == line and cached.get("actions") is Array:
		var actions: Array = cached.get("actions", [])
		if editor != null and editor.lsp_picker != null and !actions.is_empty():
			editor.lsp_picker.show_actions("Code Actions", actions)
			return
	request_code_actions(view, line, 0, true)


# ── WORKSPACE EDITS ────────────────────────────────────────────────────────

func _preview_or_apply_workspace_edit(edit: Variant, title: String) -> void:
	var normalized: Dictionary = LspText.normalize_workspace_edit(edit)
	if !bool(normalized.get("ok", false)):
		_warn("The edit is malformed.")
		return
	var files: Dictionary = normalized.get("files", {})
	if files.is_empty():
		_warn("The language server returned no file edits.")
		return
	if files.size() == 1:
		_apply_workspace_edit_now(normalized)
		return
	_preview_workspace_edit(edit, title)


func _preview_workspace_edit(edit: Variant, title: String) -> void:
	var normalized: Dictionary = LspText.normalize_workspace_edit(edit)
	if !bool(normalized.get("ok", false)):
		_warn("The edit is malformed.")
		return
	var files: Dictionary = normalized.get("files", {})
	if files.is_empty():
		_warn("The language server returned no file edits.")
		return
	var entries: Array = []
	for raw_uri in files.keys():
		var uri := str(raw_uri)
		var path := LspText.uri_to_path(uri)
		var document = null
		if editor != null and editor.documents != null:
			document = editor.documents.find_by_path(path)
		var edits: Array = files[raw_uri] if files[raw_uri] is Array else []
		entries.append({
			"uri": uri,
			"path": path,
			"file": path.get_file(),
			"edits": edits.size(),
			"locations": _edit_lines(edits),
			"open": document != null,
			"modified": document != null and bool(document.modified),
			"exists": FileAccess.file_exists(path),
		})
	_pending_workspace_edit = normalized
	_pending_workspace_title = title
	if _workspace_preview != null:
		_workspace_preview.show_preview(title, entries, normalized.get("operations", []))
	else:
		_apply_pending_workspace_edit()


func _apply_pending_workspace_edit() -> void:
	if _pending_workspace_edit.is_empty():
		return
	var normalized := _pending_workspace_edit
	_pending_workspace_edit = {}
	_apply_workspace_edit_now(normalized)


func _apply_workspace_edit_now(normalized: Dictionary) -> void:
	var files: Dictionary = normalized.get("files", {})
	if files.is_empty():
		return
	var applied := 0
	var failures: Array[String] = []
	var touched: Array[String] = []

	for raw_uri in files.keys():
		var uri := str(raw_uri)
		var path := LspText.uri_to_path(uri)
		var edits: Array = files[raw_uri] if files[raw_uri] is Array else []
		if path.is_empty() or edits.is_empty():
			continue
		if !FileAccess.file_exists(path):
			failures.append("%s does not exist." % path)
			continue

		var document = editor.documents.find_by_path(path) if editor != null and editor.documents != null else null
		if document != null:
			if bool(document.modified):
				if _apply_edits_to_document(document, edits):
					applied += 1
					touched.append(path)
				else:
					failures.append("%s: could not apply the edit." % path.get_file())
			else:
				var original := str(document.text())
				var result: Dictionary = LspText.apply_text_edits(original, edits)
				if !bool(result.get("ok", false)):
					failures.append("%s: %s" % [path.get_file(), str(result.get("error", "edit failed"))])
					continue
				var updated := str(result.get("text", original))
				var saved: Dictionary = Fs.save(path, updated)
				if !bool(saved.get("ok", false)):
					# Keep the refactor instead of losing it: leave the buffer
					# dirty so the user can fix the write error and save.
					_apply_edits_to_document(document, edits)
					failures.append("%s: %s" % [path.get_file(), str(saved.get("error", "save failed"))])
					continue
				document.set_text(updated, true)
				document.disk_mtime = editor._mtime(path)
				applied += 1
				touched.append(path)
				document_changed(document)
				document_saved(document)
		else:
			var original := FileAccess.get_file_as_string(path)
			var result: Dictionary = LspText.apply_text_edits(original, edits)
			if !bool(result.get("ok", false)):
				failures.append("%s: %s" % [path.get_file(), str(result.get("error", "edit failed"))])
				continue
			var saved: Dictionary = Fs.save(path, str(result.get("text", original)))
			if !bool(saved.get("ok", false)):
				failures.append("%s: %s" % [path.get_file(), str(saved.get("error", "save failed"))])
				continue
			applied += 1
			touched.append(path)

	for path in touched:
		if editor != null and editor.workspace != null and editor.workspace.has_workspace():
			editor.workspace.note_changed(path)
	if editor != null and editor.file_tree != null:
		editor.file_tree.refresh_all()
	if editor != null:
		if failures.is_empty():
			editor.warn("[color=#8bd5ff]LSP[/color]: Applied edits to %d file(s)." % applied)
		else:
			editor.warn("[color=yellow]LSP[/color]: Applied %d edit(s); %d failed.\n%s" % [
				applied, failures.size(), "\n".join(failures),
			])


func _apply_edits_to_document(document, edits: Array) -> bool:
	if document == null or document.view == null or !is_instance_valid(document.view):
		return false
	var view = document.view
	var original := str(view.text)
	var check: Dictionary = LspText.apply_text_edits(original, edits)
	if !bool(check.get("ok", false)):
		_warn(str(check.get("error", "The edit could not be applied.")))
		return false
	var prepared: Array = LspText.edits_for_view(original, edits)
	if prepared.is_empty():
		return false
	prepared.sort_custom(func(a, b) -> bool:
		if int(a.from_line) != int(b.from_line):
			return int(a.from_line) > int(b.from_line)
		return int(a.from_column) > int(b.from_column)
	)

	var caret_line: int = view.get_caret_line()
	var caret_column: int = view.get_caret_column()
	var was_active = editor != null and editor.documents.active_document() == document
	if was_active:
		editor.editor_host.release_active_focus()

	view.begin_complex_operation()
	for edit in prepared:
		view.remove_text(
			int(edit.from_line), int(edit.from_column),
			int(edit.to_line), int(edit.to_column)
		)
		view.insert_text(str(edit.new_text), int(edit.from_line), int(edit.from_column))
	view.end_complex_operation()

	var last_line := maxi(0, view.get_line_count() - 1)
	view.set_caret_line(clampi(caret_line, 0, last_line))
	view.set_caret_column(clampi(caret_column, 0, view.get_line(view.get_caret_line()).length()))
	document.mark_dirty()
	if was_active and editor != null:
		editor.editor_host.grab_active_focus()
	document_changed(document)
	return true


# ── SERVER INFORMATION / UI ────────────────────────────────────────────────

func server_rows() -> Array:
	if config == null:
		return []
	var rows: Array = config.server_entries()
	for row in rows:
		var profile_id := str(row.get("id", ""))
		var roots: Array[String] = []
		var running := false
		var ready := false
		for key in _specs.keys():
			var spec: Dictionary = _specs[key]
			var spec_id := str(spec.get("profile", {}).get("id", ""))
			if spec_id != profile_id:
				continue
			var root := str(spec.get("root", ""))
			if !root.is_empty() and !roots.has(root):
				roots.append(root)
			var client = _clients.get(key)
			if client != null and is_instance_valid(client):
				running = running or client.running
				ready = ready or client.is_ready()
		row["roots"] = roots
		row["running"] = running
		row["ready"] = ready
		row["active"] = _active_state_language() == profile_id or row.get("languages", []).has(_active_state_language())
	rows.sort_custom(func(a, b) -> bool:
		return str(a.get("display", "")).naturalnocasecmp_to(str(b.get("display", ""))) < 0
	)
	return rows


func install_cards() -> Array:
	var cards: Array = []
	if config == null:
		return cards
	var language := _active_language()
	if language.is_empty():
		return cards
	var document = editor.documents.active_document() if editor != null and editor.documents != null else null
	if document == null:
		return cards
	var status: Dictionary = config.server_status(language, str(document.path), _workspace_root)
	if !bool(status.get("ok", false)) and status.get("profile", {}) is Dictionary and !status.get("profile", {}).is_empty():
		var help: Dictionary = status.get("install", {})
		help["language"] = language
		help["path"] = str(document.path)
		cards.append(help)
	return cards


func _active_language() -> String:
	var document = editor.documents.active_document() if editor != null and editor.documents != null else null
	return _language_for(document)


func _active_state_language() -> String:
	var document = editor.documents.active_document() if editor != null and editor.documents != null else null
	if document == null:
		return ""
	var state := _state_for_path(str(document.path))
	return str(state.get("language_id", state.get("language", "")))


func _notify_missing(language: String, install: Variant, profile: Dictionary) -> void:
	if !(install is Dictionary):
		install = {}
	var help: Dictionary = (install as Dictionary).duplicate(true)
	help["language"] = language
	help["executable"] = str(profile.get("command", help.get("executable", "")))
	var notice_key := language + "|" + str(help.get("executable", ""))
	if !_missing_notified.has(notice_key):
		_missing_notified[notice_key] = true
		missing_server.emit(help)
		_append_log(str(profile.get("display", language)), "Command not found: " + str(help.get("executable", "")))


func _warn_unavailable(feature: String) -> void:
	var document = editor.documents.active_document() if editor != null and editor.documents != null else null
	var language := _language_for(document) if document != null else ""
	if language.is_empty():
		_warn(feature + ": this file has no language server.")
		return
	var status: Dictionary = config.server_status(language, str(document.path), _workspace_root) if config != null else {}
	if !bool(status.get("ok", false)):
		_notify_missing(language, status.get("install", {}), status.get("profile", {}))
		_warn(feature + ": the language server for %s is not installed. Open the LSP panel for install steps." % language.capitalize())
		return
	_warn(feature + ": the language server is still starting. Try again in a moment.")


func _warn(message: String) -> void:
	if editor != null and editor.has_method("warn"):
		editor.warn("[color=yellow]LSP[/color]: " + message)
	else:
		push_warning("[lsp] " + message)


func _color_hex(key: String) -> String:
	var color := LuaSingleton.str_to_clr("#7f8c98")
	if LuaSingleton.editor_theme != null:
		var fallback := LuaSingleton.editor_theme.get_color(key, "MyType")
		if fallback != null:
			color = fallback
	if LuaSingleton.gui.has(key):
		color = LuaSingleton.gui[key]
	return color.to_html(false)


func server_log() -> String:
	return "\n".join(_log_lines)


func clear_log() -> void:
	_log_lines.clear()
	log_updated.emit()


func _append_log(server: String, text: String) -> void:
	var message := str(text).strip_edges()
	if message.is_empty():
		return
	var prefix := Time.get_time_string_from_system()
	var line := "[%s] %s%s" % [prefix, ("[" + server + "] " if !server.is_empty() else ""), message]
	_log_lines.append(line)
	if _log_lines.size() > MAX_LOG_LINES:
		_log_lines = _log_lines.slice(_log_lines.size() - MAX_LOG_LINES)
	log_updated.emit()


func _on_apply_edit_requested(client, request_id: Variant, edit: Variant) -> void:
	var normalized: Dictionary = LspText.normalize_workspace_edit(edit)
	if !bool(normalized.get("ok", false)):
		client.send_response(request_id, {"applied": false, "failureReason": "The edit is malformed."})
		return
	_apply_workspace_edit_now(normalized)
	client.send_response(request_id, {"applied": true})


# ── HELPERS ─────────────────────────────────────────────────────────────────

func _client_for_document(document) -> Dictionary:
	if document == null:
		return {}
	var state := _state_for_path(str(document.path))
	if state.is_empty():
		sync_open_documents()
		state = _state_for_path(str(document.path))
	if state.is_empty():
		return {}
	var client = _clients.get(str(state.get("key", "")))
	if client == null:
		ensure_document_client(document)
		client = _clients.get(str(state.get("key", "")))
	if client == null or !client.is_ready():
		return {}
	if !bool(state.get("opened", false)):
		_open_state(str(state.get("uri", "")))
	return {"client": client, "state": state}


func _position_params(document, line: int, column: int) -> Dictionary:
	var pos: Dictionary = LspText.caret_to_position(str(document.text()), line, column)
	return {
		"textDocument": {"uri": LspText.path_to_uri(str(document.path))},
		"position": pos,
	}


func _location_items(locations: Array) -> Array:
	var items: Array = []
	for location in locations:
		var path := str(location.get("path", ""))
		if path.is_empty():
			continue
		var line := int(location.get("line", 0))
		var character := int(location.get("character", 0))
		var text := _text_for_path(path)
		var column := LspText.utf16_to_column(LspText.line_at(text, line), character)
		var relative := _relative_path(path)
		items.append({
			"path": path,
			"line": line,
			"column": column,
			"character": character,
			"file": path.get_file(),
			"label": "%s:%d" % [path.get_file(), line + 1],
			"detail": relative,
			"preview": LspText.line_at(text, line).strip_edges(),
		})
	return items


func _activate_location(item: Dictionary) -> void:
	var path := str(item.get("path", ""))
	if path.is_empty():
		return
	if editor != null:
		editor.open_search_result(path, int(item.get("line", 0)), int(item.get("column", 0)))


func _text_for_path(path: String) -> String:
	if editor != null and editor.documents != null:
		var document = editor.documents.find_by_path(path)
		if document != null:
			return str(document.text())
	if FileAccess.file_exists(path):
		return FileAccess.get_file_as_string(path)
	return ""


func _relative_path(path: String) -> String:
	if _workspace_root.is_empty() or config == null:
		return path
	if Paths.is_subpath(_workspace_root, path):
		return Paths.normalize(path).substr(Paths.normalize(_workspace_root).length() + 1)
	return path


## Unique zero-based start lines for a list of TextEdits, used by the
## workspace-edit preview to tell the user where the changes land.
func _edit_lines(edits: Array) -> Array:
	var seen: Dictionary = {}
	for edit in edits:
		if !(edit is Dictionary):
			continue
		var range: Variant = (edit as Dictionary).get("range", {})
		if !(range is Dictionary):
			continue
		var start: Variant = (range as Dictionary).get("start", {})
		if start is Dictionary:
			seen[int((start as Dictionary).get("line", 0))] = true
	var lines: Array = seen.keys()
	lines.sort()
	return lines


func _is_active_document(document) -> bool:
	return document != null and editor != null and editor.documents != null and editor.documents.active_document() == document


func _active_view():
	return editor.active_view if editor != null else null


func _setting_bool(key: String, fallback: bool) -> bool:
	var found = LuaSingleton.get_setting(key)
	if found is Array and found.size() >= 2 and int(found[1]) != -1:
		return bool(found[0].get("value", fallback))
	return fallback


func _setting_int(key: String, fallback: int) -> int:
	var found = LuaSingleton.get_setting(key)
	if found is Array and found.size() >= 2 and int(found[1]) != -1:
		return int(found[0].get("value", fallback))
	return fallback


func _on_settings_change() -> void:
	var enabled := _setting_bool("lsp_enabled", true)
	if enabled != _enabled:
		_enabled = enabled
		if !_enabled:
			hide_hover()
			hide_signature()
			_stop_all_clients(true)
			_append_log("", "Language servers disabled.")
		else:
			_append_log("", "Language servers enabled.")
			_load_config()
			sync_open_documents()
			ensure_active_client()
	if !_setting_bool("lsp_diagnostics", true):
		clear_diagnostics()
	servers_updated.emit()
