extends "res://tests/support/test_case.gd"

const Template = preload("res://src/features/learning/beginner/template_service.gd")
const TEST_DIR := "user://tests_phase9_templates"

var service = null


func before_each() -> void:
	_remove_dir(TEST_DIR)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(TEST_DIR))
	service = Template.new()


func after_each() -> void:
	service = null
	_remove_dir(TEST_DIR)


func test_manifest_lists_the_starter_templates() -> void:
	var loaded: Dictionary = service.load_templates()
	assert_true(bool(loaded.get("ok", false)), str(loaded.get("error", "")))
	var ids: Array = []
	for entry in service.templates():
		ids.append(str(entry.get("id", "")))
	assert_eq(ids, ["python", "web", "c", "empty"])
	assert_eq(str(service.get_template("python").get("primary", "")), "hello.py")


func test_unknown_template_is_rejected() -> void:
	var result: Dictionary = service.create("does-not-exist", TEST_DIR)
	assert_false(bool(result.get("ok", true)))
	assert_true(str(result.get("error", "")).contains("Unknown template"))


func test_python_template_writes_a_runnable_file() -> void:
	var result: Dictionary = service.create("python", TEST_DIR)
	assert_true(bool(result.get("ok", false)), str(result.get("error", "")))
	var primary := str(result.get("primary", ""))
	assert_true(FileAccess.file_exists(primary))
	assert_eq(primary.get_file(), "hello.py")
	assert_true(FileAccess.get_file_as_string(primary).contains("print("))


func test_web_template_creates_its_own_folder_with_relative_files() -> void:
	var result: Dictionary = service.create("web", TEST_DIR)
	assert_true(bool(result.get("ok", false)), str(result.get("error", "")))
	assert_eq(str(result.get("folder", "")).get_file(), "web")
	assert_eq((result.get("paths", []) as Array).size(), 3)
	assert_true(FileAccess.file_exists(str(result.get("folder", "")).path_join("style.css")))
	assert_true(FileAccess.file_exists(str(result.get("folder", "")).path_join("script.js")))
	assert_eq(str(result.get("primary", "")).get_file(), "index.html")


func test_creating_the_same_project_twice_never_merges_folders() -> void:
	var first: Dictionary = service.create("web", TEST_DIR)
	var second: Dictionary = service.create("web", TEST_DIR)
	assert_true(bool(second.get("ok", false)), str(second.get("error", "")))
	assert_ne(str(first.get("folder", "")), str(second.get("folder", "")))
	assert_eq(str(second.get("folder", "")).get_file(), "web-2")


func test_single_file_template_never_overwrites_an_existing_file() -> void:
	var existing := TEST_DIR.path_join("hello.py")
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(TEST_DIR))
	var write := FileAccess.open(existing, FileAccess.WRITE)
	write.store_string("# my own work\n")
	write = null

	var result: Dictionary = service.create("python", TEST_DIR)
	assert_true(bool(result.get("ok", false)), str(result.get("error", "")))
	assert_eq(FileAccess.get_file_as_string(existing), "# my own work\n")
	assert_eq(str(result.get("primary", "")).get_file(), "hello-2.py")
	assert_true(FileAccess.get_file_as_string(str(result.get("primary", ""))).contains("print("))


func test_empty_template_uses_a_unique_name() -> void:
	var first: Dictionary = service.create("empty", TEST_DIR)
	var second: Dictionary = service.create("empty", TEST_DIR)
	assert_true(bool(first.get("ok", false)), str(first.get("error", "")))
	assert_true(bool(second.get("ok", false)), str(second.get("error", "")))
	assert_eq(str(first.get("primary", "")).get_file(), "untitled.txt")
	assert_eq(str(second.get("primary", "")).get_file(), "untitled-2.txt")


func test_missing_folder_is_reported_without_creating_anything() -> void:
	var result: Dictionary = service.create("python", "")
	assert_false(bool(result.get("ok", true)))
	assert_true(str(result.get("error", "")).contains("folder"))


func _remove_dir(path: String) -> void:
	var global := ProjectSettings.globalize_path(path)
	var dir := DirAccess.open(global)
	if dir != null:
		for file_name in dir.get_files():
			DirAccess.remove_absolute(global.path_join(file_name))
		for directory_name in dir.get_directories():
			_remove_dir(path.path_join(directory_name))
	DirAccess.remove_absolute(global)
