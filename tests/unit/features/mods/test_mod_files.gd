extends "res://tests/support/test_case.gd"

## Phase 2 files API: containment, confirmation, quota-independent reads and
## the atomic write path. The workspace root is a temp folder, not a fixture, so
## the suite never touches the user's project.

const Files = preload("res://src/features/mods/mod_files.gd")
const Result = preload("res://src/features/mods/mod_result.gd")

const ROOT := "user://griddy_phase2/files"


class WorkspaceStub:
	var root: String = ""
	var open: bool = true

	func has_workspace() -> bool:
		return open

	func workspace_name() -> String:
		return root.get_file()


class EditorStub:
	var workspace = null

	func workspace_root_for_tools() -> String:
		if workspace != null and workspace.has_workspace():
			return workspace.root
		return ""


var workspace: WorkspaceStub
var editor: EditorStub
var files


func before_each() -> void:
	_clean(ROOT)
	_make_dir(ROOT)
	_write(ROOT.path_join("notes.txt"), "alpha\nbeta")
	_make_dir(ROOT.path_join("src"))
	_write(ROOT.path_join("src/main.gd"), "extends Node")
	_make_dir(ROOT.path_join("node_modules"))
	_write(ROOT.path_join("node_modules/ignored.js"), "ignored")

	workspace = WorkspaceStub.new()
	workspace.root = ROOT
	editor = EditorStub.new()
	editor.workspace = workspace
	files = Files.new(editor)


func after_each() -> void:
	files = null
	editor = null
	workspace = null
	_clean(ROOT)


func test_read_and_write_are_workspace_relative() -> void:
	var read: Dictionary = files.read({"path": "notes.txt"})
	assert_eq(Result.code_of(read), "")
	assert_eq(str(read.get("value", "")), "alpha\nbeta")

	var written: Dictionary = files.write({"path": "src/new.txt", "text": "hello"})
	check(written.get("ok", false), "write succeeds")
	assert_eq(FileAccess.get_file_as_string(ROOT.path_join("src/new.txt")), "hello")

	var reread: Dictionary = files.read({"path": "src/new.txt"})
	assert_eq(str(reread.get("value", "")), "hello")
	assert_false(FileAccess.file_exists(ROOT.path_join("src/new.txt") + ".griddy_tmp"), "temp file cleaned up")


func test_absolute_and_escaping_paths_are_rejected() -> void:
	for path in ["/etc/passwd", "C:/Windows/win.ini", "../outside.txt", "src/../../outside.txt"]:
		var result: Dictionary = files.read({"path": path})
		assert_eq(Result.code_of(result), "path.invalid", "rejected: " + path)

	var absolute_write: Dictionary = files.write({"path": "C:/temp/x.txt", "text": "x"})
	assert_eq(Result.code_of(absolute_write), "path.invalid")


func test_files_require_an_open_workspace() -> void:
	workspace.open = false
	var result: Dictionary = files.read({"path": "notes.txt"})
	assert_eq(Result.code_of(result), "workspace.required")

	var missing_root: Dictionary = files.list({})
	assert_eq(Result.code_of(missing_root), "workspace.required")


func test_list_is_recursive_sorted_and_skips_heavy_folders() -> void:
	var result: Dictionary = files.list({"path": ".", "recursive": true})
	check(result.get("ok", false), "list succeeds")
	var entries: Array = result.get("value", [])
	var paths: Array = []
	for entry in entries:
		paths.append(str(entry.get("path", "")))
	check(paths.has("notes.txt"), "root file present")
	check(paths.has("src/main.gd"), "nested file present")
	check(!paths.has("node_modules/ignored.js"), "node_modules skipped")
	var sorted := paths.duplicate()
	sorted.sort_custom(func(a, b): return str(a).naturalnocasecmp_to(str(b)) < 0)
	assert_eq(paths, sorted, "entries are sorted")

	var note := {}
	for entry in entries:
		if str(entry.get("path", "")) == "notes.txt":
			note = entry
	assert_eq(int(note.get("size", 0)), 10, "file size reported")


func test_mkdir_and_exists() -> void:
	check(files.exists({"path": "notes.txt"}).get("value", false), "file exists")
	check(files.exists({"path": "src"}).get("value", false), "folder exists")
	assert_false(files.exists({"path": "missing.txt"}).get("value", true), "missing file is false")

	var made: Dictionary = files.mkdir({"path": "src/deep/nested"})
	check(made.get("ok", false), "mkdir creates parents")
	check(DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(ROOT.path_join("src/deep/nested"))), "folder created")


func test_delete_needs_confirmation_and_refuses_non_empty_folders() -> void:
	var unconfirmed: Dictionary = files.delete({"path": "notes.txt"})
	assert_eq(Result.code_of(unconfirmed), "ui.confirmation_required")
	check(FileAccess.file_exists(ROOT.path_join("notes.txt")), "file survived unconfirmed delete")

	var confirmed: Dictionary = files.delete({"path": "notes.txt", "confirmed": true})
	check(confirmed.get("ok", false), "confirmed delete succeeds")
	check(!FileAccess.file_exists(ROOT.path_join("notes.txt")), "file deleted")

	var non_empty: Dictionary = files.delete({"path": "src", "confirmed": true})
	assert_eq(Result.code_of(non_empty), "module.not_empty")
	check(DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(ROOT.path_join("src"))), "folder survived")


func test_missing_file_and_folder_errors_are_distinct() -> void:
	var read: Dictionary = files.read({"path": "missing.txt"})
	assert_eq(Result.code_of(read), "module.not_found")

	var listed: Dictionary = files.list({"path": "missing"})
	assert_eq(Result.code_of(listed), "path.invalid")


func _write(path: String, content: String) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(content)


func _make_dir(path: String) -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(path))


func _clean(path: String) -> void:
	var db := DirAccess.open(ProjectSettings.globalize_path(path))
	if db == null:
		return
	for file_name in db.get_files():
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path.path_join(str(file_name))))
	for directory_name in db.get_directories():
		_clean(path.path_join(str(directory_name)))
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path.path_join(str(directory_name))))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
