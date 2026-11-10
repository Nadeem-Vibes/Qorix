extends "res://tests/support/test_case.gd"

## Exercise engine: typing delegation, freeform validation, hybrid phases,
## retries with checkpoints, run-backed validation and teardown.

const Exercise = preload("res://src/features/learning/exercise/exercise_service.gd")
const Validation = preload("res://src/features/learning/exercise/exercise_validation.gd")
const Result = preload("res://src/features/mods/mod_result.gd")

const MOD := "griddycode.exercise_test"

var _fake_document = null
var _fake_active_document = null
var _fake_events: Array = []
var _runs_started: Array = []
var _runs_stopped: int = 0
var _hints: Array = []


class FakeView:
	var document = null
	var text := ""
	var caret_line := 0
	var caret_column := 0
	var focus_requests := 0

	func grab_focus() -> void:
		focus_requests += 1

	func set_document_text(value: String, _mark_clean := true) -> void:
		text = value


class FakeDocument:
	var id := 4
	var path := "C:/workspace/answer.py"
	var view = null
	var caret_line := 0
	var caret_column := 0

	func text() -> String:
		return view.text


class FakeGuide:
	var live := false
	var owner := ""
	var last_spec: Dictionary = {}
	var sink: Callable = Callable()
	var state_value := "active"
	var submit_passed := true

	func is_live() -> bool:
		return live

	func start(owner_value: String, spec: Dictionary, callback: Callable = Callable()) -> Dictionary:
		live = true
		owner = owner_value
		last_spec = spec.duplicate(true)
		sink = callback
		state_value = "active"
		return {"ok": true, "value": {"state": "active"}}

	func submit(_owner_value: String, _id: int = 0) -> Dictionary:
		var passed := submit_passed
		state_value = "completed" if passed else "failed"
		if sink.is_valid():
			sink.call("validated", {
				"passed": passed,
				"results": [{"name": "guided", "type": "exact_text", "passed": passed}],
				"code": "" if passed else "exercise.failed",
				"message": "" if passed else "The guided step did not pass.",
			})
			sink.call("completed", {})
		return {"ok": true, "value": {"status": "passed" if passed else "failed"}}

	func public_state() -> Dictionary:
		return {"state": state_value}

	func hint(_owner_value: String, _text: String, _session: int = 0) -> Dictionary:
		return {"ok": true}

	func reset(_owner_value: String, _options: Dictionary = {}) -> Dictionary:
		live = true
		state_value = "active"
		return {"ok": true}

	func stop(_owner_value: String, _reason: String = "") -> Dictionary:
		live = false
		state_value = "stopped"
		return {"ok": true}

	func stop_for_mod(_owner_value: String, _reason: String = "") -> void:
		live = false
		state_value = "stopped"

	func finish(passed: bool) -> void:
		state_value = "completed" if passed else "failed"
		if sink.is_valid():
			sink.call("validated", {"passed": passed, "results": []})
			if passed:
				sink.call("completed", {})


func _find_fake(id_value) -> Variant:
	if _fake_document == null:
		return null
	return _fake_document if int(id_value) == int(_fake_document.id) else null


func _active_fake() -> Variant:
	return _fake_active_document if _fake_active_document != null else _fake_document


func _publish_fake(name: String, payload: Dictionary) -> void:
	_fake_events.append({"name": name, "payload": payload})


func _show_hint_fake(text: String) -> void:
	_hints.append(text)


func _mark_dirty_fake(_document) -> void:
	pass


func _start_run(path: String, options: Dictionary) -> void:
	_runs_started.append([path, options])


func _stop_run() -> void:
	_runs_stopped += 1


