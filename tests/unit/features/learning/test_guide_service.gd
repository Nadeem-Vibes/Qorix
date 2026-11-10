extends "res://tests/support/test_case.gd"

## Guide session lifecycle: start, progress, divergence, mistake, hints, reset,
## terminal states and teardown. The document and view are small duck-typed
## stubs, so the suite runs headlessly without the editor scene.

const Guide = preload("res://src/features/learning/guide/guide_service.gd")
const Validation = preload("res://src/features/learning/exercise/exercise_validation.gd")
const Result = preload("res://src/features/mods/mod_result.gd")

const MOD := "griddycode.guide_test"


class FakeView:
	var document = null
	var text := ""
	var caret_line := 0
	var caret_column := 0
	var selection := false
	var wrap_mode: int = TextEdit.LINE_WRAPPING_BOUNDARY
	var indent_automatic := true
	var auto_brace_completion_enabled := true
	var code_completion_enabled := true
	var focus_requests := 0

	func grab_focus() -> void:
		focus_requests += 1

	func get_caret_line() -> int:
		return caret_line

	func get_caret_column() -> int:
		return caret_column

	func has_selection() -> bool:
		return selection

	func set_document_text(value: String, _mark_clean := true) -> void:
		text = value


class FakeDocument:
	var id := 7
	var path := "C:/workspace/hello.py"
	var view = null
	var caret_line := 0
	var caret_column := 0

	func text() -> String:
		return view.text


var _fake_document = null
var _fake_active_document = null
var _fake_events: Array = []


func _find_fake(id_value) -> Variant:
	if _fake_document == null:
		return null
	return _fake_document if int(id_value) == int(_fake_document.id) else null


func _active_fake() -> Variant:
	return _fake_active_document if _fake_active_document != null else _fake_document


func _publish_fake(name: String, payload: Dictionary) -> void:
	_fake_events.append({"name": name, "payload": payload})


func _mark_dirty_fake(_document) -> void:
	pass


func _session() -> Dictionary:
	var document := FakeDocument.new()
	var view := FakeView.new()
	view.document = document
	document.view = view

	_fake_document = document
	_fake_active_document = null
	_fake_events = []

	var guide = Guide.new()
	guide.setup({
		"find_document": Callable(self, "_find_fake"),
		"active_document": Callable(self, "_active_fake"),
		"publish": Callable(self, "_publish_fake"),
		"overlay": null,
		"hints": null,
		"validator": Validation.new(),
		"mark_dirty": Callable(self, "_mark_dirty_fake"),
	})
	return {"guide": guide, "doc": document, "view": view, "events": _fake_events}


func _names(events: Array) -> Array:
	var out: Array = []
	for entry in events:
		out.append(str((entry as Dictionary).get("name", "")))
	return out


func test_start_publishes_and_guards_editor_settings() -> void:
	var session := _session()
	var guide = session["guide"]
	var view = session["view"]
	var events: Array = session["events"]

	var started: Dictionary = guide.start(MOD, {
		"doc": 7,
		"target": "print(\"Hi\")\n",
		"marks": [{"id": "fn", "text": "print"}],
		"hints": [{"on": "start", "text": "Type this."}],
	})
	check(bool(started.get("ok", false)), "session starts")
	assert_eq(str(started.get("value", {}).get("state", "")), "active", "active after start")
	check(_names(events).has("guide.started"), "guide.started is published")
	assert_eq(int(view.wrap_mode), TextEdit.LINE_WRAPPING_NONE, "guidance forces no-wrap")
	assert_false(bool(view.indent_automatic), "auto-indent is off during a session")
	assert_false(bool(view.auto_brace_completion_enabled), "auto-brace is off during a session")
	assert_false(bool(view.code_completion_enabled), "completion is off during a session")
	assert_eq(int(started.get("value", {}).get("hints", 0)), 1, "the start hint was shown")


func test_typing_advances_and_completes() -> void:
	var session := _session()
	var guide = session["guide"]
	var view = session["view"]
	var events: Array = session["events"]

	guide.start(MOD, {"doc": 7, "target": "print(\"Hi\")"})
	view.text = "pri"
	guide.on_text_changed(view)
	var state: Dictionary = guide.public_state()
	assert_eq(int(state.get("prefix", -1)), 3, "prefix follows the buffer")
	check(_names(events).has("guide.progress"), "progress is published")

	view.text = "print(\"Hi\")"
	guide.on_text_changed(view)
	state = guide.public_state()
	assert_eq(str(state.get("state", "")), "completed", "the full target completes")
	check(_names(events).has("guide.validated"), "validated is published")
	check(_names(events).has("guide.completed"), "completed is published")
	assert_true(bool(view.indent_automatic), "settings are restored on completion")


