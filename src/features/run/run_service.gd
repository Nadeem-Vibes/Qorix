extends Node

## Owns one program run at a time.
##
## Two execution modes:
##   * capture  — a detached PTY is wrapped in a marker-printing shell. Output
##                feeds RunCapture (ANSI cleanup, markers, truncation) and the
##                Run panel shows it with explanations. stdin is /dev/null/NUL,
##                so an interactive program fails fast instead of hanging.
##   * terminal — the command is typed into the visible terminal tab, exactly
##                like the old RunManager. Servers, REPLs and prompts keep their
##                keyboard, colours and Ctrl+C.
##
## RunService never touches the UI directly. It emits signals and stores
## `last_result`, which the panel renders. That keeps the whole lifecycle
## testable without a scene.

const RunConfig = preload("res://src/features/run/run_config.gd")
const RunCapture = preload("res://src/features/run/run_capture.gd")
const ErrorExplainer = preload("res://src/features/run/error_explainer.gd")
const RuntimeCatalog = preload("res://src/features/run/runtime_catalog.gd")

signal run_started(info: Dictionary)
signal output_changed(output: String)
signal run_finished(output: String, exit_code: int)
signal run_blocked(result: Dictionary)
signal state_changed

const CAPTURE_COLS := 1000
const CAPTURE_ROWS := 200
const EXIT_DRAIN_MSEC := 120
const STOP_GRACE_MSEC := 450

## Source patterns that mean a script will read the keyboard. Captured runs
## attach an empty stdin, so a detected reader is sent to the terminal before
## it can fail with EOFError. The patterns are intentionally broad: a false
## positive only changes which runner is used, never whether the program works.
const INTERACTIVE_PATTERNS := {
	"python": [
		"\\binput\\s*\\(",
		"\\bsys\\.stdin\\b",
		"\\bfileinput\\b",
	],
}

## Untyped on purpose: tests drive this with a stub that only exposes
## current_file/current_dir/active_view/documents/workspace/terminal/warn().
var editor = null

var config = null
var explainer = null
var catalog = null

var running: bool = false
var mode: String = ""
var last_result: Dictionary = {}
var last_command: String = ""
var last_profile: Dictionary = {}
var last_started_msec: int = 0

var _capture: RunCapture = null
var _session: TerminalSession = null
var _run_info: Dictionary = {}
var _stop_requested: bool = false
var _finalized: bool = false
var _session_serial: int = 0
var _last_run_msec: int = 0


func _ready() -> void:
	config = RunConfig.new()
	explainer = ErrorExplainer.new()
	explainer.load_rules()
	catalog = RuntimeCatalog.new()
	# A config/rule failure should be visible to the developer, but it must
	# never stop the editor from launching.
	for message in explainer.errors:
		push_warning("[run] " + str(message))


# ── PUBLIC ENTRY POINTS ─────────────────────────────────────────────────────

