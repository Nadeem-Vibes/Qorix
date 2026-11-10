extends RefCounted

## Exercise engine: typing, freeform and hybrid sessions.
##
## A typing exercise delegates matching, ghosting and filtering to GuideService.
## A freeform exercise is a session over the document with a submit. A hybrid is
## an ordered phase list; each phase has its own kind and validation, and phase
## boundaries create text checkpoints for retry.
##
## The core never interprets course progress: the mod persists that through
## editor.progress. The service reports state, results and stats.

const Validation = preload("res://src/features/learning/exercise/exercise_validation.gd")
const Result = preload("res://src/features/mods/mod_result.gd")

const KINDS := ["typing", "freeform", "hybrid"]
const PHASE_KINDS := ["typing", "freeform"]
const STATES := [
	"idle", "starting", "active", "paused", "diverged", "validating",
	"passed", "failed", "completed", "stopped",
]
const TERMINAL_STATES := ["completed", "stopped"]
const MAX_PHASES := 8
const MAX_CHECKPOINTS := 20

var owner_id := ""
var exercise_id: int = 0
var state := "idle"
var kind := ""
var doc_id: int = 0
var title := ""
var prompt := ""
var phases: Array = []
var phase_index: int = 0
var stats_data: Dictionary = {
	"duration_ms": 0, "attempts": 1, "mistakes": 0, "hints": 0,
}
var last_reason := ""
var last_result: Dictionary = {}

var _context: Dictionary = {}
var _guide = null
var _validator = null
var _document = null
var _next_id: int = 0
var _start_text := ""
var _phase_started_ms: int = 0
var _started_ms: int = 0
var _phase_passed := false
var _pending_token: int = 0
var _checkpoints: Array = []
var _auto_advance := false
var _last_phase_result: Dictionary = {}


## context:
##   guide           GuideService
##   validator       ExerciseValidation
##   find_document   Callable(id) -> document or null
##   active_document Callable() -> document or null
##   publish         Callable(name, payload)
##   show_hint       Callable(text), optional
##   mark_dirty      Callable(document), optional
func setup(context: Dictionary) -> void:
	_context = context
	_guide = context.get("guide", null)
	_validator = context.get("validator", null)


func is_live() -> bool:
	return !TERMINAL_STATES.has(state) and state != "idle" and state != "starting"


func start(mod_id_value: String, spec: Dictionary) -> Dictionary:
	var key := str(mod_id_value)
	if is_live() and owner_id != key:
		return Result.error("state.invalid", "Another mod already owns the active exercise.")

	var phase_list := _build_phases(spec)
	if !bool(phase_list.get("ok", false)):
		return phase_list

	var document = _resolve_document(spec.get("doc", 0))
	if document == null:
		return Result.error("doc.stale_handle", "The exercise document is not open.")

	if is_live():
		_stop_internal("restarted", false)

	owner_id = key
	_next_id += 1
	exercise_id = _next_id
	kind = str(spec.get("kind", "freeform")).to_lower()
	doc_id = int(document.id)
	title = str(spec.get("title", ""))
	prompt = str(spec.get("prompt", ""))
	phases = phase_list["phases"]
	phase_index = 0
	_document = document
	_start_text = str(document.text())
	_started_ms = int(Time.get_ticks_msec())
	_phase_started_ms = _started_ms
	_auto_advance = bool(spec.get("auto_advance", false))
	stats_data = {"duration_ms": 0, "attempts": 1, "mistakes": 0, "hints": 0}
	_checkpoints = []
	_pending_token = 0
	_phase_passed = false
	_last_phase_result = {}
	last_reason = ""
	last_result = {}
	state = "active"

	var started := _start_phase(0)
	if !bool(started.get("ok", false)):
		state = "failed"
		return started

	_publish("exercise.started", {
		"exercise": exercise_id,
		"doc": doc_id,
		"kind": kind,
		"title": title,
		"phases": _phase_summaries(),
	})
	_focus_document()
	return Result.ok(public_state())


func state_snapshot(mod_id_value: String, id: int = 0) -> Dictionary:
	if owner_id.is_empty():
		return Result.ok({
			"exercise": 0, "state": "idle", "kind": "", "doc": 0,
			"phase": 0, "phase_kind": "",
			"validation": {"pending": false, "token": 0, "result": {}},
			"stats": stats_data.duplicate(true),
		})
	var check := _check_owner(mod_id_value, id)
	if !check.is_empty():
		return check
	return Result.ok(public_state())


