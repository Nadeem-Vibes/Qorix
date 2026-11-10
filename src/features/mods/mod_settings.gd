extends RefCounted

## Per-mod settings declared by the manifest or at runtime.
##
## SettingsService owns the editor's own schema and is never mutated from here.
## The mod settings UI (Phase 2) reads `definitions()` and writes through
## `set_value()`, so the same validated store serves both the panel and the Lua
## API.

const Result = preload("res://src/features/mods/mod_result.gd")
const Store = preload("res://src/base/file_store.gd")
const Json = preload("res://src/features/mods/mod_json.gd")

const QUOTA := 64 * 1024
const MAX_SETTINGS := 64
const KEY_PATTERN := "^[a-z][a-z0-9_]{0,63}$"
const TYPES := ["bool", "int", "float", "string"]

var mod_id: String
var root: String
var last_error: String = ""

## key -> {key, type, default, label, min?, max?, options?, source}
var _definitions: Dictionary = {}
var _values: Dictionary = {}
## Persisted values that arrived before their declaration (a mod's settings are
## declared after the file is read). Applied as soon as the key is declared.
var _stored: Dictionary = {}
var _loaded: bool = false


func _init(id: String, data_root: String) -> void:
	mod_id = id
	root = data_root.path_join(id)


func settings_path() -> String:
	return root.path_join("settings.json")


func load_state() -> Dictionary:
	_values.clear()
	_stored.clear()
	_loaded = true
	last_error = ""

	var path := settings_path()
	if !FileAccess.file_exists(path):
		_apply_defaults()
		return Result.ok()

	var loaded := Store.load_json(path)
	if !loaded.get("ok", false):
		last_error = str(loaded.get("error", "Could not read settings.json."))
		Store.save(path + ".corrupt", FileAccess.get_file_as_string(path))
		_apply_defaults()
		return Result.error("registry.invalid", last_error)

	var data: Variant = loaded.get("data", {})
	var raw: Variant = data.get("values", {}) if data is Dictionary else {}
	if raw is Dictionary:
		for key in (raw as Dictionary).keys():
			var value: Variant = (raw as Dictionary)[key]
			if !Json.is_value(value):
				continue
			_stored[str(key)] = Json.normalize(value)

			var definition: Variant = _definitions.get(str(key))
			if !(definition is Dictionary):
				continue
			var coerced := _coerce(definition, value)
			if coerced.get("ok", false):
				_values[str(key)] = coerced["value"]

	_apply_defaults()
	return Result.ok()


## Declares settings. The manifest is the first source; a mod may add more at
## runtime, but it cannot redefine a manifest key with a different type.
func declare(schema: Array, source: String = "runtime") -> Dictionary:
	_ensure_loaded()
	var errors: Array = []
	var conflicts := 0

	if _definitions.size() + schema.size() > MAX_SETTINGS:
		return Result.error("settings.invalid", "A mod may declare at most %d settings." % MAX_SETTINGS)

	for index in range(schema.size()):
		var raw: Variant = schema[index]
		if !(raw is Dictionary):
			errors.append("Setting %d is not an object." % index)
			continue

		var key := str((raw as Dictionary).get("key", ""))
		if !_valid_key(key):
			errors.append("'%s' is not a valid setting key." % key)
			continue

		var type := str((raw as Dictionary).get("type", ""))
		if !TYPES.has(type):
			errors.append("Setting '%s' has an unknown type '%s'." % [key, type])
			continue

		var definition := {
			"key": key,
			"type": type,
			"label": str((raw as Dictionary).get("label", key)),
			"default": _default_for(type),
			"source": source,
		}

		var default_coerced := _coerce(definition, (raw as Dictionary).get("default"))
		if !default_coerced.get("ok", false):
			errors.append("Setting '%s' has an invalid default." % key)
			continue
		definition["default"] = default_coerced["value"]

		for bound in ["min", "max"]:
			if (raw as Dictionary).has(bound):
				var value: Variant = (raw as Dictionary)[bound]
				if typeof(value) != TYPE_INT and typeof(value) != TYPE_FLOAT:
					errors.append("Setting '%s' has a non-numeric %s." % [key, bound])
					continue
				definition[bound] = value

		if (raw as Dictionary).has("options"):
			var options: Variant = (raw as Dictionary)["options"]
			if !(options is Array):
				errors.append("Setting '%s' options must be an array." % key)
				continue
			definition["options"] = (options as Array).duplicate(true)

		if _definitions.has(key):
			var existing: Dictionary = _definitions[key]
			if str(existing.get("type", "")) != type:
				errors.append("Setting '%s' is already declared with type '%s'." % [key, existing.get("type", "")])
				conflicts += 1
				continue
			# Same key and type from the manifest and a runtime declaration is
			# idempotent; the manifest definition wins.
			continue

		_definitions[key] = definition
		if !_values.has(key):
			if _stored.has(key):
				var restored := _coerce(definition, _stored[key])
				_values[key] = restored["value"] if restored.get("ok", false) else definition["default"]
			else:
				_values[key] = definition["default"]

	if !errors.is_empty():
		var code := "settings.conflict" if conflicts > 0 and errors.size() == conflicts else "settings.invalid"
		return Result.error(code, " ".join(errors), {"errors": errors})

	var saved := _write()
	if !saved.get("ok", false):
		return saved
	return Result.ok(_definitions.size())


