extends RefCounted

## Host-owned guided typing session.
##
## One session at a time. The service reconciles the document against a compiled
## target, drives the overlay, filters keys through GuideFilter and publishes the
## `guide.*` catalogue. Validation is delegated to ExerciseValidation so typing
## exercises and standalone guides behave identically.
##
## The editor settings a session depends on (no wrap, no auto-indent, no
## auto-brace, no completion) are snapshotted on start and restored on every
## terminal state. A session never edits the document itself except on an
## explicit reset or insert decision.

const Matcher = preload("res://src/features/learning/guide/guide_matcher.gd")
const Layout = preload("res://src/features/learning/guide/guide_layout.gd")
const Filter = preload("res://src/features/learning/guide/guide_filter.gd")
const Columns = preload("res://src/features/mods/mod_text_columns.gd")
const Result = preload("res://src/features/mods/mod_result.gd")
const Validation = preload("res://src/features/learning/exercise/exercise_validation.gd")
const GHOST_ALPHA := 0.32

const IDLE_HINT_MS := 12000.0
const HINT_TTL := 6.0
const TERMINAL_STATES := ["stopped", "failed", "completed"]

var owner_id := ""
var session_id: int = 0
var state := "idle"
var paused := false
var doc_id: int = 0
var title := ""
var compiled: Dictionary = {}
var validation: Dictionary = {}
var prefix_cp: int = 0
var mistakes: int = 0
var hints_shown: int = 0
var started_at_ms: int = 0
var ended_at_ms: int = 0
var last_reason := ""

var _context: Dictionary = {}
var _spec: Dictionary = {}
var _document = null
var _view = null
var _sink: Callable = Callable()
var _validator = null
var _overlay = null
var _hints = null

var _start_text := ""
var _checkpoint_text := ""
var _settings_snapshot: Dictionary = {}
var _settings_applied := false

var _now_ms: float = 0.0
var _idle_ms: float = 0.0
var _next_id: int = 0
var _notify_every: int = 8
var _last_progress_cp: int = -1
var _marks_entered: Dictionary = {}
var _segments_done: Dictionary = {}
var _validation_token: int = 0
var _last_hint := ""


## context:
##   find_document   Callable(id) -> document or null
##   active_document Callable() -> document or null
##   publish         Callable(name, payload)
##   overlay         GuideOverlay or null
##   hints           GuideHintLayer or null
##   validator       ExerciseValidation or null
##   mark_dirty      Callable(document), optional
func setup(context: Dictionary) -> void:
	_context = context
	_overlay = context.get("overlay", null)
	_hints = context.get("hints", null)
	_validator = context.get("validator", null)


func mod_id() -> String:
	return owner_id


func is_live() -> bool:
	return !TERMINAL_STATES.has(state) and state != "idle" and state != "starting"


func start(mod_id_value: String, spec: Dictionary, sink: Callable = Callable()) -> Dictionary:
	var key := str(mod_id_value)
	if is_live() and owner_id != key:
		return Result.error(
			"state.invalid",
			"Another mod already owns the active guide session.",
		)

	var built := Matcher.compile(spec)
	if !bool(built.get("ok", false)):
		return built

	var document = _resolve_document(spec.get("doc", 0))
	if document == null:
		return Result.error("doc.stale_handle", "The guide document is not open.")

	if is_live():
		_stop_internal("restarted")

	_reset_runtime()
	owner_id = key
	_next_id += 1
	session_id = _next_id
	_spec = spec.duplicate(true)
	compiled = built
	validation = _validation_spec(spec.get("validation", spec.get("tests", null)))
	_document = document
	_view = document.view
	doc_id = int(document.id)
	title = str(spec.get("title", ""))
	_notify_every = maxi(1, int(spec.get("notify_every", 8)))
	_start_text = _text()
	_checkpoint_text = _start_text
	started_at_ms = int(Time.get_ticks_msec())
	_sink = sink
	state = "active"

	_apply_session_settings()
	_reconcile(true)

	_publish("guide.started", {
		"session": session_id,
		"doc": doc_id,
		"title": title,
		"target": str(compiled.get("target", "")),
		"clusters": int(compiled.get("cluster_count", 0)),
		"mode": str(compiled.get("mode", "strict")),
		"progression": str(compiled.get("progression", "character")),
		"display": (compiled.get("display", {}) as Dictionary).duplicate(true),
	})
	_show_hints("start")
	_sync_overlay()
	_notify_sink("started", {})

	if state == "active":
		_focus_view()
	if state == "active" and prefix_cp >= Matcher.completion_length(str(compiled.get("target", ""))):
		_complete_target()
	return Result.ok(public_state())


