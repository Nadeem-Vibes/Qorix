extends SceneTree

## End-to-end DAP acceptance run against the real editor scene and a real
## debugpy adapter. It covers the full vertical slice: adapter launch, Python
## configuration, breakpoints (gutter click and F9), stopping, variables,
## watches, call stack, console evaluation, stepping (into/out/over),
## cross-file navigation to a stopped frame, continue to termination and the
## Stop Debugging command.
##
##   godot --headless --path . --script res://tests/integration/dap_e2e_runner.gd -- \
##       --workspace="C:/temp/qorix-dap-e2e" --python="C:/Python/python.exe"
##
## Python must have the debugpy package installed. The run is skipped (exit 0)
## when Python or debugpy is missing. Exit code 1 = at least one failure.
##
## The line numbers below are pinned to tests/fixtures/dap_target.py and
## tests/fixtures/dap_helper.py; update both files together.

const Paths = preload("res://src/base/path_utils.gd")
const RuntimeCatalog = preload("res://src/features/run/runtime_catalog.gd")

const TARGET_NAME := "dap_target.py"
const HELPER_NAME := "dap_helper.py"

const MAIN_BREAKPOINT := 14       # value = add(base, step)
const FUNCTION_LINE := 7          # total = a + b, first line inside add()
const AFTER_CALL_LINE := 15       # print(...), where Step Out of add() lands
const HELPER_CALL_LINE := 16      # helper_add(step, 5)
const LOOP_LINE := 17             # for index in range(3)
const LOOP_BODY_LINE := 18        # value += index
const HELPER_BREAKPOINT := 4      # total = a + b, inside dap_helper.add()

var checks: int = 0
var failures: int = 0
var editor = null
var workspace_path: String = ""
var python_path: String = ""
var target_path: String = ""
var helper_path: String = ""
var created_workspace: bool = false
var keep_workspace: bool = false
var skipped: bool = false


func _initialize() -> void:
	_run()


func _run() -> void:
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--workspace="):
			workspace_path = argument.trim_prefix("--workspace=")
		elif argument.begins_with("--python="):
			python_path = argument.trim_prefix("--python=")
		elif argument == "--keep":
			keep_workspace = true

	if !_prepare_workspace():
		_finish(0 if skipped else 1)
		return

	await process_frame
	editor = await _boot_editor()
	if editor == null:
		print("FAIL  the editor scene did not boot")
		failures += 1
		await _finish(1)
		return

	await _stop_background_work()
	# Trust the fixture before opening it (mirrors the user's one-click
	# "Trust folder"): project-level debug config is only honoured for
	# trusted folders, and this one is fully runner-owned.
	if editor.has_method("is_workspace_trusted") and !editor.is_workspace_trusted(workspace_path):
		var trust_result: Dictionary = editor.trust_service.trust(workspace_path)
		if !bool(trust_result.get("ok", false)):
			print("FAIL  could not trust the test workspace")
			failures += 1
	editor.set_workspace(workspace_path, false)
	await _wait_frames(5)
	editor.open_file(target_path)
	await _wait_frames(6)
	editor.dap_manager.clear_console()

	await _test_breakpoint_editing()
	var started: bool = await _test_start_and_stop()
	if started:
		await _test_variables_and_stack()
		await _test_watch()
		await _test_console_evaluation()
		await _test_stepping()
		await _test_cross_file_stop()
		await _test_step_out_and_termination()
		await _test_stop_command()
		await _test_session_state()
	else:
		_dump_debug_state()

	await _finish(0 if failures == 0 else 1)


# ── SETUP ───────────────────────────────────────────────────────────────────

