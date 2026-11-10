extends RefCounted

## Turns raw program output into short, human explanations.
##
## Rules live next to this script as JSON files:
##
##   {
##     "language": "python",
##     "rules": [{
##       "id": "python-syntax", "title": "...", "severity": "error",
##       "pattern": "File \"([^\"]+)\", line (\\d+)...",
##       "file_group": 1, "line_group": 2, "column_group": 3,
##       "message": "... {1} ...", "explain": "...", "fix": "...",
##       "dedupe_key": "python-syntax"
##     }]
##   }
##
## A template can use {0} (the whole match) or any numbered capture group.
## Rules for the run's language win over generic rules; a file with an unknown
## language still gets the generic rules and the exit-code fallback.
##
## This class is pure string/regex work so the headless suite can feed it
## captured output without starting a process.

const Paths = preload("res://src/base/path_utils.gd")

const RULE_DIR := "res://src/features/run/error_rules"
const MAX_DIAGNOSES := 5
const MAX_RULES_PER_MATCH := 1

## Set by the host to pin the language of explanations; "" auto-detects the
## UI language from the settings store ("en" when nothing is reachable,
## which is also the headless default). Tests may pin locale explicitly.
var locale := ""
var _detected_locale := ""

const FALLBACKS := {
	"run-success": {
		"en": ["The program finished successfully", "It printed nothing and exited with code 0.", "A successful run can still be silent, for example when the program only writes files.", ""],
		"de": ["Das Programm wurde erfolgreich beendet", "Es hat nichts ausgegeben und mit Code 0 geendet.", "Auch ein erfolgreicher Lauf kann still sein, zum Beispiel wenn das Programm nur Dateien schreibt.", ""],
		"es": ["El programa terminó correctamente", "No imprimió nada y salió con el código 0.", "Una ejecución exitosa también puede ser silenciosa, por ejemplo cuando el programa solo escribe archivos.", ""],
	},
	"run-stopped": {
		"en": ["The program stopped", "The run ended without a normal exit code.", "The process was stopped by Qorix, the operating system, or a crash.", "Run it again. If it keeps happening, run the same command in the terminal to see the full output."],
		"de": ["Das Programm wurde gestoppt", "Der Lauf endete ohne normalen Exit-Code.", "Der Prozess wurde von Qorix, dem Betriebssystem oder einem Absturz gestoppt.", "Führe es erneut aus. Wenn es weiter passiert, führe denselben Befehl im Terminal aus, um die vollständige Ausgabe zu sehen."],
		"es": ["El programa se detuvo", "La ejecución terminó sin un código de salida normal.", "El proceso fue detenido por Qorix, por el sistema operativo o por un fallo.", "Ejecútalo otra vez. Si sigue pasando, ejecuta el mismo comando en la terminal para ver la salida completa."],
	},
	"run-exit-code": {
		"en": ["The program exited with code %d", "No error message was printed.", "The output above is the most direct clue; this editor did not recognise a language-specific error pattern in it.", "Read the last lines of the output. If the program expects keyboard input, run it in the terminal instead of the captured Run panel."],
		"de": ["Das Programm endete mit Code %d", "Es wurde keine Fehlermeldung ausgegeben.", "Die Ausgabe darüber ist der direkteste Hinweis; dieser Editor erkannte kein sprachspezifisches Fehlermuster darin.", "Lies die letzten Zeilen der Ausgabe. Wenn das Programm Eingaben von der Tastatur erwartet, führe es im Terminal statt im Run-Panel aus."],
		"es": ["El programa salió con código %d", "No se imprimió ningún mensaje de error.", "La salida de arriba es la pista más directa; este editor no reconoció ningún patrón de error específico de un idioma.", "Lee las últimas líneas de la salida. Si el programa espera entrada del teclado, ejecútalo en la terminal en lugar del panel de ejecución."],
	},
}

const LANGUAGE_ALIASES := {
	"py": "python", "python3": "python",
	"js": "javascript", "jsx": "javascript", "node": "javascript",
	"ts": "javascript", "tsx": "javascript", "typescript": "javascript",
	"c": "c", "h": "c",
	"cpp": "c", "cc": "c", "cxx": "c", "c++": "c", "hpp": "c",
	"golang": "go",
	"java": "java",
}

