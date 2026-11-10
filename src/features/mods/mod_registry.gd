extends RefCounted

## Installed-mod ledger: user://mod_registry.json.
##
## The registry is a cache of what is on disk, not the source of truth: a folder
## under user://mods is still discovered if the registry is missing or corrupt.
## Entries store the enabled flag, the package hash, the manifest mtime and the
## previous version, so an update can be rolled back without touching mod data.

const Result = preload("res://src/features/mods/mod_result.gd")
const Store = preload("res://src/base/file_store.gd")
const Manifest = preload("res://src/features/mods/mod_manifest.gd")

const VERSION := 1
const DEFAULT_PATH := "user://mod_registry.json"

var path: String = DEFAULT_PATH
var last_error: String = ""

var _mods: Dictionary = {}


func _init(registry_path: String = DEFAULT_PATH) -> void:
	path = registry_path


func load_registry() -> Dictionary:
	_mods.clear()
	last_error = ""

	if path.is_empty() or !FileAccess.file_exists(path):
		return Result.ok()

	var loaded := Store.load_json(path)
	if !loaded.get("ok", false):
		last_error = str(loaded.get("error", "Could not read mod_registry.json."))
		_backup_corrupt()
		return Result.error("registry.invalid", last_error)

	var data: Variant = loaded.get("data", {})
	var raw: Variant = data.get("mods", {}) if data is Dictionary else {}
	if !(raw is Dictionary):
		last_error = "mod_registry.json has no mods object."
		_backup_corrupt()
		return Result.error("registry.invalid", last_error)

	for key in (raw as Dictionary).keys():
		var entry: Variant = raw[key]
		if !(entry is Dictionary):
			continue
		_mods[str(key)] = _normalize_entry(str(key), entry)

	return Result.ok()


func save() -> Dictionary:
	var payload: Dictionary = {}
	for id in _mods.keys():
		payload[id] = _mods[id].duplicate(true)

	var saved := Store.save_json(path, {"version": VERSION, "mods": payload})
	last_error = str(saved.get("error", ""))
	return saved


func has(id: String) -> bool:
	return _mods.has(str(id))


func entry(id: String) -> Dictionary:
	var found: Variant = _mods.get(str(id))
	return (found as Dictionary).duplicate(true) if found is Dictionary else {}


func all() -> Array:
	var ids: Array = _mods.keys()
	ids.sort()
	var out: Array = []
	for id in ids:
		out.append((_mods[id] as Dictionary).duplicate(true))
	return out


func record(id: String, data: Dictionary) -> Dictionary:
	if !Manifest.is_valid_id(str(id)):
		return Result.error("registry.invalid", "'%s' is not a valid mod id." % str(id))

	var merged: Dictionary = entry(id)
	for key in data.keys():
		merged[str(key)] = data[key]
	merged["id"] = str(id)

	_mods[str(id)] = _normalize_entry(str(id), merged)
	var saved := save()
	if !saved.get("ok", false):
		return Result.error("registry.invalid", "Could not save mod_registry.json: " + str(saved.get("error", "")))

	return Result.ok(_mods[str(id)].duplicate(true))


func set_enabled(id: String, enabled: bool, reason: String = "") -> Dictionary:
	if !_mods.has(str(id)):
		return Result.error("registry.invalid", "'%s' is not recorded." % str(id))

	_mods[str(id)]["enabled"] = enabled
	_mods[str(id)]["disabled_reason"] = "" if enabled else reason
	return save()


func is_enabled(id: String) -> bool:
	if !_mods.has(str(id)):
		return true
	return bool((_mods[str(id)] as Dictionary).get("enabled", true))


func forget(id: String) -> Dictionary:
	_mods.erase(str(id))
	return save()


func _normalize_entry(id: String, entry: Dictionary) -> Dictionary:
	var previous: Variant = entry.get("previous", {})
	var signature: Variant = entry.get("signature", {})
	return {
		"id": id,
		"version": str(entry.get("version", "")),
		"hash": str(entry.get("hash", "")),
		"path": str(entry.get("path", "")),
		"manifest_mtime": int(entry.get("manifest_mtime", 0)),
		"package_mtime": int(entry.get("package_mtime", 0)),
		"enabled": bool(entry.get("enabled", true)),
		"disabled_reason": str(entry.get("disabled_reason", "")),
		"previous_version": str(entry.get("previous_version", "")),
		"previous": _normalize_previous(previous) if previous is Dictionary else {},
		"signature": _normalize_signature(signature) if signature is Dictionary else _normalize_signature({}),
		"allow_unsigned": bool(entry.get("allow_unsigned", false)),
		"installed_at": int(entry.get("installed_at", 0)),
		"updated_at": int(entry.get("updated_at", 0)),
	}


static func _normalize_previous(value: Variant) -> Dictionary:
	if !(value is Dictionary):
		return {}
	var source: Dictionary = value
	if str(source.get("version", "")).is_empty():
		return {}
	var signature: Variant = source.get("signature", {})
	return {
		"version": str(source.get("version", "")),
		"hash": str(source.get("hash", "")),
		"path": str(source.get("path", "")),
		"manifest_mtime": int(source.get("manifest_mtime", 0)),
		"package_mtime": int(source.get("package_mtime", 0)),
		"signature": _normalize_signature(signature) if signature is Dictionary else _normalize_signature({}),
		"allow_unsigned": bool(source.get("allow_unsigned", false)),
	}


static func _normalize_signature(value: Variant) -> Dictionary:
	if !(value is Dictionary):
		return {}
	var source: Dictionary = value
	return {
		"present": bool(source.get("present", false)),
		"ok": bool(source.get("ok", false)),
		"status": str(source.get("status", "unsigned")),
		"publisher_id": str(source.get("publisher_id", "")),
		"fingerprint": str(source.get("fingerprint", "")),
		"public_key": str(source.get("public_key", "")),
		"display_name": str(source.get("display_name", "")),
		"signed_at": int(source.get("signed_at", 0)),
		"error": str(source.get("error", "")),
	}


func _backup_corrupt() -> void:
	if path.is_empty() or !FileAccess.file_exists(path):
		return
	var text := FileAccess.get_file_as_string(path)
	if text.is_empty():
		return
	Store.save(path + ".corrupt", text)