func test_trailing_newline_is_optional_for_completion() -> void:
	# The lesson's final newline is not drawn by the ghost. Typing the last
	# visible character must finish the step; pressing Enter afterwards is
	# still allowed but cannot be an invisible requirement.
	var session := _session()
	var guide = session["guide"]
	var view = session["view"]
	var events: Array = session["events"]

	guide.start(MOD, {"doc": 7, "target": "id = \"example.hello\"\n"})
	view.text = "id = \"example.hello\""
	guide.on_text_changed(view)
	assert_eq(
		str(guide.public_state().get("state", "")),
		"completed",
		"the last visible character completes a target that ends with a newline",
	)
	assert_eq(int(guide.public_state().get("percent", 0)), 100, "completion reports 100%")
	check(_names(events).has("guide.completed"), "the final visible character emits completion")

	# An internal newline is still required and still part of the target.
	var multiline := _session()
	var multiline_guide = multiline["guide"]
	var multiline_view = multiline["view"]
	multiline_guide.start(MOD, {"doc": 7, "target": "a\nb\n"})
	multiline_view.text = "a\n"
	multiline_guide.on_text_changed(multiline_view)
	assert_eq(
		str(multiline_guide.public_state().get("state", "")),
		"active",
		"internal newlines are still typed",
	)
	multiline_view.text = "a\nb"
	multiline_guide.on_text_changed(multiline_view)
	assert_eq(
		str(multiline_guide.public_state().get("state", "")),
		"completed",
		"the last visible line completes the multi-line target",
	)


func test_mark_entry_and_segment_events() -> void:
	var session := _session()
	var guide = session["guide"]
	var view = session["view"]
	var events: Array = session["events"]

	guide.start(MOD, {
		"doc": 7,
		"target": "print(\"Hi\")",
		"marks": [{"id": "fn", "text": "print"}, {"id": "msg", "text": "\"Hi\""}],
		"hints": [{"on": "mark", "mark": "fn", "text": "This is print."}],
	})
	view.text = "p"
	guide.on_text_changed(view)
	check(_names(events).has("guide.progress"), "progress before a mark ends")

	view.text = "print"
	guide.on_text_changed(view)
	check(_names(events).has("guide.segment"), "a completed mark emits a segment")


func test_divergence_pauses_and_recovery_resumes() -> void:
	var session := _session()
	var guide = session["guide"]
	var view = session["view"]
	var events: Array = session["events"]
	var sink_events: Array = []
	var sink := func(event: String, payload: Dictionary) -> void:
		sink_events.append({"event": event, "payload": payload})

	guide.start(MOD, {"doc": 7, "target": "print(\"Hi\")"}, sink)
	view.text = "prXnt"
	guide.on_text_changed(view)
	var state: Dictionary = guide.public_state()
	assert_eq(str(state.get("state", "")), "diverged", "a wrong edit diverges")
	check(bool(state.get("paused", false)), "diverged sessions pause filtering")
	check(_names(events).has("guide.diverged"), "diverged is published")

	# The event bus is shared by every mod; only the owning mod's session sink
	# receives the text that was actually typed.
	var public_payload: Dictionary = {}
	for entry in events:
		if str((entry as Dictionary).get("name", "")) == "guide.diverged":
			public_payload = (entry as Dictionary).get("payload", {})
	assert_false(public_payload.has("actual"), "the public event does not carry document text")
	var private_payload: Dictionary = {}
	for entry in sink_events:
		if str((entry as Dictionary).get("event", "")) == "diverged":
			private_payload = (entry as Dictionary).get("payload", {})
	check(private_payload.has("actual"), "the owning mod still gets the actual text")

	view.text = "pri"
	guide.on_text_changed(view)
	state = guide.public_state()
	assert_eq(str(state.get("state", "")), "active", "returning to the prefix resumes")
	assert_false(bool(state.get("paused", true)), "filtering resumes")


func test_wrong_key_is_a_mistake_and_counts() -> void:
	var session := _session()
	var guide = session["guide"]
	var view = session["view"]
	var events: Array = session["events"]

	guide.start(MOD, {"doc": 7, "target": "abc"})
	var decision: Dictionary = guide.filter({"kind": "text", "text": "x"})
	assert_eq(str(decision.get("action", "")), "swallow", "strict mode blocks the key")
	var state: Dictionary = guide.public_state()
	assert_eq(int(state.get("mistakes", 0)), 1, "mistake is counted")
	check(_names(events).has("guide.mistake"), "guide.mistake is published")


func test_filter_passes_when_the_user_switched_documents() -> void:
	var session := _session()
	var guide = session["guide"]
	guide.start(MOD, {"doc": 7, "target": "abc"})
	var other := FakeDocument.new()
	other.id = 9
	other.path = "C:/workspace/other.py"
	var other_view := FakeView.new()
	other_view.document = other
	other.view = other_view
	_fake_document = other

	var decision: Dictionary = guide.filter({"kind": "text", "text": "x"})
	assert_eq(str(decision.get("action", "")), "pass", "a session on another document never swallows keys")


