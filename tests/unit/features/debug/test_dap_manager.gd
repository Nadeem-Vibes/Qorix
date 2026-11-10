extends "res://tests/support/test_case.gd"

## Manager behavior that does not launch an adapter: breakpoint bookkeeping,
## pause state, stack/scopes/variables presentation, watches, console and the
## persisted session fields. The live protocol round-trip is covered by
## tests/integration/dap_e2e_runner.gd.

const DapManager = preload("res://src/features/debug/dap_manager.gd")
const DapConfig = preload("res://src/features/debug/dap_config.gd")


class DocumentStub:
	var path: String = ""
	var untitled: bool = false
	var language_override: String = ""
	var language_highlight: String = ""
	var view = null


class DocumentsStub:
	var active = null

	func active_document():
		return active


class EditorStub:
	var documents = DocumentsStub.new()
	var warnings: Array = []
	var save_calls: int = 0
	var save_ok: bool = true

	func warn(message: String) -> void:
		warnings.append(message)

	func save_all_for_debug() -> Dictionary:
		save_calls += 1
		return {"ok": save_ok, "error": "" if save_ok else "Could not save."}


var managers: Array = []


func before_each() -> void:
	managers.clear()


func after_each() -> void:
	for manager in managers:
		if is_instance_valid(manager):
			manager.free()
	managers.clear()


func _manager() -> Node:
	var manager = DapManager.new()
	manager.editor = EditorStub.new()
	managers.append(manager)
	return manager


func _exists(path: String) -> bool:
	var normalized := path.replace("\\", "/").to_lower()
	return normalized in ["c:/fake/bin/python.exe"]


func _python_manager() -> Node:
	var manager = _manager()
	manager.config = DapConfig.new("windows", "C:/fake/bin", ".EXE", Callable(self, "_exists"))
	return manager


# ── BREAKPOINTS ─────────────────────────────────────────────────────────────

func test_a_file_can_hold_several_sorted_breakpoints() -> void:
	var manager = _manager()
	assert_eq(manager.add_breakpoint("C:/p/main.py", 8), true)
	assert_eq(manager.add_breakpoint("C:/p/main.py", 2), true)
	assert_eq(manager.add_breakpoint("C:/p/main.py", 5), true)

	assert_eq(manager.breakpoint_count(), 3)
	assert_eq(manager.breakpoint_lines("C:/p/main.py"), [2, 5, 8])
	assert_true(manager.has_breakpoint("C:/p/main.py", 5))
	assert_false(manager.has_breakpoint("C:/p/main.py", 6))
	assert_eq(manager.breakpoints_for_path("C:/p/main.py").size(), 3)


func test_adding_the_same_line_updates_its_condition() -> void:
	var manager = _manager()
	manager.add_breakpoint("C:/p/main.py", 4)
	manager.add_breakpoint("C:/p/main.py", 4, " i == 2 ")

	assert_eq(manager.breakpoint_count(), 1)
	var rows: Array = manager.breakpoints_for_path("C:/p/main.py")
	assert_eq(rows[0].get("condition"), " i == 2 ", "the condition is stored verbatim; setBreakpoints trims it")


func test_removing_one_breakpoint_keeps_the_others() -> void:
	var manager = _manager()
	manager.add_breakpoint("C:/p/main.py", 1)
	manager.add_breakpoint("C:/p/main.py", 7)
	manager.remove_breakpoint("C:/p/main.py", 1)

	assert_eq(manager.breakpoint_lines("C:/p/main.py"), [7])
	assert_eq(manager.breakpoint_count(), 1)

	manager.remove_breakpoint("C:/p/main.py", 7)
	assert_eq(manager.breakpoint_count(), 0)
	assert_eq(manager.breakpoints_for_path("C:/p/main.py"), [])


