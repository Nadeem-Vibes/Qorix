extends "res://tests/support/test_case.gd"

const CourseService = preload("res://src/features/learning/courses/course_service.gd")

const TEST_DIR := "user://tests_course_service"

var course


func before_each() -> void:
	_remove_dir(TEST_DIR)
	DirAccess.make_dir_recursive_absolute(_root())
	course = CourseService.new()
	course.progress_path = TEST_DIR.path_join("progress.json")


func after_each() -> void:
	_remove_dir(TEST_DIR)
	course = null


func _root() -> String:
	return ProjectSettings.globalize_path(TEST_DIR).replace("\\", "/")


func _remove_dir(path: String) -> void:
	var global := ProjectSettings.globalize_path(path)
	var dir := DirAccess.open(global)
	if dir == null:
		return
	for file in dir.get_files():
		DirAccess.remove_absolute(global.path_join(file))
	DirAccess.remove_absolute(global)


func test_the_bundled_catalog_is_valid() -> void:
	var result: Dictionary = course.load_catalog()
	assert_true(bool(result.get("ok", false)), str(result.get("error", "")))
	assert_eq(int(course.total_lessons()), 5)
	var ids: Array = []
	for lesson in course.lessons():
		ids.append(str(lesson.get("id", "")))
	assert_eq(ids, ["01_hello", "02_variables", "03_types", "04_conditionals", "05_loops"])
	for lesson in course.lessons():
		var exercise: Dictionary = lesson.get("exercise", {})
		var typing: Dictionary = exercise.get("typing", {})
		assert_ne(str(typing.get("target", "")), "")
		var freeform: Dictionary = exercise.get("freeform", {})
		assert_true(freeform.get("run", {}) is Dictionary)
		assert_true(freeform.get("text", {}) is Dictionary)


func test_a_fresh_progress_store_starts_empty() -> void:
	assert_eq(course.completed_count(), 0)
	assert_eq(course.last_lesson(), "")
	assert_false(course.is_done("01_hello"))
	assert_false(course.is_typed("01_hello"))
	assert_eq(course.next_lesson_id(""), "01_hello")


func test_marking_a_lesson_done_persists() -> void:
	var result: Dictionary = course.mark_done("01_hello")
	assert_true(bool(result.get("ok", false)))
	assert_true(course.is_done("01_hello"))
	assert_true(course.is_typed("01_hello"))
	assert_eq(course.completed_count(), 1)

	# Reloading from disk sees the same state.
	var reloaded := CourseService.new()
	reloaded.progress_path = course.progress_path
	assert_true(reloaded.is_done("01_hello"))
	assert_eq(reloaded.completed_count(), 1)
	assert_eq(reloaded.last_lesson(), "01_hello")


func test_mark_typed_does_not_mark_done() -> void:
	var result: Dictionary = course.mark_typed("02_variables")
	assert_true(bool(result.get("ok", false)))
	assert_true(course.is_typed("02_variables"))
	assert_false(course.is_done("02_variables"))
	assert_eq(course.completed_count(), 0)
	assert_eq(course.last_lesson(), "02_variables")


func test_next_lesson_skips_completed_lessons() -> void:
	course.mark_done("01_hello")
	course.mark_done("02_variables")
	assert_eq(course.next_lesson_id(""), "03_types")
	assert_eq(course.next_lesson_id("02_variables"), "03_types")
	assert_eq(course.next_lesson_id("03_types"), "04_conditionals")


func test_next_lesson_wraps_and_finishes() -> void:
	assert_eq(course.next_lesson_id("04_conditionals"), "05_loops")
	course.mark_done("01_hello")
	course.mark_done("02_variables")
	course.mark_done("03_types")
	course.mark_done("04_conditionals")
	course.mark_done("05_loops")
	assert_eq(course.next_lesson_id(""), "")


func test_reset_progress_clears_everything() -> void:
	course.mark_done("01_hello")
	course.reset_progress()
	assert_eq(course.completed_count(), 0)
	assert_false(course.is_done("01_hello"))
	assert_eq(course.last_lesson(), "")


func test_german_catalog_loads_with_identical_code() -> void:
	var de := CourseService.new()
	de.progress_path = TEST_DIR.path_join("progress_de.json")
	de.set_locale("de")
	var result: Dictionary = de.load_catalog()
	assert_true(bool(result.get("ok", false)), str(result.get("error", "")))
	var lessons: Array = de.lessons()
	assert_eq(lessons.size(), 5)
	assert_eq(str(lessons[0].get("exercise", {}).get("typing", {}).get("target", "")), "print(\"Hello, Qorix!\")\n")
	# Hints are localized; the code target is not.
	var hint0 := str(lessons[0].get("exercise", {}).get("typing", {}).get("hints", [])[0].get("text", ""))
	assert_true(hint0.contains("Tippe"))
	assert_false(hint0.contains("Escribe"))


