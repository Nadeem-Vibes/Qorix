extends "res://tests/support/test_case.gd"

const ErrorFeedback = preload("res://src/features/run/error_feedback.gd")

const TEST_DIR := "user://tests_error_feedback"

var feedback


func before_each() -> void:
	_remove_dir(TEST_DIR)
	DirAccess.make_dir_recursive_absolute(_root())
	feedback = ErrorFeedback.new()
	feedback.state_path = TEST_DIR.path_join("error_feedback.json")
	feedback.now_override = 1_700_000_000


func after_each() -> void:
	_remove_dir(TEST_DIR)
	feedback = null


func _root() -> String:
	return ProjectSettings.globalize_path(TEST_DIR).replace("\\", "/")


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


func test_a_vote_is_recorded_and_counted() -> void:
	var result: Dictionary = feedback.record("python-zero-division", "up", "python")
	assert_true(bool(result.get("ok", false)))
	assert_eq(int(result.get("count", 0)), 1)
	feedback.record("python-zero-division", "down", "python")
	var summary: Dictionary = feedback.summary()
	assert_eq(int(summary.get("total", 0)), 2)
	assert_eq(int(summary.get("up", 0)), 1)
	assert_eq(int(summary.get("down", 0)), 1)
	assert_eq(int(summary["by_card"]["python-zero-division"]["up"]), 1)
	assert_eq(int(summary["by_card"]["python-zero-division"]["down"]), 1)


func test_language_is_stored_lower_case() -> void:
	var result: Dictionary = feedback.record("generic-exit", "down", "PYTHON")
	assert_true(bool(result.get("ok", false)))
	var text := FileAccess.get_file_as_string(feedback.state_path)
	var parsed: Variant = JSON.parse_string(text)
	assert_true(parsed is Dictionary)
	var entries: Variant = (parsed as Dictionary).get("entries", [])
	assert_true(entries is Array)
	assert_eq(str(entries[0].get("language", "")), "python")


func test_consecutive_identical_votes_collapse() -> void:
	feedback.record("card", "up")
	feedback.record("card", "up")
	var summary: Dictionary = feedback.summary()
	assert_eq(int(summary.get("total", 0)), 1)


func test_consecutive_votes_for_different_ratings_are_kept() -> void:
	feedback.record("card", "up")
	feedback.record("card", "down")
	var summary: Dictionary = feedback.summary()
	assert_eq(int(summary.get("total", 0)), 2)


func test_a_missing_id_is_rejected() -> void:
	var result: Dictionary = feedback.record("   ", "up")
	assert_false(bool(result.get("ok", true)))


func test_an_invalid_rating_is_rejected() -> void:
	var result: Dictionary = feedback.record("card", "meh")
	assert_false(bool(result.get("ok", true)))
	assert_eq(int(result.get("count", -1)), 0)


func test_the_store_is_capped_at_two_hundred_entries() -> void:
	for i in range(205):
		feedback.now_override = 1_700_000_000 + i
		var result: Dictionary = feedback.record("card-%d" % i, "up" if i % 2 == 0 else "down")
		assert_true(bool(result.get("ok", false)))
	var summary: Dictionary = feedback.summary()
	assert_eq(int(summary.get("total", 0)), ErrorFeedback.MAX_ENTRIES)


func test_a_fresh_store_reads_as_empty() -> void:
	var summary: Dictionary = feedback.summary()
	assert_eq(int(summary.get("total", -1)), 0)
	assert_true(bool(summary.get("ok", false)))