func submit(mod_id_value: String, id: int = 0) -> Dictionary:
	var check := _check_owner(mod_id_value, id)
	if !check.is_empty():
		return check
	if state in ["completed", "stopped"]:
		return Result.ok(public_state())

	var phase := current_phase()
	if phase.is_empty():
		return Result.error("exercise.invalid_state", "The exercise has no current phase.")

	_publish("exercise.submitted", {
		"exercise": exercise_id,
		"doc": doc_id,
		"phase": phase_index,
		"kind": str(phase.get("kind", "freeform")),
	})

	if str(phase.get("kind", "freeform")) == "typing":
		if _guide == null:
			return Result.error("state.invalid", "The guide engine is not available.")
		var result: Dictionary = _guide.submit(owner_id, 0)
		if bool(result.get("ok", false)):
			var value: Variant = result.get("value", {})
			if value is Dictionary and str((value as Dictionary).get("status", "")) == "pending":
				state = "validating"
				_pending_token = int((value as Dictionary).get("token", 0))
		return result

	return _begin_freeform_validation(phase)


func advance(mod_id_value: String, id: int = 0) -> Dictionary:
	var check := _check_owner(mod_id_value, id)
	if !check.is_empty():
		return check
	if kind != "hybrid":
		return Result.error("exercise.invalid_state", "Only a hybrid exercise advances phases.")
	if phase_index + 1 >= phases.size():
		return Result.error("exercise.invalid_state", "The final phase has no next phase.")

	var phase := current_phase()
	if str(phase.get("kind", "")) == "typing" and _guide != null:
		var guide_state := str(_guide.public_state().get("state", ""))
		if guide_state != "completed":
			return Result.error("exercise.invalid_state", "Finish the typing phase before advancing.")
	if str(phase.get("kind", "")) == "freeform" and !_phase_passed:
		if _has_validation(phase):
			return Result.error("exercise.invalid_state", "The freeform phase has not passed yet.")

	if _guide != null and _guide.is_live():
		_guide.stop(owner_id, "Phase complete.")

	_checkpoint(str(_document.text()) if _document != null else "")
	phase_index += 1
	_phase_passed = false
	_last_phase_result = {}
	state = "active"
	_phase_started_ms = int(Time.get_ticks_msec())

	var started := _start_phase(phase_index)
	if !bool(started.get("ok", false)):
		state = "failed"
		return started

	_publish("exercise.phase_changed", {
		"exercise": exercise_id,
		"doc": doc_id,
		"phase": phase_index,
		"kind": str((phases[phase_index] as Dictionary).get("kind", "freeform")),
		"phases": _phase_summaries(),
	})
	_focus_document()
	return Result.ok(public_state())


func retry(mod_id_value: String, options: Dictionary = {}) -> Dictionary:
	var check := _check_owner(mod_id_value, int(options.get("id", 0)))
	if !check.is_empty():
		return check
	if state == "completed":
		return Result.error("exercise.invalid_state", "The exercise is already complete.")

	var restore := str(options.get("restore", "checkpoint"))
	if restore != "start" and restore != "checkpoint" and restore != "keep":
		return Result.error("api.bad_args", "retry restore is start, checkpoint or keep.")

	var phase := current_phase()
	if !phase.is_empty() and str(phase.get("kind", "")) == "typing" and _guide != null:
		_guide.reset(owner_id, {"restore": restore})
	elif restore != "keep" and _document != null:
		var target := _start_text if restore == "start" else _checkpoint_text(restore)
		_set_text(target)

	if _validator != null and _pending_token > 0:
		_validator.cancel(_pending_token)
		_pending_token = 0

	stats_data["attempts"] = int(stats_data.get("attempts", 1)) + 1
	_phase_passed = false
	_last_phase_result = {}
	state = "active"
	_phase_started_ms = int(Time.get_ticks_msec())
	_focus_document()
	return Result.ok(public_state())


func hint(mod_id_value: String, text: String, id: int = 0) -> Dictionary:
	var check := _check_owner(mod_id_value, id)
	if !check.is_empty():
		return check
	stats_data["hints"] = int(stats_data.get("hints", 0)) + 1
	if _guide != null and is_live() and str(current_phase().get("kind", "")) == "typing":
		return _guide.hint(owner_id, text, 0)
	var show: Variant = _context.get("show_hint", Callable())
	if show is Callable and (show as Callable).is_valid():
		(show as Callable).call(str(text))
	return Result.ok(true)