## Runs the active document (or `file_path`). Returns the final result when
## awaited, so commands and tests can use one call.
func run(file_path: String = "", options: Dictionary = {}) -> Dictionary:
	var now := Time.get_ticks_msec()
	# One keypress can reach both the editor shortcut and the toolbar; keep a
	# tiny floor like RunManager did, or the same file starts twice.
	if now - _last_run_msec < 250 and file_path.is_empty():
		return {}
	_last_run_msec = now

	if running:
		stop()
		await get_tree().create_timer(0.35).timeout
		if !is_inside_tree():
			return {}
		if running:
			return _blocked("A previous run is still stopping. Press Run again in a moment.", "busy")

	var target := str(file_path)
	var document = _document_for(target)
	if target.is_empty() and document != null:
		target = str(document.path)
	if target.is_empty():
		target = _current_file()
	if target.is_empty():
		return _notify_blocked("Nothing to run — open or save a file first.", "no-file")

	if document == null:
		document = _document_for(target)

	# Unsaved buffers have no path for a compiler/interpreter to open. Offer
	# the normal Save As flow instead of inventing a temp filename the error
	# links could not point back into.
	if (document != null and bool(document.untitled)) or target.is_empty():
		if editor != null and editor.has_method("save_as"):
			editor.save_as()
		return _notify_blocked("Save this file first, then press Run again.", "unsaved")

	if bool(options.get("save", true)) and _setting_bool("save_before_run", true):
		if document != null and bool(document.modified):
			if editor != null and editor.has_method("_save_document"):
				if !editor._save_document(document):
					return _notify_blocked("The file could not be saved, so the run was cancelled.", "save-failed")

	var text := _document_text(document)
	if document == null and FileAccess.file_exists(target):
		# Running a path that is not open (or a test stub without documents)
		# still needs the source for the interactive-run check.
		text = FileAccess.get_file_as_string(target)
	var workspace := _workspace_root()
	var respect_shebang := _setting_bool("respect_shebang", true)

	_sync_workspace_trust()
	config.load_for_project(workspace, target, text, respect_shebang)
	var language_override := ""
	if document != null:
		language_override = str(document.get("language_override")) if document.get("language_override") != null else ""
	var profile: Dictionary = config.profile_for(target, language_override)
	if profile.is_empty():
		return _notify_blocked(
			"No run configuration matches this file. Create .griddycode/run.json to add one.",
			"no-executor"
		)

	var command: String = config.resolve_command(profile, target, workspace)
	if command.strip_edges().is_empty():
		return _notify_blocked("The selected run profile has an empty command.", "empty-command")

	var cwd: String = config.resolve_existing_cwd(profile, target, workspace)
	var preflight: Dictionary = catalog.check_profile(profile, command)

	# PATH fallbacks (python3/py, nodejs, clang, pwsh) are rewritten into the
	# command before spawning; the preflight is also what turns a missing
	# runtime into an install card instead of a raw shell error.
	var replacements: Dictionary = preflight.get("replacements", {})
	for requested in replacements.keys():
		command = RuntimeCatalog.replace_executable(command, str(requested), str(replacements[requested]))

	var auto_terminal := script_reads_stdin(profile, text)
	var terminal_mode := str(profile.get("mode", "capture")) == "terminal" \
		or bool(options.get("force_terminal", false)) \
		or auto_terminal
	if terminal_mode:
		return _run_in_terminal(profile, command, cwd, target, workspace, auto_terminal)

	var missing: Array = preflight.get("missing", [])
	if !missing.is_empty():
		var blocked := _base_result(profile, command, cwd, target)
		blocked["ok"] = false
		blocked["status"] = "blocked"
		blocked["exit_code"] = -1
		blocked["install"] = missing.duplicate(true)
		blocked["message"] = "This run needs software that is not installed."
		blocked["diagnoses"] = []
		last_result = blocked
		last_command = command
		last_profile = profile
		run_blocked.emit(blocked)
		run_finished.emit("", -1)
		state_changed.emit()
		return blocked

	return await _start_capture(profile, command, cwd, target, workspace)


## Stop the active run. Captured runs get Ctrl+C first (so a program can clean
## up), then a PTY kill if it does not leave; terminal runs receive Ctrl+C.
func stop() -> void:
	if mode == "terminal":
		_stop_terminal()
		return

	if !running:
		return

	_stop_requested = true
	if _session != null and _session.running:
		_session.write(PackedByteArray([3]))
		await get_tree().create_timer(STOP_GRACE_MSEC / 1000.0).timeout
		if !is_inside_tree():
			return
		if running and _session != null and _session.running:
			_session.kill()

	# A PTY that dies from a kill may not emit exited on every platform.
	if running:
		_finalize(-1)


func toggle_terminal_run() -> Dictionary:
	if running:
		stop()
		return {}
	return await run("", {"force_terminal": true})


## Opens `.griddycode/run.json`, creating it from the documented template when
## it does not exist yet. Returns the normalized path (or "" on failure).
func open_config() -> String:
	var root := _workspace_root()
	if root.is_empty():
		if editor != null:
			editor.warn("[color=yellow]RUN[/color]: Open a folder first; run configs live inside a project.")
		return ""

	var folder := root.path_join(".griddycode")
	if !DirAccess.dir_exists_absolute(folder):
		var made := DirAccess.make_dir_recursive_absolute(folder)
		if made != OK:
			if editor != null:
				editor.warn("[color=red]RUN[/color]: Could not create %s." % folder)
			return ""

	var path := folder.path_join("run.json")
	if !FileAccess.file_exists(path):
		var result := _write_text(path, RunConfig.default_config_text())
		if !result:
			return ""

	if editor != null and editor.has_method("open_file"):
		editor.open_file(path)
	return path


