extends RefCounted

## Namespaced mod storage: user://mod_data/<id>/.
##
## KV values are JSON, so quotas are exact byte counts and a corrupted file can
## always be identified without instantiating engine objects. Writes are atomic
## (temp file + swap) through FileStore; blobs are written the same way.

const Result = preload("res://src/features/mods/mod_result.gd")
const Store = preload("res://src/base/file_store.gd")
const Json = preload("res://src/features/mods/mod_json.gd")

const KV_QUOTA := 2 * 1024 * 1024
const BLOB_LIMIT := 10 * 1024 * 1024
const TOTAL_QUOTA := 50 * 1024 * 1024
const MAX_BLOBS := 256
const MAX_KEY_LENGTH := 128

const KEY_PATTERN := "^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$"
const BLOB_PATTERN := "^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$"

var mod_id: String
var root: String
var last_error: String = ""

var _kv: Dictionary = {}
var _blob_sizes: Dictionary = {}
var _loaded: bool = false


func _init(id: String, data_root: String) -> void:
	mod_id = id
	root = data_root.path_join(id)


func kv_path() -> String:
	return root.path_join("kv.json")


func blob_dir() -> String:
	return root.path_join("blobs")


func load_state() -> Dictionary:
	_kv.clear()
	_loaded = true
	last_error = ""

	_ensure_dir(blob_dir())

	var path := kv_path()
	if FileAccess.file_exists(path):
		var parsed := _read_json_object(path)
		if !parsed.get("ok", false):
			last_error = str(parsed.get("error", "Could not read kv.json."))
			_backup_corrupt(path)
		else:
			_kv = parsed["data"]

	_scan_blobs()
	return Result.ok()


func get_value(key: String, fallback: Variant = null) -> Dictionary:
	_ensure_loaded()
	if !is_valid_key(key):
		return Result.error("storage.invalid_key", "'%s' is not a valid storage key." % key)

	if !_kv.has(key):
		return Result.ok(Json.normalize(fallback))
	return Result.ok(Json.clone(_kv[key]))


func set_value(key: String, value: Variant) -> Dictionary:
	_ensure_loaded()
	if !is_valid_key(key):
		return Result.error("storage.invalid_key", "'%s' is not a valid storage key." % key)

	var normalized: Variant = Json.normalize(value)
	if !Json.is_value(normalized):
		return Result.error("storage.invalid_value", "Storage values must be JSON-serializable.")

	var candidate: Dictionary = _kv.duplicate(true)
	candidate[key] = normalized

	var kv_bytes := Json.size_bytes(candidate)
	if kv_bytes > KV_QUOTA:
		return Result.error(
			"storage.quota",
			"KV storage would use %d of %d bytes." % [kv_bytes, KV_QUOTA],
			{"used": kv_bytes, "quota": KV_QUOTA},
		)

	var total := kv_bytes + _blob_bytes()
	if total > TOTAL_QUOTA:
		return Result.error(
			"storage.quota",
			"Mod storage would use %d of %d bytes in total." % [total, TOTAL_QUOTA],
			{"used": total, "quota": TOTAL_QUOTA},
		)

	_kv = candidate
	var saved := _write_kv()
	if !saved.get("ok", false):
		return saved
	return Result.ok(normalized)


func delete(key: String) -> Dictionary:
	_ensure_loaded()
	if !is_valid_key(key):
		return Result.error("storage.invalid_key", "'%s' is not a valid storage key." % key)
	_kv.erase(key)
	return _write_kv()


func keys() -> Dictionary:
	_ensure_loaded()
	var out: Array = _kv.keys()
	out.sort()
	return Result.ok(out)


func clear() -> Dictionary:
	_ensure_loaded()
	_kv.clear()
	return _write_kv()


# ── BLOBS ───────────────────────────────────────────────────────────────────

func blob_write(name: String, data: Variant) -> Dictionary:
	_ensure_loaded()
	if !is_valid_blob_name(name):
		return Result.error("storage.invalid_key", "'%s' is not a valid blob name." % name)

	var bytes := PackedByteArray()
	if data is PackedByteArray:
		bytes = data
	elif data is String:
		bytes = (data as String).to_utf8_buffer()
	else:
		return Result.error("storage.invalid_value", "Blobs must be bytes or a string.")

	var size := bytes.size()
	if size > BLOB_LIMIT:
		return Result.error(
			"storage.quota",
			"Blob '%s' is %d bytes; the limit is %d." % [name, size, BLOB_LIMIT],
			{"size": size, "limit": BLOB_LIMIT},
		)

	var previous := int(_blob_sizes.get(name, 0))
	var prospective_blobs := _blob_bytes() - previous + size
	var prospective_total := prospective_blobs + Json.size_bytes(_kv)
	if prospective_total > TOTAL_QUOTA:
		return Result.error(
			"storage.quota",
			"Mod storage would use %d of %d bytes in total." % [prospective_total, TOTAL_QUOTA],
			{"used": prospective_total, "quota": TOTAL_QUOTA},
		)

	if !_blob_sizes.has(name) and _blob_sizes.size() >= MAX_BLOBS:
		return Result.error("storage.quota", "A mod may keep at most %d blobs." % MAX_BLOBS)

	_ensure_dir(blob_dir())
	var written := _write_bytes(blob_dir().path_join(name), bytes)
	if !written.get("ok", false):
		return written

	_blob_sizes[name] = size
	return Result.ok(size)


