class_name LocalizationService
extends Node

## Loads Godot-format CSV translations at runtime.
##
## The CSV is the same format the Godot editor imports (`keys,en,de,...`), but
## it is parsed here instead of relying on an import step. That keeps a plain
## `godot --headless --path . --script ...` run and a fresh checkout working
## without generated `.translation` files, and it lets `user://localization/
## strings.csv` override individual rows without re-exporting the project.
##
## Keys are the English source strings, so existing UI code can simply wrap a
## label in `tr("Save")` and get a translation wherever one exists.

const DEFAULT_LOCALE := "en"
const BUNDLED_CSV := "res://resources/localization/strings.csv"
const USER_CSV := "user://localization/strings.csv"

const LANGUAGE_NAMES := {
	"en": "English",
	"de": "Deutsch",
	"es": "Español",
	"fr": "Français",
	"pt": "Português",
	"it": "Italiano",
}

var translations: Dictionary = {}
var languages: Array = []
var active_locale: String = DEFAULT_LOCALE
var last_error: String = ""


## The owner calls install() explicitly. Doing it from _ready() would race
## with the settings service: the saved locale must be known first.


## Parses the bundled CSV and the optional user override, registers every
## translation, and applies the active locale. Safe to call more than once.
func install() -> Dictionary:
	translations.clear()
	languages.clear()
	last_error = ""

	var bundled := _load_csv(BUNDLED_CSV)
	if !bool(bundled.get("ok", false)):
		last_error = str(bundled.get("error", "Could not read the translation CSV."))
		# Without a CSV the service still needs a pickable English option.
		languages = [{"display": "English", "value": "en", "name": "English"}]
		_translate_locale(DEFAULT_LOCALE)
		return {"ok": false, "error": last_error, "languages": languages.size()}

	var user := _load_csv(USER_CSV)
	if bool(user.get("ok", false)):
		_merge(user.get("rows", []), true)

	for locale in translations.keys():
		TranslationServer.add_translation(translations[locale])

	active_locale = _normalize_locale(active_locale)
	_translate_locale(active_locale)

	return {"ok": true, "error": "", "languages": languages.size()}


## Ordered options for the language picker. `display` is the language's own
## name so a reader can find it even while the UI is in another language.
func language_options() -> Array:
	return languages.duplicate(true)


func has_locale(locale: String) -> bool:
	return translations.has(_normalize_locale(locale))


func set_locale(locale: String) -> bool:
	var code := _normalize_locale(locale)
	if !translations.has(code) and code != DEFAULT_LOCALE:
		return false
	active_locale = code
	_translate_locale(code)
	return true


func _translate_locale(code: String) -> void:
	TranslationServer.set_locale(code)


func _normalize_locale(locale: String) -> String:
	var code := str(locale).strip_edges().to_lower().replace("-", "_")
	if code.is_empty():
		return DEFAULT_LOCALE
	if !translations.has(code):
		var base := code.split("_")[0]
		if translations.has(base):
			return base
	return code


# ── CSV ─────────────────────────────────────────────────────────────────────

func _load_csv(path: String) -> Dictionary:
	if !FileAccess.file_exists(path):
		return {"ok": false, "error": "Missing translation file: " + path, "rows": []}

	var text := FileAccess.get_file_as_string(path)
	if text.strip_edges().is_empty():
		return {"ok": false, "error": "Translation file is empty: " + path, "rows": []}

	var rows := parse_csv(text)
	if rows.size() < 2:
		return {"ok": false, "error": "Translation file has no rows: " + path, "rows": []}

	var header: Array = rows[0]
	if header.is_empty() or str(header[0]).strip_edges().to_lower() != "keys":
		return {"ok": false, "error": "Translation CSV must start with a keys column.", "rows": []}

	var locales: Array = []
	for i in range(1, header.size()):
		var code := _normalize_locale(str(header[i]))
		if code.is_empty():
			continue
		locales.append({"index": i, "code": code})
		if !translations.has(code):
			translations[code] = _new_translation(code)
		if !_has_language(code):
			languages.append({
				"display": str(LANGUAGE_NAMES.get(code, code.capitalize())),
				"value": code,
				"name": code,
			})

	if locales.is_empty():
		return {"ok": false, "error": "Translation CSV has no language columns.", "rows": []}

	for row_index in range(1, rows.size()):
		var row: Array = rows[row_index]
		if row.is_empty():
			continue
		var key := str(row[0])
		if key.is_empty():
			continue
		for locale in locales:
			var index: int = int(locale["index"])
			if index >= row.size():
				continue
			var value := str(row[index])
			if value.is_empty():
				continue
			(translations[locale["code"]] as Translation).add_message(key, value)

	return {"ok": true, "error": "", "rows": rows}


func _merge(rows: Array, override: bool) -> void:
	if rows.size() < 2:
		return

	var header: Array = rows[0]
	if header.is_empty() or str(header[0]).strip_edges().to_lower() != "keys":
		return

	var locales: Array = []
	for i in range(1, header.size()):
		var code := _normalize_locale(str(header[i]))
		if code.is_empty():
			continue
		if !translations.has(code):
			translations[code] = _new_translation(code)
		locales.append({"index": i, "code": code})

	for row_index in range(1, rows.size()):
		var row: Array = rows[row_index]
		if row.is_empty():
			continue
		var key := str(row[0])
		if key.is_empty():
			continue
		for locale in locales:
			var index: int = int(locale["index"])
			if index >= row.size():
				continue
			var value := str(row[index])
			if value.is_empty():
				continue
			if !override:
				var existing := str((translations[locale["code"]] as Translation).get_message(key))
				if !existing.is_empty():
					continue
			(translations[locale["code"]] as Translation).add_message(key, value)


func _new_translation(code: String) -> Translation:
	var translation := Translation.new()
	translation.locale = code
	return translation


func _has_language(code: String) -> bool:
	for entry in languages:
		if str(entry.get("value", "")) == code:
			return true
	return false


## Minimal RFC-4180 CSV parser: quotes, doubled quotes, commas and newlines
## inside quoted fields, CRLF. Returns an array of rows (arrays of strings).
static func parse_csv(text: String) -> Array:
	var rows: Array = []
	var row: Array = []
	var field := ""
	var quoted := false
	var i := 0
	var length := text.length()

	while i < length:
		var c := text[i]
		if quoted:
			if c == "\"":
				if i + 1 < length and text[i + 1] == "\"":
					field += "\""
					i += 2
					continue
				quoted = false
				i += 1
				continue
			field += c
			i += 1
			continue

		match c:
			"\"":
				quoted = true
			",":
				row.append(field)
				field = ""
			"\r":
				pass
			"\n":
				row.append(field)
				field = ""
				rows.append(row)
				row = []
			_:
				field += c
		i += 1

	if field != "" or !row.is_empty():
		row.append(field)
		rows.append(row)

	return rows
