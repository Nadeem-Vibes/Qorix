extends RefCounted

## Catalog and progress for the built-in Python Journey course.
##
## The five lessons ship inside the app as data (`res://resources/courses/
## python_journey.json`); the engine that delivers them is the same guide /
## exercise engine mods use. This class is deliberately pure: it loads the
## catalog, reads and writes progress, and builds engine specs — no scenes, no
## editor, no engine singletons — so the headless suite can exercise it.
##
## Progress lives in `user://python_journey_progress.json` as
## {version, last, lessons: {id: {typed, done}}}; it is local to this
## computer and is never uploaded.

const Store = preload("res://src/base/file_store.gd")

const CATALOG_PATH := "res://resources/courses/python_journey.json"
const DEFAULT_PROGRESS_PATH := "user://python_journey_progress.json"
const COURSE_ID := "griddycode.python_journey"
const COURSE_TITLE := "Python Journey"

var catalog_path: String = CATALOG_PATH
var progress_path: String = DEFAULT_PROGRESS_PATH

## UI language for the course copy. "en" uses the base catalog; "de" and "es"
## load `python_journey.<locale>.json` when present (falling back to English
## so a missing translation never blocks a lesson).
var locale := "en"

var _catalog: Dictionary = {}
var _catalog_loaded: bool = false
var _progress: Dictionary = {"version": 1, "last": "", "lessons": {}}
var _progress_loaded: bool = false


# ── CATALOG ─────────────────────────────────────────────────────────────────

func load_catalog() -> Dictionary:
	if _catalog_loaded:
		return {"ok": true, "lessons": _lessons()}

	_catalog = {}
	_catalog_loaded = false
	var path := _catalog_path()
	var result: Dictionary = Store.load_json(path)
	if !bool(result.get("ok", false)) and path != CATALOG_PATH:
		# A localized catalog is missing: fall back to English rather than
		# blocking the course behind an untranslated file.
		path = CATALOG_PATH
		result = Store.load_json(path)
	catalog_path = path
	if !bool(result.get("ok", false)):
		return {"ok": false, "error": str(result.get("error", "The course catalog could not be read.")), "lessons": []}

	var data: Variant = result.get("data", {})
	if !(data is Dictionary):
		return {"ok": false, "error": "The course catalog is not a JSON object.", "lessons": []}

	var lessons: Variant = data.get("lessons", [])
	if !(lessons is Array) or (lessons as Array).is_empty():
		return {"ok": false, "error": "The course catalog has no lessons.", "lessons": []}

	_catalog = data
	_catalog_loaded = true

	var problems := validate_catalog(data)
	if !problems.is_empty():
		_catalog = {}
		_catalog_loaded = false
		return {"ok": false, "error": "The course catalog is invalid: " + "; ".join(problems), "lessons": []}

	return {"ok": true, "error": "", "lessons": _lessons()}


## Structural checks on the catalog so a broken edit to the JSON fails loudly
## in the test suite instead of halfway through a lesson.
func _catalog_path() -> String:
	if locale != "de" and locale != "es":
		return CATALOG_PATH
	var localized := CATALOG_PATH.get_base_dir().path_join("python_journey.%s.json" % locale)
	if FileAccess.file_exists(localized):
		return localized
	return CATALOG_PATH


func set_locale(code: String) -> bool:
	var normalized := str(code).strip_edges().to_lower()
	if normalized.is_empty():
		normalized = "en"
	if normalized == locale:
		return true
	locale = normalized
	_catalog = {}
	_catalog_loaded = false
	return true


static func validate_catalog(data: Dictionary) -> Array:
	var problems: Array = []
	var lessons: Variant = data.get("lessons", [])
	if !(lessons is Array):
		return ["lessons must be an array"]

	var seen := {}
	for raw in lessons:
		if !(raw is Dictionary):
			problems.append("every lesson must be an object")
			continue
		var lesson: Dictionary = raw
		var id := str(lesson.get("id", ""))
		if id.is_empty():
			problems.append("a lesson has no id")
			continue
		if seen.has(id):
			problems.append("duplicate lesson id %s" % id)
		if str(lesson.get("title", "")).strip_edges().is_empty():
			problems.append("%s has no title" % id)
		var exercise: Variant = lesson.get("exercise", {})
		if !(exercise is Dictionary):
			problems.append("%s has no exercise block" % id)
			continue
		var typing: Variant = exercise.get("typing", {})
		if !(typing is Dictionary) or str(typing.get("target", "")).strip_edges().is_empty():
			problems.append("%s has no typing target" % id)
		var freeform: Variant = exercise.get("freeform", {})
		if !(freeform is Dictionary):
			problems.append("%s has no freeform block" % id)
		else:
			var run: Variant = freeform.get("run", {})
			var text: Variant = freeform.get("text", {})
			if !((run is Dictionary) or (text is Dictionary)):
				problems.append("%s has neither run nor text validation" % id)
		seen[id] = true

	return problems


func _lessons() -> Array:
	var out: Array = []
	for raw in _catalog.get("lessons", []):
		if raw is Dictionary:
			out.append(raw)
	return out


func lessons() -> Array:
	var result := load_catalog()
	if !bool(result.get("ok", false)):
		return []
	return result.get("lessons", [])