## The workspace may supply .griddycode/run.json, which names a shell command.
## Only apply it when the editor says the folder is trusted.
func _sync_workspace_trust() -> void:
	if config == null:
		return
	if editor != null and editor.has_method("is_workspace_trusted"):
		config.workspace_trust = Callable(editor, "is_workspace_trusted")


func config_path() -> String:
	var root := _workspace_root()
	if root.is_empty():
		return ""
	return root.path_join(".griddycode/run.json")


## Profile for the active file without running it (panel breadcrumb + tests).
func current_profile() -> Dictionary:
	var target := _current_file()
	if target.is_empty():
		return {}
	var document = _document_for(target)
	var language := ""
	if document != null and document.get("language_override") != null:
		language = str(document.get("language_override"))
	_sync_workspace_trust()
	config.load_for_project(_workspace_root(), target, _document_text(document), _setting_bool("respect_shebang", true))
	return config.profile_for(target, language)


func is_capturing() -> bool:
	return running and mode == "capture"


func shutdown() -> void:
	running = false
	if _session != null and is_instance_valid(_session):
		_session.kill()
		_session.queue_free()
		_session = null


## True when the profile opts into auto-terminal and the buffer contains a
## known keyboard-read call. Kept static and data-driven so the headless suite
## can verify it without creating a Node or touching the PTY.
static func script_reads_stdin(profile: Dictionary, text: String) -> bool:
	if !bool(profile.get("auto_terminal", false)) or text.strip_edges().is_empty():
		return false

	var language := str(profile.get("language", "")).strip_edges().to_lower()
	var patterns: Variant = INTERACTIVE_PATTERNS.get(language, [])
	if !(patterns is Array):
		return false

	for pattern in patterns:
		var regex := RegEx.new()
		if regex.compile(str(pattern)) != OK:
			continue
		if regex.search(text) != null:
			return true
	return false


# ── CAPTURE MODE ────────────────────────────────────────────────────────────

func _start_capture(profile: Dictionary, command: String, cwd: String, target: String, workspace: String) -> Dictionary:
	var token := RunCapture.make_token()
	_capture = RunCapture.new(token)
	_capture.clear()
	_finalized = false
	_stop_requested = false
	mode = "capture"
	running = true
	last_started_msec = Time.get_ticks_msec()
	last_command = command
	last_profile = profile

	_run_info = _base_result(profile, command, cwd, target)
	_run_info["mode"] = "capture"
	_run_info["workspace"] = workspace
	_run_info["token"] = token
	_run_info["config_errors"] = config.errors.duplicate()
	last_result = _run_info.duplicate(true)
	run_started.emit(_run_info.duplicate(true))

	_session_serial += 1
	_session = TerminalSession.new()
	_session.name = "RunSession%d" % _session_serial
	add_child(_session)
	_session.data_received.connect(_on_session_data)
	_session.exited.connect(_on_session_exited)

	var wrapper := _wrap_capture(command, token)
	var executable := "cmd.exe" if OS.get_name() == "Windows" else "/bin/sh"
	var args := PackedStringArray()
	if OS.get_name() == "Windows":
		args = PackedStringArray(["/D", "/S", "/C", wrapper])
	else:
		args = PackedStringArray(["-c", wrapper])

	if !DirAccess.dir_exists_absolute(cwd):
		cwd = workspace if !workspace.is_empty() else target.get_base_dir()

	var started: bool = await _session.start_command(executable, args, cwd, CAPTURE_COLS, CAPTURE_ROWS)
	if !is_inside_tree():
		return {}

	if !started:
		running = false
		var no_pty := _base_result(profile, command, cwd, target)
		no_pty["ok"] = false
		no_pty["status"] = "blocked"
		no_pty["message"] = "The terminal backend (godot-xterm) is not loaded. Restart Qorix once and try again."
		no_pty["exit_code"] = -1
		no_pty["diagnoses"] = []
		last_result = no_pty
		_dispose_session()
		run_blocked.emit(no_pty)
		run_finished.emit("", -1)
		state_changed.emit()
		return no_pty

	return {}