func state_snapshot(mod_id_value: String, id: int = 0) -> Dictionary:
	if owner_id.is_empty():
		return Result.ok({
			"session": 0, "state": "idle", "paused": false, "prefix": 0,
			"doc": 0, "title": "", "validation": {"configured": false, "pending": false, "token": 0},
		})
	var check := _check_owner(mod_id_value, id)
	if !check.is_empty():
		return check
	return Result.ok(public_state())


func filter(event: Dictionary) -> Dictionary:
	if !is_live() or paused or state != "active":
		return Filter.decide({"active": false}, event)
	if !_is_active_document():
		# The session belongs to a document the user is not typing in; never
		# swallow keys from another view.
		return Filter.decide({"active": false}, event)

	var caret := _caret()
	var decision := Filter.decide({
		"compiled": compiled,
		"prefix_cp": prefix_cp,
		"caret_line": int(caret.get("line", 0)),
		"caret_col": int(caret.get("col", 0)),
		"has_selection": _has_selection(),
		"paused": paused,
		"active": state == "active",
	}, event)

	if bool(decision.get("mistake", false)):
		_note_mistake(decision)
	return decision


## Called by the composition root after any view emits content_changed.
func on_text_changed(view) -> Dictionary:
	if !is_live() or _document == null:
		return {}
	if view != null and int(view.document.id) != doc_id:
		return {}

	if state == "validating" and _validator != null:
		if _validator.has_pending():
			_validator.cancel(_validation_token)
		_validation_token = 0
		state = "active"

	_reconcile(false)

	if state == "diverged":
		return {"state": state}

	if state == "active" and prefix_cp >= Matcher.completion_length(str(compiled.get("target", ""))):
		_complete_target()
	return {"state": state, "prefix": prefix_cp}


## Called when the caret moves so the ghost and hint anchor follow it.
func on_caret_moved(view) -> void:
	if !is_live() or view != _view:
		return
	_sync_overlay()


func pause(mod_id_value: String, id: int = 0) -> Dictionary:
	var check := _check_owner(mod_id_value, id)
	if !check.is_empty():
		return check
	if !is_live():
		return Result.error("state.invalid", "There is no active guide session.")
	paused = true
	state = "paused"
	_sync_overlay()
	_notify_sink("state", {})
	return Result.ok(public_state())


func resume(mod_id_value: String, id: int = 0) -> Dictionary:
	var check := _check_owner(mod_id_value, id)
	if !check.is_empty():
		return check
	if state != "paused" and state != "diverged":
		return Result.error("state.invalid", "The session is not paused.")
	paused = false
	state = "active"
	_reconcile(false)
	_notify_sink("state", {})
	_focus_view()
	return Result.ok(public_state())


func reset(mod_id_value: String, options: Dictionary = {}) -> Dictionary:
	var check := _check_owner(mod_id_value, int(options.get("session", 0)))
	if !check.is_empty():
		return check
	if _document == null:
		return Result.error("state.invalid", "There is no guide session to reset.")

	var restore := str(options.get("restore", "start"))
	var text := _start_text
	if restore == "checkpoint":
		text = _checkpoint_text
	elif restore == "keep":
		text = _text()

	if _validator != null and _validation_token > 0:
		_validator.cancel(_validation_token)
		_validation_token = 0
	_set_text(text)
	mistakes = 0
	hints_shown = 0
	_marks_entered.clear()
	_segments_done.clear()
	_idle_ms = 0.0
	paused = false
	state = "active"
	prefix_cp = 0
	_last_progress_cp = -1
	_reconcile(true)
	_notify_sink("state", {})
	_focus_view()
	return Result.ok(public_state())