func _prepare_workspace() -> bool:
	var target_fixture := ProjectSettings.globalize_path("res://tests/fixtures/" + TARGET_NAME)
	var helper_fixture := ProjectSettings.globalize_path("res://tests/fixtures/" + HELPER_NAME)
	if !FileAccess.file_exists(target_fixture) or !FileAccess.file_exists(helper_fixture):
		print("SKIP  the DAP fixtures are missing: " + target_fixture)
		skipped = true
		return false

	var catalog = RuntimeCatalog.new()
	var python_command := python_path.strip_edges()
	if python_command.is_empty():
		python_command = catalog.find_executable("python")
	elif !python_command.contains("/") and !python_command.contains("\\"):
		var resolved := catalog.find_executable(python_command)
		if !resolved.is_empty():
			python_command = resolved
	if python_command.is_empty():
		print("SKIP  Python is not on PATH; install Python or pass --python=<path>.")
		skipped = true
		return false

	var probe: Array = []
	var probe_code := OS.execute(python_command,
		["-c", "import debugpy; print(debugpy.__version__)"], probe, true)
	if probe_code != 0:
		print("SKIP  debugpy is not installed for %s. Install it with: %s -m pip install debugpy"
			% [python_command, python_command])
		print("      " + str(probe).strip_edges())
		skipped = true
		return false
	print("INFO  python: " + python_command)
	print("INFO  debugpy: " + str(probe).strip_edges())

	if workspace_path.is_empty():
		workspace_path = OS.get_temp_dir().path_join(
			"qorix_dap_e2e_%d_%d" % [OS.get_process_id(), Time.get_ticks_msec()]
		)
		created_workspace = true
	workspace_path = workspace_path.replace("\\", "/")
	DirAccess.make_dir_recursive_absolute(workspace_path)
	target_path = workspace_path.path_join(TARGET_NAME)
	helper_path = workspace_path.path_join(HELPER_NAME)

	_copy_file(target_fixture, target_path)
	_copy_file(helper_fixture, helper_path)
	_write(".griddycode.json", JSON.stringify({
		"debug": {
			"python": {
				"command": python_command,
			},
		},
	}, "\t", false))
	print("INFO  workspace: " + workspace_path)
	return true


func _copy_file(source: String, destination: String) -> void:
	var text := FileAccess.get_file_as_string(source)
	var file := FileAccess.open(destination, FileAccess.WRITE)
	file.store_string(text)
	file = null


func _write(name: String, text: String) -> void:
	var path := workspace_path.path_join(name)
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(text)
	file = null


func _boot_editor():
	var packed: PackedScene = load("res://src/main/editor.tscn")
	if packed == null:
		return null
	var instance = packed.instantiate()
	root.add_child(instance)
	current_scene = instance
	await _wait_frames(10)

	# The welcome picker covers the editor on a fresh profile.
	if instance.overlays != null and instance.overlays.is_open(instance.file_dialog):
		instance.overlays.close(instance.file_dialog)
		await _wait_frames(20)
	return instance


func _stop_background_work() -> void:
	if editor.session_timer != null:
		editor.session_timer.stop()
	if editor.external_timer != null:
		editor.external_timer.stop()
	var autosave = editor.get_node_or_null("AutoSaveTimer")
	if autosave != null:
		autosave.stop()


# ── BREAKPOINTS ─────────────────────────────────────────────────────────────

func _test_breakpoint_editing() -> void:
	var manager = editor.dap_manager
	var view = editor.active_view
	_check(view != null, "the fixture opens in an editor view")
	if view == null:
		return
	_check(view._debug_gutter >= 0, "the editor has a debug gutter")
	_check(view.get_gutter_name(view._debug_gutter) == "debug", "the debug gutter is registered by name")

	# A real gutter click goes through EditorView's dispatch, not just the
	# manager API.
	view._on_gutter_clicked(MAIN_BREAKPOINT, view._debug_gutter)
	await _wait(0.1)
	_check(manager.has_breakpoint(target_path, MAIN_BREAKPOINT), "a click on the debug gutter adds a breakpoint")
	_check(view.debug_mark_at(MAIN_BREAKPOINT) == "breakpoint", "the gutter marks the breakpoint line")
	_check(view.debug_gutter_line_count() == 1, "the gutter paints the breakpoint dot")
	_check(manager.breakpoint_lines(target_path) == [MAIN_BREAKPOINT], "the file stores exactly one breakpoint")

	view.set_caret_line(LOOP_BODY_LINE)
	view.set_caret_column(0)
	editor.toggle_breakpoint_at_cursor()
	_check(manager.has_breakpoint(target_path, LOOP_BODY_LINE), "Toggle Breakpoint (F9) uses the caret line")
	view.set_caret_line(LOOP_BODY_LINE)
	editor.toggle_breakpoint_at_cursor()
	await _wait(0.1)
	_check(!manager.has_breakpoint(target_path, LOOP_BODY_LINE), "F9 removes the same line again")

	view._on_gutter_clicked(MAIN_BREAKPOINT, view._debug_gutter)
	await _wait(0.1)
	_check(!manager.has_breakpoint(target_path, MAIN_BREAKPOINT), "a second gutter click removes the breakpoint")
	view._on_gutter_clicked(MAIN_BREAKPOINT, view._debug_gutter)

	# The second file is not open yet; its breakpoint still exists so that the
	# cross-file navigation test has somewhere to stop.
	manager.add_breakpoint(helper_path, HELPER_BREAKPOINT)
	await _wait(0.1)
	_check(manager.breakpoint_count() == 2, "breakpoints can span two files")
	_check(manager.has_breakpoint(helper_path, HELPER_BREAKPOINT), "the closed file's breakpoint is kept")
	_check(view.debug_mark_at(MAIN_BREAKPOINT) == "breakpoint", "the open file repaints after a remote breakpoint change")


