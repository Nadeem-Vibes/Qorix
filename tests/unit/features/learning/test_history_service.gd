extends "res://tests/support/test_case.gd"

const History = preload("res://src/features/learning/beginner/history_service.gd")
const Paths = preload("res://src/base/path_utils.gd")
const TEST_DIR := "user://tests_phase9_history"

var service = null
var file_path := ""


func before_each() -> void:
	_remove_dir(TEST_DIR)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(TEST_DIR))
	service = History.new()
	service.root = TEST_DIR.path_join("store")
	service.now_override = 1_700_000_000
	file_path = TEST_DIR.path_join("notes.txt")
	_write(file_path, "first\n")


func after_each() -> void:
	service.clear_all()
	service = null
	_remove_dir(TEST_DIR)


func test_directory_uses_sha1_of_the_canonical_path() -> void:
	var directory: String = service.directory_for(file_path)
	var expected: String = Paths.canonical(file_path).sha1_text()
	assert_eq(directory.get_file(), expected)
	assert_eq(expected.length(), 40)


func test_snapshot_stores_metadata_and_content() -> void:
	var result: Dictionary = service.snapshot(file_path, "hello\n", "before_save")
	assert_true(bool(result.get("ok", false)), str(result.get("error", "")))
	assert_eq(int(service.count(file_path)), 1)

	var latest: Dictionary = service.latest(file_path)
	assert_eq(str(latest.get("reason", "")), "before_save")
	assert_eq(str(latest.get("path", "")), file_path.replace("\\", "/"))
	assert_eq(str(latest.get("content", "")), "hello\n")
	assert_true(str(latest.get("time_label", "")).contains("2023-11-14"))


func test_identical_consecutive_content_is_deduplicated() -> void:
	service.snapshot(file_path, "same\n", "save")
	var second: Dictionary = service.snapshot(file_path, "same\n", "autosave")
	assert_true(bool(second.get("deduped", false)))
	assert_eq(int(service.count(file_path)), 1)


func test_newest_snapshot_comes_first() -> void:
	service.snapshot(file_path, "one\n", "save")
	service.now_override += 1
	service.snapshot(file_path, "two\n", "run")
	var list: Array = service.snapshots(file_path)
	assert_eq(int(list.size()), 2)
	assert_eq(str(list[0].get("reason", "")), "run")
	assert_eq(str(list[1].get("reason", "")), "save")


func test_retention_keeps_the_newest_fifty() -> void:
	for index in range(History.MAX_SNAPSHOTS + 5):
		service.now_override += 1
		service.snapshot(file_path, "line %d\n" % index, "autosave")
	assert_eq(int(service.count(file_path)), History.MAX_SNAPSHOTS)
	var latest: Dictionary = service.latest(file_path)
	assert_eq(str(latest.get("content", "")), "line %d\n" % (History.MAX_SNAPSHOTS + 4))


func test_old_snapshots_are_pruned() -> void:
	service.snapshot(file_path, "old\n", "save")
	service.now_override += History.MAX_AGE_SECONDS + 60
	service.snapshot(file_path, "new\n", "save")
	assert_eq(int(service.count(file_path)), 1)
	assert_eq(str(service.latest(file_path).get("content", "")), "new\n")


func test_size_cap_prunes_larger_history() -> void:
	var big := "x".repeat(1_300_000)
	service.snapshot(file_path, big, "save")
	service.now_override += 1
	service.snapshot(file_path, big + "y", "save")
	assert_eq(int(service.count(file_path)), 1, "the oldest copy is removed to stay under the cap")


func test_restore_writes_the_snapshot_content() -> void:
	service.snapshot(file_path, "first\n", "before_save")
	service.now_override += 1
	service.snapshot(file_path, "second\n", "before_save")
	var target: Dictionary = service.snapshots(file_path)[1]
	var result: Dictionary = service.restore(file_path, str(target.get("file", "")))
	assert_true(bool(result.get("ok", false)), str(result.get("error", "")))
	assert_eq(FileAccess.get_file_as_string(file_path), "first\n")
	assert_eq(str(result.get("content", "")), "first\n")


func test_diff_compares_snapshot_with_the_current_buffer() -> void:
	service.snapshot(file_path, "one\ntwo\n", "before_save")
	var entry: Dictionary = service.snapshots(file_path)[0]
	var result: Dictionary = service.diff(file_path, str(entry.get("file", "")), "one\nTWO\nthree\n")
	assert_true(bool(result.get("ok", false)), str(result.get("error", "")))
	assert_eq(int(result.get("modified", 0)), 1)
	assert_eq(int(result.get("added", 0)), 1)

	var kinds: Array = []
	for line in result.get("lines", []):
		kinds.append(str(line.get("kind", "")))
	assert_true(kinds.has("delete"))
	assert_true(kinds.has("add"))


func test_snapshot_names_cannot_escape_their_folder() -> void:
	var result: Dictionary = service.read(file_path, "../outside.json")
	assert_false(bool(result.get("ok", true)))
	assert_true(str(result.get("error", "")).contains("Invalid"))


func test_clear_removes_only_that_files_history() -> void:
	var other := TEST_DIR.path_join("other.txt")
	service.snapshot(file_path, "a\n", "save")
	service.snapshot(other, "b\n", "save")
	assert_eq(service.clear(file_path), 1)
	assert_eq(int(service.count(file_path)), 0)
	assert_eq(int(service.count(other)), 1)


func test_reason_labels_are_plain_language() -> void:
	assert_eq(History.reason_label("before_save"), "Before a save")
	assert_eq(History.reason_label("before_run"), "Before running")
	assert_eq(History.reason_label("before_close"), "Before closing")
	assert_eq(History.reason_label("autosave"), "Automatic backup")
	assert_eq(History.reason_label("before_restore"), "Before restoring")


func _write(path: String, content: String) -> void:
	var parent := path.get_base_dir()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(parent))
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(content)
	file = null


func _remove_dir(path: String) -> void:
	var global := ProjectSettings.globalize_path(path)
	var dir := DirAccess.open(global)
	if dir != null:
		for file_name in dir.get_files():
			DirAccess.remove_absolute(global.path_join(file_name))
		for directory_name in dir.get_directories():
			_remove_dir(path.path_join(directory_name))
	DirAccess.remove_absolute(global)