func stop(mod_id_value: String, reason: String = "") -> Dictionary:
	var check := _check_owner(mod_id_value, 0)
	if !check.is_empty():
		return check
	if TERMINAL_STATES.has(state):
		return Result.ok(public_state())
	_stop_internal(reason if !reason.is_empty() else "Stopped by the mod.")
	return Result.ok(public_state())


func stop_for_mod(mod_id_value: String, reason: String = "The mod stopped.") -> void:
	if owner_id == str(mod_id_value) and is_live():
		_stop_internal(reason)


## Stops the live session when its document closes — the view it points
## at is about to be freed. Returns whether a session was stopped.
func stop_for_document(document_id: int, reason: String = "The document was closed.") -> bool:
	if is_live() and doc_id == document_id:
		_stop_internal(reason)
		return true
	return false


func hint(mod_id_value: String, text: String, id: int = 0) -> Dictionary:
	var check := _check_owner(mod_id_value, id)
	if !check.is_empty():
		return check
	_show_host_hint(str(text))
	return Result.ok(true)


func set_target(mod_id_value: String, target: String, id: int = 0) -> Dictionary:
	var check := _check_owner(mod_id_value, id)
	if !check.is_empty():
		return check
	var next := _spec.duplicate(true)
	next["target"] = str(target)
	var built := Matcher.compile(next)
	if !bool(built.get("ok", false)):
		return built
	_spec = next
	compiled = built
	_reset_progress_marks()
	state = "active"
	_reconcile(true)
	return Result.ok(public_state())


func set_validation(mod_id_value: String, spec: Variant, id: int = 0) -> Dictionary:
	var check := _check_owner(mod_id_value, id)
	if !check.is_empty():
		return check
	validation = _validation_spec(spec)
	_spec["validation"] = spec
	return Result.ok(public_state())


func set_mode(mod_id_value: String, mode: String, id: int = 0) -> Dictionary:
	var check := _check_owner(mod_id_value, id)
	if !check.is_empty():
		return check
	var value := str(mode).to_lower()
	if !Matcher.MODES.has(value):
		return Result.error("guide.invalid_spec", "'%s' is not a guide mode." % value)
	compiled["mode"] = value
	_spec["mode"] = value
	return Result.ok(public_state())


func set_progression(mod_id_value: String, progression: String, id: int = 0) -> Dictionary:
	var check := _check_owner(mod_id_value, id)
	if !check.is_empty():
		return check
	var value := str(progression).to_lower()
	if !Matcher.PROGRESSIONS.has(value):
		return Result.error("guide.invalid_spec", "'%s' is not a progression." % value)
	compiled["progression"] = value
	_spec["progression"] = value
	return Result.ok(public_state())


func set_display(mod_id_value: String, display: Dictionary, id: int = 0) -> Dictionary:
	var check := _check_owner(mod_id_value, id)
	if !check.is_empty():
		return check
	var next := _spec.duplicate(true)
	next["display"] = display.duplicate(true)
	var built := Matcher.compile(next)
	if !bool(built.get("ok", false)):
		return built
	_spec = next
	compiled = built
	_sync_overlay()
	return Result.ok(public_state())


func submit(mod_id_value: String, id: int = 0) -> Dictionary:
	var check := _check_owner(mod_id_value, id)
	if !check.is_empty():
		return check
	if validation.is_empty():
		return Result.error("state.invalid", "This guide session has no validation.")
	return _begin_validation()


func resolve_validation(mod_id_value: String, token: int, passed: bool, details: Dictionary = {}) -> Dictionary:
	var check := _check_owner(mod_id_value, 0)
	if !check.is_empty():
		return check
	if _validator == null:
		return Result.error("state.invalid", "No validation runner is available.")
	var outcome: Dictionary = _validator.resolve(int(token), bool(passed), details)
	if !outcome.has("status"):
		return outcome
	return Result.ok(outcome)


func requires_run() -> bool:
	return !validation.is_empty() and Validation.needs_run(validation)


static func validator_needs_run(spec: Variant) -> bool:
	return Validation.needs_run(spec)


