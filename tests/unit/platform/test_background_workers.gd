extends "res://tests/support/test_case.gd"

const SearchWorkerScript = preload("res://src/platform/search_worker.gd")
const IndexWorkerScript = preload("res://src/platform/index_worker.gd")

const TEST_DIR := "user://tests_workers"


func before_each() -> void:
	_remove_dir(TEST_DIR)
	_make_dir(TEST_DIR)
	_write(TEST_DIR.path_join("alpha.txt"), "hello one\nhello again\n")
	_write(TEST_DIR.path_join("beta.txt"), "nothing to see\n")
	_make_dir(TEST_DIR.path_join("nested"))
	_write(TEST_DIR.path_join("nested/deep.txt"), "hello deep\n")
	_make_dir(TEST_DIR.path_join("node_modules"))
	_write(TEST_DIR.path_join("node_modules/ignored.js"), "hello ignored\n")


func after_each() -> void:
	_remove_dir(TEST_DIR)


func _write(path: String, content: String) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(content)
	file.flush()
	file = null


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


func test_search_worker_publishes_matches_and_finishes() -> void:
	var worker = SearchWorkerScript.new()
	var paths := [
		TEST_DIR.path_join("alpha.txt"),
		TEST_DIR.path_join("beta.txt"),
		TEST_DIR.path_join("nested/deep.txt"),
	]

	assert_true(worker.start(paths, "hello", {}))

	var results: Array = []
	var done := false
	var deadline := Time.get_ticks_msec() + 5000
	while Time.get_ticks_msec() < deadline:
		var batch: Dictionary = worker.drain()
		results.append_array(batch.get("results", []))
		if bool(batch.get("done", false)):
			done = true
			break
		OS.delay_msec(5)

	if !done:
		worker.cancel()
	worker.wait()

	assert_true(done, "the search worker did not finish in time")
	assert_eq(results.size(), 3)

	var found: Array = []
	for row in results:
		found.append(str(row.get("path", "")))
	assert_true(found.has(TEST_DIR.path_join("alpha.txt")))
	assert_true(found.has(TEST_DIR.path_join("nested/deep.txt")))


func test_search_worker_cancel_is_safe() -> void:
	var worker = SearchWorkerScript.new()
	assert_true(worker.start([TEST_DIR.path_join("alpha.txt")], "hello", {}))

	worker.cancel()
	worker.wait()

	assert_false(worker.is_running())


func test_index_worker_batches_files_and_skips_heavy_folders() -> void:
	var worker = IndexWorkerScript.new()
	assert_true(worker.start(TEST_DIR, ["node_modules"], 100, 8))

	var entries: Array = []
	var done := false
	var deadline := Time.get_ticks_msec() + 5000
	while Time.get_ticks_msec() < deadline:
		var batch: Dictionary = worker.drain()
		entries.append_array(batch.get("entries", []))
		if bool(batch.get("finished", false)):
			done = true
			break
		OS.delay_msec(5)

	if !done:
		worker.cancel()
	worker.wait()

	assert_true(done, "the index worker did not finish in time")
	assert_eq(entries.size(), 3)

	var rels: Array = []
	for entry in entries:
		var rel := str(entry.get("rel", ""))
		assert_false(rel.contains("node_modules"), "skipped folders must never be indexed")
		rels.append(rel)
	rels.sort()
	assert_eq(rels, ["alpha.txt", "beta.txt", "nested/deep.txt"])