var rules: Array = []
var errors: Array = []
var _loaded: bool = false


## Loads and compiles every rule file once. Safe to call repeatedly.
func load_rules(directory: String = RULE_DIR) -> Dictionary:
	rules.clear()
	errors.clear()
	_loaded = true

	var dir := DirAccess.open(directory)
	if dir == null:
		errors.append("Could not open error rule folder: %s" % directory)
		return {"ok": false, "rules": 0, "errors": errors.duplicate()}

	var files: Array[String] = []
	for file in dir.get_files():
		if file.get_extension().to_lower() == "json":
			files.append(directory.path_join(file))
	files.sort()

	for path in files:
		_load_file(path)

	return {"ok": errors.is_empty(), "rules": rules.size(), "errors": errors.duplicate()}


func _load_file(path: String) -> void:
	var text := FileAccess.get_file_as_string(path)
	if text.strip_edges().is_empty():
		errors.append("%s is empty." % path.get_file())
		return

	var parsed: Variant = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		errors.append("%s is not a valid JSON object." % path.get_file())
		return

	var file_language := str(parsed.get("language", "generic")).to_lower()
	var raw_rules: Variant = parsed.get("rules", [])
	if !(raw_rules is Array):
		errors.append("%s has no rules array." % path.get_file())
		return

	for raw in raw_rules:
		if !(raw is Dictionary):
			continue
		var rule: Dictionary = raw.duplicate(true)
		var pattern := str(rule.get("pattern", ""))
		if pattern.is_empty():
			continue

		var regex := RegEx.new()
		if regex.compile(pattern) != OK:
			errors.append("%s: rule \"%s\" has an invalid pattern." % [
				path.get_file(), str(rule.get("id", "?")),
			])
			continue

		rule["regex"] = regex
		rule["language"] = str(rule.get("language", file_language)).to_lower()
		rule["source"] = path.get_file()
		rule["severity"] = _normalize_severity(rule.get("severity", "error"))
		rules.append(rule)


## Returns an ordered array of diagnosis dictionaries. Every entry is safe to
## render directly: strings are already substituted and severity is one of
## error / warning / info.
func explain(output: String, context: Dictionary = {}) -> Array:
	if !_loaded:
		load_rules()
	_detected_locale = _detect_locale()

	var text := output.replace("\r\n", "\n")
	var language := _normalize_language(str(context.get("language", "")))
	var ordered := _ordered_rules(language)
	var found: Array = []
	var seen: Dictionary = {}

	for rule in ordered:
		var regex: RegEx = rule.get("regex")
		if regex == null:
			continue

		var matches := regex.search_all(text)
		if matches.is_empty():
			continue

		var per_rule := 0
		for result in matches:
			var diagnosis := _diagnosis(rule, result, text, context)
			var key := str(diagnosis.get("dedupe_key", diagnosis.get("id", "")))
			if !key.is_empty() and seen.has(key):
				continue
			if !key.is_empty():
				seen[key] = true

			found.append(diagnosis)
			per_rule += 1
			if per_rule >= int(rule.get("max_matches", MAX_RULES_PER_MATCH)):
				break
			if found.size() >= MAX_DIAGNOSES:
				break
		if found.size() >= MAX_DIAGNOSES:
			break

	if found.is_empty():
		var fallback := _fallback(text, int(context.get("exit_code", 0)))
		if !fallback.is_empty():
			found.append(fallback)

	return found


## Short one-line summary used by the panel header and the status strip.
func summary(diagnoses: Array, exit_code: int = 0) -> String:
	if !diagnoses.is_empty():
		return str(diagnoses[0].get("title", "Program problem"))
	if exit_code == 0:
		return "Program finished"
	if exit_code < 0:
		return "Program stopped"
	return "Program failed (exit code %d)" % exit_code


## Locale of the explanations. Tests and headless runs land on "en".
func _detect_locale() -> String:
	if !locale.is_empty():
		return locale
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
			var loc := str(entry.get("value", "en")).strip_edges().to_lower()
			if loc in ["en", "de", "es"]:
				return loc
	return "en"