func tick(delta: float) -> void:
	var ms := maxf(0.0, float(delta)) * 1000.0
	_now_ms += ms
	if _hints != null and _hints.has_method("tick"):
		_hints.tick(maxf(0.0, float(delta)))
	if !is_live() or paused or state != "active":
		return

	_idle_ms += ms
	if _idle_ms >= IDLE_HINT_MS:
		_idle_ms = 0.0
		_show_hints("idle")


func public_state() -> Dictionary:
	var target := str(compiled.get("target", ""))
	var position := Columns.position_of(target, prefix_cp)
	return {
		"session": session_id,
		"state": state,
		"doc": doc_id,
		"title": title,
		"paused": paused,
		"prefix": prefix_cp,
		"clusters": Matcher.cluster_index(compiled, prefix_cp),
		"total_clusters": int(compiled.get("cluster_count", 0)),
		"percent": _percent(),
		"position": {"line": int(position.get("line", 0)), "col": int(position.get("col", 0))},
		"mistakes": mistakes,
		"hints": hints_shown,
		"mode": str(compiled.get("mode", "strict")),
		"progression": str(compiled.get("progression", "character")),
		"display": (compiled.get("display", {}) as Dictionary).duplicate(true),
		"validation": {
			"configured": !validation.is_empty(),
			"pending": _validator != null and _validator.has_pending(),
			"token": _validation_token,
		},
		"stats": stats(),
	}


func stats() -> Dictionary:
	var elapsed := (ended_at_ms if ended_at_ms > 0 else int(Time.get_ticks_msec())) - started_at_ms
	return {
		"duration_ms": maxi(0, elapsed),
		"mistakes": mistakes,
		"hints": hints_shown,
	}


## A completed target reports 100% even when the learner stopped at the last
## visible character and did not type the optional trailing newline.
func _percent() -> int:
	var target := str(compiled.get("target", ""))
	var required := Matcher.completion_length(target)
	if required <= 0:
		return 0
	return int(round(float(mini(prefix_cp, required)) / float(required) * 100.0))


# ── INTERNALS ───────────────────────────────────────────────────────────────

func _reset_runtime() -> void:
	state = "idle"
	paused = false
	compiled = {}
	validation = {}
	prefix_cp = 0
	mistakes = 0
	hints_shown = 0
	started_at_ms = 0
	ended_at_ms = 0
	_document = null
	_view = null
	_start_text = ""
	_checkpoint_text = ""
	_settings_snapshot = {}
	_settings_applied = false
	_idle_ms = 0.0
	_notify_every = 8
	_last_progress_cp = -1
	_marks_entered.clear()
	_segments_done.clear()
	_validation_token = 0
	_last_hint = ""
	_sink = Callable()
	last_reason = ""


func _resolve_document(raw: Variant):
	var find: Variant = _context.get("find_document", Callable())
	var active: Variant = _context.get("active_document", Callable())
	var wanted := int(raw) if raw is int or raw is float else 0
	if wanted > 0:
		if find is Callable and (find as Callable).is_valid():
			return (find as Callable).call(wanted)
		return null
	if active is Callable and (active as Callable).is_valid():
		return (active as Callable).call()
	return null


func _text() -> String:
	if _document == null:
		return ""
	return str(_document.text())


func _caret() -> Dictionary:
	if _view != null and is_instance_valid(_view):
		return {
			"line": int(_view.get_caret_line()),
			"col": int(_view.get_caret_column()),
		}
	if _document != null:
		return {"line": int(_document.caret_line), "col": int(_document.caret_column)}
	return {"line": 0, "col": 0}


func _has_selection() -> bool:
	return _view != null and is_instance_valid(_view) and _view.has_selection()


func _is_active_document() -> bool:
	var active: Variant = _context.get("active_document", Callable())
	if !(active is Callable) or !(active as Callable).is_valid():
		return true
	return (active as Callable).call() == _document


## A mod starts a session from its own dock button, so keyboard focus is on
## that button. Typing only reaches the editor when its view owns focus; never
## pull focus to a background document.
func _focus_view() -> void:
	if !_is_active_document():
		return
	if _view == null or !is_instance_valid(_view) or !_view.has_method("grab_focus"):
		return
	_view.grab_focus()