func test_toggle_adds_then_removes_one_line() -> void:
	var manager = _manager()
	assert_eq(manager.toggle_breakpoint("C:/p/main.py", 3), true)
	assert_eq(manager.has_breakpoint("C:/p/main.py", 3), true)
	assert_eq(manager.toggle_breakpoint("C:/p/main.py", 3), false)
	assert_eq(manager.has_breakpoint("C:/p/main.py", 3), false)


func test_breakpoint_paths_fold_case_on_windows() -> void:
	if OS.get_name() != "Windows":
		return
	var manager = _manager()
	manager.add_breakpoint("C:/Project/Main.py", 2)
	assert_true(manager.has_breakpoint("c:/project/main.py", 2))
	assert_eq(manager.breakpoint_lines("C:\\Project\\Main.py"), [2], "separators and case fold to one key")


func test_breakpoint_queries_return_copies() -> void:
	var manager = _manager()
	manager.add_breakpoint("C:/p/main.py", 2)
	var rows: Array = manager.breakpoints_for_path("C:/p/main.py")
	rows[0]["verified"] = true
	assert_eq(manager.breakpoints_for_path("C:/p/main.py")[0].get("verified"), false)
	assert_eq(manager.all_breakpoints().size(), 1)


func test_a_breakpoint_response_marks_the_matching_line() -> void:
	var manager = _manager()
	manager.add_breakpoint("C:/p/main.py", 5)
	manager._on_set_breakpoints_response({
		"ok": true,
		"body": {"breakpoints": [{"verified": true, "id": 12, "line": 6}]},
	}, manager._breakpoint_key("C:/p/main.py"), [5])

	var row: Dictionary = manager.breakpoints_for_path("C:/p/main.py")[0]
	assert_eq(row.get("verified"), true)
	assert_eq(row.get("id"), 12)
	assert_eq(row.get("actual_line"), 5)

	manager._on_set_breakpoints_response({
		"ok": false, "error": "no source",
	}, manager._breakpoint_key("C:/p/main.py"), [5])
	row = manager.breakpoints_for_path("C:/p/main.py")[0]
	assert_eq(row.get("verified"), false)
	assert_eq(row.get("message"), "no source")


func test_a_breakpoint_event_updates_verification_by_id() -> void:
	var manager = _manager()
	manager.add_breakpoint("C:/p/main.py", 4)
	var key: String = manager._breakpoint_key("C:/p/main.py")
	manager.breakpoints[key][0]["id"] = 33

	manager._on_breakpoint_event({"breakpoint": {"id": 33, "verified": true, "line": 4, "message": "ok"}})
	var row: Dictionary = manager.breakpoints_for_path("C:/p/main.py")[0]
	assert_eq(row.get("verified"), true)
	assert_eq(row.get("message"), "ok")


func test_clearing_breakpoints_removes_every_file() -> void:
	var manager = _manager()
	manager.add_breakpoint("C:/p/a.py", 1)
	manager.add_breakpoint("C:/p/b.py", 2)
	manager.clear_breakpoints()
	assert_eq(manager.breakpoint_count(), 0)
	assert_eq(manager.all_breakpoints(), [])


# ── SESSION STATE ───────────────────────────────────────────────────────────

func test_capture_and_restore_keep_watches_breakpoints_and_logging() -> void:
	var manager = _manager()
	manager.add_breakpoint("C:/p/main.py", 5, "i > 1")
	manager.add_watch("total")
	manager.verbose_log = true

	var data: Dictionary = manager.capture_session()
	assert_eq(data.get("watches"), ["total"])
	assert_eq((data.get("breakpoints") as Array).size(), 1)
	assert_eq(data.get("verbose_log"), true)

	var restored = _manager()
	restored.restore_session(data)
	assert_eq(restored.watches, ["total"])
	assert_eq(restored.breakpoint_lines("C:/p/main.py"), [5])
	assert_eq(restored.breakpoints_for_path("C:/p/main.py")[0].get("condition"), "i > 1")
	assert_eq(restored.verbose_log, true)