func _session() -> Dictionary:
	var document := FakeDocument.new()
	var view := FakeView.new()
	view.document = document
	document.view = view

	_fake_document = document
	_fake_active_document = null
	_fake_events = []
	_hints = []
	_runs_started = []
	_runs_stopped = 0

	var validator = Validation.new()
	validator.set_run_bridge(Callable(self, "_start_run"), Callable(self, "_stop_run"))
	var guide := FakeGuide.new()
	var exercise = Exercise.new()
	exercise.setup({
		"guide": guide,
		"validator": validator,
		"find_document": Callable(self, "_find_fake"),
		"active_document": Callable(self, "_active_fake"),
		"publish": Callable(self, "_publish_fake"),
		"show_hint": Callable(self, "_show_hint_fake"),
		"mark_dirty": Callable(self, "_mark_dirty_fake"),
	})
	return {
		"exercise": exercise, "guide": guide, "validator": validator,
		"doc": document, "view": view, "events": _fake_events,
	}


func _names(events: Array) -> Array:
	var out: Array = []
	for entry in events:
		out.append(str((entry as Dictionary).get("name", "")))
	return out


func test_freeform_passes_text_validation_and_completes() -> void:
	var session := _session()
	var exercise = session["exercise"]
	var view = session["view"]
	var events: Array = session["events"]

	var started: Dictionary = exercise.start(MOD, {
		"kind": "freeform",
		"doc": 4,
		"title": "Print one",
		"prompt": "Print the number 1.",
		"validation": {"type": "exact_text", "value": "print(1)"},
	})
	check(bool(started.get("ok", false)), "freeform starts")
	assert_eq(str(started.get("value", {}).get("state", "")), "active")

	view.text = "print(1)"
	var submitted: Dictionary = exercise.submit(MOD, 0)
	check(bool(submitted.get("ok", false)), "submit succeeds")
	assert_eq(str(exercise.public_state().get("state", "")), "completed", "validation completes the exercise")
	check(_names(events).has("exercise.submitted"), "submitted is published")
	check(_names(events).has("exercise.completed"), "completed is published")
	assert_eq(int(exercise.public_state().get("attempts", 0)), 1, "first attempt is recorded")


func test_freeform_failure_and_retry_restore_start() -> void:
	var session := _session()
	var exercise = session["exercise"]
	var view = session["view"]

	exercise.start(MOD, {
		"kind": "freeform",
		"doc": 4,
		"prompt": "Print yes.",
		"validation": {"type": "exact_text", "value": "print(\"yes\")"},
	})
	view.text = "print(\"no\")"
	exercise.submit(MOD, 0)
	assert_eq(str(exercise.public_state().get("state", "")), "failed", "a failed check fails the exercise")

	var retried: Dictionary = exercise.retry(MOD, {"restore": "start"})
	check(bool(retried.get("ok", false)), "retry succeeds")
	assert_eq(str(view.text), "", "retry restores the start text")
	assert_eq(str(exercise.public_state().get("state", "")), "active", "retry re-activates")
	assert_eq(int(exercise.public_state().get("attempts", 0)), 2, "attempt counter grows")


func test_typing_delegates_to_the_guide() -> void:
	var session := _session()
	var exercise = session["exercise"]
	var guide: FakeGuide = session["guide"]

	exercise.start(MOD, {
		"kind": "typing",
		"doc": 4,
		"title": "Guided",
		"target": "print(1)",
		"validation": {"type": "exact_text", "value": "print(1)"},
	})
	check(guide.live, "the guide session started")
	assert_eq(str(guide.last_spec.get("target", "")), "print(1)", "the target was delegated")
	assert_eq(int(guide.last_spec.get("doc", 0)), 4, "the document was delegated")

	guide.finish(true)
	assert_eq(str(exercise.public_state().get("state", "")), "completed", "a passed guide completes the exercise")

	var errors := _session()
	errors["exercise"].start(MOD, {"kind": "typing", "doc": 4, "target": "abc"})
	errors["guide"].finish(false)
	assert_eq(str(errors["exercise"].public_state().get("state", "")), "failed", "a failed guide fails the exercise")