func _reconcile(first: bool) -> void:
	if compiled.is_empty() or _document == null:
		return
	var previous := prefix_cp
	var result := Matcher.reconcile(compiled, _text(), previous)
	prefix_cp = int(result.get("prefix_cp", 0))
	var on_track := bool(result.get("on_track", true))

	if !on_track:
		if state != "diverged":
			state = "diverged"
			paused = true
			_publish("guide.diverged", {
				"session": session_id,
				"doc": doc_id,
				"position": result.get("position", {}),
				"expected": str(result.get("expected", "")),
			})
			_show_hints("diverged")
			_notify_sink("diverged", {
				"expected": str(result.get("expected", "")),
				"actual": str(result.get("actual", "")),
				"position": result.get("position", {}),
			})
		_sync_overlay()
		return

	if state == "diverged":
		state = "active"
		paused = false
		_notify_sink("state", {})

	_sync_overlay()

	var target := str(compiled.get("target", ""))
	if first or prefix_cp != previous:
		_idle_ms = 0.0
		_enter_marks()
		_finish_segments()

	if first or prefix_cp != previous or prefix_cp != _last_progress_cp:
		if prefix_cp - _last_progress_cp >= _notify_every or prefix_cp == target.length() or first:
			_last_progress_cp = prefix_cp
			var position := Columns.position_of(target, prefix_cp)
			_publish("guide.progress", {
				"session": session_id,
				"doc": doc_id,
				"prefix": prefix_cp,
				"clusters": Matcher.cluster_index(compiled, prefix_cp),
				"total_clusters": int(compiled.get("cluster_count", 0)),
				"percent": _percent(),
				"position": {"line": int(position.get("line", 0)), "col": int(position.get("col", 0))},
			})
			_notify_sink("progress", {"prefix": prefix_cp})


func _enter_marks() -> void:
	var mark_id := Matcher.mark_starting_at(compiled, prefix_cp)
	if mark_id.is_empty() or _marks_entered.has(mark_id):
		return
	_marks_entered[mark_id] = true
	_show_hints("mark", mark_id)
	_notify_sink("mark", {"mark": mark_id})


func _finish_segments() -> void:
	var marks: Dictionary = compiled.get("marks", {})
	for id in marks.keys():
		var mark: Dictionary = marks[id]
		if prefix_cp < int(mark.get("end", 0)) or _segments_done.has(id):
			continue
		_segments_done[id] = true
		_checkpoint_text = _text()
		_publish("guide.segment", {
			"session": session_id,
			"doc": doc_id,
			"mark": str(id),
			"prefix": prefix_cp,
		})
		_show_hints("segment_done")
		_notify_sink("segment", {"mark": str(id)})


func _complete_target() -> void:
	if state == "validating" or state == "completed":
		return
	if validation.is_empty():
		state = "completed"
		_checkpoint_text = _text()
		_restore_session_settings()
		_show_hints("complete")
		_publish("guide.validated", {
			"session": session_id,
			"doc": doc_id,
			"passed": true,
			"results": [],
			"code": "",
			"message": "",
		})
		_publish("guide.completed", {
			"session": session_id,
			"doc": doc_id,
			"stats": stats(),
		})
		_sync_overlay()
		_notify_sink("validated", {"passed": true, "results": []})
		_notify_sink("completed", {})
		return
	_begin_validation()


func _begin_validation() -> Dictionary:
	if _validator == null:
		return Result.error("state.invalid", "No validation runner is available.")
	state = "validating"
	_validation_token = 0

	var context := {
		"text": _text(),
		"path": str(_document.path) if _document != null else "",
		"doc": doc_id,
	}
	var outcome: Dictionary = _validator.start(validation, context, Callable(self, "_on_validation_done"))
	var status := str(outcome.get("status", "failed"))

	if status == "pending":
		_validation_token = int(outcome.get("token", 0))
		_notify_sink("validating", {"token": _validation_token})
		return Result.ok({
			"state": state,
			"status": "pending",
			"token": _validation_token,
			"session": session_id,
		})

	if !outcome.has("status"):
		# A structured runner failure (no run bridge, invalid spec).
		var failure: Variant = outcome.get("error", {})
		var code := "state.invalid"
		var message := "Validation could not start."
		if failure is Dictionary:
			code = str((failure as Dictionary).get("code", code))
			message = str((failure as Dictionary).get("message", message))
		state = "failed"
		_restore_session_settings()
		_publish("guide.validated", {
			"session": session_id, "doc": doc_id, "passed": false,
			"results": [], "code": code, "message": message,
		})
		_notify_sink("validated", {"passed": false, "code": code, "message": message})
		return Result.error(code, message)

	return Result.ok(outcome)


