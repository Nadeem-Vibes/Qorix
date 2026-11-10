extends "res://tests/support/test_case.gd"

## Manager behavior that does not need a live server: diagnostics ownership,
## problem ordering, workspace edits and server/install rows. The live
## round-trip is covered by tests/integration/lsp_e2e_runner.gd.

const LspText = preload("res://src/features/lsp/lsp_text.gd")
const LspConfig = preload("res://src/features/lsp/lsp_config.gd")

const TEST_DIR := "user://tests_lsp_manager"


class ClientStub:
	var key: String = ""


class DocumentStub:
	var path: String = ""
	var language_override: String = ""
	var language_highlight: String = ""


class DocumentsStub:
	var active = null

	func active_document():
		return active


class EditorStub:
	var documents = null
	var workspace = null
	var file_tree = null
	var warnings: Array = []

	func warn(message: String) -> void:
		warnings.append(message)


func before_each() -> void:
	_remove_dir(TEST_DIR)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(TEST_DIR))


func after_each() -> void:
	_remove_dir(TEST_DIR)


func _remove_dir(path: String) -> void:
	var global := ProjectSettings.globalize_path(path)
	var dir := DirAccess.open(global)
	if dir == null:
		return
	for file in dir.get_files():
		DirAccess.remove_absolute(global.path_join(file))
	for folder in dir.get_directories():
		_remove_dir(path.path_join(folder))
	DirAccess.remove_absolute(global)


func _manager(editor = null):
	var script = load("res://src/features/lsp/lsp_manager.gd")
	var manager = script.new()
	manager.editor = editor
	return manager


func _config(found: Array[String] = []) -> LspConfig:
	var config = LspConfig.new("windows", "C:/bin", ".EXE", func(path: String) -> bool:
		return FileAccess.file_exists(path)
	)
	config.executable_resolver = func(command: String) -> String:
		return "C:/tools/" + command if found.has(command) else ""
	return config


func _uri(path: String) -> String:
	return LspText.path_to_uri(ProjectSettings.globalize_path(path))


func _write(path: String, text: String) -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(path.get_base_dir()))
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(text)
	file = null


func _diagnostic(line: int, severity: int, message: String, source: String = "Fake") -> Dictionary:
	return LspText.normalize_diagnostic({
		"range": {
			"start": {"line": line, "character": 0},
			"end": {"line": line, "character": 4},
		},
		"severity": severity,
		"message": message,
		"source": source,
	})


# ── DIAGNOSTICS ─────────────────────────────────────────────────────────────

func test_publish_diagnostics_is_scoped_to_its_client_and_uri() -> void:
	var manager = _manager()
	var uri := "file:///C:/project/a.py"
	manager._doc_states[uri] = {"key": "python|C:/project", "path": "C:/project/a.py"}

	var client := ClientStub.new()
	client.key = "python|C:/project"
	var changed: Array = []
	manager.diagnostics_updated.connect(func() -> void: changed.append(true))

	manager._on_client_diagnostics(client, {
		"uri": uri,
		"diagnostics": [{"range": {"start": {"line": 2}}, "message": "bad", "severity": 1}],
	})

	assert_eq(manager.diagnostics_for_uri(uri).size(), 1)
	assert_eq(manager.problem_counts().get("error"), 1)
	assert_eq(manager.problem_counts().get("total"), 1)
	assert_eq(changed.size(), 1)

	# A late publish from an old server instance must not resurrect problems.
	client.key = "python|C:/other"
	manager._on_client_diagnostics(client, {"uri": uri, "diagnostics": []})
	assert_eq(manager.diagnostics_for_uri(uri).size(), 1)

	manager.free()


func test_publish_diagnostics_resolves_an_equivalent_uri_by_path() -> void:
	var manager = _manager()
	var state_uri := "file:///C:/project/a%2Eb.py"
	manager._doc_states[state_uri] = {
		"uri": state_uri,
		"key": "python|C:/project",
		"path": "C:/project/a.b.py",
	}
	var client := ClientStub.new()
	client.key = "python|C:/project"

	# A server may normalize percent escapes differently from path_to_uri().
	manager._on_client_diagnostics(client, {
		"uri": "file:///C:/project/a.b.py",
		"diagnostics": [{"range": {"start": {"line": 2}}, "message": "bad", "severity": 1}],
	})

	assert_eq(manager.diagnostics_for_uri(state_uri).size(), 1)
	assert_eq(manager.problem_counts().get("error"), 1)
	manager.free()