func lesson(id: String) -> Dictionary:
	for entry in lessons():
		if str(entry.get("id", "")) == str(id):
			return entry
	return {}


# ── PROGRESS ────────────────────────────────────────────────────────────────

func load_progress() -> Dictionary:
	if _progress_loaded:
		return _progress.duplicate(true)

	var result: Dictionary = Store.load_json(progress_path)
	_progress = {"version": 1, "last": "", "lessons": {}}
	if bool(result.get("ok", false)):
		var data: Variant = result.get("data", {})
		if data is Dictionary:
			var raw_lessons: Variant = data.get("lessons", {})
			if raw_lessons is Dictionary:
				var lessons := {}
				for key in raw_lessons.keys():
					if str(key).is_empty():
						continue
					var value: Variant = raw_lessons[key]
					if value is Dictionary:
						lessons[str(key)] = {
							"typed": bool(value.get("typed", false)),
							"done": bool(value.get("done", false)),
						}
				_progress["lessons"] = lessons
				_progress["last"] = str(data.get("last", ""))

	_progress_loaded = true
	return _progress.duplicate(true)


func save_progress() -> Dictionary:
	return Store.save_json(progress_path, _progress)


func mark_typed(id: String) -> Dictionary:
	load_progress()
	var key := str(id)
	var entry: Dictionary = _progress["lessons"].get(key, {"typed": false, "done": false})
	entry["typed"] = true
	_progress["lessons"][key] = entry
	_progress["last"] = key
	return save_progress()


func mark_done(id: String) -> Dictionary:
	load_progress()
	var key := str(id)
	var entry: Dictionary = _progress["lessons"].get(key, {"typed": false, "done": false})
	entry["typed"] = true
	entry["done"] = true
	_progress["lessons"][key] = entry
	_progress["last"] = key
	return save_progress()


func reset_progress() -> Dictionary:
	_progress = {"version": 1, "last": "", "lessons": {}}
	_progress_loaded = true
	return save_progress()


func completed_count() -> int:
	var total := 0
	var state := load_progress()
	for id in state.get("lessons", {}).keys():
		if bool(state["lessons"][id].get("done", false)):
			total += 1
	return total


func total_lessons() -> int:
	return lessons().size()


func is_done(id: String) -> bool:
	var state := load_progress()
	var lessons: Dictionary = state.get("lessons", {})
	return bool(lessons.get(str(id), {}).get("done", false))


func is_typed(id: String) -> bool:
	var state := load_progress()
	var lessons: Dictionary = state.get("lessons", {})
	return bool(lessons.get(str(id), {}).get("typed", false))


func last_lesson() -> String:
	return str(load_progress().get("last", ""))


## The next lesson to work on: the first incomplete lesson at or after
## `current_id`, wrapping to the beginning. Returns "" when everything is done.
func next_lesson_id(current_id: String = "") -> String:
	var ordered := lessons()
	var state := load_progress()

	var start_index := 0
	if !str(current_id).is_empty():
		for i in range(ordered.size()):
			if str(ordered[i].get("id", "")) == str(current_id):
				start_index = i + 1
				break

	for offset in range(ordered.size()):
		var index := (start_index + offset) % ordered.size()
		var id := str(ordered[index].get("id", ""))
		var done := bool(state["lessons"].get(id, {}).get("done", false))
		if !done:
			return id
	return ""


# ── ENGINE SPEC ─────────────────────────────────────────────────────────────

## Builds the hybrid exercise spec for a lesson. `use_run` picks the run-backed
## validation; otherwise the text checks are used. The returned spec is fresh
## (safe to hand to the exercise engine) and its validation block is always a
## normalized spec the engine accepts.
func build_spec(lesson: Dictionary, doc_id: int, use_run: bool) -> Dictionary:
	var exercise: Dictionary = lesson.get("exercise", {})
	var typing: Dictionary = exercise.get("typing", {})
	var freeform: Dictionary = exercise.get("freeform", {})

	var run_spec: Variant = freeform.get("run", null)
	var text_spec: Variant = freeform.get("text", null)
	var validation: Dictionary = {}
	if use_run and run_spec is Dictionary:
		validation = (run_spec as Dictionary).duplicate(true)
	elif text_spec is Dictionary:
		validation = (text_spec as Dictionary).duplicate(true)
	elif run_spec is Dictionary:
		validation = (run_spec as Dictionary).duplicate(true)

	var spec := {
		"kind": "hybrid",
		"doc": int(doc_id),
		"title": str(exercise.get("title", lesson.get("title", COURSE_TITLE))),
		"prompt": str(exercise.get("prompt", "")),
		"auto_advance": true,
		"phases": [
			{
				"id": "typing",
				"kind": "typing",
				"title": str(exercise.get("title", lesson.get("title", ""))),
				"target": str(typing.get("target", "")),
				"progression": "character",
				"mode": "strict",
				"display": typing.get("display", {}),
				"marks": typing.get("marks", []),
				"hints": typing.get("hints", []),
			},
			{
				"id": "freeform",
				"kind": "freeform",
				"title": "Make it yours",
				"prompt": str(freeform.get("prompt", "")),
				"validation": validation,
			},
		],
	}
	return spec