func test_restore_rejects_bad_breakpoints_and_duplicate_watches() -> void:
	var manager = _manager()
	manager.restore_session({
		"watches": ["x", "x", "  ", "y"],
		"breakpoints": [
			{"path": "C:/p/main.py", "line": 3},
			{"path": "C:/p/main.py", "line": 3, "condition": "duplicate"},
			{"path": "", "line": 2},
			{"path": "C:/p/main.py", "line": -1},
		],
	})

	assert_eq(manager.watches, ["x", "y"])
	assert_eq(manager.breakpoint_count(), 1)
	assert_eq(manager.breakpoint_lines("C:/p/main.py"), [3])


# ── PAUSE / STACK ───────────────────────────────────────────────────────────

func test_status_text_names_the_paused_file_and_reason() -> void:
	var manager = _manager()
	manager.state = "idle"
	assert_eq(manager.status_text(), "Ready")

	manager.state = "starting"
	manager.adapter_display = "Python (debugpy)"
	assert_eq(manager.status_text(), "Starting Python (debugpy)…")

	manager.state = "stopped"
	manager.program_path = "C:/p/main.py"
	manager._execution_path = "C:/p/sub.py"
	manager._execution_line = 6
	manager.stop_reason = "breakpoint"
	var text: String = manager.status_text()
	assert_true(text.contains("Paused (breakpoint)"))
	assert_true(text.contains("sub.py:7"))


func test_stopped_event_records_thread_and_clears_the_previous_pause() -> void:
	var manager = _manager()
	manager.state = "running"
	manager.stack = [{"id": 1, "name": "old", "path": "C:/p/old.py", "line": 1}]
	manager.scopes = [{"name": "Locals", "variables_reference": 9}]
	manager._variables = {9: [{"name": "old"}]}

	manager._on_stopped_event({"reason": "breakpoint", "threadId": 4, "description": "hit"})

	assert_eq(manager.state, "stopped")
	assert_eq(manager.thread_id, 4)
	assert_eq(manager.stop_reason, "breakpoint")
	assert_eq(manager.stop_description, "hit")
	assert_eq(manager.stack, [])
	assert_eq(manager.scopes, [])
	assert_eq(manager.variables_for(9), [], "pause-local variables are dropped for the new stop")


func test_the_top_frame_drives_the_execution_marker() -> void:
	var manager = _manager()
	manager.state = "stopped"
	manager.stack = [{
		"id": 11, "name": "main", "path": "C:/p/main.py", "line": 7, "column": 5,
	}]
	var execution: Array = []
	manager.execution_line_changed.connect(func(path: String, line: int) -> void:
		execution.append([path, line])
	)

	manager._show_frame(0, true)

	assert_eq(manager.selected_frame, 0)
	assert_eq(execution.size(), 1)
	assert_eq(execution[0], ["C:/p/main.py", 6], "editor lines are zero-based")
	assert_eq(manager._execution_path, "C:/p/main.py")
	assert_eq(manager._execution_line, 6)

	manager._clear_pause(true)
	assert_eq(execution.size(), 2)
	assert_eq(execution[1], ["", -1], "leaving the pause clears the marker")


func test_frame_items_and_scope_items_present_manager_state() -> void:
	var manager = _manager()
	manager.stack = [
		{"id": 1, "name": "main", "path": "C:/p/main.py", "line": 9, "column": 1},
		{"id": 2, "name": "helper", "path": "C:/p/lib.py", "line": 3, "column": 2},
	]
	manager.selected_frame = 1
	manager.scopes = [{"name": "Locals", "variables_reference": 10, "expensive": false}]
	manager._variables = {10: [{
		"name": "total", "value": "3", "type": "int",
		"evaluate_name": "total", "variables_reference": 0, "indexed": 0, "named": 0,
	}]}

	var frames: Array = manager.frame_items()
	assert_eq(frames.size(), 2)
	assert_eq(frames[0].get("file"), "main.py")
	assert_eq(frames[0].get("selected"), false)
	assert_eq(frames[1].get("selected"), true)

	var scopes: Array = manager.scope_items()
	assert_eq(scopes[0].get("name"), "Locals")
	var variables: Array = manager.variables_for(10)
	assert_eq(variables[0].get("name"), "total")
	assert_eq(variables[0].get("value"), "3")
	assert_eq(manager.variables_for(999), [])