func test_diagnostics_are_cleared_when_a_server_stops() -> void:
	var manager = _manager()
	var first := "file:///C:/project/a.py"
	var second := "file:///C:/project/b.py"
	manager._doc_states[first] = {"key": "python|root", "path": "C:/project/a.py"}
	manager._doc_states[second] = {"key": "rust|root", "path": "C:/project/b.py"}
	manager._diagnostics[first] = [_diagnostic(0, 1, "python error")]
	manager._diagnostics[second] = [_diagnostic(1, 2, "rust warning")]

	manager._clear_diagnostics_for_key("python|root")

	assert_true(manager.diagnostics_for_uri(first).is_empty())
	assert_eq(manager.diagnostics_for_uri(second).size(), 1)
	assert_eq(manager.problem_counts().get("warning"), 1)
	manager.free()


func test_problem_items_are_sorted_by_file_line_and_severity() -> void:
	var manager = _manager()
	var b_uri := "file:///C:/project/b.py"
	var a_uri := "file:///C:/project/a.py"
	manager._doc_states[a_uri] = {"key": "python|root", "path": "C:/project/a.py"}
	manager._doc_states[b_uri] = {"key": "python|root", "path": "C:/project/b.py"}
	manager._diagnostics[a_uri] = [
		_diagnostic(5, 2, "warning"),
		_diagnostic(5, 1, "error"),
	]
	manager._diagnostics[b_uri] = [_diagnostic(1, 3, "note")]

	var items: Array = manager.problem_items()

	assert_eq(items.size(), 3)
	assert_eq(items[0].get("file"), "a.py")
	assert_eq(items[0].get("severity_name"), "error")
	assert_eq(items[0].get("line"), 5)
	assert_eq(items[0].get("symbol"), "●")
	assert_eq(items[1].get("severity_name"), "warning")
	assert_eq(items[2].get("file"), "b.py")
	assert_true(str(items[2].get("label")).contains("Fake"))
	manager.free()


func test_diagnostics_cover_the_whole_multi_line_range() -> void:
	var manager = _manager()
	var uri := "file:///C:/project/a.py"
	manager._doc_states[uri] = {"key": "python|root", "path": "C:/project/a.py", "uri": uri}
	manager._diagnostics[uri] = [LspText.normalize_diagnostic({
		"range": {
			"start": {"line": 2, "character": 1},
			"end": {"line": 4, "character": 0},
		},
		"message": "multi-line",
	})]
	var document := DocumentStub.new()
	document.path = "C:/project/a.py"

	assert_eq(manager.problems_on_line(document, 1).size(), 0)
	assert_eq(manager.problems_on_line(document, 2).size(), 1)
	assert_eq(manager.problems_on_line(document, 4).size(), 1)
	assert_eq(manager.problems_on_line(document, 5).size(), 0)
	manager.free()


# ── MISSING SERVERS / RESTARTS ──────────────────────────────────────────────

func test_missing_server_is_reported_only_once() -> void:
	var manager = _manager()
	var notices: Array = []
	manager.missing_server.connect(func(help: Dictionary) -> void: notices.append(help))

	manager._notify_missing("python", {"title": "Install Python"}, {"command": "pyright-langserver", "display": "Python"})
	manager._notify_missing("python", {"title": "Install Python"}, {"command": "pyright-langserver", "display": "Python"})

	assert_eq(notices.size(), 1)
	assert_eq(notices[0].get("language"), "python")
	assert_eq(notices[0].get("executable"), "pyright-langserver")
	assert_true(manager.server_log().contains("Command not found"))
	manager.free()


func test_crash_restarts_are_capped_at_three_per_minute() -> void:
	var manager = _manager()
	manager._specs["python|root"] = {"profile": {"display": "Python"}}

	for i in range(4):
		manager._schedule_restart("python|root")

	assert_eq(manager._restart_timers.size(), 1)
	assert_true(manager.server_log().contains("Stopped after 3 crashes"))
	manager.free()


# ── SERVER / INSTALL ROWS ───────────────────────────────────────────────────

