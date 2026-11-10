class_name SettingsService
extends Node

# The glide the camera performs when smooth scrolling is on. The default lives
# here so the schema and the camera can never drift apart.
const Scroll = preload("res://src/editor/scroll_math.gd")

## Schema-driven settings store.
##
## Values are persisted by stable key (never by their position in the list).
## In particular `editor_font` stores the font's display name, not its index in
## OS.get_system_fonts(), so installing/removing fonts can never silently
## select a different font. The JSON file carries a settings_version so future
## renames/migrations can be applied deliberately.
##
## LuaSingleton keeps its historical `settings` / `get_setting()` /
## `change_setting()` API as a compatibility wrapper around this service.

const CURRENT_VERSION := 2
const DEFAULT_PATH := "user://settings.json"

## Presentation order for the Ctrl+, panel. Settings reference these keys via
## their "category" field; an entry without a known category still renders,
## under "Other", so adding a setting can never make it disappear.
const CATEGORIES := [
	{"key": "beginner", "display": "Getting Started"},
	{"key": "editor", "display": "Editor"},
	{"key": "indentation", "display": "Indentation"},
	{"key": "running", "display": "Running"},
	{"key": "language", "display": "Language Support"},
	{"key": "debug", "display": "Debugger"},
	{"key": "workspace", "display": "Workspace"},
	{"key": "git", "display": "Source Control"},
	{"key": "scrolling", "display": "Scrolling & Minimap"},
	{"key": "appearance", "display": "Appearance & Effects"},
	{"key": "accessibility", "display": "Accessibility"},
	{"key": "localization", "display": "Language & Region"},
	{"key": "performance", "display": "Performance"},
	{"key": "audio", "display": "Audio"},
	{"key": "integrations", "display": "Integrations"},
]

signal changed(key: String, value: Variant)

var path: String = DEFAULT_PATH

var _schema: Array = []
var _by_key: Dictionary = {}
var _values: Dictionary = {}
var _version: int = CURRENT_VERSION
var _loaded: bool = false
var _save_timer: Timer = null
var _beginner_mode: bool = false


func _init() -> void:
	_schema = _default_schema()
	_reindex()
	_apply_defaults()


func _ready() -> void:
	_save_timer = Timer.new()
	_save_timer.one_shot = true
	_save_timer.wait_time = 0.5
	add_child(_save_timer)
	_save_timer.timeout.connect(func() -> void: save())


# ── PUBLIC API ──────────────────────────────────────────────────────────────

func get_value(key: String, fallback: Variant = null) -> Variant:
	if _values.has(key):
		return _values[key]
	if _by_key.has(key):
		return _by_key[key].get("default", fallback)
	return fallback


func set_value(key: String, value: Variant) -> bool:
	var previous: Variant = _values.get(key)
	if !_set_value_raw(key, value):
		return false

	# Silent, but still persisted: used when one shader turns the other off.
	if previous != _values[key]:
		_schedule_save()
	return true


## Named `set_setting` rather than `set`: Node already has a native set(),
## and a script method with that name cannot be resolved externally.
func set_setting(key: String, value: Variant) -> bool:
	if !_by_key.has(key):
		return false

	var previous: Variant = _values.get(key)
	if !_set_value_raw(key, value):
		return false

	var current: Variant = _values[key]
	if previous == current:
		return true

	changed.emit(key, current)
	_schedule_save()
	return true


func reset(key: String) -> bool:
	if !_by_key.has(key):
		return false

	return set_setting(key, _by_key[key].get("default"))


## Restores every default, tells the UI, and persists. The old version only
## rewrote the in-memory values, so "reset to defaults" silently reverted on
## the next start.
func reset_all() -> void:
	var changed_keys: Array = []
	for entry in _schema:
		var key := str(entry.get("key", ""))
		if key.is_empty():
			continue
		var previous: Variant = _values.get(key)
		var value: Variant = entry.get("default")
		_values[key] = value
		if previous != value:
			changed_keys.append(key)

	for key in changed_keys:
		changed.emit(str(key), _values[key])
	_schedule_save()


func has(key: String) -> bool:
	return _by_key.has(key)


func keys() -> Array:
	var out: Array = []
	for entry in _schema:
		out.append(entry["key"])
	return out


## Ordered category descriptors for the settings UI.
func categories() -> Array:
	if !_beginner_mode:
		return _localized_categories(CATEGORIES)

	# Beginner mode shows only categories that still have a visible entry, so
	# the panel never has an empty "Debugger" or "Source Control" heading.
	var out: Array = []
	for category in CATEGORIES:
		var key := str(category.get("key", ""))
		for entry in _schema:
			if str(entry.get("category", "")) == key and bool(entry.get("beginner_visible", false)):
				out.append(category.duplicate(true))
				break
	return _localized_categories(out)