func _on_validation_done(result: Dictionary) -> void:
	_validation_token = 0
	var passed := bool(result.get("passed", false))
	_restore_session_settings()

	if passed:
		state = "completed"
		_show_hints("complete")
		_publish("guide.validated", {
			"session": session_id,
			"doc": doc_id,
			"passed": true,
			"results": result.get("results", []),
			"code": "",
			"message": "",
		})
		_publish("guide.completed", {
			"session": session_id,
			"doc": doc_id,
			"stats": stats(),
		})
		_sync_overlay()
		_notify_sink("validated", {"passed": true, "results": result.get("results", [])})
		_notify_sink("completed", {})
		return

	state = "failed"
	_publish("guide.validated", {
		"session": session_id,
		"doc": doc_id,
		"passed": false,
		"results": result.get("results", []),
		"code": str(result.get("code", "exercise.failed")),
		"message": str(result.get("message", "Validation failed.")),
	})
	_sync_overlay()
	_notify_sink("validated", {
		"passed": false,
		"results": result.get("results", []),
		"code": str(result.get("code", "exercise.failed")),
		"message": str(result.get("message", "Validation failed.")),
	})


func _note_mistake(decision: Dictionary) -> void:
	mistakes += 1
	_idle_ms = 0.0
	var mark := Matcher.mark_at(compiled, prefix_cp)
	var mark_id := str(mark.get("id", ""))
	var target := str(compiled.get("target", ""))
	var position := Columns.position_of(target, prefix_cp)

	_publish("guide.mistake", {
		"session": session_id,
		"doc": doc_id,
		"count": mistakes,
		"mark": mark_id,
		"expected": str(decision.get("expected", "")),
		"reason": str(decision.get("reason", "")),
		"position": {"line": int(position.get("line", 0)), "col": int(position.get("col", 0))},
	})

	if _overlay != null and _overlay.has_method("flash_mistake"):
		_overlay.flash_mistake(int(position.get("line", 0)), int(position.get("col", 0)))

	var hints := Matcher.hints_for(compiled, "mistake", mark_id, mistakes)
	if !hints.is_empty():
		_show_host_hint(str(hints[mini(mistakes - 1, hints.size() - 1)]))
	elif !mark_id.is_empty() and mistakes % 3 == 0:
		var mark_hints := Matcher.hints_for(compiled, "mark", mark_id)
		if !mark_hints.is_empty():
			_show_host_hint(str(mark_hints[0]))

	_notify_sink("mistake", {
		"count": mistakes,
		"mark": mark_id,
		"expected": str(decision.get("expected", "")),
	})


func _show_hints(trigger: String, mark_id: String = "") -> void:
	var hints := Matcher.hints_for(compiled, trigger, mark_id)
	if hints.is_empty():
		return
	_show_host_hint(str(hints[0]))


func _show_host_hint(text: String) -> void:
	var clean := str(text).strip_edges()
	if clean.is_empty():
		return
	_last_hint = clean
	hints_shown += 1
	if _hints != null and _hints.has_method("show_hint"):
		var position := _caret()
		var anchor := screen_anchor(int(position.get("line", 0)), int(position.get("col", 0)))
		_hints.show_hint(clean, anchor, HINT_TTL)
	_notify_sink("hint", {"text": clean})


func screen_anchor(line: int, col: int) -> Vector2:
	if _view == null or !is_instance_valid(_view) or !_view.has_method("get_rect_at_line_column"):
		return Vector2.ZERO
	var font: Font = Layout.view_font(_view)
	var font_size := Layout.view_font_size(_view)
	var rect := Layout.position_rect(_view, line, col, font, font_size)
	var transform: Transform2D = _view.get_global_transform_with_canvas()
	return transform * rect.position