func test_session_info_reports_the_active_adapter() -> void:
	var manager = _manager()
	manager.state = "running"
	manager.adapter_id = "python"
	manager.adapter_display = "Python (debugpy)"
	manager.program_path = "C:/p/main.py"
	manager.capabilities = {"supportsConfigurationDoneRequest": true}

	var info: Dictionary = manager.session_info()
	assert_eq(info.get("active"), true)
	assert_eq(info.get("state"), "running")
	assert_eq(info.get("adapter_id"), "python")
	assert_eq(info.get("program"), "C:/p/main.py")
	assert_true(info.get("status").contains("Running"))
	assert_eq(info.get("capabilities").get("supportsConfigurationDoneRequest"), true)


func test_supports_reads_capabilities_with_a_fallback() -> void:
	var manager = _manager()
	assert_eq(manager.supports("supportsConfigurationDoneRequest", true), true)
	manager.capabilities = {"supportsConfigurationDoneRequest": false}
	assert_eq(manager.supports("supportsConfigurationDoneRequest", true), false)
	assert_eq(manager.supports("supportsEvaluateForHovers", true), true)


# ── WATCHES / CONSOLE ───────────────────────────────────────────────────────

func test_watches_are_unique_and_capped() -> void:
	var manager = _manager()
	assert_eq(manager.add_watch("  total  "), true)
	assert_eq(manager.add_watch("total"), false, "the expression is trimmed before the duplicate check")
	assert_eq(manager.watches, ["total"])

	for index in range(25):
		manager.add_watch("value_%d" % index)
	assert_eq(manager.watches.size(), manager.MAX_WATCHES)
	assert_eq(manager.watches[manager.watches.size() - 1], "value_24", "the newest watch replaces the oldest")

	var items: Array = manager.watch_items()
	assert_eq(items.size(), manager.MAX_WATCHES)
	assert_eq(items[0].get("expression"), "total")
	assert_eq(items[0].get("pending"), true)


func test_remove_and_replace_the_watch_list() -> void:
	var manager = _manager()
	manager.add_watch("a")
	manager.add_watch("b")
	manager.remove_watch(0)
	assert_eq(manager.watches, ["b"])

	manager.set_watches(["x", "x", "y", ""])
	assert_eq(manager.watches, ["x", "y"])


func test_console_entries_append_coalesce_and_clear() -> void:
	var manager = _manager()
	manager._log_console("system", "hello")
	manager._append_output("first", "output")
	manager._append_output(" second", "output")

	var entries: Array = manager.console_entries_copy()
	assert_eq(entries.size(), 2, "adjacent program output coalesces")
	assert_eq(entries[0].get("kind"), "system")
	assert_eq(entries[1].get("text"), "first second")
	assert_true(manager.console_text().contains("hello"))

	manager.clear_console()
	assert_eq(manager.console_entries_copy(), [])


func test_evaluate_refuses_to_run_without_a_pause() -> void:
	var manager = _manager()
	assert_eq(manager.evaluate("1 + 1"), -1)
	assert_true(manager.console_text().contains("Start a debug session"))

	manager.state = "running"
	manager.client = null
	assert_eq(manager.evaluate("1 + 1"), -1)
	assert_true(manager.console_text().contains("Pause the program"))


func test_console_errors_become_the_last_error() -> void:
	var manager = _manager()
	manager._log_console("error", "adapter exploded")
	assert_eq(manager.last_error, "adapter exploded")


# ── START GUARDS ────────────────────────────────────────────────────────────