func definitions() -> Array:
	var keys: Array = _definitions.keys()
	keys.sort()
	var out: Array = []
	for key in keys:
		out.append((_definitions[key] as Dictionary).duplicate(true))
	return out


func has_definition(key: String) -> bool:
	return _definitions.has(str(key))


func get_value(key: String, fallback: Variant = null) -> Dictionary:
	_ensure_loaded()
	if !_definitions.has(str(key)):
		return Result.error("settings.invalid", "'%s' is not a declared setting." % key)
	if !_values.has(str(key)):
		return Result.ok(fallback)
	return Result.ok(Json.clone(_values[str(key)]))


func set_value(key: String, value: Variant) -> Dictionary:
	_ensure_loaded()
	if !_definitions.has(str(key)):
		return Result.error("settings.invalid", "'%s' is not a declared setting." % key)

	var coerced := _coerce(_definitions[str(key)], value)
	if !coerced.get("ok", false):
		return Result.error("settings.invalid", "The value does not match the setting type.")

	_values[str(key)] = coerced["value"]
	return _write()


func values() -> Dictionary:
	_ensure_loaded()
	return _values.duplicate(true)


func flush() -> Dictionary:
	if !_loaded:
		return Result.ok()
	return _write()


# ── INTERNALS ───────────────────────────────────────────────────────────────

func _apply_defaults() -> void:
	for key in _definitions.keys():
		if !_values.has(key):
			_values[key] = (_definitions[key] as Dictionary).get("default")


func _coerce(definition: Dictionary, value: Variant) -> Dictionary:
	var type := str(definition.get("type", "string"))

	match type:
		"bool":
			if typeof(value) == TYPE_BOOL:
				return {"ok": true, "value": value}
			return {"ok": false, "value": null}

		"int":
			if typeof(value) != TYPE_INT and typeof(value) != TYPE_FLOAT:
				return {"ok": false, "value": null}
			if float(value) != floor(float(value)):
				return {"ok": false, "value": null}
			var number := int(value)
			if definition.has("min"):
				number = maxi(number, int(definition["min"]))
			if definition.has("max"):
				number = mini(number, int(definition["max"]))
			return {"ok": true, "value": number}

		"float":
			if typeof(value) != TYPE_INT and typeof(value) != TYPE_FLOAT:
				return {"ok": false, "value": null}
			var decimal := float(value)
			if definition.has("min"):
				decimal = maxf(decimal, float(definition["min"]))
			if definition.has("max"):
				decimal = minf(decimal, float(definition["max"]))
			return {"ok": true, "value": decimal}

		"string":
			if typeof(value) == TYPE_STRING or typeof(value) == TYPE_STRING_NAME:
				return {"ok": true, "value": str(value)}
			return {"ok": false, "value": null}

	return {"ok": false, "value": null}


func _default_for(type: String) -> Variant:
	match type:
		"bool":
			return false
		"int":
			return 0
		"float":
			return 0.0
		"string":
			return ""
	return null


func _valid_key(key: String) -> bool:
	var regex := RegEx.new()
	if regex.compile(KEY_PATTERN) != OK:
		return false
	return regex.search(key) != null


func _ensure_loaded() -> void:
	if !_loaded:
		load_state()


func _write() -> Dictionary:
	if Json.size_bytes(_values) > QUOTA:
		return Result.error("storage.quota", "Mod settings exceed %d bytes." % QUOTA)

	var global := ProjectSettings.globalize_path(root)
	if !DirAccess.dir_exists_absolute(global):
		DirAccess.make_dir_recursive_absolute(global)

	var saved := Store.save_json(settings_path(), {"version": 1, "values": _values})
	if !saved.get("ok", false):
		last_error = str(saved.get("error", "Could not write settings.json."))
		return Result.error("storage.quota", last_error)
	return Result.ok()