# ── START / STOP ────────────────────────────────────────────────────────────

func _test_start_and_stop() -> bool:
	var manager = editor.dap_manager
	manager.clear_console()
	editor.debug_start_or_continue()
	_check(manager.is_active() or str(manager.state) == "starting", "Start Debugging begins a session")

	var stopped := await _wait_until(func() -> bool:
		return _stopped_at(manager, target_path, MAIN_BREAKPOINT)
	, 25.0)
	_check(stopped, "the debuggee stops on the breakpoint")
	if !stopped:
		return false

	_check(str(manager.stop_reason) == "breakpoint", "the stop reason is breakpoint")
	_check(int(manager.thread_id) > 0, "the adapter reported a thread id")
	_check(manager.status_text().contains("Paused"), "the status line says Paused")
	_check(editor.debug_panel != null and editor.debug_panel.visible, "starting a session opens the debug panel")

	var view = editor.active_view
	_check(view != null and view.debug_mark_at(MAIN_BREAKPOINT) == "execution",
		"the execution marker sits on the paused line")
	var document = editor.documents.active_document()
	_check(document != null and int(document.caret_line) == MAIN_BREAKPOINT,
		"the caret jumps to the paused line")
	return true


# ── INSPECTION ──────────────────────────────────────────────────────────────

func _test_variables_and_stack() -> void:
	var manager = editor.dap_manager
	var ready := await _wait_until(func() -> bool:
		return _has_variables(manager, ["base", "step"])
	, 10.0)
	_check(ready, "the Locals scope exposes base and step")

	var values: Dictionary = _variable_values(manager)
	_check(str(values.get("base", "")) == "2", "base evaluates to 2")
	_check(str(values.get("step", "")) == "3", "step evaluates to 3")

	var frames: Array = manager.frame_items()
	_check(frames.size() >= 1, "the call stack has a frame")
	if !frames.is_empty():
		_check(str(frames[0].get("name", "")) == "main", "the top frame is main")
		_check(str(frames[0].get("file", "")) == TARGET_NAME, "the top frame names the target file")

	await _wait(0.5)
	var panel = editor.debug_panel
	_check(panel._stack_list != null and panel._stack_list.item_count >= 1,
		"the panel lists the call stack")
	_check(_tree_contains(panel._variables_tree, "base"), "the Variables tree shows base")
	_check(_tree_contains(panel._variables_tree, "step"), "the Variables tree shows step")


func _test_watch() -> void:
	var manager = editor.dap_manager
	manager.add_watch("base + step")
	var got := await _wait_until(func() -> bool:
		var items: Array = manager.watch_items()
		return !items.is_empty() and str(items[0].get("value", "")) == "5"
	, 8.0)
	_check(got, "a watch expression evaluates while paused")
	_check(!manager.watch_items().is_empty() and manager.watch_items()[0].get("ok") == true,
		"the watch result is marked as successful")

	await _wait(0.4)
	var panel = editor.debug_panel
	_check(_tree_contains(panel._watch_tree, "base + step"), "the Watch list shows the expression")
	_check(_tree_contains(panel._watch_tree, "5"), "the Watch list shows the value")