func test_starting_without_a_document_fails_cleanly() -> void:
	var manager = _python_manager()
	var editor = manager.editor

	var result: Dictionary = manager.start_debugging()
	assert_eq(result.get("ok"), false)
	assert_eq(manager.state, "idle")
	assert_true(str(result.get("error", "")).contains("Open a file"))
	assert_eq(editor.warnings.size(), 1)


func test_an_untitled_buffer_cannot_be_debugged() -> void:
	var manager = _python_manager()
	var document = DocumentStub.new()
	document.untitled = true
	document.path = ""
	manager.editor.documents.active = document

	var result: Dictionary = manager.start_debugging()
	assert_eq(result.get("ok"), false)
	assert_true(str(result.get("error", "")).contains("Save this buffer"))
	assert_eq(manager.state, "idle")


func test_a_second_start_is_rejected_while_active() -> void:
	var manager = _python_manager()
	manager.state = "running"
	var result: Dictionary = manager.start_debugging()
	assert_eq(result.get("ok"), false)
	assert_true(str(result.get("error", "")).contains("already active"))


func test_an_unexpected_failure_while_starting_shows_the_install_card() -> void:
	var manager = _python_manager()
	var helps: Array = []
	manager.missing_adapter.connect(func(help: Dictionary) -> void: helps.append(help))
	manager._resolved = {"install": {"title": "Python debugging needs debugpy"}}
	manager.state = "starting"

	manager._on_client_disconnected(null, true, "The adapter exited before it listened.")

	assert_eq(helps.size(), 1, "a start failure offers the install card")
	assert_eq(helps[0].get("title"), "Python debugging needs debugpy")
	assert_eq(manager.state, "idle")
	assert_true(manager.last_error.contains("before it listened"))


func test_a_crash_during_a_running_session_does_not_show_the_install_card() -> void:
	var manager = _python_manager()
	var helps: Array = []
	manager.missing_adapter.connect(func(help: Dictionary) -> void: helps.append(help))
	manager._resolved = {"install": {"title": "unused"}}
	manager.state = "running"

	manager._on_client_disconnected(null, true, "The adapter crashed.")

	assert_eq(helps.size(), 0, "a mid-session crash is not a missing adapter")
	assert_eq(manager.state, "idle")


func test_a_failed_pre_debug_save_prevents_the_launch() -> void:
	var manager = _python_manager()
	var path := ProjectSettings.globalize_path("user://tests_dap_manager/target.py")
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string("print('hi')\n")
	file = null

	var document = DocumentStub.new()
	document.path = path
	manager.editor.documents.active = document
	manager.editor.save_ok = false

	var result: Dictionary = manager.start_debugging()
	assert_eq(result.get("ok"), false)
	assert_true(str(result.get("error", "")).contains("Could not save"))
	assert_eq(manager.editor.save_calls, 1)
	assert_eq(manager.state, "idle")
	DirAccess.remove_absolute(path)


func test_a_missing_file_is_reported_before_a_client_starts() -> void:
	var manager = _python_manager()
	var document = DocumentStub.new()
	document.path = "C:/does/not/exist/target.py"
	manager.editor.documents.active = document

	var result: Dictionary = manager.start_debugging()
	assert_eq(result.get("ok"), false)
	assert_true(str(result.get("error", "")).contains("does not exist"))
	assert_true(manager.client == null)


func test_a_file_without_an_adapter_reports_the_supported_list() -> void:
	var manager = _python_manager()
	var path := ProjectSettings.globalize_path("user://tests_dap_manager/notes.txt")
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string("hello")
	file = null

	var document = DocumentStub.new()
	document.path = path
	manager.editor.documents.active = document

	var result: Dictionary = manager.start_debugging()
	assert_eq(result.get("ok"), false)
	assert_true(str(result.get("error", "")).contains("No debug adapter"))
	assert_true(str(result.get("error", "")).contains("Python"))
	assert_eq(manager.state, "idle")
	DirAccess.remove_absolute(path)