func _localized_categories(source: Array) -> Array:
	var out: Array = []
	for category in source:
		var entry: Dictionary = category.duplicate(true)
		entry["display"] = _translate(str(entry.get("display", "")))
		out.append(entry)
	return out


## Translation keys are the English source strings. With no translation for
## the active locale the key comes back unchanged, so callers never need to
## branch on whether localization is installed.
static func _translate(text: String) -> String:
	return TranslationServer.translate(text)


func set_beginner_mode(enabled: bool) -> void:
	_beginner_mode = enabled


func beginner_mode() -> bool:
	return _beginner_mode


func values() -> Dictionary:
	return _values.duplicate(true)


## Historical settings-list shape: [{property, value, display, ...}, ...].
func compat_entries() -> Array:
	var out: Array = []
	for entry in _schema:
		if _beginner_mode and !bool(entry.get("beginner_visible", false)):
			continue
		out.append(compat_entry(entry["key"]))
	return out


func compat_entry(key: String) -> Dictionary:
	if !_by_key.has(key):
		return {}

	var entry: Dictionary = _by_key[key]
	var out := entry.duplicate(true)
	out["property"] = key
	out["value"] = _values.get(key, entry.get("default"))
	if _beginner_mode and entry.has("beginner_label"):
		out["display"] = _translate(str(entry.get("beginner_label")))
	else:
		out["display"] = _translate(str(entry.get("display", "")))
	if out.has("description"):
		out["description"] = _translate(str(out["description"]))
	return out


func index_of(key: String) -> int:
	for i in range(_schema.size()):
		if _schema[i]["key"] == key:
			return i
	return -1


## Used by LuaSingleton once the theme (and therefore the built-in fonts) has
## been loaded. Keeps the dropdown data in the schema without coupling this
## service to the theme.
func set_options(key: String, options: Array) -> void:
	if !_by_key.has(key):
		return

	_by_key[key]["options"] = options.duplicate(true)


func set_default(key: String, value: Variant) -> void:
	if !_by_key.has(key):
		return

	_by_key[key]["default"] = value
	if !_loaded:
		_values[key] = value


func loaded_from_file() -> bool:
	return _loaded


func version() -> int:
	return _version


# ── PERSISTENCE ─────────────────────────────────────────────────────────────

func load_settings() -> Dictionary:
	var result := {
		"ok": true,
		"loaded": false,
		"migrated": false,
		"from_version": 0,
		"error": "",
	}

	if path.is_empty() or !FileAccess.file_exists(path):
		return result

	var text := FileAccess.get_file_as_string(path)
	if text.strip_edges().is_empty():
		result["ok"] = false
		result["error"] = "Settings file is empty."
		return result

	var parsed: Variant = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		result["ok"] = false
		result["error"] = "Settings file is not a JSON object."
		return result

	var data: Dictionary = parsed
	var from_version := 0
	var values: Dictionary = {}

	if data.get("values") is Dictionary:
		values = data["values"]
		from_version = int(data.get("settings_version", 0))
	elif data.get("settings") is Array or data.get("settings") is Dictionary:
		# Legacy data.save payload, accepted as a fallback import source.
		values = _entries_to_dict(data["settings"])
		from_version = int(data.get("settings_version", 0))
	else:
		values = data
		from_version = int(data.get("settings_version", 0))

	for key in values.keys():
		var setting_key := str(key)
		if !_by_key.has(setting_key):
			continue
		_set_value_raw(setting_key, _migrate_value(setting_key, values[key], from_version))

	_version = CURRENT_VERSION
	_loaded = true
	result["loaded"] = true
	result["from_version"] = from_version
	result["migrated"] = from_version < CURRENT_VERSION

	if result["migrated"]:
		save()

	return result


## Imports the old settings array/dictionary from user://data.save.
## Does nothing once a settings.json has been loaded/persisted, so the legacy
## copy can never overwrite newer values on a later launch.
func import_legacy(entries: Variant) -> Dictionary:
	var result := {
		"ok": true,
		"imported": 0,
		"skipped": _loaded,
		"error": "",
	}

	if _loaded:
		return result

	var values := _entries_to_dict(entries)
	var imported := 0

	for key in values.keys():
		var setting_key := str(key)
		if !_by_key.has(setting_key):
			continue
		if _set_value_raw(setting_key, _migrate_value(setting_key, values[key], 0)):
			imported += 1

	if imported == 0:
		return result

	_version = CURRENT_VERSION
	_loaded = true
	var saved := save()
	result["imported"] = imported
	result["ok"] = saved.get("ok", false)
	result["error"] = saved.get("error", "")
	return result


func migrate(from_version: int) -> Dictionary:
	if from_version >= CURRENT_VERSION:
		return {"ok": true, "from_version": from_version, "to_version": CURRENT_VERSION, "error": ""}

	for key in _values.keys():
		_values[key] = _migrate_value(key, _values[key], from_version)

	_version = CURRENT_VERSION
	var saved := save()
	return {
		"ok": saved.get("ok", false),
		"from_version": from_version,
		"to_version": CURRENT_VERSION,
		"error": saved.get("error", ""),
	}