func test_hybrid_advances_phases_and_completes() -> void:
	var session := _session()
	var exercise = session["exercise"]
	var guide: FakeGuide = session["guide"]
	var view = session["view"]
	var events: Array = session["events"]

	var started: Dictionary = exercise.start(MOD, {
		"kind": "hybrid",
		"doc": 4,
		"title": "Build then extend",
		"phases": [
			{"id": "skeleton", "kind": "typing", "target": "def f():", "validation": {"type": "exact_text", "value": "def f():"}},
			{"id": "extend", "kind": "freeform", "prompt": "Add a body.", "validation": {"type": "contains", "value": "return"}},
		],
	})
	check(bool(started.get("ok", false)), "hybrid starts")

	guide.finish(true)
	assert_eq(str(exercise.public_state().get("state", "")), "passed", "phase one passes and waits")
	assert_eq(int(exercise.public_state().get("phase", -1)), 0, "still phase one")

	var advanced: Dictionary = exercise.advance(MOD, 0)
	check(bool(advanced.get("ok", false)), "advance succeeds")
	assert_eq(int(exercise.public_state().get("phase", -1)), 1, "phase two is active")
	check(_names(events).has("exercise.phase_changed"), "phase_changed is published")

	view.text = "def f():\n    return 1"
	exercise.submit(MOD, 0)
	assert_eq(str(exercise.public_state().get("state", "")), "completed", "the last phase completes")


func test_hybrid_auto_advance_does_not_complete_the_freeform_phase() -> void:
	## Regression: the guide emits "validated" and "completed" back to back.
	## With auto_advance the exercise used to advance into the freeform phase
	## and then treat the stale typing "completed" as the freeform result,
	## completing the exercise without any freeform attempt.
	var session := _session()
	var exercise = session["exercise"]
	var guide: FakeGuide = session["guide"]

	var started: Dictionary = exercise.start(MOD, {
		"kind": "hybrid",
		"doc": 4,
		"auto_advance": true,
		"phases": [
			{"id": "typing", "kind": "typing", "target": "abc"},
			{"id": "extend", "kind": "freeform", "prompt": "Add a body."},
		],
	})
	check(bool(started.get("ok", false)), "hybrid starts")

	guide.finish(true)
	var state: Dictionary = exercise.public_state()
	assert_eq(str(state.get("state", "")), "active", "the freeform phase is active, not completed")
	assert_eq(str(state.get("phase_kind", "")), "freeform", "auto advance moved into the freeform phase")


func test_hybrid_cannot_advance_before_a_typing_phase_finishes() -> void:
	var session := _session()
	var exercise = session["exercise"]
	exercise.start(MOD, {
		"kind": "hybrid",
		"doc": 4,
		"phases": [
			{"id": "one", "kind": "typing", "target": "abc"},
			{"id": "two", "kind": "freeform", "prompt": "Anything."},
		],
	})
	assert_eq(Result.code_of(exercise.advance(MOD, 0)), "exercise.invalid_state", "typing must finish first")


func test_run_backed_freeform_validation_resolves_from_the_run() -> void:
	var session := _session()
	var exercise = session["exercise"]
	var validator = session["validator"]
	var events: Array = session["events"]

	exercise.start(MOD, {
		"kind": "freeform",
		"doc": 4,
		"prompt": "Print the numbers 1 to 3.",
		"validation": {
			"tests": [
				{"name": "runs", "type": "exit_code", "value": 0},
				{"name": "output", "type": "stdout_regex", "value": "^1\\n2\\n3\\n$"},
			],
		},
	})
	var submitted: Dictionary = exercise.submit(MOD, 0)
	check(bool(submitted.get("ok", false)), "submit starts a validation run")
	assert_eq(str(exercise.public_state().get("state", "")), "validating", "state is validating")
	assert_eq(_runs_started.size(), 1, "the run bridge was called")

	validator.notify_run_finished("1\n2\n3\n", 0)
	assert_eq(str(exercise.public_state().get("state", "")), "completed", "the run result completes the exercise")
	check(_names(events).has("exercise.completed"), "completion is published")


func test_custom_validation_is_answered_with_its_token() -> void:
	var session := _session()
	var exercise = session["exercise"]
	exercise.start(MOD, {
		"kind": "freeform",
		"doc": 4,
		"prompt": "Explain the output.",
		"validation": {"type": "custom", "value": "teacher"},
	})
	var submitted: Dictionary = exercise.submit(MOD, 0)
	check(bool(submitted.get("ok", false)), "submit starts a custom check")
	assert_eq(str(exercise.public_state().get("state", "")), "validating", "the exercise waits for the mod")
	var token := int(exercise.public_state().get("validation", {}).get("token", 0))
	check(token > 0, "a custom token is issued")

	var resolved: Dictionary = exercise.resolve_validation(MOD, token, true, {
		"results": [{"name": "manual", "type": "custom", "passed": true}],
	})
	check(bool(resolved.get("ok", false)), "the owning mod can resolve the token")
	assert_eq(str(exercise.public_state().get("state", "")), "completed", "the answer completes the exercise")


