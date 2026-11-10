extends "res://tests/support/test_case.gd"

const Session = preload("res://src/platform/session_service.gd")

const TEST_DIR := "user://tests_session"
const ROOT := "user://tests_session/project"

var service


func before_each() -> void:
	_remove_dir(TEST_DIR)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(ROOT))
	service = _new_service()


func after_each() -> void:
	_remove_dir(TEST_DIR)
	service = null


func _new_service():
	var instance := Session.new()
	instance.session_path = TEST_DIR.path_join("session.json")
	instance.backup_dir = TEST_DIR.path_join("backups")
	instance.lock_path = TEST_DIR.path_join("session.lock")
	return instance


func _remove_dir(path: String) -> void:
	var global_path := ProjectSettings.globalize_path(path)
	var dir := DirAccess.open(global_path)
	if dir == null:
		return
	for file_name in dir.get_files():
		DirAccess.remove_absolute(global_path.path_join(file_name))
	for directory_name in dir.get_directories():
		_remove_dir(path.path_join(directory_name))
	DirAccess.remove_absolute(global_path)


func _write(path: String, content: String) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(content)


func _snapshot() -> Dictionary:
	return {
		"workspace_root": ROOT,
		"active_index": 1,
		"documents": [
			{
				"path": ROOT.path_join("alpha.gd"),
				"title": "alpha.gd",
				"untitled": false,
				"modified": true,
				"text": "changed on screen",
				"caret_line": 3,
				"caret_column": 7,
				"scroll_vertical": 12,
				"scroll_horizontal": 2,
				"has_selection": true,
				"selection_from_line": 1,
				"selection_from_column": 0,
				"selection_to_line": 2,
				"selection_to_column": 4,
			},
			{
				"path": "",
				"title": "Scratch",
				"untitled": true,
				"modified": true,
				"text": "note to self",
				"caret_line": 0,
				"caret_column": 4,
			},
			{
				"path": ROOT.path_join("beta.txt"),
				"title": "beta.txt",
				"untitled": false,
				"modified": false,
			},
		],
		"terminal": {
			"open": true,
			"active_index": 1,
			"entries": [
				{"title": "Terminal 1", "start_cwd": ROOT},
				{"title": "Terminal 2", "start_cwd": ROOT.path_join("src")},
			],
		},
		"panels": {
			"file_tree": true,
			"search": false,
			"terminal": true,
		},
	}


func test_begin_session_detects_a_stale_lock() -> void:
	var first: Dictionary = service.begin_session()
	assert_eq(first.get("ok"), true)
	assert_eq(first.get("recovered"), false)
	assert_true(FileAccess.file_exists(service.lock_path))

	var second = _new_service()
	var result: Dictionary = second.begin_session()
	assert_eq(result.get("recovered"), true)
	assert_eq(second.unclean, true)


func test_finish_session_saves_and_releases_the_lock() -> void:
	service.begin_session()
	var result: Dictionary = service.finish_session(_snapshot())

	assert_eq(result.get("ok"), true)
	assert_true(FileAccess.file_exists(service.session_path))
	assert_false(FileAccess.file_exists(service.lock_path))


func test_save_writes_backups_and_load_restores_them() -> void:
	service.begin_session()
	var saved: Dictionary = service.save_session(_snapshot())
	assert_eq(saved.get("ok"), true)
	assert_eq(saved.get("backups_written"), 2)

	var raw: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(service.session_path))
	assert_eq(raw.get("version"), Session.VERSION)
	assert_eq(raw.get("workspace_root"), ROOT)
	assert_eq(raw.get("active_index"), 1)
	assert_eq(raw.get("documents").size(), 3)
	assert_false(raw.get("documents")[0].has("text"), "buffer text belongs in a backup file")

	var loaded = _new_service()
	var result: Dictionary = loaded.load_session()
	assert_eq(result.get("ok"), true)

	var data: Dictionary = result.get("data")
	assert_eq(data.get("workspace_root"), ROOT)
	assert_eq(data.get("active_index"), 1)

	var documents: Array = data.get("documents")
	assert_eq(documents[0].get("text"), "changed on screen")
	assert_eq(documents[0].get("modified"), true)
	assert_eq(documents[0].get("caret_line"), 3)
	assert_eq(documents[0].get("scroll_vertical"), 12)
	assert_eq(documents[0].get("has_selection"), true)
	assert_eq(documents[1].get("text"), "note to self")
	assert_eq(documents[1].get("untitled"), true)
	assert_false(documents[2].has("text"))

	assert_eq(data.get("terminal").get("open"), true)
	assert_eq(data.get("terminal").get("entries")[1].get("start_cwd"), ROOT.path_join("src"))
	assert_eq(data.get("panels").get("file_tree"), true)