func save() -> Dictionary:
	var data := {
		"settings_version": CURRENT_VERSION,
		"values": _values,
	}
	var json := JSON.stringify(data, "\t")

	var global_path := ProjectSettings.globalize_path(path)
	var directory := global_path.get_base_dir()
	if !directory.is_empty() and !DirAccess.dir_exists_absolute(directory):
		DirAccess.make_dir_recursive_absolute(directory)

	var temp_path := global_path + ".griddy_tmp"
	var file := FileAccess.open(temp_path, FileAccess.WRITE)
	if file == null:
		return _save_error("Could not open the settings file for writing (error %d)." % FileAccess.get_open_error())

	file.store_string(json)
	file.flush()
	var write_error := file.get_error()
	file = null  # release before rename on Windows

	if write_error != OK:
		DirAccess.remove_absolute(temp_path)
		return _save_error("Could not write the settings file (error %d)." % write_error)

	if FileAccess.file_exists(global_path):
		if DirAccess.remove_absolute(global_path) != OK:
			# Could not replace atomically: write in place instead of losing it.
			var fallback := FileAccess.open(global_path, FileAccess.WRITE)
			if fallback == null:
				DirAccess.remove_absolute(temp_path)
				return _save_error("Could not replace the settings file (error %d)." % FileAccess.get_open_error())
			fallback.store_string(json)
			fallback.flush()
			var fallback_error := fallback.get_error()
			DirAccess.remove_absolute(temp_path)
			if fallback_error != OK:
				return _save_error("Could not write the settings file (error %d)." % fallback_error)
			return _save_ok()

	var rename_error := DirAccess.rename_absolute(temp_path, global_path)
	if rename_error != OK:
		var restored := FileAccess.open(global_path, FileAccess.WRITE)
		if restored == null:
			DirAccess.remove_absolute(temp_path)
			return _save_error("Could not rename the settings file (error %d)." % rename_error)
		restored.store_string(json)
		restored.flush()
		var restored_error := restored.get_error()
		DirAccess.remove_absolute(temp_path)
		if restored_error != OK:
			return _save_error("Could not write the settings file (error %d)." % restored_error)

	return _save_ok()


func _save_ok() -> Dictionary:
	return {"ok": true, "error": "", "path": path}


func _save_error(message: String) -> Dictionary:
	return {"ok": false, "error": message, "path": path}


func _schedule_save() -> void:
	if _save_timer != null:
		_save_timer.start()


# ── VALIDATION / MIGRATION ──────────────────────────────────────────────────

func _set_value_raw(key: String, value: Variant) -> bool:
	if !_by_key.has(key):
		return false

	var coerced := _coerce(_by_key[key], value)
	if !coerced.get("ok", false):
		return false

	_values[key] = coerced["value"]
	return true


func _coerce(entry: Dictionary, value: Variant) -> Dictionary:
	match str(entry.get("type", "string")):
		"bool":
			if typeof(value) == TYPE_BOOL:
				return {"ok": true, "value": value}
			if typeof(value) == TYPE_INT or typeof(value) == TYPE_FLOAT:
				return {"ok": true, "value": bool(value)}
			return {"ok": false, "value": null}

		"int":
			var number: int
			if typeof(value) == TYPE_INT:
				number = int(value)
			elif typeof(value) == TYPE_FLOAT:
				number = roundi(float(value))
			elif typeof(value) == TYPE_STRING and str(value).is_valid_int():
				number = int(value)
			else:
				return {"ok": false, "value": null}

			if entry.has("min"):
				number = maxi(number, int(entry["min"]))
			if entry.has("max"):
				number = mini(number, int(entry["max"]))
			return {"ok": true, "value": number}

		"float":
			var decimal: float
			if typeof(value) == TYPE_INT or typeof(value) == TYPE_FLOAT:
				decimal = float(value)
			elif typeof(value) == TYPE_STRING and str(value).is_valid_float():
				decimal = float(value)
			else:
				return {"ok": false, "value": null}

			if entry.has("min"):
				decimal = maxf(decimal, float(entry["min"]))
			if entry.has("max"):
				decimal = minf(decimal, float(entry["max"]))
			return {"ok": true, "value": decimal}

		"string":
			if typeof(value) == TYPE_STRING or typeof(value) == TYPE_STRING_NAME:
				return {"ok": true, "value": str(value)}
			return {"ok": false, "value": null}

	return {"ok": false, "value": null}