## Localized field of a rule with English fallback.
func _pick(rule: Dictionary, key: String) -> String:
	var code := _detected_locale
	if code != "en":
		var value: Variant = rule.get(key + "_" + code, "")
		if value is String and !str(value).strip_edges().is_empty():
			return str(value)
	return str(rule.get(key, ""))


func _ordered_rules(language: String) -> Array:
	var matching: Array = []
	var generic: Array = []
	var others: Array = []
	for rule in rules:
		var rule_language := str(rule.get("language", "generic")).to_lower()
		if rule_language == "generic" or rule_language.is_empty():
			generic.append(rule)
		elif !language.is_empty() and rule_language == language:
			matching.append(rule)
		else:
			others.append(rule)

	var out: Array = []
	out.append_array(matching)
	out.append_array(generic)
	# Other languages are still useful for a shebang mismatch or a compiler
	# that prints a foreign diagnostic; they simply come last.
	out.append_array(others)
	return out


func _diagnosis(rule: Dictionary, result: RegExMatch, full_output: String, context: Dictionary) -> Dictionary:
	var template_values: Array = [result.get_string(0)]
	for i in range(1, result.get_group_count() + 1):
		template_values.append(result.get_string(i))

	var title := _render(_pick(rule, "title"), template_values)
	var message := _render(_pick(rule, "message"), template_values)
	var explain := _render(_pick(rule, "explain"), template_values)
	var fix := _render(_pick(rule, "fix"), template_values)

	var file := ""
	var file_group := int(rule.get("file_group", 0))
	if file_group > 0:
		file = _resolve_path(result.get_string(file_group), context)

	var line := 0
	var line_group := int(rule.get("line_group", 0))
	if line_group > 0:
		line = maxi(0, int(result.get_string(line_group)))

	var column := 0
	var column_group := int(rule.get("column_group", 0))
	if column_group > 0:
		column = maxi(0, int(result.get_string(column_group)))

	var severity := _normalize_severity(rule.get("severity", "error"))
	var severity_group := int(rule.get("severity_group", 0))
	if severity_group > 0:
		severity = _normalize_severity(result.get_string(severity_group))

	var source_line := _source_line(full_output, file, line)

	var out: Dictionary = {
		"id": str(rule.get("id", "rule")),
		"rule": str(rule.get("id", "rule")),
		"source": str(rule.get("source", "")),
		"language": str(rule.get("language", "generic")),
		"title": title.strip_edges(),
		"severity": severity,
		"message": message.strip_edges(),
		"explain": explain.strip_edges(),
		"fix": fix.strip_edges(),
		"file": file,
		"line": line,
		"column": column,
		"file_exists": !file.is_empty() and FileAccess.file_exists(file),
		"source_line": source_line,
		"dedupe_key": str(rule.get("dedupe_key", rule.get("id", ""))),
		"matched_text": result.get_string(0).strip_edges(),
	}
	out["link"] = bool(out["file_exists"]) and line > 0
	return out


func _fallback_entry(id: String) -> Dictionary:
	var table: Variant = FALLBACKS.get(id, {})
	var code := _detected_locale
	if table is Dictionary:
		var entry: Variant = table.get(code, table.get("en", {}))
		if entry is Array and (entry as Array).size() >= 4:
			return {"title": entry[0], "message": entry[1], "explain": entry[2], "fix": entry[3]}
	return {"title": id, "message": "", "explain": "", "fix": ""}


