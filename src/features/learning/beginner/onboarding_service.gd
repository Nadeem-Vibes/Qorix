extends RefCounted

## Four-step first-run tutorial: open a file, type, run, see output.
##
## The state is persisted after every transition, so closing the editor in the
## middle of the tutorial resumes at the same step. Completing the tutorial
## sets `completed`; starting it again always replays from step 0.

signal state_changed(state: Dictionary)
signal completed

const Store = preload("res://src/base/file_store.gd")
const DEFAULT_PATH := "user://onboarding.json"
const STEP_COUNT := 4

const STEPS := [
	{
		"id": "open_file",
		"title": "Open or create a file",
		"title_de": "Öffne oder erstelle eine Datei",
		"title_es": "Abre o crea un archivo",
		"hint": "Use a template, open a folder, or make an empty file. A Python file is the quickest start.",
		"hint_de": "Nutze eine Vorlage, öffne einen Ordner oder erstelle eine leere Datei. Eine Python-Datei ist der schnellste Einstieg.",
		"hint_es": "Usa una plantilla, abre una carpeta o crea un archivo vacío. Un archivo de Python es el inicio más rápido.",
		"action": "Create a starter file",
		"action_de": "Starterdatei erstellen",
		"action_es": "Crear un archivo inicial",
	},
	{
		"id": "type_a_line",
		"title": "Type a line of code",
		"title_de": "Schreibe eine Zeile Code",
		"title_es": "Escribe una línea de código",
		"hint": "Click in the editor and add or change one line. There is no wrong answer here.",
		"hint_de": "Klick in den Editor und füge eine Zeile hinzu oder ändere eine. Hier gibt es keine falsche Antwort.",
		"hint_es": "Haz clic en el editor y añade o cambia una línea. No hay respuesta incorrecta.",
		"action": "Go to the editor",
		"action_de": "Zum Editor",
		"action_es": "Ir al editor",
	},
	{
		"id": "run",
		"title": "Run your code",
		"title_de": "Führe deinen Code aus",
		"title_es": "Ejecuta tu código",
		"hint": "Press the Run button or F5. Qorix saves the file first, then starts it.",
		"hint_de": "Drücke den Run-Button oder F5. Qorix speichert die Datei zuerst, dann startet sie.",
		"hint_es": "Pulsa el botón Ejecutar o F5. Qorix guarda el archivo primero y luego lo inicia.",
		"action": "Run my code",
		"action_de": "Code ausführen",
		"action_es": "Ejecutar mi código",
	},
	{
		"id": "see_output",
		"title": "See your output",
		"title_de": "Sieh deine Ausgabe",
		"title_es": "Mira tu salida",
		"hint": "The Run panel opens with the program's output. That is the loop: edit, run, read.",
		"hint_de": "Das Run-Panel öffnet sich mit der Ausgabe deines Programms. Das ist der Kreislauf: bearbeiten, ausführen, lesen.",
		"hint_es": "El panel de ejecución se abre con la salida de tu programa. Ese es el ciclo: editar, ejecutar, leer.",
		"action": "Show the output",
		"action_de": "Ausgabe anzeigen",
		"action_es": "Mostrar la salida",
	},
]

## Locale override for the tutorial copy. "" auto-detects the UI language
## ("en" headless and in tests by default).
var locale := ""
var _detected_locale := ""

var state_path: String = DEFAULT_PATH

var _state: Dictionary = _default_state()
var _loaded: bool = false


static func _detect_locale() -> String:
	var loop := Engine.get_main_loop() as SceneTree
	if loop == null or loop.root == null:
		return "en"
	var ls := loop.root.get_node_or_null("LuaSingleton")
	if ls == null or !ls.has_method("get_setting"):
		return "en"
	var found: Variant = ls.get_setting("ui_language")
	if typeof(found) == TYPE_ARRAY and (found as Array).size() >= 1:
		var entry: Variant = (found as Array)[0]
		if entry is Dictionary:
			var code := str(entry.get("value", "en")).strip_edges().to_lower()
			if code in ["en", "de", "es"]:
				return code
	return "en"


func _locale_code() -> String:
	if !locale.is_empty():
		return locale
	_detected_locale = _detect_locale()
	return _detected_locale


static func _pick(step: Dictionary, key: String, code: String) -> String:
	if code != "en":
		var value: Variant = step.get(key + "_" + code, "")
		if value is String and !str(value).strip_edges().is_empty():
			return str(value)
	return str(step.get(key, ""))