func stop(mod_id_value: String, reason: String = "") -> Dictionary:
	var check := _check_owner(mod_id_value, 0)
	if !check.is_empty():
		return check
	if TERMINAL_STATES.has(state):
		return Result.ok(public_state())
	_stop_internal(reason if !reason.is_empty() else "Stopped by the mod.", true)
	return Result.ok(public_state())


func stop_for_mod(mod_id_value: String, reason: String = "The mod stopped.") -> void:
	if owner_id == str(mod_id_value) and is_live():
		_stop_internal(reason, false)


## Stops the live exercise when its document closes — the view it points
## at is about to be freed. Returns whether a session was stopped.
func stop_for_document(document_id: int, reason: String = "The document was closed.") -> bool:
	if is_live() and doc_id == document_id:
		_stop_internal(reason, false)
		return true
	return false


func current_phase() -> Dictionary:
	if phase_index < 0 or phase_index >= phases.size():
		return {}
	return phases[phase_index]


## The validation object of the current phase when it needs a program run, or
## null. The API uses this to require `run` before `exercise.submit`.
## Resolves a custom-validation token issued to this exercise. The shared
## runner validates the token itself; the owner check keeps one mod from
## answering another mod's request.
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


func requires_run_spec() -> Variant:
	var phase := current_phase()
	if phase.is_empty():
		return null
	var spec: Variant = phase.get("validation", phase.get("tests", null))
	return spec if Validation.needs_run(spec) else null


func public_state() -> Dictionary:
	var phase := current_phase()
	stats_data["duration_ms"] = maxi(0, int(Time.get_ticks_msec()) - _started_ms)
	return {
		"exercise": exercise_id,
		"state": state,
		"kind": kind,
		"doc": doc_id,
		"title": title,
		"prompt": prompt,
		"phase": phase_index,
		"phase_kind": str(phase.get("kind", "")),
		"phases": _phase_summaries(),
		"attempts": int(stats_data.get("attempts", 1)),
		"mistakes": int(stats_data.get("mistakes", 0)),
		"hints": int(stats_data.get("hints", 0)),
		"validation": {
			"pending": _pending_token > 0,
			"token": _pending_token,
			"result": last_result.duplicate(true),
		},
		"reason": last_reason,
		"stats": stats_data.duplicate(true),
	}


func stats() -> Dictionary:
	return stats_data.duplicate(true)


func tick(_delta: float) -> void:
	if _document == null or !is_live():
		return
	stats_data["duration_ms"] = maxi(0, int(Time.get_ticks_msec()) - _started_ms)


# ── PHASES ──────────────────────────────────────────────────────────────────

func _build_phases(spec: Dictionary) -> Dictionary:
	var requested := str(spec.get("kind", "freeform")).to_lower()
	if !KINDS.has(requested):
		return Result.error("exercise.invalid_spec", "'%s' is not an exercise kind." % requested)

	if requested == "hybrid":
		var raw: Variant = spec.get("phases", [])
		if !(raw is Array) or (raw as Array).is_empty():
			return Result.error("exercise.invalid_spec", "A hybrid exercise needs at least one phase.")
		if (raw as Array).size() > MAX_PHASES:
			return Result.error("exercise.invalid_spec", "A hybrid exercise is limited to %d phases." % MAX_PHASES)

		var list: Array = []
		for index in range((raw as Array).size()):
			var phase: Variant = (raw as Array)[index]
			if !(phase is Dictionary):
				return Result.error("exercise.invalid_spec", "Every phase must be an object.")
			var checked := _check_phase(phase as Dictionary, index)
			if !bool(checked.get("ok", false)):
				return checked
			list.append(checked["phase"])
		return {"ok": true, "phases": list}

	var only := spec.duplicate(true)
	only["kind"] = requested
	var checked := _check_phase(only, 0)
	if !bool(checked.get("ok", false)):
		return checked
	return {"ok": true, "phases": [checked["phase"]]}