func _test_console_evaluation() -> void:
	var manager = editor.dap_manager
	var panel = editor.debug_panel
	editor.focus_debug_console()
	await _wait(0.2)
	_check(panel.visible, "Evaluate opens the debug panel")
	_check(panel._prompt != null and panel._prompt.editable, "the console prompt is editable while paused")
	if panel._prompt == null:
		return

	panel._prompt.text = "base + step + 100"
	panel._prompt.text_submitted.emit(panel._prompt.text)
	var evaluated := await _wait_until(func() -> bool:
		return manager.console_text().contains("105")
	, 8.0)
	_check(evaluated, "the console evaluates expressions against the paused frame")
	_check(manager.console_text().contains("> base + step + 100"),
		"the console echoes the submitted expression")
	_check(str(panel._prompt.text).is_empty(), "the prompt clears after evaluating")


# ── STEPPING ────────────────────────────────────────────────────────────────

func _test_stepping() -> void:
	var manager = editor.dap_manager
	var view = editor.active_view

	editor.debug_step_into()
	var stepped_in := await _wait_until(func() -> bool:
		return _stopped_at(manager, target_path, FUNCTION_LINE)
	, 12.0)
	_check(stepped_in, "Step Into enters add()")
	if stepped_in and view != null:
		_check(view.debug_mark_at(FUNCTION_LINE) == "execution", "the marker follows Step Into")

	editor.debug_step_out()
	# debugpy reports the caller's call line, not the line after it.
	var stepped_out := await _wait_until(func() -> bool:
		return _stopped_at(manager, target_path, MAIN_BREAKPOINT)
	, 12.0)
	if !stepped_out:
		print("STEP  after stepOut: " + _top_location(manager))
	_check(stepped_out, "Step Out returns to the caller")

	editor.debug_step_over()
	var stepped_over := await _wait_until(func() -> bool:
		return _stopped_at(manager, target_path, AFTER_CALL_LINE)
	, 12.0)
	if !stepped_over:
		print("STEP  after stepOver: " + _top_location(manager))
	_check(stepped_over, "Step Over advances one line")


func _test_cross_file_stop() -> void:
	var manager = editor.dap_manager
	# At AFTER_CALL_LINE, continuing executes the rest of the loop body, then
	# the helper call on HELPER_CALL_LINE hits the breakpoint in the file that
	# is not open yet.
	editor.debug_start_or_continue()
	var stopped := await _wait_until(func() -> bool:
		return _stopped_at(manager, helper_path, HELPER_BREAKPOINT)
	, 15.0)
	_check(stopped, "Continue hits the breakpoint in the second file")
	if !stopped:
		return

	var document = editor.documents.active_document()
	_check(document != null and Paths.same_file(str(document.path), helper_path),
		"the editor opens the stopped file")
	var view = editor.active_view
	_check(view != null and Paths.same_file(str(view.document.path), helper_path),
		"the stopped file is the active tab")
	if view != null:
		_check(view.debug_mark_at(HELPER_BREAKPOINT) == "execution",
			"the execution marker is in the opened file")
		_check(int(view.get_caret_line()) == HELPER_BREAKPOINT,
			"the caret lands on the stopped line")

	var frames: Array = manager.frame_items()
	_check(frames.size() >= 2, "the call stack shows the callee and its caller")
	if frames.size() >= 2:
		_check(str(frames[1].get("name", "")) == "main", "the caller frame is main")

	await _wait(0.5)
	var panel = editor.debug_panel
	_check(panel._stack_list != null and panel._stack_list.item_count >= 2,
		"the panel lists both frames")

	editor.debug_step_out()
	var back := await _wait_until(func() -> bool:
		return _stopped_at(manager, target_path, HELPER_CALL_LINE)
	, 12.0)
	if !back:
		print("STEP  after cross-file stepOut: " + _top_location(manager))
	_check(back, "Step Out returns to the caller after the cross-file stop")
	_check(editor.active_view != null and Paths.same_file(str(editor.active_view.document.path), target_path),
		"the editor switches back to the caller file")


