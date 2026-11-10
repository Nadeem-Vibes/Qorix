extends RefCounted

## Mod-scoped progress values.
##
## Progress is intentionally a separate file from general storage: it is small,
## written on every completed step, and flushed on teardown, while a mod may keep
## large blobs in storage. `reset("")` clears the whole namespace.

const Result = preload("res://src/features/mods/mod_result.gd")
const Store = preload("res://src/base/file_store.gd")
const Json = preload("res://src/features/mods/mod_json.gd")

const QUOTA := 64 * 1024
const KEY_PATTERN := "^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$"

var mod_id: String
var root: String
var last_error: String = ""

var _values: Dictionary = {}
var _loaded: bool = false


func _init(id: String, data_root: String) -> void:
	mod_id = id
	root = data_root.path_join(id)


func progress_path() -> String:
	return root.path_join("progress.json")


func load_state() -> Dictionary:
	_values.clear()
	_loaded = true
	last_error = ""

	var path := progress_path()
	if !FileAccess.file_exists(path):
		return Result.ok()

	var text := FileAccess.get_file_as_string(path)
	if text.strip_edges().is_empty():
		return Result.ok()

	var json := JSON.new()
	if json.parse(text) != OK or !(json.data is Dictionary):
		last_error = "'progress.json' is not valid JSON."
		Store.save(path + ".corrupt", text)
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
		return Result.error("registry.invalid", last_error)

	for key in (json.data as Dictionary).keys():
		var value: Variant = (json.data as Dictionary)[key]
		if Json.is_value(value):
			_values[str(key)] = Json.normalize(value)

	return Result.ok()


func get_value(key: String, fallback: Variant = null) -> Dictionary:
	_ensure_loaded()
	if !is_valid_key(key):
		return Result.error("storage.invalid_key", "'%s' is not a valid progress key." % key)
	if !_values.has(key):
		return Result.ok(Json.normalize(fallback))
	return Result.ok(Json.clone(_values[key]))


func set_value(key: String, value: Variant) -> Dictionary:
	_ensure_loaded()
	if !is_valid_key(key):
		return Result.error("storage.invalid_key", "'%s' is not a valid progress key." % key)

	var normalized: Variant = Json.normalize(value)
	if !Json.is_value(normalized):
		return Result.error("storage.invalid_value", "Progress values must be JSON-serializable.")

	var candidate: Dictionary = _values.duplicate(true)
	candidate[key] = normalized

	var size := Json.size_bytes(candidate)
	if size > QUOTA:
		return Result.error(
			"storage.quota",
			"Progress would use %d of %d bytes." % [size, QUOTA],
			{"used": size, "quota": QUOTA},
		)

	_values = candidate
	return _write()


func increment(key: String, amount: Variant = 1) -> Dictionary:
	_ensure_loaded()
	if !is_valid_key(key):
		return Result.error("storage.invalid_key", "'%s' is not a valid progress key." % key)
	if typeof(amount) != TYPE_INT and typeof(amount) != TYPE_FLOAT:
		return Result.error("storage.invalid_value", "increment needs a number.")

	var current: Variant = _values.get(key, 0)
	if typeof(current) != TYPE_INT and typeof(current) != TYPE_FLOAT:
		return Result.error("storage.invalid_value", "'%s' is not a number." % key)

	var next: Variant = current + amount
	if typeof(next) == TYPE_FLOAT and is_finite(next) and next == floor(next):
		next = int(next)

	return set_value(key, next)


func reset(key: String = "") -> Dictionary:
	_ensure_loaded()
	if key.is_empty():
		_values.clear()
	else:
		_values.erase(key)
	return _write()


func all() -> Dictionary:
	_ensure_loaded()
	return Result.ok(_values.duplicate(true))


func flush() -> Dictionary:
	if !_loaded:
		return Result.ok()
	return _write()


func usage() -> Dictionary:
	_ensure_loaded()
	return {"used": Json.size_bytes(_values), "quota": QUOTA}


static func is_valid_key(key: String) -> bool:
	if key.is_empty() or key.length() > 128:
		return false
	var regex := RegEx.new()
	if regex.compile(KEY_PATTERN) != OK:
		return false
	return regex.search(key) != null


func _ensure_loaded() -> void:
	if !_loaded:
		load_state()


func _write() -> Dictionary:
	var global := ProjectSettings.globalize_path(root)
	if !DirAccess.dir_exists_absolute(global):
		DirAccess.make_dir_recursive_absolute(global)

	var saved := Store.save_json(progress_path(), _values)
	if !saved.get("ok", false):
		last_error = str(saved.get("error", "Could not write progress.json."))
		return Result.error("storage.quota", last_error)
	return Result.ok(_values.duplicate(true))
