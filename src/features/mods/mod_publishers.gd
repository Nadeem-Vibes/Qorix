extends RefCounted

## Publisher trust store: user://mod_publishers.json.
##
## A signature proves that the package was signed by a key, not that the user
## trusts that key. The first signed package from a publisher is therefore
## "new" and needs explicit trust; the fingerprint is pinned when trust is
## granted. Later packages must use the same key:
##
##   new          first package from this publisher id -> ask the user
##   trusted      same publisher id and same public key
##   key_changed  same publisher id, different public key -> ask again
##   unsigned     no signature.json in the package
##   invalid      the signature did not verify before this store was consulted
##
## The store never accepts a key on its own: trust() is only called by the
## import review UI after the user has seen the publisher id and fingerprint.

const Result = preload("res://src/features/mods/mod_result.gd")
const Store = preload("res://src/base/file_store.gd")
const Package = preload("res://src/features/mods/mod_package.gd")

const VERSION := 1
const DEFAULT_PATH := "user://mod_publishers.json"

var path: String = DEFAULT_PATH
var last_error: String = ""

var _publishers: Dictionary = {}


func _init(store_path: String = DEFAULT_PATH) -> void:
	path = store_path


func load_store() -> Dictionary:
	_publishers.clear()
	last_error = ""

	if path.is_empty() or !FileAccess.file_exists(path):
		return Result.ok()

	var loaded := Store.load_json(path)
	if !loaded.get("ok", false):
		last_error = str(loaded.get("error", "Could not read mod_publishers.json."))
		_backup_corrupt()
		return Result.error("publisher.store_invalid", last_error)

	var data: Variant = loaded.get("data", {})
	var raw: Variant = (data as Dictionary).get("publishers", {}) if data is Dictionary else {}
	if !(raw is Dictionary):
		last_error = "mod_publishers.json has no publishers object."
		_backup_corrupt()
		return Result.error("publisher.store_invalid", last_error)

	for key in (raw as Dictionary).keys():
		var entry: Variant = raw[key]
		if !(entry is Dictionary):
			continue
		var normalized := _normalize_entry(str(key), entry)
		if str(normalized.get("fingerprint", "")).length() != 64:
			continue
		_publishers[str(key)] = normalized

	return Result.ok()


func save() -> Dictionary:
	var payload: Dictionary = {}
	for id in _publishers.keys():
		payload[id] = (_publishers[id] as Dictionary).duplicate(true)

	var saved := Store.save_json(path, {"version": VERSION, "publishers": payload})
	last_error = str(saved.get("error", ""))
	return saved


func get_publisher(publisher_id: String) -> Dictionary:
	var found: Variant = _publishers.get(str(publisher_id))
	return (found as Dictionary).duplicate(true) if found is Dictionary else {}


func publishers() -> Array:
	var ids: Array = _publishers.keys()
	ids.sort()
	var out: Array = []
	for id in ids:
		out.append((_publishers[id] as Dictionary).duplicate(true))
	return out


## Classifies a validated signature block from ModPackage.
## Returns {status, trusted, requires_trust, publisher_id, fingerprint,
##          public_key, display_name, stored_fingerprint, reason}.
func state(signature: Dictionary) -> Dictionary:
	var out := {
		"status": "unsigned",
		"trusted": false,
		"requires_trust": false,
		"publisher_id": "",
		"fingerprint": "",
		"public_key": "",
		"display_name": "",
		"stored_fingerprint": "",
		"reason": "",
	}

	if signature.is_empty() or !bool(signature.get("present", false)):
		return out

	var publisher_id := str(signature.get("publisher_id", ""))
	var fingerprint := str(signature.get("fingerprint", "")).to_lower()
	var public_key := str(signature.get("public_key", "")).to_lower()
	out["publisher_id"] = publisher_id
	out["fingerprint"] = fingerprint
	out["public_key"] = public_key
	out["display_name"] = str(signature.get("display_name", ""))

	if !bool(signature.get("ok", false)):
		out["status"] = "invalid"
		out["reason"] = str(signature.get("error", "The package signature is invalid."))
		return out

	if !Package.is_valid_publisher_id(publisher_id) or fingerprint.length() != 64:
		out["status"] = "invalid"
		out["reason"] = "The signature does not name a valid publisher."
		return out

	var stored: Variant = _publishers.get(publisher_id)
	if stored == null:
		out["status"] = "new"
		out["requires_trust"] = true
		out["reason"] = "This is the first package from '%s'." % publisher_id
		return out

	var stored_fingerprint := str((stored as Dictionary).get("fingerprint", "")).to_lower()
	out["stored_fingerprint"] = stored_fingerprint
	if stored_fingerprint != fingerprint:
		out["status"] = "key_changed"
		out["requires_trust"] = true
		out["reason"] = "The signing key for '%s' changed." % publisher_id
		return out

	out["status"] = "trusted"
	out["trusted"] = true
	return out


