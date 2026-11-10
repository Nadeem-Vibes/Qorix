extends "res://tests/support/test_case.gd"

const Workspace = preload("res://src/platform/workspace_service.gd")
const Entry = preload("res://src/platform/file_entry.gd")

const TEST_DIR := "user://tests_workspace"
const ROOT := "user://tests_workspace/root"

var service: Node


func before_each() -> void:
	_remove_dir(TEST_DIR)
	_make_dir(ROOT)
	_write(ROOT.path_join("a.txt"), "alpha")
	_write(ROOT.path_join("README.md"), "# readme")
	_make_dir(ROOT.path_join("src"))
	_write(ROOT.path_join("src/main.gd"), "extends Node")
	_write(ROOT.path_join("src/util.gd"), "func helper(): pass")
	_make_dir(ROOT.path_join("src/nested"))
	_write(ROOT.path_join("src/nested/deep.py"), "print('deep')")
	_make_dir(ROOT.path_join("node_modules"))
	_write(ROOT.path_join("node_modules/ignored.js"), "ignore me")
	_make_dir(ROOT.path_join(".git"))
	_write(ROOT.path_join(".git/config"), "ignore me too")

	service = Workspace.new()
	service.recents_path = TEST_DIR.path_join("workspaces.json")


func after_each() -> void:
	if is_instance_valid(service):
		service.free()
	service = null
	_remove_dir(TEST_DIR)


func _build() -> void:
	var opened: Dictionary = service.open_folder(ROOT)
	assert_eq(opened.get("ok"), true)
	service.pump(1_000_000)


func _write(path: String, content: String) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(content)


func _make_dir(path: String) -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(path))


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


func test_open_folder_indexes_files_and_skips_heavy_folders() -> void:
	_build()

	assert_eq(service.root, ROOT)
	assert_true(service.has_workspace())
	assert_eq(service.index_size(), 5)

	var paths := []
	for entry in service.entries:
		paths.append(entry.rel)
	paths.sort()

	assert_eq(paths, [
		"README.md",
		"a.txt",
		"src/main.gd",
		"src/nested/deep.py",
		"src/util.gd",
	])


func test_open_folder_refuses_drive_roots_and_missing_folders() -> void:
	var root_path := "C:/" if OS.get_name() == "Windows" else "/"
	var rejected: Dictionary = service.open_folder(root_path)
	assert_eq(rejected.get("ok"), false)
	assert_true(str(rejected.get("error", "")).length() > 0)

	var missing: Dictionary = service.open_folder(TEST_DIR.path_join("does_not_exist"))
	assert_eq(missing.get("ok"), false)
	assert_false(service.has_workspace())


func test_list_children_is_lazy_sorted_and_hides_skipped_folders() -> void:
	_build()

	var top: Array = service.list_children("")
	assert_eq(top[0].name, "src")
	assert_eq(top[0].is_dir, true)

	var names := []
	for child in top:
		names.append(child.name)
	assert_eq(names, ["src", "a.txt", "README.md"])

	var src: Array = service.list_children("src")
	assert_eq(src.size(), 3)
	assert_eq(src[0].name, "nested")
	assert_eq(src[1].name, "main.gd")
	assert_eq(src[2].name, "util.gd")


func test_quick_open_finds_names_and_ranks_the_file_name_first() -> void:
	_build()

	var hits: Array = service.quick_open("main")
	assert_true(hits.size() >= 1)
	assert_eq(hits[0].name, "main.gd")

	var exact: Array = service.quick_open("util.gd")
	assert_eq(exact[0].rel, "src/util.gd")

	var path_hit: Array = service.quick_open("nested deep")
	assert_true(path_hit.size() >= 1)
	assert_eq(path_hit[0].rel, "src/nested/deep.py")

	var none: Array = service.quick_open("zzzzzz")
	assert_eq(none.size(), 0)


