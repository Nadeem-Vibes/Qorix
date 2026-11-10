extends "res://tests/support/test_case.gd"

const Onboarding = preload("res://src/features/learning/beginner/onboarding_service.gd")
const TEST_DIR := "user://tests_phase9_onboarding"

var service = null
var states: Array = []
var completions: int = 0


func before_each() -> void:
	_remove_dir(TEST_DIR)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(TEST_DIR))
	service = Onboarding.new()
	service.state_path = TEST_DIR.path_join("onboarding.json")
	states = []
	completions = 0
	service.state_changed.connect(func(state: Dictionary) -> void: states.append(state))
	service.completed.connect(func() -> void: completions += 1)


func after_each() -> void:
	service = null
	_remove_dir(TEST_DIR)


func test_start_activates_step_zero_with_four_steps() -> void:
	service.start(true)
	var state: Dictionary = service.snapshot()
	assert_true(bool(state.get("active", false)))
	assert_eq(int(state.get("step", -1)), 0)
	assert_eq(int(state.get("step_count", 0)), 4)
	assert_eq(str(state.get("step_info", {}).get("id", "")), "open_file")
	assert_false(service.is_completed())


func test_events_advance_through_open_type_run_output() -> void:
	var opened: Dictionary = service.start(true)
	assert_true(bool(opened.get("active", false)))

	assert_true(service.notify_document_open())
	assert_eq(service.current_step(), 1)
	assert_true(service.notify_typed())
	assert_eq(service.current_step(), 2)
	assert_true(service.notify_run())
	assert_eq(service.current_step(), 3)

	assert_true(service.notify_output("Hello, world!"))
	assert_eq(service.current_step(), 4)
	assert_true(service.is_completed())
	assert_eq(int(service.snapshot().get("onboarding_completed", 0)), 1)
	assert_eq(completions, 1, "completion is emitted exactly once")


func test_the_tutorial_copy_renders_in_german_and_spanish() -> void:
	service.locale = "de"
	var german: Dictionary = service.snapshot()
	assert_eq(str(german.get("step_info", {}).get("title", "")), "Öffne oder erstelle eine Datei")
	assert_true(str(german.get("step_info", {}).get("hint", "")).contains("Vorlage"))

	service.locale = "es"
	var spanish: Dictionary = service.snapshot()
	assert_eq(str(spanish.get("step_info", {}).get("title", "")), "Abre o crea un archivo")
	assert_true(str(spanish.get("step_info", {}).get("hint", "")).contains("plantilla"))

	service.locale = "en"
	var english: Dictionary = service.snapshot()
	assert_eq(str(english.get("step_info", {}).get("title", "")), "Open or create a file")


func test_events_cannot_move_backwards() -> void:
	service.start(true)
	service.notify_document_open()
	service.notify_typed()
	assert_false(service.notify_document_open())
	assert_eq(service.current_step(), 2)


func test_empty_output_does_not_complete_the_tutorial() -> void:
	service.start(true)
	service.notify_document_open()
	service.notify_typed()
	service.notify_run()
	assert_false(service.notify_output("   "))
	assert_eq(service.current_step(), 3)
	assert_false(service.is_completed())


func test_completion_is_persisted_and_can_be_replayed() -> void:
	service.start(true)
	service.notify_document_open()
	service.notify_typed()
	service.notify_run()
	service.notify_output("done")

	var reloaded = Onboarding.new()
	reloaded.state_path = service.state_path
	assert_true(reloaded.is_completed())
	assert_true(bool(reloaded.load_state().get("onboarding_completed", false)))

	var replay: Dictionary = reloaded.start(true)
	assert_true(bool(replay.get("active", false)))
	assert_eq(int(replay.get("step", -1)), 0)
	assert_true(reloaded.is_completed(), "replaying keeps the completed flag")


func test_skip_stops_the_tutorial_without_completing_it() -> void:
	service.start(true)
	service.skip()
	assert_false(service.is_active())
	assert_false(service.is_completed())
	assert_true(bool(service.load_state().get("skipped", false)))


func test_reset_clears_everything() -> void:
	service.start(true)
	service.finish()
	assert_true(service.is_completed())
	service.reset()
	assert_false(service.is_completed())
	assert_false(service.is_active())
	assert_eq(service.current_step(), 0)


func test_finish_marks_completed_and_emits() -> void:
	service.start(true)
	service.finish()
	assert_true(service.is_completed())
	assert_false(service.is_active())
	assert_eq(service.current_step(), Onboarding.STEP_COUNT)
	assert_eq(completions, 1)
	assert_true(states.size() > 0, "state changes are published")


func _remove_dir(path: String) -> void:
	var global := ProjectSettings.globalize_path(path)
	var dir := DirAccess.open(global)
	if dir != null:
		for file_name in dir.get_files():
			DirAccess.remove_absolute(global.path_join(file_name))
		for directory_name in dir.get_directories():
			_remove_dir(path.path_join(directory_name))
	DirAccess.remove_absolute(global)