func is_trusted(signature: Dictionary) -> bool:
	return bool(state(signature).get("trusted", false))


## Pins a publisher key after the user has approved it. Replaces an existing key
## only when `replace_key` is true; callers get the key_changed state first.
func trust(signature: Dictionary, options: Dictionary = {}) -> Dictionary:
	if signature.is_empty() or !bool(signature.get("present", false)) or !bool(signature.get("ok", false)):
		return Result.error("publisher.invalid", "Only a verified signature can be trusted.")

	var publisher_id := str(signature.get("publisher_id", ""))
	var fingerprint := str(signature.get("fingerprint", "")).to_lower()
	var public_key := str(signature.get("public_key", "")).to_lower()
	if !Package.is_valid_publisher_id(publisher_id):
		return Result.error("publisher.invalid", "'%s' is not a valid publisher id." % publisher_id)
	if fingerprint.length() != 64 or public_key.length() != 64:
		return Result.error("publisher.invalid", "The signature is missing its key fingerprint.")

	var existing: Variant = _publishers.get(publisher_id)
	if existing is Dictionary:
		var existing_fingerprint := str((existing as Dictionary).get("fingerprint", "")).to_lower()
		if existing_fingerprint != fingerprint and !bool(options.get("replace_key", false)):
			return Result.error(
				"publisher.key_changed",
				"The publisher '%s' already uses a different key." % publisher_id,
				{"publisher_id": publisher_id, "fingerprint": fingerprint, "stored_fingerprint": existing_fingerprint},
			)

	var now := int(Time.get_unix_time_from_system())
	var entry := {
		"id": publisher_id,
		"public_key": public_key,
		"fingerprint": fingerprint,
		"display_name": str(signature.get("display_name", "")).strip_edges(),
		"trusted_at": now,
		"last_seen_at": now,
		"previous_fingerprint": "",
	}
	if existing is Dictionary:
		var old := existing as Dictionary
		entry["trusted_at"] = int(old.get("trusted_at", now))
		if str(old.get("fingerprint", "")).to_lower() == fingerprint:
			entry["display_name"] = str(old.get("display_name", entry["display_name"]))
		else:
			entry["key_changed_at"] = now
			entry["previous_fingerprint"] = str(old.get("fingerprint", "")).to_lower()
	if str(entry["display_name"]).is_empty():
		entry["display_name"] = publisher_id

	_publishers[publisher_id] = entry
	var saved := save()
	if !saved.get("ok", false):
		_publishers.erase(publisher_id)
		return Result.error("publisher.store_invalid", "Could not save mod_publishers.json: " + str(saved.get("error", "")))

	return Result.ok(entry.duplicate(true))


## Updates last_seen_at for a trusted publisher. Best-effort: a failed write is
## reported but never blocks an install.
func note_seen(publisher_id: String) -> Dictionary:
	if !_publishers.has(publisher_id):
		return Result.ok()
	(_publishers[publisher_id] as Dictionary)["last_seen_at"] = int(Time.get_unix_time_from_system())
	return save()


func forget(publisher_id: String) -> Dictionary:
	if !_publishers.has(publisher_id):
		return Result.ok()
	_publishers.erase(publisher_id)
	return save()


## Short fingerprint for the UI: the first `length` hex characters, grouped.
static func short_fingerprint(fingerprint: String, length: int = 16) -> String:
	var clean := fingerprint.to_lower()
	if clean.length() <= length:
		return clean
	var head := clean.substr(0, length)
	var chunks: Array = []
	for index in range(0, head.length(), 4):
		chunks.append(head.substr(index, 4))
	return " ".join(chunks)


func _normalize_entry(id: String, entry: Dictionary) -> Dictionary:
	return {
		"id": id,
		"public_key": str(entry.get("public_key", "")).to_lower(),
		"fingerprint": str(entry.get("fingerprint", "")).to_lower(),
		"display_name": str(entry.get("display_name", id)),
		"trusted_at": int(entry.get("trusted_at", 0)),
		"last_seen_at": int(entry.get("last_seen_at", 0)),
		"key_changed_at": int(entry.get("key_changed_at", 0)),
		"previous_fingerprint": str(entry.get("previous_fingerprint", "")).to_lower(),
	}


func _backup_corrupt() -> void:
	if path.is_empty() or !FileAccess.file_exists(path):
		return
	var text := FileAccess.get_file_as_string(path)
	if text.is_empty():
		return
	Store.save(path + ".corrupt", text)