func _test_step_out_and_termination() -> void:
	var manager = editor.dap_manager
	editor.debug_start_or_continue()
	var ended := await _wait_until(func() -> bool:
		return str(manager.state) == "idle"
	, 20.0)
	_check(ended, "Continue runs the program to termination")
	_check(!manager.is_active(), "the session is closed after termination")
	_check(manager.console_text().contains("terminated") or manager.console_text().contains("Debug session ended."),
		"the console reports the end of the session")

	var view = editor.active_view
	_check(view != null and view.debug_mark_at(LOOP_LINE) == "",
		"the execution marker is cleared when the session ends")


# ── STOP / SESSION STATE ────────────────────────────────────────────────────

func _test_stop_command() -> void:
	var manager = editor.dap_manager
	var view = editor.active_view
	editor.clear_all_breakpoints()
	await _wait(0.1)
	_check(manager.breakpoint_count() == 0, "Remove All Breakpoints empties the list")
	_check(view != null and view.debug_mark_at(MAIN_BREAKPOINT) == "",
		"removing all breakpoints repaints the gutter")

	if view != null:
		view.set_caret_line(LOOP_BODY_LINE)
		view.set_caret_column(0)
	editor.toggle_breakpoint_at_cursor()
	await _wait(0.1)
	_check(manager.has_breakpoint(target_path, LOOP_BODY_LINE), "F9 adds the breakpoint for the stop test")

	editor.debug_start_or_continue()
	var stopped := await _wait_until(func() -> bool:
		return _stopped_at(manager, target_path, LOOP_BODY_LINE)
	, 25.0)
	_check(stopped, "the second session stops at the loop breakpoint")
	if !stopped:
		return

	editor.debug_stop()
	var shut_down := await _wait_until(func() -> bool:
		return str(manager.state) == "idle"
	, 15.0)
	_check(shut_down, "Stop Debugging ends the session")
	_check(manager.client == null, "Stop Debugging releases the adapter")
	_check(editor.debug_panel._stop_button != null and editor.debug_panel._stop_button.disabled,
		"the Stop button is disabled once the session is gone")
	_check(view != null and view.debug_mark_at(LOOP_BODY_LINE) == "breakpoint",
		"the breakpoint dot returns when the pause ends")


func _test_session_state() -> void:
	var manager = editor.dap_manager
	var panel = editor.debug_panel
	manager.set_watches(["base + step"])
	panel.capture_session()
	var data: Dictionary = panel.capture_session()
	var captured_watches: Array = data.get("watches", [])
	var captured_breakpoints: Array = data.get("breakpoints", [])
	_check(bool(data.get("open", false)), "the panel captures whether it is open")
	_check(int(data.get("tab", -1)) >= 0, "the panel captures the selected tab")
	_check(captured_watches.has("base + step"), "the panel captures watches")
	_check(captured_breakpoints.size() == 1, "the panel captures breakpoints")
	_check(!captured_breakpoints.is_empty()
		and int(captured_breakpoints[0].get("line", -1)) == LOOP_BODY_LINE,
		"the captured breakpoint keeps its line")

	manager.clear_breakpoints()
	manager.set_watches([])
	manager.restore_session(data)
	_check(manager.breakpoint_lines(target_path) == [LOOP_BODY_LINE],
		"restoring the session brings breakpoints back")
	var restored_watches: Array = manager.watches
	_check(restored_watches.has("base + step"), "restoring the session brings watches back")

	var verbose_before: bool = manager.verbose_log
	manager.verbose_log = true
	var logging: Dictionary = manager.capture_session()
	manager.verbose_log = verbose_before
	_check(logging.get("verbose_log") == true, "the verbose log setting is part of the session state")


# ── HELPERS ─────────────────────────────────────────────────────────────────

func _check(condition: bool, label: String) -> void:
	checks += 1
	if condition:
		print("PASS  " + label)
	else:
		failures += 1
		print("FAIL  " + label)