func test_quick_open_empty_query_returns_browsable_prefix() -> void:
	_build()

	var hits: Array = service.quick_open("", 2)
	assert_eq(hits.size(), 2)
	assert_eq(hits[0].rel, "a.txt")
	assert_eq(hits[1].rel, "README.md")


func test_quick_open_stays_fast_with_five_thousand_entries() -> void:
	_build()
	service.entries.clear()
	for i in range(5000):
		service.entries.append(Entry.new(
			"C:/project/folder_%d/file_%d.gd" % [i % 50, i],
			"folder_%d/file_%d.gd" % [i % 50, i],
			"file_%d.gd" % i,
			"gd",
			10,
			0
		))

	var started := Time.get_ticks_msec()
	var hits: Array = service.quick_open("file_4999")
	var elapsed := Time.get_ticks_msec() - started

	assert_eq(hits.size() >= 1, true)
	assert_eq(hits[0].name, "file_4999.gd")
	assert_true(elapsed < 500, "quick open took %d ms for 5000 entries" % elapsed)


func test_paths_are_recognized_inside_the_workspace() -> void:
	_build()

	assert_true(service.is_inside_workspace(ROOT.path_join("src/main.gd")))
	assert_false(service.is_inside_workspace(TEST_DIR.path_join("elsewhere.txt")))
	assert_eq(service.relative_path(ROOT.path_join("src/main.gd")), "src/main.gd")
	assert_eq(service.relative_path(ROOT), "")


func test_note_changed_adds_and_removes_single_files() -> void:
	_build()

	var added := ROOT.path_join("src/new.gd")
	_write(added, "new")
	assert_true(service.note_changed(added))
	assert_true(service.file_for_path(added) != null)
	assert_eq(service.index_size(), 6)

	DirAccess.remove_absolute(ProjectSettings.globalize_path(added))
	assert_true(service.note_changed(added))
	assert_true(service.file_for_path(added) == null)
	assert_eq(service.index_size(), 5)


func test_note_renamed_moves_the_index_subtree() -> void:
	_build()

	var old_dir := ROOT.path_join("src/nested")
	var new_dir := ROOT.path_join("src/moved")
	DirAccess.rename_absolute(
		ProjectSettings.globalize_path(old_dir),
		ProjectSettings.globalize_path(new_dir)
	)
	service.note_renamed(old_dir, new_dir)

	assert_true(service.file_for_path(old_dir.path_join("deep.py")) == null)
	var moved = service.file_for_path(new_dir.path_join("deep.py"))
	assert_true(moved != null)
	assert_eq(moved.rel, "src/moved/deep.py")


func test_recent_workspaces_are_deduplicated_and_persisted() -> void:
	_build()

	assert_eq(service.recent_workspaces.size(), 1)
	assert_eq(service.recent_workspaces[0], ROOT)

	# opening it again must not duplicate the entry
	service.open_folder(ROOT)
	service.pump(1_000_000)
	assert_eq(service.recent_workspaces.size(), 1)

	var other := TEST_DIR.path_join("other")
	_make_dir(other)
	service.open_folder(other)
	service.pump(1_000_000)
	assert_eq(service.recent_workspaces[0], other)
	assert_eq(service.recent_workspaces[1], ROOT)

	var reloaded := Workspace.new()
	reloaded.recents_path = service.recents_path
	reloaded.load_recents()
	assert_eq(reloaded.recent_workspaces.size(), 2)
	assert_eq(reloaded.recent_workspaces[0], other)
	reloaded.free()


func test_index_finished_reports_the_file_count() -> void:
	_build()

	var reported := {"count": -1, "truncated": true}
	service.index_finished.connect(func(count: int, truncated: bool) -> void:
		reported.count = count
		reported.truncated = truncated
	)
	service.open_folder(ROOT)
	service.pump(1_000_000)

	assert_eq(reported.count, 5)
	assert_eq(reported.truncated, false)
