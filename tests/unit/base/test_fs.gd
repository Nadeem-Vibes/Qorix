extends "res://tests/support/test_case.gd"

const FsScript = preload("res://src/main/autoloads/fs.gd")
const TEST_DIR := "user://tests_tmp"

var fs: Node


func before_each() -> void:
	fs = FsScript.new()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(TEST_DIR))


func after_each() -> void:
	_remove_dir(TEST_DIR)
	fs.free()
	fs = null


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


func test_save_returns_structured_success() -> void:
	var path := TEST_DIR.path_join("save_ok.txt")
	var result: Dictionary = fs.save(path, "hello\nworld")

	assert_eq(result.get("ok"), true)
	assert_eq(result.get("error"), "")
	assert_eq(result.get("path"), path)
	assert_eq(FileAccess.get_file_as_string(path), "hello\nworld")


func test_save_leaves_no_temp_file_behind() -> void:
	var path := TEST_DIR.path_join("atomic.txt")
	var result: Dictionary = fs.save(path, "atomic")

	assert_eq(result.get("ok"), true)
	assert_false(FileAccess.file_exists(path + ".griddy_tmp"))
	assert_false(FileAccess.file_exists(ProjectSettings.globalize_path(path) + ".griddy_tmp"))


func test_save_overwrites_existing_content() -> void:
	var path := TEST_DIR.path_join("overwrite.txt")
	assert_eq(fs.save(path, "first").get("ok"), true)
	assert_eq(fs.save(path, "second").get("ok"), true)
	assert_eq(FileAccess.get_file_as_string(path), "second")


func test_save_reports_failure_instead_of_failing_silently() -> void:
	var path := TEST_DIR.path_join("missing_subdir/file.txt")
	var result: Dictionary = fs.save(path, "nope")

	assert_eq(result.get("ok"), false)
	assert_true(str(result.get("error", "")).length() > 0, "failure must explain itself")


func test_save_rejects_empty_path() -> void:
	var result: Dictionary = fs.save("", "nope")

	assert_eq(result.get("ok"), false)
	assert_true(str(result.get("error", "")).length() > 0)