func _on_session_data(data: PackedByteArray) -> void:
	if !running or _capture == null:
		return
	if _capture.feed_bytes(data):
		output_changed.emit(_capture.output())


func _on_session_exited(exit_code: int, _signal_code: int) -> void:
	if !running or _capture == null:
		return

	# ConPTY can deliver the exit status one frame before the last output
	# chunk. Give the reader a short drain window, then finalize exactly once.
	await get_tree().create_timer(EXIT_DRAIN_MSEC / 1000.0).timeout
	if !is_inside_tree():
		return
	if !running:
		return
	_finalize(exit_code)


func _finalize(exit_code: int) -> void:
	if _finalized:
		return
	_finalized = true

	if _capture != null:
		_capture.finish(exit_code)
		exit_code = _capture.exit_code() if _capture.exit_code() >= 0 else exit_code
	var output := _capture.output() if _capture != null else ""
	var raw := _capture.raw_output() if _capture != null else ""
	var truncated := _capture.truncated() if _capture != null else false

	running = false
	mode = ""
	var result := last_result
	if result.is_empty():
		result = _run_info.duplicate(true)
	if result.is_empty():
		result = {}
	result["ok"] = exit_code == 0 and !_stop_requested
	result["status"] = "stopped" if _stop_requested and exit_code < 0 else ("finished" if exit_code == 0 else "failed")
	result["output"] = output
	result["raw_output"] = raw
	result["exit_code"] = exit_code
	result["truncated"] = truncated
	result["duration_ms"] = maxi(0, Time.get_ticks_msec() - last_started_msec)
	result["stopped"] = _stop_requested

	var diagnoses: Array = explainer.explain(output, {
		"language": str(result.get("language", "")),
		"exit_code": exit_code,
		"cwd": str(result.get("cwd", "")),
		"workspace": _workspace_root(),
		"file_dir": str(result.get("file", "")).get_base_dir(),
	})
	result["diagnoses"] = diagnoses
	result["summary"] = explainer.summary(diagnoses, exit_code)
	last_result = result

	_dispose_session()
	output_changed.emit(output)
	run_finished.emit(output, exit_code)
	state_changed.emit()


## Builds the shell snippet that prints an invisible start marker, runs the
## user's command with an empty stdin, then prints an end marker. `exit /b`
## (cmd) and `exit $code` (sh) preserve the program's real exit status.
func _wrap_capture(command: String, token: String) -> String:
	var start := "__GRIDDY_RUN_START_%s__" % token
	var finish := "__GRIDDY_RUN_EXIT_%s__" % token
	if OS.get_name() == "Windows":
		# `> CONOUT$` is not cosmetic: when Qorix itself was started from
		# a console, Windows duplicates that console's std handles into the
		# child even though ConPTY is attached (the documented
		# STARTF_USESTDHANDLES quirk). Explicitly reopening the attached
		# console keeps stdout/stderr inside the pseudo terminal instead of
		# leaking the program's output into the editor's parent console.
		# Parentheses keep user-level && / || chains together as one group.
		# Delayed expansion is not needed: exit /b with no argument keeps the
		# current ERRORLEVEL, which is the program's status, not echo's.
		return "echo %s > CONOUT$& (%s) > CONOUT$ 2>&1 <NUL& echo %s > CONOUT$& exit /b" % [start, command, finish]
	return "printf '\\n%s\\n'; (%s) < /dev/null; __griddy_exit=$?; printf '\\n%s\\n'; exit $__griddy_exit" % [start, command, finish]


func _dispose_session() -> void:
	if _session != null and is_instance_valid(_session):
		_session.queue_free()
	_session = null


# ── TERMINAL MODE ───────────────────────────────────────────────────────────