func _migrate_value(key: String, value: Variant, from_version: int) -> Variant:
	# v1 stored editor_font as an index into fonts[]. Resolve it against the
	# current option list and store the stable display name instead.
	if key == "editor_font":
		if typeof(value) == TYPE_INT or typeof(value) == TYPE_FLOAT:
			return _font_name_for_index(roundi(float(value)))

		if typeof(value) == TYPE_STRING or typeof(value) == TYPE_STRING_NAME:
			var stored := str(value)
			var resolved := _resolve_font_id(stored)
			return resolved if !resolved.is_empty() else stored

	return value


func _font_name_for_index(index: int) -> String:
	if !_by_key.has("editor_font"):
		return ""

	var options: Array = _by_key["editor_font"].get("options", [])
	if index < 0 or index >= options.size():
		return ""

	var option: Dictionary = options[index]
	return str(option.get("display", option.get("value", "")))


func _resolve_font_id(stored: String) -> String:
	if !_by_key.has("editor_font"):
		return ""

	var options: Array = _by_key["editor_font"].get("options", [])
	for option in options:
		if !(option is Dictionary):
			continue
		if str(option.get("display", "")) == stored:
			return stored
		if str(option.get("value", "")) == stored:
			return str(option.get("display", stored))
		if str(option.get("name", "")) == stored:
			return str(option.get("display", stored))

	return ""


func _entries_to_dict(entries: Variant) -> Dictionary:
	var out: Dictionary = {}

	if entries is Array:
		for entry in entries:
			if !(entry is Dictionary):
				continue
			if !entry.has("value"):
				continue
			var key := str(entry.get("property", entry.get("key", "")))
			if !key.is_empty():
				out[key] = entry["value"]
	elif entries is Dictionary:
		out = entries.duplicate(true)

	return out


func _reindex() -> void:
	_by_key.clear()
	for entry in _schema:
		_by_key[entry["key"]] = entry


func _apply_defaults() -> void:
	_values.clear()
	for entry in _schema:
		_values[entry["key"]] = entry.get("default")


# ── SCHEMA ──────────────────────────────────────────────────────────────────