func _sync_overlay() -> void:
	if _overlay == null:
		return
	if state in ["completed", "stopped", "failed"]:
		_overlay.clear()
		return
	var ghost := Matcher.ghost(compiled, prefix_cp)
	var display: Dictionary = compiled.get("display", {})
	_overlay.set_session(_view, ghost, float(display.get("alpha", GHOST_ALPHA)))


func _apply_session_settings() -> void:
	if _view == null or !is_instance_valid(_view):
		return
	_settings_snapshot = {
		"wrap_mode": int(_view.wrap_mode),
		"indent_automatic": bool(_view.indent_automatic),
		"auto_brace_completion": bool(_view.auto_brace_completion_enabled),
		"code_completion": bool(_view.code_completion_enabled),
	}
	_settings_applied = true
	_view.wrap_mode = TextEdit.LINE_WRAPPING_NONE
	_view.indent_automatic = false
	_view.auto_brace_completion_enabled = false
	_view.code_completion_enabled = false


func _restore_session_settings() -> void:
	if !_settings_applied or _view == null or !is_instance_valid(_view) or _settings_snapshot.is_empty():
		_settings_applied = false
		return
	_view.wrap_mode = int(_settings_snapshot.get("wrap_mode", TextEdit.LINE_WRAPPING_NONE))
	_view.indent_automatic = bool(_settings_snapshot.get("indent_automatic", true))
	_view.auto_brace_completion_enabled = bool(_settings_snapshot.get("auto_brace_completion", true))
	_view.code_completion_enabled = bool(_settings_snapshot.get("code_completion", true))
	_settings_applied = false


func _set_text(text: String) -> void:
	if _view != null and is_instance_valid(_view):
		if _view.has_method("set_document_text"):
			_view.set_document_text(text, false)
		else:
			_view.text = text
	var dirty: Variant = _context.get("mark_dirty", Callable())
	if dirty is Callable and (dirty as Callable).is_valid() and _document != null:
		(dirty as Callable).call(_document)


func _stop_internal(reason: String) -> void:
	if _validator != null and _validation_token > 0:
		_validator.cancel(_validation_token)
		_validation_token = 0
	_restore_session_settings()
	if _overlay != null:
		_overlay.clear()
	if _hints != null and _hints.has_method("hide_hint"):
		_hints.hide_hint()
	ended_at_ms = int(Time.get_ticks_msec())
	state = "stopped"
	last_reason = reason
	_publish("guide.stopped", {
		"session": session_id,
		"doc": doc_id,
		"reason": reason,
		"stats": stats(),
	})
	_notify_sink("stopped", {"reason": reason})


func _reset_progress_marks() -> void:
	prefix_cp = 0
	_last_progress_cp = -1
	_marks_entered.clear()
	_segments_done.clear()
	_checkpoint_text = _start_text


func _check_owner(mod_id_value: String, id: int) -> Dictionary:
	if owner_id.is_empty():
		return Result.error("state.invalid", "There is no guide session.")
	if owner_id != str(mod_id_value):
		return Result.error("state.invalid", "Another mod owns the active guide session.")
	if int(id) > 0 and int(id) != session_id:
		return Result.error("state.invalid", "That guide session has ended.")
	return {}


func _validation_spec(raw: Variant) -> Dictionary:
	if raw == null:
		return {}
	if raw is Dictionary and (raw as Dictionary).is_empty():
		return {}
	if raw is Dictionary and (raw as Dictionary).has("type"):
		return (raw as Dictionary).duplicate(true)
	if raw is Dictionary and (raw as Dictionary).has("tests"):
		return (raw as Dictionary).duplicate(true)
	return {}


func _publish(name: String, payload: Dictionary) -> void:
	var publish: Variant = _context.get("publish", Callable())
	if publish is Callable and (publish as Callable).is_valid():
		(publish as Callable).call(name, payload)


func _notify_sink(event: String, payload: Dictionary) -> void:
	if _sink.is_valid():
		_sink.call(event, payload)
	elif _context.get("on_event") is Callable:
		var callable: Callable = _context["on_event"]
		if callable.is_valid():
			callable.call(event, payload)