func _check_phase(phase: Dictionary, index: int) -> Dictionary:
	var kind_value := str(phase.get("kind", "freeform")).to_lower()
	if !PHASE_KINDS.has(kind_value):
		return Result.error(
			"exercise.invalid_spec",
			"Phase %d has an unknown kind '%s'." % [index, kind_value],
		)
	var copy := phase.duplicate(true)
	copy["kind"] = kind_value
	copy["id"] = str(copy.get("id", "phase%d" % (index + 1)))

	if kind_value == "typing":
		if str(copy.get("target", "")).strip_edges().is_empty():
			return Result.error("exercise.invalid_spec", "A typing phase needs a target.")
		if !copy.has("progression"):
			copy["progression"] = "character"
		if !copy.has("mode"):
			copy["mode"] = "strict"
	else:
		if str(copy.get("prompt", "")).strip_edges().is_empty() and !_has_validation(copy):
			return Result.error(
				"exercise.invalid_spec",
				"A freeform phase needs a prompt or validation.",
			)

	if _has_validation(copy):
		var normalized := Validation.normalize_spec(copy.get("validation", copy.get("tests")))
		if !bool(normalized.get("ok", false)):
			return normalized

	return {"ok": true, "phase": copy}


func _start_phase(index: int) -> Dictionary:
	var phase := current_phase()
	if phase.is_empty():
		return Result.error("exercise.invalid_state", "There is no phase to start.")

	_checkpoint(str(_document.text()) if _document != null else "")
	_phase_started_ms = int(Time.get_ticks_msec())

	if str(phase.get("kind", "")) == "typing":
		if _guide == null:
			return Result.error("state.invalid", "The guide engine is not available.")
		var spec := phase.duplicate(true)
		spec["doc"] = doc_id
		spec["title"] = title
		spec["validation"] = phase.get("validation", phase.get("tests", null))
		var started: Dictionary = _guide.start(owner_id, spec, Callable(self, "_on_guide_event"))
		if !bool(started.get("ok", false)):
			return started
		state = "active"
		return Result.ok(public_state())

	state = "active"
	return Result.ok(public_state())


func _on_guide_event(event: String, payload: Dictionary) -> void:
	if !is_live():
		return
	match event:
		"progress", "mark", "segment":
			if state != "validating" and state != "passed":
				state = "active"
		"state":
			var guide_state := str(_guide.public_state().get("state", ""))
			if guide_state == "paused":
				state = "paused"
			elif guide_state == "active" and state != "validating" and state != "passed":
				state = "active"
		"mistake":
			stats_data["mistakes"] = maxi(
				int(stats_data.get("mistakes", 0)),
				int(payload.get("count", 0)),
			)
		"validated":
			# The guide fires both "validated" and "completed" in one go. After an
			# auto-advance the current phase is freeform; a stale typing-phase
			# event must not complete it for free.
			if str(current_phase().get("kind", "")) != "typing":
				return
			var passed := bool(payload.get("passed", false))
			_phase_validated(passed, payload)
		"completed":
			if str(current_phase().get("kind", "")) != "typing":
				return
			if !_phase_passed:
				_phase_validated(true, {"passed": true, "results": []})
		"stopped":
			if is_live():
				state = "stopped"
				last_reason = str(payload.get("reason", ""))


func _begin_freeform_validation(phase: Dictionary) -> Dictionary:
	if _validator == null:
		return Result.error("state.invalid", "No validation runner is available.")
	if !_has_validation(phase):
		# No checks declared for this phase: treat it as passed and route
		# through the normal completion path. Without this, an exercise whose
		# final phase has no validation stayed in "passed" forever — the dock
		# never saw "completed" and the exercise never published its event.
		_phase_validated(true, {"passed": true, "results": []})
		return Result.ok(public_state())

	state = "validating"
	var spec: Variant = phase.get("validation", phase.get("tests"))
	var context := {
		"text": str(_document.text()) if _document != null else "",
		"path": str(_document.path) if _document != null else "",
		"doc": doc_id,
	}
	var outcome: Dictionary = _validator.start(spec, context, Callable(self, "_on_freeform_done"))
	if str(outcome.get("status", "")) == "pending":
		_pending_token = int(outcome.get("token", 0))
		return Result.ok({
			"state": state,
			"status": "pending",
			"token": _pending_token,
			"exercise": exercise_id,
		})

	if !outcome.has("status"):
		state = "failed"
		last_reason = Result.message_of(outcome)
		_publish("exercise.failed", {
			"exercise": exercise_id,
			"doc": doc_id,
			"phase": phase_index,
			"code": Result.code_of(outcome),
			"message": last_reason,
		})
		return outcome
	return Result.ok(public_state())


func _on_freeform_done(result: Dictionary) -> void:
	_pending_token = 0
	last_result = result.duplicate(true)
	_phase_validated(bool(result.get("passed", false)), result)


