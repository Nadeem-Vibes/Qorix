extends "res://tests/support/test_case.gd"

const Search = preload("res://src/platform/search_service.gd")

const TEST_DIR := "user://tests_search"

var service: Node
var state: Dictionary


func before_each() -> void:
	_remove_dir(TEST_DIR)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(TEST_DIR))

	_write(TEST_DIR.path_join("alpha.txt"), "Hello world\nhello again\n")
	_write(TEST_DIR.path_join("beta.md"), "no match here\n")
	_write(TEST_DIR.path_join("gamma.txt"), "hello only once\n")

	var binary := FileAccess.open(TEST_DIR.path_join("image.png"), FileAccess.WRITE)
	binary.store_buffer(PackedByteArray([0x89, 0x50, 0x4E, 0x47, 0x00, 0x01, 0x02]))
	binary = null

	service = Search.new()
	state = {"finished": false, "results": [], "stats": {}}
	service.search_finished.connect(func(results: Array, stats: Dictionary) -> void:
		state.finished = true
		state.results = results
		state.stats = stats
	)


func after_each() -> void:
	if is_instance_valid(service):
		service.free()
	service = null
	_remove_dir(TEST_DIR)


func _write(path: String, content: String) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(content)


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


func _paths() -> Array:
	return [
		TEST_DIR.path_join("alpha.txt"),
		TEST_DIR.path_join("beta.md"),
		TEST_DIR.path_join("gamma.txt"),
		TEST_DIR.path_join("image.png"),
	]


func _run(query: String, options: Dictionary = {}) -> void:
	service.search(query, _paths(), options)
	if !state.finished:
		service.pump(1_000_000)


func test_search_is_case_insensitive_and_reports_line_columns() -> void:
	_run("hello")

	assert_true(state.finished)
	assert_eq(state.results.size(), 3)
	assert_eq(state.stats.get("files_scanned"), 4)
	assert_eq(state.stats.get("files_total"), 4)
	assert_eq(state.stats.get("truncated"), false)

	var first: Dictionary = state.results[0]
	assert_eq(first.get("rel"), TEST_DIR.path_join("alpha.txt"))
	assert_eq(first.get("line"), 0)
	assert_eq(first.get("column"), 0)
	assert_eq(first.get("preview"), "Hello world")


func test_case_sensitive_search_keeps_only_exact_case() -> void:
	_run("Hello", {"case_sensitive": true})

	assert_true(state.finished)
	assert_eq(state.results.size(), 1)
	assert_eq(state.results[0].get("line"), 0)


func test_binary_files_are_skipped() -> void:
	_run("hello")

	for result in state.results:
		assert_ne(result.get("path"), TEST_DIR.path_join("image.png"))


func test_oversized_files_are_skipped() -> void:
	_run("hello", {"max_file_size": 5})

	assert_eq(state.results.size(), 0)
	assert_true(state.finished)


func test_results_are_capped_and_marked_truncated() -> void:
	_run("hello", {"max_results": 1})

	assert_eq(state.results.size(), 1)
	assert_eq(state.stats.get("truncated"), true)


func test_empty_file_list_still_finishes() -> void:
	service.search("hello", [])
	assert_true(state.finished)
	assert_eq(state.results.size(), 0)


func test_empty_query_does_not_start_a_search() -> void:
	var started: bool = service.search("   ", _paths())
	assert_false(started)
	assert_false(service.searching)
	assert_true(state.finished)


func test_cancel_stops_the_search() -> void:
	var many: Array = []
	for i in range(400):
		var path := TEST_DIR.path_join("bulk_%03d.txt" % i)
		_write(path, "hello padding\n" + "x".repeat(2048))
		many.append(path)

	service.search("hello", many)
	service.cancel()

	assert_false(service.searching)
	assert_false(state.finished, "cancel must not emit a finished event")


func test_replace_preview_counts_without_writing() -> void:
	var before := FileAccess.get_file_as_string(TEST_DIR.path_join("alpha.txt"))
	var preview: Dictionary = service.replace_preview(
		[TEST_DIR.path_join("alpha.txt")], "hello", "goodbye"
	)

	assert_eq(preview.get("ok"), true)
	assert_eq(preview.get("total"), 2)
	assert_eq(preview.get("files").size(), 1)
	assert_eq(FileAccess.get_file_as_string(TEST_DIR.path_join("alpha.txt")), before)


func test_replace_preview_respects_skip_paths() -> void:
	var preview: Dictionary = service.replace_preview(
		[TEST_DIR.path_join("alpha.txt")],
		"hello",
		"x",
		{"skip_paths": [TEST_DIR.path_join("alpha.txt")]}
	)

	assert_eq(preview.get("files").size(), 0)
	assert_eq(preview.get("skipped").size(), 1)


func test_replace_apply_writes_every_file() -> void:
	var applied: Dictionary = service.replace_apply(
		[TEST_DIR.path_join("alpha.txt"), TEST_DIR.path_join("gamma.txt")],
		"hello",
		"bye",
		{"case_sensitive": false}
	)

	assert_eq(applied.get("ok"), true)
	assert_eq(applied.get("total"), 3)
	assert_eq(applied.get("written").size(), 2)
	assert_eq(FileAccess.get_file_as_string(TEST_DIR.path_join("alpha.txt")), "bye world\nbye again\n")
	assert_eq(FileAccess.get_file_as_string(TEST_DIR.path_join("gamma.txt")), "bye only once\n")


func test_replace_apply_is_case_sensitive_when_asked() -> void:
	var applied: Dictionary = service.replace_apply(
		[TEST_DIR.path_join("alpha.txt")], "Hello", "Hi", {"case_sensitive": true}
	)

	assert_eq(applied.get("total"), 1)
	assert_eq(FileAccess.get_file_as_string(TEST_DIR.path_join("alpha.txt")), "Hi world\nhello again\n")
