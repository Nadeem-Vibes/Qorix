extends "res://tests/support/test_case.gd"

const Welcome = preload("res://src/features/learning/beginner/welcome_service.gd")
const TEST_DIR := "user://tests_phase9_welcome"

var service = null


func before_each() -> void:
	_remove_dir(TEST_DIR)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(TEST_DIR))
	service = Welcome.new()
	service.state_path = TEST_DIR.path_join("welcome.json")


func after_each() -> void:
	service = null
	_remove_dir(TEST_DIR)


func test_recent_files_are_newest_first_and_deduplicated() -> void:
	var first := _make_file("first.txt")
	var second := _make_file("second.txt")

	assert_true(service.remember_file(first))
	assert_true(service.remember_file(second))
	assert_true(service.remember_file(first))

	var recent: Array = service.recent_files()
	assert_eq(recent.size(), 2)
	assert_eq(str(recent[0]), first.replace("\\", "/"))
	assert_eq(str(recent[1]), second.replace("\\", "/"))


func test_missing_files_are_hidden() -> void:
	var keep := _make_file("keep.txt")
	var gone := _make_file("gone.txt")
	service.remember_file(gone)
	service.remember_file(keep)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(gone))

	var recent: Array = service.recent_files()
	assert_eq(recent.size(), 1)
	assert_eq(str(recent[0]), keep.replace("\\", "/"))


func test_recent_list_is_capped() -> void:
	for index in range(Welcome.MAX_RECENT_FILES + 4):
		service.remember_file(_make_file("file-%02d.txt" % index))
	assert_eq(service.recent_files(999).size(), Welcome.MAX_RECENT_FILES)


func test_welcome_seen_and_clear_persist() -> void:
	assert_false(service.welcome_seen())
	service.mark_welcome_seen()
	assert_true(service.welcome_seen())

	var reloaded = Welcome.new()
	reloaded.state_path = service.state_path
	assert_true(reloaded.welcome_seen())

	reloaded.clear()
	assert_false(reloaded.welcome_seen())
	assert_eq(reloaded.recent_files().size(), 0)


func test_empty_path_is_not_remembered() -> void:
	assert_false(service.remember_file(""))
	assert_eq(service.recent_files().size(), 0)


func _make_file(name: String) -> String:
	var path := TEST_DIR.path_join(name)
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(name)
	file = null
	return path


func _remove_dir(path: String) -> void:
	var global := ProjectSettings.globalize_path(path)
	var dir := DirAccess.open(global)
	if dir != null:
		for file_name in dir.get_files():
			DirAccess.remove_absolute(global.path_join(file_name))
		for directory_name in dir.get_directories():
			_remove_dir(path.path_join(directory_name))
	DirAccess.remove_absolute(global)