func _stopped_at(manager, path: String, line: int) -> bool:
	if str(manager.state) != "stopped" or manager.stack.is_empty():
		return false
	var frame: Dictionary = manager.stack[0]
	if !Paths.same_file(str(frame.get("path", "")), path):
		return false
	return int(frame.get("line", 0)) - 1 == line


func _top_location(manager) -> String:
	if manager.stack.is_empty():
		return "state=%s no stack" % str(manager.state)
	var frame: Dictionary = manager.stack[0]
	return "%s:%d state=%s reason=%s" % [
		str(frame.get("path", "")).get_file(), int(frame.get("line", 0)) - 1,
		str(manager.state), str(manager.stop_reason),
	]


func _variable_values(manager) -> Dictionary:
	var values: Dictionary = {}
	for scope in manager.scope_items():
		if !(scope is Dictionary):
			continue
		var reference := int(scope.get("variables_reference", 0))
		for row in manager.variables_for(reference):
			if row is Dictionary:
				values[str(row.get("name", ""))] = str(row.get("value", ""))
	return values


func _variable_names(manager) -> Array:
	var names: Array = []
	for scope in manager.scope_items():
		if !(scope is Dictionary):
			continue
		var reference := int(scope.get("variables_reference", 0))
		for row in manager.variables_for(reference):
			if row is Dictionary:
				names.append(str(row.get("name", "")))
	return names


func _has_variables(manager, wanted: Array) -> bool:
	var names: Array = _variable_names(manager)
	for name in wanted:
		if !names.has(str(name)):
			return false
	return true


func _tree_contains(tree, needle: String) -> bool:
	if tree == null:
		return false
	var root = tree.get_root()
	return _item_contains(root, needle)


func _item_contains(item, needle: String) -> bool:
	if item == null:
		return false
	if str(item.get_text(0)).contains(needle) or str(item.get_text(1)).contains(needle):
		return true
	var child = item.get_first_child()
	while child != null:
		if _item_contains(child, needle):
			return true
		child = child.get_next()
	return false


func _dump_debug_state() -> void:
	print("---- debug state ----")
	var manager = editor.dap_manager if editor != null else null
	if manager != null:
		print("state: " + str(manager.state))
		print("status: " + manager.status_text())
		print("last_error: " + str(manager.last_error))
		print("breakpoints: " + str(manager.all_breakpoints()))
		print("stack: " + str(manager.stack))
		print("---- console ----")
		print(manager.console_text())
	if editor != null and editor.debug_panel != null:
		editor.debug_panel.visible = true
		editor.debug_panel._render()


func _wait_frames(count: int) -> void:
	for i in range(count):
		await process_frame


func _wait(seconds: float) -> void:
	await create_timer(seconds).timeout


func _wait_until(predicate: Callable, timeout_seconds: float = 10.0) -> bool:
	var deadline := Time.get_ticks_msec() + int(timeout_seconds * 1000.0)
	while Time.get_ticks_msec() < deadline:
		if predicate.call():
			return true
		await create_timer(0.02).timeout
	return predicate.call()


func _finish(code: int) -> void:
	if editor != null and is_instance_valid(editor):
		if editor.dap_manager != null:
			editor.dap_manager.shutdown()
		if editor.lsp_manager != null:
			editor.lsp_manager.shutdown()
		if editor.terminal != null:
			editor.terminal.shutdown()
		editor.queue_free()
		await _wait_frames(4)
		editor = null

	if created_workspace and !keep_workspace:
		_remove_dir(workspace_path)

	print("")
	if skipped:
		print("DAP end-to-end run skipped.")
	elif failures == 0:
		print("All DAP end-to-end checks passed: %d checks." % checks)
	else:
		print("%d of %d DAP end-to-end checks failed." % [failures, checks])
	quit(code)


func _remove_dir(path: String) -> void:
	var dir := DirAccess.open(path)
	if dir == null:
		return
	for file in dir.get_files():
		DirAccess.remove_absolute(path.path_join(file))
	for folder in dir.get_directories():
		_remove_dir(path.path_join(folder))
	DirAccess.remove_absolute(path)