func _run_in_terminal(profile: Dictionary, command: String, cwd: String, target: String, workspace: String, auto_terminal: bool = false) -> Dictionary:
	mode = "terminal"
	running = false
	last_command = command
	last_profile = profile

	var result := _base_result(profile, command, cwd, target)
	result["ok"] = true
	result["status"] = "terminal"
	result["mode"] = "terminal"
	result["workspace"] = workspace
	result["auto_terminal"] = auto_terminal
	if auto_terminal:
		result["output"] = "This program reads keyboard input, so it is running in the terminal.\n\n%s\n\nin %s" % [command, cwd]
	else:
		result["output"] = "This profile runs in the terminal.\n\n%s\n\nin %s" % [command, cwd]
	result["exit_code"] = -1
	result["diagnoses"] = []
	result["install"] = []
	result["summary"] = "Running in the terminal" if !auto_terminal else "Running in the terminal (reads input)"
	result["duration_ms"] = 0
	last_result = result

	run_started.emit(result.duplicate(true))
	if editor == null or editor.terminal == null:
		result["ok"] = false
		result["status"] = "blocked"
		result["message"] = "The terminal panel is not available."
		run_blocked.emit(result)
		run_finished.emit("", -1)
		state_changed.emit()
		return result

	editor.terminal.open()
	editor.terminal.run_command(command)
	output_changed.emit(str(result["output"]))
	run_finished.emit(str(result["output"]), -1)
	state_changed.emit()
	return result


func _stop_terminal() -> void:
	if editor == null or editor.terminal == null:
		return
	var session = editor.terminal.get_active_session()
	if session != null and session.running:
		session.write(PackedByteArray([3]))


# ── RESULT / CONFIG HELPERS ─────────────────────────────────────────────────

func _base_result(profile: Dictionary, command: String, cwd: String, target: String) -> Dictionary:
	var language := str(profile.get("language", ""))
	if language.is_empty():
		language = str(target.get_extension()).to_lower()
	return {
		"ok": true,
		"status": "starting",
		"mode": "capture",
		"output": "",
		"raw_output": "",
		"exit_code": 0,
		"truncated": false,
		"stopped": false,
		"summary": "",
		"diagnoses": [],
		"install": [],
		"config_errors": [],
		"message": "",
		"auto_terminal": false,
		"command": command,
		"cwd": cwd,
		"file": target,
		"language": language,
		"profile": str(profile.get("id", "")),
		"display": str(profile.get("display", profile.get("id", ""))),
		"duration_ms": 0,
	}


func _blocked(message: String, status: String) -> Dictionary:
	var result := {
		"ok": false,
		"status": status,
		"mode": mode,
		"output": "",
		"raw_output": "",
		"exit_code": -1,
		"truncated": false,
		"stopped": false,
		"summary": message,
		"diagnoses": [],
		"install": [],
		"config_errors": [],
		"message": message,
		"auto_terminal": false,
		"command": last_command,
		"cwd": "",
		"file": _current_file(),
		"language": "",
		"profile": "",
		"display": "",
		"duration_ms": 0,
	}
	last_result = result
	running = false
	run_blocked.emit(result)
	run_finished.emit("", -1)
	state_changed.emit()
	return result


func _notify_blocked(message: String, status: String) -> Dictionary:
	if editor != null and editor.has_method("warn"):
		editor.warn("[color=yellow]RUN[/color]: %s" % message)
	return _blocked(message, status)


func _document_for(path: String):
	if editor == null or editor.documents == null:
		return null
	if !path.is_empty():
		return editor.documents.find_by_path(path)
	return editor.documents.active_document()


func _current_file() -> String:
	if editor == null:
		return ""
	if editor.documents != null:
		var document = editor.documents.active_document()
		if document != null and !str(document.path).is_empty():
			return str(document.path)
	return str(editor.current_file)


func _document_text(document) -> String:
	if document == null:
		return ""
	if document.has_method("text"):
		return str(document.text())
	return ""


func _workspace_root() -> String:
	if editor != null and editor.has_method("workspace_root_for_tools"):
		return str(editor.workspace_root_for_tools())
	return ""


func _setting_bool(key: String, fallback: bool) -> bool:
	var singleton = get_node_or_null("/root/LuaSingleton")
	if singleton == null:
		return fallback
	var found = singleton.get_setting(key)
	if found is Array and found.size() >= 2 and int(found[1]) != -1:
		return bool(found[0].get("value", fallback))
	return fallback


func _write_text(path: String, text: String) -> bool:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		if editor != null:
			editor.warn("[color=red]RUN[/color]: Could not write %s." % path)
		return false
	file.store_string(text)
	file = null
	return true