func _default_schema() -> Array:
	return [
		{
			"key": "beginner_mode", "type": "bool", "default": false, "scope": "user",
			"display": "Beginner Mode", "beginner_label": "Beginner Mode", "icon": "🌱",
			"category": "beginner", "beginner_visible": true,
			"description": "Make the text larger, use plain-language menus, simplify this settings list, and ask before destructive actions. Your previous text size is restored when you turn it off.",
			"options": [],
		},
		{
			"key": "show_welcome", "type": "bool", "default": true, "scope": "user",
			"display": "Show the welcome screen at startup", "beginner_label": "Show the welcome screen",
			"icon": "󰈔", "category": "beginner", "beginner_visible": true,
			"description": "Open a start screen with starter templates, recent files and recent folders when no file is open.",
			"options": [],
		},
		{
			"key": "history_enabled", "type": "bool", "default": true, "scope": "user",
			"display": "Keep previous versions", "beginner_label": "Keep previous versions",
			"icon": "󰋚", "category": "beginner", "beginner_visible": true,
			"description": "Save a local copy before a save, before a run, before closing, and every minute while a file has unsaved edits. History is stored on your computer and never uploaded.",
			"options": [],
		},
		{
			"key": "history_interval", "type": "int", "default": 60, "min": 15, "max": 600,
			"scope": "user", "display": "Automatic backup interval", "beginner_label": "Back up every",
			"icon": "󰔛", "category": "beginner", "beginner_visible": true, "unit": "sec.",
			"description": "How often a modified file is copied into History. Saves, runs and closing take an extra copy immediately.",
			"options": [],
		},
		{
			"key": "glossary_enabled", "type": "bool", "default": true, "scope": "user",
			"display": "Explain words on hover", "beginner_label": "Explain words on hover",
			"icon": "󰋖", "category": "beginner", "beginner_visible": true,
			"description": "Show a plain-language explanation and a small example when the pointer rests on a keyword. The Explain This command works even when hover is off.",
			"options": [],
		},
		{
			"key": "preview_port", "type": "int", "default": 0, "min": 0, "max": 65535,
			"scope": "user", "display": "Preview server port", "icon": "󰖟",
			"category": "beginner", "unit": "port",
			"description": "Port for the local preview server. 0 picks a free port automatically, which is the safest choice.",
			"options": [],
		},
		{
			"key": "editor_font", "type": "string", "default": "", "scope": "user",
			"display": "Editor Font", "beginner_label": "Text style", "beginner_visible": true,
			"icon": "", "category": "editor",
			"description": "Typeface used for the code and the editor UI. Any installed system font can be selected; the choice is saved by font name.",
			"options": [],
		},
		{
			"key": "editor_font_size", "type": "int", "default": 16, "min": 8, "max": 48,
			"scope": "user", "display": "Editor Font Size", "beginner_label": "Text size",
			"beginner_visible": true, "icon": "󰛖",
			"category": "editor", "unit": "px",
			"description": "Size of the code text in pixels. Ctrl+= and Ctrl+- zoom the view instead.",
			"options": [],
		},
		{
			"key": "editor_line_height", "type": "float", "default": 1.25, "min": 1.0, "max": 2.5,
			"scope": "user", "display": "Editor Line Height", "beginner_label": "Line spacing",
			"beginner_visible": true, "icon": "󰛖",
			"category": "editor", "unit": "x", "precision": true,
			"description": "Line height as a multiple of the font size. 1.0 is the tightest, 2.5 is the airiest; raising it is a real layout change, not just a zoom.",
			"options": [],
		},
		{
			"key": "caret_type", "type": "int", "default": 0, "scope": "user",
			"display": "Caret type", "icon": "", "category": "editor",
			"description": "Shape of the text cursor: Line is a thin bar, Block covers the character under it.",
			"options": [{"display": "Line", "value": 0}, {"display": "Block", "value": 1}],
		},
		{
			"key": "caret_blink", "type": "bool", "default": true, "scope": "user",
			"display": "Caret Blinking", "beginner_label": "Blinking cursor", "beginner_visible": true,
			"icon": "|", "category": "editor",
			"description": "Let the text cursor blink while you are not typing. Turn this off for a solid cursor.",
			"options": [],
		},
		{
			"key": "cursor_effect", "type": "int", "default": 1, "scope": "user",
			"display": "Cursor Trail", "icon": char(0xF0D1), "category": "editor",
			"description": "Draw a trail behind the text cursor while it moves. Warp stretches the cursor towards its new spot, Sweep shrinks the old spot onto the new one, Tail leaves a comet.",
			"options": [
				{"display": "Off", "value": 0},
				{"display": "Warp", "value": 1},
				{"display": "Sweep", "value": 2},
				{"display": "Tail", "value": 3},
			],
		},
		{
			"key": "cursor_effect_duration", "type": "float", "default": 0.2, "min": 0.05, "max": 1.0,
			"scope": "user", "display": "Cursor Trail: Duration", "icon": char(0xE382),
			"category": "editor",
			"unit": "sec.", "precision": true,
			"description": "How long the trail takes to fade out after the cursor moved.",
			"options": [],
		},
		{
			"key": "cursor_effect_opacity", "type": "int", "default": 55, "min": 0, "max": 100,
			"scope": "user", "display": "Cursor Trail: Opacity", "icon": char(0xF05EC),
			"category": "editor",
			"unit": "%",
			"description": "How strongly the trail is painted over the code.",
			"options": [],
		},
		{
			"key": "caret_interval", "type": "float", "default": 0.6, "min": 0.1, "max": 3.0,
			"scope": "user", "display": "Caret Blink Interval", "icon": "",
			"category": "editor", "unit": "sec.", "precision": true,
			"description": "How fast the cursor blinks. Lower values blink faster.",
			"options": [],
		},
		{
			"key": "draw_line_numbers", "type": "bool", "default": true, "scope": "user",
			"display": "Draw Line Number", "beginner_label": "Line numbers", "beginner_visible": true,
			"icon": "", "category": "editor",
			"description": "Show line numbers in the gutter next to the code.",
			"options": [],
		},
		{
			"key": "code_completion", "type": "bool", "default": true, "scope": "user",
			"display": "Code Completion", "icon": "", "category": "editor",
			"description": "Suggest functions and variables from the current file while typing. Provided by the language's Lua plugin.",
			"options": [],
		},
		{
			"key": "indentation_size", "type": "int", "default": 4, "min": 1, "max": 8,
			"scope": "user", "display": "Indentation Size", "beginner_label": "Indent size",
			"beginner_visible": true, "icon": "󰌒",
			"category": "indentation", "unit": "tabs",
			"description": "How many columns one indent level adds when you press Tab or indent a block.",
			"options": [],
		},
		{
			"key": "indentation_automatic", "type": "bool", "default": true, "scope": "user",
			"display": "Automatic Indentation", "icon": "󰁨", "category": "indentation",
			"description": "Keep the indentation of the previous line when you press Enter.",
			"options": [],
		},
		{
			"key": "indentation_use_spaces", "type": "bool", "default": false, "scope": "user",
			"display": "Indentation: use spaces", "beginner_label": "Use spaces for indentation",
			"beginner_visible": true, "icon": "󱁐", "category": "indentation",
			"description": "Insert spaces instead of tab characters. Useful for projects that require spaces.",
			"options": [],
		},
		{
			"key": "auto_brace_completion", "type": "bool", "default": true, "scope": "user",
			"display": "Auto Brace Completion", "icon": "󰅩", "category": "indentation",
			"description": "Automatically insert a closing bracket, brace, or quote when you type its opening partner.",
			"options": [],
		},
		{
			"key": "auto_brace_highlight_matching", "type": "bool", "default": true, "scope": "user",
			"display": "Highlight Matching Braces", "icon": "󱃖", "category": "indentation",
			"description": "Highlight the partner when the caret is next to a bracket or brace.",
			"options": [],
		},
		{
			"key": "respect_shebang", "type": "bool", "default": true, "scope": "user",
			"display": "Run: shebang first", "icon": "", "category": "running",
			"description": "If the file begins with #!, run the interpreter named there instead of guessing from the extension.",
			"options": [],
		},
		{
			"key": "terminal_shell", "type": "string", "default": "", "scope": "user",
			"display": "Terminal Shell", "icon": ">_", "category": "running",
			"description": "Program to start for a new terminal tab. The system default is cmd.exe on Windows and $SHELL elsewhere. This is a user setting; project files cannot change it.",
			"options": [
				{"display": "System default", "value": ""},
				{"display": "Command Prompt (cmd.exe)", "value": "cmd.exe"},
				{"display": "PowerShell", "value": "powershell.exe"},
				{"display": "PowerShell 7", "value": "pwsh.exe"},
				{"display": "Bash", "value": "bash"},
				{"display": "Zsh", "value": "zsh"},
			],
		},
		{
			"key": "save_before_run", "type": "bool", "default": true, "scope": "user",
			"display": "Run: save file first", "beginner_label": "Save before running",
			"beginner_visible": true, "icon": "", "category": "running",
			"description": "Save the current file before running it so the compiler or interpreter sees your latest edits.",
			"options": [],
		},
		{
			"key": "auto_detect_language", "type": "bool", "default": true, "scope": "user",
			"display": "Detect Language in Plain Text", "icon": "", "category": "editor",
			"description": "When a file has no useful extension (for example .txt or .log), identify its language from the contents and use that for highlighting and Run. Real source files always trust their extension.",
			"options": [],
		},
		{
			"key": "lsp_enabled", "type": "bool", "default": true, "scope": "user",
			"display": "Language Servers", "icon": "", "category": "language",
			"description": "Start a language server for Python, TypeScript/JavaScript, Rust, C/C++ or Go files. Servers are launched from your PATH; Qorix never downloads or installs them.",
			"options": [],
		},
		{
			"key": "lsp_diagnostics", "type": "bool", "default": true, "scope": "user",
			"display": "Diagnostics: errors and warnings", "icon": "", "category": "language",
			"description": "Underline problem lines in the editor and list them in the Problems tab. Turning this off hides gutter marks but keeps the server running for other features.",
			"options": [],
		},
		{
			"key": "lsp_completion", "type": "bool", "default": true, "scope": "user",
			"display": "Completion from the language server", "icon": "", "category": "language",
			"description": "Merge server suggestions into the existing completion popup. Local symbol completion keeps working when this is off.",
			"options": [],
		},
		{
			"key": "lsp_hover", "type": "bool", "default": true, "scope": "user",
			"display": "Hover documentation", "icon": "", "category": "language",
			"description": "Show types, signatures and docs when the pointer rests on a symbol. The explicit Show Hover Information command still works when this is off.",
			"options": [],
		},
		{
			"key": "lsp_signature_help", "type": "bool", "default": true, "scope": "user",
			"display": "Signature help while typing", "icon": "", "category": "language",
			"description": "Show the active call signature and the parameter you are filling in. Appears automatically inside argument lists and on demand with Ctrl+Shift+Space.",
			"options": [],
		},
		{
			"key": "lsp_lightbulb", "type": "bool", "default": true, "scope": "user",
			"display": "Code action lightbulb", "icon": "", "category": "language",
			"description": "Mark lines that have quick fixes or refactors. Click the ✦ gutter or press Ctrl+. to open the action list.",
			"options": [],
		},
		{
			"key": "lsp_auto_open_problems", "type": "bool", "default": false, "scope": "user",
			"display": "Open Problems when new errors appear", "icon": "", "category": "language",
			"description": "Automatically open the Problems tab when the number of diagnostics grows. Off by default so the bottom dock stays out of the way.",
			"options": [],
		},
		{
			"key": "debug_auto_open_stopped_file", "type": "bool", "default": true, "scope": "user",
			"display": "Open the file when a breakpoint is hit", "icon": "", "category": "debug",
			"description": "Switch to the paused file and put the caret on the stopped line. Turn this off to stay in the current tab; the execution marker still appears in any open file.",
			"options": [],
		},
		{
			"key": "debug_verbose_log", "type": "bool", "default": false, "scope": "user",
			"display": "Verbose debug adapter log", "icon": "", "category": "debug",
			"description": "Print every DAP request, response and event to the Debug Console. Useful when an adapter refuses to start or behaves unexpectedly.",
			"options": [],
		},
		{
			"key": "restore_session", "type": "bool", "default": true, "scope": "user",
			"display": "Restore Session", "beginner_label": "Reopen my files next time",
			"beginner_visible": true, "icon": "󰁯", "category": "workspace",
			"description": "On startup, reopen the last workspace with its tabs, carets, scroll positions and terminal folders. Unsaved buffers are backed up and restored too.",
			"options": [],
		},
		{
			"key": "session_autosave", "type": "int", "default": 20, "min": 5, "max": 300,
			"scope": "user", "display": "Session Autosave", "icon": "󰆓",
			"category": "workspace", "unit": "sec.",
			"description": "How often the session and unsaved buffers are backed up while you work. Lower values protect more recent edits; higher values write to disk less often.",
			"options": [],
		},
		{
			"key": "external_change_check", "type": "bool", "default": true, "scope": "user",
			"display": "Watch for Disk Changes", "icon": "󰈈", "category": "workspace",
			"description": "Notice when an open file is changed or deleted by another program, and offer to reload it, keep your buffer, or compare the two.",
			"options": [],
		},
		{
			"key": "git_gutter", "type": "bool", "default": true, "scope": "user",
			"display": "Changed-line markers", "icon": "󰊢", "category": "git",
			"description": "Show added, modified and deleted lines in the editor gutter. Click a marker to open the diff for that file.",
			"options": [],
		},
		{
			"key": "git_auto_refresh", "type": "bool", "default": true, "scope": "user",
			"display": "Refresh Source Control automatically", "icon": "󰑓", "category": "git",
			"description": "Poll the repository for changes every few seconds while Source Control is open. Turning this off leaves the Refresh button available.",
			"options": [],
		},
		{
			"key": "smooth_scrolling", "type": "bool", "default": true, "scope": "user",
			"display": "Smooth Scrolling", "icon": "󱕒", "category": "scrolling",
			"description": "Glide the view towards the caret instead of jumping to it.",
			"options": [],
		},
		{
			"key": "scroll_speed", "type": "int", "default": int(Scroll.DEFAULT_SCROLL_SPEED), "min": 100, "max": 6000,
			"scope": "user", "display": "Scrolling Speed", "icon": "",
			"category": "scrolling", "unit": "px/s",
			"description": "How fast the view travels through the file. Lower is slower; every move takes a moment so it reads as a glide.",
			"options": [],
		},
		{
			"key": "minimap", "type": "bool", "default": true, "scope": "user",
			"display": "Minimap", "icon": "󰍍", "category": "scrolling",
			"description": "Show a miniature overview of the whole file on the right edge of the screen. Click it to jump.",
			"options": [],
		},
		{
			"key": "minimap_width", "type": "int", "default": 80, "min": 20, "max": 500,
			"scope": "user", "display": "Minimap Width", "icon": "",
			"category": "scrolling", "unit": "px",
			"description": "How wide the minimap is. Larger values make it easier to see the shape of the file.",
			"options": [],
		},
		{
			"key": "zoom_intensity", "type": "float", "default": 1.0, "min": 0.1, "max": 3.0,
			"scope": "user", "display": "Zoom: Intensity", "icon": char(0xF0349),
			"category": "appearance", "unit": "x", "precision": true,
			"description": "How much the camera zooms in on your code. Raise it to make text larger, lower it to see more of the file.",
			"options": [],
		},
		{
			"key": "ui_animations", "type": "bool", "default": true, "scope": "user",
			"display": "UI Animations", "icon": "󰐕", "category": "appearance",
			"description": "Animate panels, docks and other interface transitions. Reduced Motion and Static Camera always disable these transitions.",
			"options": [],
		},
		{
			"key": "ui_polish", "type": "bool", "default": true, "scope": "user",
			"display": "UI Polish", "icon": "󰔛", "category": "appearance",
			"description": "Enable the current interface's subtle panel feedback, stacked notifications and status transitions without changing the editor layout or theme.",
			"options": [],
		},
		{
			"key": "state_feedback", "type": "bool", "default": true, "scope": "user",
			"display": "State Feedback", "icon": "󰄬", "category": "appearance",
			"description": "Use brief visual feedback when tabs, diagnostics, Git changes, or debugger state changes. This never affects typing or editor scrolling.",
			"options": [],
		},
		{
			"key": "glow", "type": "bool", "default": true, "scope": "user",
			"display": "Glow", "icon": "󰌶", "category": "appearance",
			"description": "Add a neon bloom around bright text. Some light themes turn this off automatically.",
			"options": [],
		},
		{
			"key": "glow_intensity", "type": "float", "default": 2.0, "min": 0.0, "max": 4.0,
			"scope": "user", "display": "Glow: Intensity", "icon": "󰌶",
			"category": "appearance", "unit": "x", "precision": true,
			"description": "Strength of the glow. At 0 the glow is effectively off even while Glow is enabled.",
			"options": [],
		},
		{
			"key": "sunlight", "type": "bool", "default": false, "scope": "user",
			"display": "Shader: Sunlight", "icon": "", "shader": true, "category": "appearance",
			"description": "Warm sunlight rays over the editor. Only one full-screen shader can be active at a time.",
			"options": [],
		},
		{
			"key": "vhs", "type": "bool", "default": false, "scope": "user",
			"display": "Shader: VHS and CRT", "icon": "", "shader": true, "category": "appearance",
			"description": "VHS scanlines and CRT distortion over the editor. Only one full-screen shader can be active at a time.",
			"options": [],
		},
		{
			"key": "reduced_motion", "type": "bool", "default": false, "scope": "user",
			"display": "Reduced Motion", "beginner_label": "Calm mode", "beginner_visible": true,
			"icon": "󰒲", "category": "accessibility",
			"description": "Turn off camera shake, music pulses, cursor trails, background motion and full-screen shaders. Navigation stays instant so the editor never moves under the reader.",
			"options": [],
		},
		{
			"key": "static_camera", "type": "bool", "default": false, "scope": "user",
			"display": "Static Camera", "beginner_label": "Camera stays still", "beginner_visible": true,
			"icon": "󰁌", "category": "accessibility",
			"description": "Stop the camera wobble and the smooth glide. The view jumps straight to the caret, without any shake or drift.",
			"options": [],
		},
		{
			"key": "high_contrast", "type": "bool", "default": false, "scope": "user",
			"display": "High Contrast", "beginner_label": "High contrast colours", "beginner_visible": true,
			"icon": "󰐕", "category": "accessibility",
			"description": "Replace the theme colours with a black background and bright, WCAG AAA text and syntax colours. Glow is suspended while this is on.",
			"options": [],
		},
		{
			"key": "dyslexia_font", "type": "bool", "default": false, "scope": "user",
			"display": "Dyslexia-friendly Font", "beginner_label": "Easier-to-read text", "beginner_visible": true,
			"icon": "󰛖", "category": "accessibility",
			"description": "Use the first installed dyslexia-friendly font (OpenDyslexic, Atkinson Hyperlegible or Lexend) and open the line height up. Nothing is downloaded; a notice appears if none is installed.",
			"options": [],
		},
		{
			"key": "focus_indicators", "type": "bool", "default": true, "scope": "user",
			"display": "Focus Indicators", "beginner_label": "Show where the keyboard is", "beginner_visible": true,
			"icon": "󰆿", "category": "accessibility",
			"description": "Draw a bright border around the control the keyboard is on, so Tab navigation is always visible.",
			"options": [],
		},
		{
			"key": "ui_language", "type": "string", "default": "en", "scope": "user",
			"display": "Interface Language", "beginner_label": "Language", "beginner_visible": true,
			"icon": "󰗊", "category": "localization",
			"description": "Language for menus, commands and settings. Translations come from resources/localization/strings.csv; missing keys stay in English.",
			"options": [],
		},
		{
			"key": "large_file_mode", "type": "bool", "default": true, "scope": "user",
			"display": "Large File Mode", "beginner_label": "Keep huge files fast", "beginner_visible": true,
			"icon": "󰈔", "category": "performance",
			"description": "For files above the threshold, turn off the minimap, syntax highlighting and completion. Typing stays responsive instead of pausing on every key.",
			"options": [],
		},
		{
			"key": "large_file_threshold", "type": "int", "default": 5000, "min": 500, "max": 100000,
			"scope": "user", "display": "Large File Threshold", "icon": "󰔚",
			"category": "performance", "unit": "lines",
			"description": "Files with more lines than this open in Large File Mode. The default catches 10,000-line files while leaving normal source files fully featured.",
			"options": [],
		},
		{
			"key": "background_indexing", "type": "bool", "default": true, "scope": "user",
			"display": "Background Indexing", "icon": "󰑮", "category": "performance",
			"description": "Walk the workspace index and run file searches on worker threads. Turning it off falls back to the old frame-sliced scan.",
			"options": [],
		},
		{
			"key": "music", "type": "bool", "default": false, "scope": "user",
			"display": "Music", "icon": "󰝚", "category": "audio",
			"description": "Play background music while the editor is open.",
			"options": [],
		},
		{
			"key": "music_volume", "type": "int", "default": 100, "min": 0, "max": 100,
			"scope": "user", "display": "Music: Volume", "icon": "",
			"category": "audio", "unit": "%",
			"description": "Background music volume. 0% is silent.",
			"options": [],
		},
		{
			"key": "music_move_intensity", "type": "int", "default": 1, "min": 0, "max": 10,
			"scope": "user", "display": "Music: Camera Intensity", "icon": "",
			"category": "audio", "unit": "x",
			"description": "How strongly the camera pulses with the beat of the music. 0 turns the pulse off.",
			"options": [],
		},
		{
			"key": "discord_sdk", "type": "bool", "default": false, "scope": "user",
			"display": "Discord SDK", "icon": "󰙯", "category": "integrations",
			"description": "Share the file you are working on through Discord Rich Presence. Off by default: presence broadcasts activity, so it is opt-in. Discord must be running.",
			"options": [],
		},
	]