func load_state() -> Dictionary:
	if _loaded:
		return _state.duplicate(true)

	var result: Dictionary = Store.load_json(state_path)
	if bool(result.get("ok", false)):
		var data: Dictionary = result.get("data", {})
		_state["completed"] = bool(data.get("completed", data.get("onboarding_completed", false)))
		_state["onboarding_completed"] = bool(_state["completed"])
		_state["active"] = bool(data.get("active", false))
		_state["step"] = clampi(int(data.get("step", 0)), 0, STEP_COUNT)
		_state["started_at"] = int(data.get("started_at", 0))
		_state["completed_at"] = int(data.get("completed_at", 0))
		_state["skipped"] = bool(data.get("skipped", false))
		if bool(_state["completed"]) and !bool(_state["active"]):
			_state["step"] = STEP_COUNT
	_loaded = true
	return _state.duplicate(true)


func save_state() -> Dictionary:
	return Store.save_json(state_path, _state)


func start(replay: bool = true) -> Dictionary:
	load_state()
	_state["active"] = true
	_state["step"] = 0
	_state["skipped"] = false
	if int(_state.get("started_at", 0)) == 0 or replay:
		_state["started_at"] = int(Time.get_unix_time_from_system())
	save_state()
	_emit()
	return snapshot()


func finish() -> void:
	load_state()
	_state["active"] = false
	_state["step"] = STEP_COUNT
	_state["skipped"] = false
	_state["completed"] = true
	_state["onboarding_completed"] = true
	_state["completed_at"] = int(Time.get_unix_time_from_system())
	save_state()
	_emit()
	completed.emit()


func skip() -> void:
	load_state()
	_state["active"] = false
	_state["skipped"] = true
	save_state()
	_emit()


func reset() -> void:
	_state = _default_state()
	_loaded = true
	save_state()
	_emit()


func is_active() -> bool:
	load_state()
	return bool(_state.get("active", false))


func is_completed() -> bool:
	load_state()
	return bool(_state.get("completed", false))


func current_step() -> int:
	load_state()
	return int(_state.get("step", 0))


func snapshot() -> Dictionary:
	load_state()
	var copy := _state.duplicate(true)
	copy["step_count"] = STEP_COUNT
	var index := int(copy.get("step", 0))
	if index < STEP_COUNT:
		var code := _locale_code()
		var step: Dictionary = STEPS[index]
		copy["step_info"] = {
			"id": str(step.get("id", "")),
			"title": _pick(step, "title", code),
			"hint": _pick(step, "hint", code),
			"action": _pick(step, "action", code),
		}
	else:
		copy["step_info"] = {}
	return copy


static func steps() -> Array:
	return STEPS.duplicate(true)


func notify_document_open() -> bool:
	load_state()
	if !bool(_state.get("active", false)):
		return false
	if int(_state.get("step", 0)) > 0:
		return false
	return _advance_to(1)


func notify_typed() -> bool:
	load_state()
	if !bool(_state.get("active", false)):
		return false
	var step := int(_state.get("step", 0))
	if step >= 2:
		return false
	return _advance_to(2)


func notify_run() -> bool:
	load_state()
	if !bool(_state.get("active", false)):
		return false
	if int(_state.get("step", 0)) >= 3:
		return false
	return _advance_to(3)


func notify_output(output: String) -> bool:
	load_state()
	if !bool(_state.get("active", false)):
		return false
	if output.strip_edges().is_empty():
		return false
	var step := int(_state.get("step", 0))
	if step >= STEP_COUNT:
		return false
	_state["step"] = STEP_COUNT
	_state["completed"] = true
	_state["onboarding_completed"] = true
	_state["completed_at"] = int(Time.get_unix_time_from_system())
	_state["active"] = true
	save_state()
	_emit()
	completed.emit()
	return true


func _advance_to(step: int) -> bool:
	var target := clampi(step, 0, STEP_COUNT)
	if target <= int(_state.get("step", 0)):
		return false
	_state["step"] = target
	save_state()
	_emit()
	return true


func _emit() -> void:
	state_changed.emit(snapshot())


static func _default_state() -> Dictionary:
	return {
		"version": 1,
		"completed": false,
		"onboarding_completed": false,
		"active": false,
		"step": 0,
		"started_at": 0,
		"completed_at": 0,
		"skipped": false,
	}