func test_server_rows_report_found_and_missing_commands() -> void:
	var manager = _manager()
	var config := _config(["present-server"])
	config.apply_config({
		"python": {"command": "present-server"},
		"rust": {"command": "missing-server"},
	})
	manager.config = config

	var rows: Array = manager.server_rows()
	var by_id := {}
	for row in rows:
		by_id[str(row.get("id", ""))] = row

	assert_true(by_id.has("python"))
	assert_true(by_id.has("rust"))
	assert_true(by_id["python"].get("found"))
	assert_eq(by_id["python"].get("command_path"), "C:/tools/present-server")
	assert_false(by_id["rust"].get("found"))
	manager.free()


func test_install_cards_appear_only_when_the_active_language_is_missing() -> void:
	var manager = _manager()
	var config := _config([])
	config.apply_config({"python": {"command": "missing-server"}})
	manager.config = config

	var document := DocumentStub.new()
	document.path = "C:/project/main.py"
	document.language_highlight = "python"
	var documents := DocumentsStub.new()
	documents.active = document
	var editor := EditorStub.new()
	editor.documents = documents
	manager.editor = editor

	var cards: Array = manager.install_cards()

	assert_eq(cards.size(), 1)
	assert_eq(cards[0].get("language"), "python")
	assert_eq(cards[0].get("executable"), "missing-server")
	assert_true(str(cards[0].get("title")).contains("Install"))
	manager.free()


func test_install_cards_are_empty_for_a_found_server_or_plain_text() -> void:
	var manager = _manager()
	var config := _config(["present-server"])
	config.apply_config({"python": {"command": "present-server"}})
	manager.config = config

	var document := DocumentStub.new()
	document.path = "C:/project/main.py"
	document.language_highlight = "python"
	var documents := DocumentsStub.new()
	documents.active = document
	var editor := EditorStub.new()
	editor.documents = documents
	manager.editor = editor

	assert_true(manager.install_cards().is_empty())

	document.path = "C:/project/notes.txt"
	document.language_highlight = "text"
	assert_true(manager.install_cards().is_empty())
	manager.free()


# ── WORKSPACE EDITS ────────────────────────────────────────────────────────

func test_workspace_edit_writes_files_that_are_not_open() -> void:
	var path := TEST_DIR.path_join("not_open.py")
	_write(path, "before = 1\nkeep = 2\n")
	var global := ProjectSettings.globalize_path(path)
	var manager = _manager(EditorStub.new())

	var normalized := LspText.normalize_workspace_edit({"changes": {
		_uri(path): [{
			"range": {
				"start": {"line": 0, "character": 0},
				"end": {"line": 0, "character": 6},
			},
			"newText": "after",
		}],
	}})
	manager._apply_workspace_edit_now(normalized)

	assert_eq(FileAccess.get_file_as_string(global), "after = 1\nkeep = 2\n")
	assert_true(str(manager.editor.warnings[0]).contains("Applied edits to 1 file"))
	manager.free()


func test_workspace_edit_reports_missing_files_without_stopping_others() -> void:
	var good := TEST_DIR.path_join("good.py")
	_write(good, "abc\n")
	var manager = _manager(EditorStub.new())
	var edit := {"changes": {
		_uri(good): [_edit(0, 0, 0, 1, "A")],
		_uri(TEST_DIR.path_join("missing.py")): [_edit(0, 0, 0, 1, "B")],
	}}
	var normalized := LspText.normalize_workspace_edit(edit)

	manager._apply_workspace_edit_now(normalized)

	assert_eq(FileAccess.get_file_as_string(ProjectSettings.globalize_path(good)), "Abc\n")
	assert_true(str(manager.editor.warnings[0]).contains("missing.py does not exist"))
	manager.free()


func test_edit_lines_are_unique_and_sorted_for_the_preview() -> void:
	var manager = _manager()
	var lines: Array = manager._edit_lines([
		_edit(8, 0, 8, 1, "x"),
		_edit(2, 0, 2, 1, "x"),
		_edit(8, 3, 8, 4, "x"),
	])

	assert_eq(lines, [2, 8])
	manager.free()


func _edit(line: int, character: int, end_line: int, end_character: int, text: String) -> Dictionary:
	return {
		"range": {
			"start": {"line": line, "character": character},
			"end": {"line": end_line, "character": end_character},
		},
		"newText": text,
	}