func blob_read(name: String) -> Dictionary:
	_ensure_loaded()
	if !is_valid_blob_name(name):
		return Result.error("storage.invalid_key", "'%s' is not a valid blob name." % name)

	var path := blob_dir().path_join(name)
	if !FileAccess.file_exists(path):
		return Result.error("module.not_found", "Blob '%s' does not exist." % name)

	var bytes := FileAccess.get_file_as_bytes(path)
	if bytes.size() > BLOB_LIMIT:
		return Result.error("storage.quota", "Blob '%s' is larger than the read limit." % name)
	return Result.ok(bytes)


func blob_delete(name: String) -> Dictionary:
	_ensure_loaded()
	if !is_valid_blob_name(name):
		return Result.error("storage.invalid_key", "'%s' is not a valid blob name." % name)

	var path := blob_dir().path_join(name)
	if FileAccess.file_exists(path):
		var error := DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
		if error != OK:
			return Result.error("storage.quota", "Could not delete blob '%s' (error %d)." % [name, error])

	_blob_sizes.erase(name)
	return Result.ok()


func usage() -> Dictionary:
	_ensure_loaded()
	var kv_bytes := Json.size_bytes(_kv)
	var blobs := _blob_bytes()
	return {
		"kv_bytes": kv_bytes,
		"blob_bytes": blobs,
		"total_bytes": kv_bytes + blobs,
		"kv_quota": KV_QUOTA,
		"blob_limit": BLOB_LIMIT,
		"total_quota": TOTAL_QUOTA,
		"blob_count": _blob_sizes.size(),
	}


func flush() -> Dictionary:
	if !_loaded:
		return Result.ok()
	return _write_kv()


# ── HELPERS ─────────────────────────────────────────────────────────────────

static func is_valid_key(key: String) -> bool:
	if key.is_empty() or key.length() > MAX_KEY_LENGTH:
		return false
	return _match(KEY_PATTERN, key)


static func is_valid_blob_name(name: String) -> bool:
	if name.is_empty() or name.length() > MAX_KEY_LENGTH:
		return false
	if name.contains(".."):
		return false
	return _match(BLOB_PATTERN, name)


func _ensure_loaded() -> void:
	if !_loaded:
		load_state()


func _write_kv() -> Dictionary:
	_ensure_dir(root)
	var saved := Store.save_json(kv_path(), _kv)
	if !saved.get("ok", false):
		last_error = str(saved.get("error", "Could not write kv.json."))
		return Result.error("storage.quota", last_error)
	return Result.ok()


func _write_bytes(path: String, bytes: PackedByteArray) -> Dictionary:
	var global_path := ProjectSettings.globalize_path(path)
	var temp_path := global_path + Store.TMP_SUFFIX

	var file := FileAccess.open(temp_path, FileAccess.WRITE)
	if file == null:
		return Result.error("storage.quota", "Could not open '%s' for writing (error %d)." % [path, FileAccess.get_open_error()])

	file.store_buffer(bytes)
	file.flush()
	var write_error := file.get_error()
	file = null

	if write_error != OK:
		DirAccess.remove_absolute(temp_path)
		return Result.error("storage.quota", "Could not write '%s' (error %d)." % [path, write_error])

	if FileAccess.file_exists(global_path):
		if DirAccess.remove_absolute(global_path) != OK:
			DirAccess.remove_absolute(temp_path)
			return Result.error("storage.quota", "Could not replace '%s'." % path)

	var rename_error := DirAccess.rename_absolute(temp_path, global_path)
	if rename_error != OK:
		DirAccess.remove_absolute(temp_path)
		return Result.error("storage.quota", "Could not finalize '%s' (error %d)." % [path, rename_error])

	return Result.ok()


func _scan_blobs() -> void:
	_blob_sizes.clear()
	var dir := DirAccess.open(blob_dir())
	if dir == null:
		return
	for name in dir.get_files():
		if str(name).ends_with(Store.TMP_SUFFIX):
			continue
		var bytes := FileAccess.get_file_as_bytes(blob_dir().path_join(str(name)))
		_blob_sizes[str(name)] = bytes.size()


func _blob_bytes() -> int:
	var total := 0
	for size in _blob_sizes.values():
		total += int(size)
	return total


func _ensure_dir(directory: String) -> void:
	var global := ProjectSettings.globalize_path(directory)
	if !DirAccess.dir_exists_absolute(global):
		DirAccess.make_dir_recursive_absolute(global)


func _read_json_object(path: String) -> Dictionary:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {"ok": false, "data": {}, "error": "Could not open '%s'." % path}
	var text := file.get_as_text()
	file.close()

	if text.strip_edges().is_empty():
		return {"ok": false, "data": {}, "error": "'%s' is empty." % path}

	var json := JSON.new()
	if json.parse(text) != OK:
		return {"ok": false, "data": {}, "error": "'%s' is not valid JSON." % path}
	if !(json.data is Dictionary):
		return {"ok": false, "data": {}, "error": "'%s' is not a JSON object." % path}

	var data: Dictionary = {}
	for key in (json.data as Dictionary).keys():
		var value: Variant = (json.data as Dictionary)[key]
		if !Json.is_value(value):
			continue
		data[str(key)] = Json.normalize(value)

	return {"ok": true, "data": data, "error": ""}


func _backup_corrupt(path: String) -> void:
	var text := FileAccess.get_file_as_string(path)
	if text.is_empty():
		return
	Store.save(path + ".corrupt", text)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


static func _match(pattern: String, value: String) -> bool:
	var regex := RegEx.new()
	if regex.compile(pattern) != OK:
		return false
	return regex.search(value) != null