func test_spanish_catalog_loads_with_identical_code() -> void:
	var es := CourseService.new()
	es.progress_path = TEST_DIR.path_join("progress_es.json")
	es.set_locale("es")
	var result: Dictionary = es.load_catalog()
	assert_true(bool(result.get("ok", false)), str(result.get("error", "")))
	var lessons: Array = es.lessons()
	assert_eq(lessons.size(), 5)
	assert_eq(str(lessons[0].get("exercise", {}).get("typing", {}).get("target", "")), "print(\"Hello, Qorix!\")\n")
	var hint0 := str(lessons[0].get("exercise", {}).get("typing", {}).get("hints", [])[0].get("text", ""))
	assert_true(hint0.contains("Escribe"))


func test_an_unknown_locale_falls_back_to_english() -> void:
	var other := CourseService.new()
	other.progress_path = TEST_DIR.path_join("progress_zz.json")
	other.set_locale("zz")
	var result: Dictionary = other.load_catalog()
	assert_true(bool(result.get("ok", false)))
	var lessons: Array = other.lessons()
	assert_eq(lessons.size(), 5)
	# The English catalog is returned, target identical.
	assert_eq(str(lessons[0].get("exercise", {}).get("typing", {}).get("target", "")), "print(\"Hello, Qorix!\")\n")


func test_the_practice_report_names_the_catalog_id() -> void:
	assert_eq(CourseService.COURSE_ID, "griddycode.python_journey")


func _lesson(id: String) -> Dictionary:
	return course.lesson(id)


func test_a_missing_lesson_id_is_empty() -> void:
	assert_eq(_lesson("nope"), {})


func test_build_spec_hybrid_phases_are_ordered() -> void:
	var lesson: Dictionary = _lesson("01_hello")
	var spec: Dictionary = course.build_spec(lesson, 42, true)

	assert_eq(str(spec.get("kind", "")), "hybrid")
	assert_eq(int(spec.get("doc", 0)), 42)
	assert_eq(str(spec.get("title", "")), "Say hello")
	assert_true(bool(spec.get("auto_advance", false)))

	var phases: Array = spec.get("phases", [])
	assert_eq(phases.size(), 2)
	assert_eq(str(phases[0].get("kind", "")), "typing")
	assert_eq(str(phases[0].get("target", "")), "print(\"Hello, Qorix!\")\n")
	assert_eq(str(phases[0].get("mode", "")), "strict")
	assert_eq(str(phases[1].get("kind", "")), "freeform")

	# Run-backed validation: stdout checks, not text checks.
	var validation: Dictionary = phases[1].get("validation", {})
	var tests: Array = validation.get("tests", [])
	assert_ne(tests.size(), 0)
	assert_eq(str(tests[0].get("type", "")), "stdout_contains")
	assert_eq(int(validation.get("timeout_ms", 0)), 15000)


func test_build_spec_without_python_falls_back_to_text_tests() -> void:
	var lesson: Dictionary = _lesson("01_hello")
	var spec: Dictionary = course.build_spec(lesson, 7, false)

	var phases: Array = spec.get("phases", [])
	var validation: Dictionary = phases[1].get("validation", {})
	var tests: Array = validation.get("tests", [])
	assert_ne(tests.size(), 0)
	assert_eq(str(tests[0].get("type", "")), "contains")


func test_build_spec_carries_lesson_marks_and_hints() -> void:
	var lesson: Dictionary = _lesson("04_conditionals")
	var spec: Dictionary = course.build_spec(lesson, 9, true)

	var phases: Array = spec.get("phases", [])
	var marks: Array = phases[0].get("marks", [])
	var hints: Array = phases[0].get("hints", [])
	assert_ne(marks.size(), 0)
	assert_ne(hints.size(), 0)
	assert_eq(str(marks[0].get("id", "")), "condition")


func test_catalog_validation_rejects_broken_documents() -> void:
	var problems: Array = CourseService.validate_catalog({"lessons": []})
	assert_true(problems.is_empty())

	problems = CourseService.validate_catalog({"lessons": [{"id": "a"}]})
	assert_ne(problems.size(), 0)

	problems = CourseService.validate_catalog({
		"lessons": [
			{"id": "a", "title": "A", "exercise": {"typing": {"target": "print(1)\n"}, "freeform": {"text": {"tests": []}}}},
			{"id": "a", "title": "A", "exercise": {"typing": {"target": "print(1)\n"}, "freeform": {"text": {"tests": []}}}},
		],
	})
	assert_eq(problems.size() >= 1, true)