func test_non_run_validation_never_starts_a_process() -> void:
	var session := _session()
	var exercise = session["exercise"]
	var view = session["view"]
	exercise.start(MOD, {
		"kind": "freeform",
		"doc": 4,
		"prompt": "Print one.",
		"validation": {"type": "contains", "value": "print"},
	})
	view.text = "print(1)"
	exercise.submit(MOD, 0)
	assert_eq(_runs_started.size(), 0, "a text check does not run a program")


func test_hint_and_stop() -> void:
	var session := _session()
	var exercise = session["exercise"]
	var events: Array = session["events"]

	exercise.start(MOD, {
		"kind": "freeform", "doc": 4, "prompt": "Anything.",
		"validation": {"tests": [{"name": "x", "type": "contains", "value": "x"}]},
	})
	check(bool(exercise.hint(MOD, "Try print().", 0).get("ok", false)), "hint succeeds")
	assert_eq(_hints.size(), 1, "the host hint layer was used")

	check(bool(exercise.stop(MOD, "user quit").get("ok", false)), "stop succeeds")
	assert_eq(str(exercise.public_state().get("state", "")), "stopped", "stopped state")
	check(_names(events).has("exercise.stopped"), "stopped is published")


func test_focus_returns_to_the_view_on_start_advance_and_retry() -> void:
	var session := _session()
	var exercise = session["exercise"]
	var guide: FakeGuide = session["guide"]
	var view = session["view"]

	exercise.start(MOD, {
		"kind": "hybrid",
		"doc": 4,
		"phases": [
			{"id": "one", "kind": "typing", "target": "abc"},
			{"id": "two", "kind": "freeform", "prompt": "Anything."},
		],
	})
	assert_eq(view.focus_requests, 1, "starting an exercise returns focus to the view")

	guide.finish(true)
	exercise.advance(MOD, 0)
	assert_eq(view.focus_requests, 2, "a phase change returns focus to the view")

	exercise.retry(MOD, {"restore": "keep"})
	assert_eq(view.focus_requests, 3, "retry returns focus after a dock-button click")


func test_background_exercise_does_not_take_focus() -> void:
	var session := _session()
	var exercise = session["exercise"]
	var view = session["view"]
	var other := FakeDocument.new()
	other.id = 5
	other.view = FakeView.new()
	_fake_active_document = other

	exercise.start(MOD, {"kind": "freeform", "doc": 4, "prompt": "Anything."})
	assert_eq(view.focus_requests, 0, "a background exercise does not pull focus from the active tab")


func test_second_owner_is_refused() -> void:
	var session := _session()
	var exercise = session["exercise"]
	exercise.start(MOD, {
		"kind": "freeform", "doc": 4, "prompt": "Anything.",
		"validation": {"tests": [{"name": "x", "type": "contains", "value": "x"}]},
	})
	var other: Dictionary = exercise.start("griddycode.other", {"kind": "freeform", "doc": 4, "prompt": "Anything."})
	assert_eq(Result.code_of(other), "state.invalid", "an exercise session is exclusive")


func test_invalid_phase_specs_are_refused() -> void:
	var session := _session()
	var exercise = session["exercise"]
	assert_eq(Result.code_of(exercise.start(MOD, {"kind": "nope", "doc": 4})), "exercise.invalid_spec")
	assert_eq(Result.code_of(exercise.start(MOD, {"kind": "typing", "doc": 4})), "exercise.invalid_spec")
	assert_eq(
		Result.code_of(exercise.start(MOD, {"kind": "freeform", "doc": 4})),
		"exercise.invalid_spec",
		"freeform needs a prompt or validation",
	)