func test_pause_resume_reset_and_stop() -> void:
	var session := _session()
	var guide = session["guide"]
	var view = session["view"]
	var events: Array = session["events"]

	guide.start(MOD, {"doc": 7, "target": "abc"})
	check(bool(guide.pause(MOD).get("ok", false)), "pause succeeds")
	assert_eq(str(guide.public_state().get("state", "")), "paused", "paused state")

	view.text = "ab"
	check(bool(guide.resume(MOD).get("ok", false)), "resume succeeds")
	assert_eq(int(guide.public_state().get("prefix", -1)), 2, "resume reconciles the buffer")

	check(bool(guide.reset(MOD, {"restore": "start"}).get("ok", false)), "reset succeeds")
	assert_eq(str(view.text), "", "reset restores the start text")
	assert_eq(int(guide.public_state().get("prefix", -1)), 0, "reset clears the prefix")

	check(bool(guide.stop(MOD, "done").get("ok", false)), "stop succeeds")
	assert_eq(str(guide.public_state().get("state", "")), "stopped", "stopped state")
	check(_names(events).has("guide.stopped"), "guide.stopped is published")
	assert_true(bool(view.indent_automatic), "stop restores editor settings")


func test_second_owner_is_refused() -> void:
	var session := _session()
	var guide = session["guide"]
	guide.start(MOD, {"doc": 7, "target": "abc"})
	var other: Dictionary = guide.start("griddycode.other", {"doc": 7, "target": "abc"})
	assert_eq(Result.code_of(other), "state.invalid", "a guide session is exclusive")


func test_validation_pass_and_fail() -> void:
	var pass_session := _session()
	var pass_guide = pass_session["guide"]
	var pass_view = pass_session["view"]
	var pass_events: Array = pass_session["events"]
	pass_guide.start(MOD, {
		"doc": 7,
		"target": "ok",
		"validation": {"type": "exact_text", "value": "ok"},
	})
	pass_view.text = "ok"
	pass_guide.on_text_changed(pass_view)
	assert_eq(str(pass_guide.public_state().get("state", "")), "completed", "matching text passes")
	check(_names(pass_events).has("guide.completed"), "completion is published")

	var fail_session := _session()
	var fail_guide = fail_session["guide"]
	var fail_view = fail_session["view"]
	var fail_events: Array = fail_session["events"]
	fail_guide.start(MOD, {
		"doc": 7,
		"target": "no",
		"validation": {"type": "exact_text", "value": "yes"},
	})
	fail_view.text = "no"
	fail_guide.on_text_changed(fail_view)
	assert_eq(str(fail_guide.public_state().get("state", "")), "failed", "a failed check fails the session")
	check(_names(fail_events).has("guide.validated"), "the failure is reported through validated")


func test_focus_returns_to_the_view_on_start_resume_and_reset() -> void:
	var session := _session()
	var guide = session["guide"]
	var view = session["view"]

	guide.start(MOD, {"doc": 7, "target": "abc"})
	assert_eq(view.focus_requests, 1, "starting a guide puts the caret back in the view")

	guide.pause(MOD)
	guide.resume(MOD)
	assert_eq(view.focus_requests, 2, "resuming returns focus after a dock-button click")

	guide.reset(MOD)
	assert_eq(view.focus_requests, 3, "retry/reset returns focus to the view")


func test_focus_is_not_taken_from_another_document() -> void:
	var session := _session()
	var guide = session["guide"]
	var view = session["view"]
	var other := FakeDocument.new()
	other.id = 8
	other.view = FakeView.new()
	_fake_active_document = other

	guide.start(MOD, {"doc": 7, "target": "abc"})
	assert_eq(view.focus_requests, 0, "a background guide does not pull focus from the active tab")


func test_set_target_mode_and_progression() -> void:
	var session := _session()
	var guide = session["guide"]
	guide.start(MOD, {"doc": 7, "target": "abc"})
	check(bool(guide.set_target(MOD, "xy").get("ok", false)), "set_target succeeds")
	assert_eq(int(guide.public_state().get("total_clusters", 0)), 2, "the new target compiles")
	check(bool(guide.set_mode(MOD, "coach").get("ok", false)), "set_mode succeeds")
	assert_eq(str(guide.public_state().get("mode", "")), "coach", "mode changed")
	check(bool(guide.set_progression(MOD, "line").get("ok", false)), "set_progression succeeds")
	assert_eq(str(guide.public_state().get("progression", "")), "line", "progression changed")
	assert_eq(Result.code_of(guide.set_mode(MOD, "nope")), "guide.invalid_spec", "bad mode is refused")