func _fallback(output: String, exit_code: int) -> Dictionary:
	var success_text := _fallback_entry("run-success")
	var stopped_text := _fallback_entry("run-stopped")
	var exit_text := _fallback_entry("run-exit-code")
	if exit_code == 0 and output.strip_edges().is_empty():
		return {
			"id": "run-success",
			"title": success_text["title"],
			"severity": "info",
			"message": success_text["message"],
			"explain": success_text["explain"],
			"fix": success_text["fix"],
			"file": "", "line": 0, "column": 0, "link": false,
			"file_exists": false, "source_line": "",
			"dedupe_key": "run-success", "matched_text": "",
		}

	if exit_code == 0:
		return {}

	var last := _last_meaningful_line(output)
	if exit_code < 0:
		return {
			"id": "run-stopped",
			"title": stopped_text["title"],
			"severity": "warning",
			"message": stopped_text["message"],
			"explain": stopped_text["explain"],
			"fix": stopped_text["fix"],
			"file": "", "line": 0, "column": 0, "link": false,
			"file_exists": false, "source_line": last,
			"dedupe_key": "run-stopped", "matched_text": "",
		}

	return {
		"id": "run-exit-code",
		"title": exit_text["title"] % exit_code,
		"severity": "error",
		"message": last if !last.is_empty() else exit_text["message"],
		"explain": exit_text["explain"],
		"fix": exit_text["fix"],
		"file": "", "line": 0, "column": 0, "link": false,
		"file_exists": false, "source_line": last,
		"dedupe_key": "run-exit-code", "matched_text": "",
	}


func _last_meaningful_line(output: String) -> String:
	var lines := output.split("\n", false)
	for i in range(lines.size() - 1, -1, -1):
		var line := str(lines[i]).strip_edges()
		if !line.is_empty():
			return line.substr(0, 300)
	return ""


## Finds the source line for extra context in the card. Preference is the real
## file (which the link opens); captured output is only a fallback.
func _source_line(output: String, file: String, one_based_line: int) -> String:
	if one_based_line <= 0:
		return ""

	if !file.is_empty() and FileAccess.file_exists(file):
		var source := FileAccess.get_file_as_string(file).replace("\r\n", "\n")
		var source_lines := source.split("\n", false)
		if one_based_line <= source_lines.size():
			var from_file := str(source_lines[one_based_line - 1]).strip_edges()
			if from_file.length() <= 300:
				return from_file

	var lines := output.split("\n", false)
	if one_based_line <= lines.size():
		var candidate := str(lines[one_based_line - 1]).strip_edges()
		if candidate.length() <= 300:
			return candidate
	return ""


static func _render(template: String, values: Array) -> String:
	if template.is_empty():
		return ""

	var out := ""
	var i := 0
	while i < template.length():
		var character := template[i]
		if character != "{":
			out += character
			i += 1
			continue

		var close := template.find("}", i + 1)
		if close < 0:
			out += character
			i += 1
			continue

		var index_text := template.substr(i + 1, close - i - 1)
		if index_text.is_valid_int():
			var index := int(index_text)
			if index >= 0 and index < values.size():
				out += str(values[index])
			i = close + 1
			continue

		out += character
		i += 1
	return out


## Resolves a path printed by a compiler. Relative paths are tried against the
## run cwd first, then the workspace, then the source file's folder. If none
## exists, the cwd spelling is kept so the output still links somewhere useful.
func _resolve_path(value: String, context: Dictionary) -> String:
	var text := value.strip_edges().strip_edges()
	if text.is_empty():
		return ""

	text = text.trim_prefix("file://").replace("\\", "/")
	if text.begins_with("./"):
		text = text.substr(2)

	if text.is_absolute_path() or text.begins_with("res://") or text.begins_with("user://"):
		return Paths.normalize(text)

	var bases: Array[String] = []
	for key in ["cwd", "workspace", "file_dir"]:
		var base := Paths.normalize(str(context.get(key, "")))
		if !base.is_empty() and !bases.has(base):
			bases.append(base)

	for base in bases:
		var candidate := Paths.normalize(base.path_join(text))
		if FileAccess.file_exists(candidate):
			return candidate

	if !bases.is_empty():
		return Paths.normalize(bases[0].path_join(text))
	return Paths.normalize(text)


static func _normalize_language(value: String) -> String:
	var language := value.strip_edges().to_lower()
	return str(LANGUAGE_ALIASES.get(language, language))


static func _normalize_severity(value: Variant) -> String:
	var severity := str(value).strip_edges().to_lower()
	if severity == "warning" or severity == "warn":
		return "warning"
	if severity == "info" or severity == "note" or severity == "hint":
		return "info"
	return "error"


func is_loaded() -> bool:
	return _loaded