func test_clean_documents_do_not_get_a_backup() -> void:
	service.begin_session()
	service.save_session(_snapshot())

	var raw: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(service.session_path))
	var documents: Array = raw.get("documents")
	assert_eq(documents[2].get("backup"), "")


func test_debug_breakpoints_watches_and_panel_state_round_trip() -> void:
	var snapshot := _snapshot()
	snapshot["panels"]["debug"] = true
	snapshot["debug"] = {
		"open": true,
		"tab": 1,
		"verbose_log": true,
		"watches": ["total", "total", "  ", 7, "items[0]"],
		"breakpoints": [
			{"path": ROOT.path_join("main.py"), "line": 4, "condition": " i == 2 "},
			{"path": ROOT.path_join("main.py"), "line": 4, "condition": "duplicate"},
			{"path": "", "line": 1},
			{"path": ROOT.path_join("bad.py"), "line": -1},
			"not a breakpoint",
		],
	}

	service.begin_session()
	service.save_session(snapshot)

	var loaded = _new_service()
	var result: Dictionary = loaded.load_session()
	assert_eq(result.get("ok"), true)
	var debug: Dictionary = result.get("data").get("debug")

	assert_eq(debug.get("open"), true)
	assert_eq(debug.get("tab"), 1)
	assert_eq(debug.get("verbose_log"), true)
	assert_eq(debug.get("watches"), ["total", "items[0]"], "duplicates and non-strings are dropped")

	var breakpoints: Array = debug.get("breakpoints")
	assert_eq(breakpoints.size(), 1, "a line is stored once per file")
	assert_eq(breakpoints[0].get("line"), 4)
	assert_eq(breakpoints[0].get("condition"), "i == 2", "conditions are trimmed on save")
	assert_eq(result.get("data").get("panels").get("debug"), true)


func test_a_malformed_debug_block_degrades_to_defaults() -> void:
	var snapshot := _snapshot()
	snapshot["debug"] = {"tab": 99, "watches": "total", "breakpoints": "main.py"}

	service.begin_session()
	service.save_session(snapshot)

	var result: Dictionary = _new_service().load_session()
	var debug: Dictionary = result.get("data").get("debug")
	assert_eq(debug.get("open"), false)
	assert_eq(debug.get("tab"), 1, "the tab index is clamped to the two real tabs")
	assert_eq(debug.get("watches"), [])
	assert_eq(debug.get("breakpoints"), [])
	assert_eq(debug.get("verbose_log"), false)


func test_a_missing_backup_is_reported_without_crashing() -> void:
	service.begin_session()
	service.save_session(_snapshot())

	var raw: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(service.session_path))
	var backup_name := str(raw.get("documents")[0].get("backup"))
	assert_true(!backup_name.is_empty())
	DirAccess.remove_absolute(ProjectSettings.globalize_path(service.backup_dir.path_join(backup_name)))

	var loaded = _new_service()
	var result: Dictionary = loaded.load_session()
	var document: Dictionary = result.get("data").get("documents")[0]

	assert_eq(document.get("backup_missing"), true)
	assert_false(document.has("text"))


func test_orphan_backups_are_cleaned_up() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(service.backup_dir))
	_write(service.backup_dir.path_join("buffer_999_orphan.bak"), "old")

	service.begin_session()
	service.save_session(_snapshot())

	assert_false(FileAccess.file_exists(service.backup_dir.path_join("buffer_999_orphan.bak")))
	assert_eq(DirAccess.open(service.backup_dir).get_files().size(), 2)


func test_clear_session_removes_everything() -> void:
	service.begin_session()
	service.save_session(_snapshot())

	service.clear_session()

	assert_false(FileAccess.file_exists(service.session_path))
	assert_false(FileAccess.file_exists(service.lock_path))
	assert_false(FileAccess.file_exists(service.backup_dir.path_join("buffer_000_any.bak")))


func test_malformed_session_json_is_reported() -> void:
	_write(service.session_path, "{not json")

	var result: Dictionary = service.load_session()
	assert_eq(result.get("ok"), false)
	assert_true(str(result.get("error", "")).length() > 0)


func test_saved_state_sanitizes_counters_and_paths() -> void:
	service.begin_session()
	var snapshot := _snapshot()
	snapshot["active_index"] = 99
	snapshot["documents"][0]["caret_line"] = -4
	snapshot["documents"][0]["scroll_vertical"] = -1
	service.save_session(snapshot)

	var raw: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(service.session_path))
	assert_eq(raw.get("active_index"), 2)
	assert_eq(raw.get("documents")[0].get("caret_line"), 0)
	assert_eq(raw.get("documents")[0].get("scroll_vertical"), 0)