func _phase_validated(passed: bool, payload: Dictionary) -> void:
	if _phase_passed:
		return

	last_result = payload.duplicate(true)
	if !passed:
		state = "failed"
		last_reason = str(payload.get("message", "The exercise did not pass its validation."))
		_publish("exercise.failed", {
			"exercise": exercise_id,
			"doc": doc_id,
			"phase": phase_index,
			"code": str(payload.get("code", "exercise.failed")),
			"message": last_reason,
			"results": payload.get("results", []),
		})
		return

	_phase_passed = true
	_checkpoint(str(_document.text()) if _document != null else "")

	if phase_index + 1 < phases.size():
		state = "passed"
		if _auto_advance:
			advance(owner_id, 0)
		return

	state = "completed"
	stats_data["duration_ms"] = maxi(0, int(Time.get_ticks_msec()) - _started_ms)
	_publish("exercise.completed", {
		"exercise": exercise_id,
		"doc": doc_id,
		"passed": true,
		"results": payload.get("results", []),
		"stats": stats_data.duplicate(true),
	})


func _has_validation(phase: Dictionary) -> bool:
	var spec: Variant = phase.get("validation", phase.get("tests", null))
	if spec == null:
		return false
	if spec is Dictionary and (spec as Dictionary).is_empty():
		return false
	return true


func _phase_summaries() -> Array:
	var out: Array = []
	for index in range(phases.size()):
		var phase: Dictionary = phases[index]
		out.append({
			"id": str(phase.get("id", "")),
			"kind": str(phase.get("kind", "freeform")),
			"title": str(phase.get("title", "")),
		})
	return out


func _checkpoint(text: String) -> void:
	var entry := {"text": text, "at_ms": int(Time.get_ticks_msec())}
	if !_checkpoints.is_empty() and str((_checkpoints[-1] as Dictionary).get("text", "")) == text:
		return
	_checkpoints.append(entry)
	while _checkpoints.size() > MAX_CHECKPOINTS:
		_checkpoints.pop_front()


func _checkpoint_text(restore: String) -> String:
	if _checkpoints.is_empty():
		return _start_text
	if restore == "start":
		return _start_text
	return str((_checkpoints[-1] as Dictionary).get("text", _start_text))


func _set_text(text: String) -> void:
	if _document == null:
		return
	var view = _document.view
	if view != null and is_instance_valid(view):
		if view.has_method("set_document_text"):
			view.set_document_text(text, false)
		else:
			view.text = text
	var mark: Variant = _context.get("mark_dirty", Callable())
	if mark is Callable and (mark as Callable).is_valid():
		(mark as Callable).call(_document)


func _stop_internal(reason: String, publish: bool) -> void:
	if _validator != null and _pending_token > 0:
		_validator.cancel(_pending_token)
		_pending_token = 0
	if _guide != null:
		_guide.stop_for_mod(owner_id, reason)
	state = "stopped"
	last_reason = reason
	stats_data["duration_ms"] = maxi(0, int(Time.get_ticks_msec()) - _started_ms)
	if publish:
		_publish("exercise.stopped", {
			"exercise": exercise_id,
			"doc": doc_id,
			"reason": reason,
			"stats": stats_data.duplicate(true),
		})


func _check_owner(mod_id_value: String, id: int) -> Dictionary:
	if owner_id.is_empty():
		return Result.error("exercise.unknown", "There is no exercise session.")
	if owner_id != str(mod_id_value):
		return Result.error("state.invalid", "Another mod owns the active exercise.")
	if int(id) > 0 and int(id) != exercise_id:
		return Result.error("exercise.unknown", "That exercise session has ended.")
	return {}


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


## A mod starts an exercise from its own dock button, so keyboard focus is on
## that button. Freeform phases have no guide session to do this for them.
## Never pull focus to a background document.
func _focus_document() -> void:
	if _document == null:
		return
	var active: Variant = _context.get("active_document", Callable())
	if active is Callable and (active as Callable).is_valid() and (active as Callable).call() != _document:
		return
	var view = _document.view
	if view != null and is_instance_valid(view) and view.has_method("grab_focus"):
		view.grab_focus()


func _publish(name: String, payload: Dictionary) -> void:
	var publish: Variant = _context.get("publish", Callable())
	if publish is Callable and (publish as Callable).is_valid():
		(publish as Callable).call(name, payload)
