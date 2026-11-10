extends RefCounted

## Permission catalogue and consent records.
##
## Two layers, on purpose:
##   * The manifest declares capabilities. Validation rejects names that are not
##     in the catalogue and names that are reserved for a later phase.
##   * Consent records prove the user agreed to the sensitive ones. Core is
##     granted on install; everything else needs an explicit record.
##
## Native checks stay authoritative. `editor.permissions.has()` is display only:
## it lets a mod choose a fallback path, never unlock one.

const Result = preload("res://src/features/mods/mod_result.gd")
const Store = preload("res://src/base/file_store.gd")

const CORE := "core"
const VERSION := 1
const DEFAULT_PATH := "user://mod_permissions.json"

## permission -> {risk, consent, grants, available}
const CATALOGUE := {
	"core": {
		"risk": "low", "consent": "install", "available": true,
		"grants": "events, commands, partial UI, notifications, storage, progress, assets, timers",
	},
	"documents.read": {
		"risk": "medium", "consent": "explicit", "available": true,
		"grants": "text, cursor, selection",
	},
	"documents.write": {
		"risk": "medium", "consent": "explicit", "available": true,
		"grants": "edits, open, save",
	},
	"files.read": {
		"risk": "high", "consent": "explicit+trust", "available": true,
		"grants": "workspace files",
	},
	"files.write": {
		"risk": "high", "consent": "explicit+trust", "available": true,
		"grants": "workspace files",
	},
	"workspace.read": {
		"risk": "medium", "consent": "explicit", "available": true,
		"grants": "listing, root",
	},
	"run": {
		"risk": "critical", "consent": "explicit+trust", "available": true,
		"grants": "execute through RunService",
	},
	"terminal.read": {
		"risk": "high", "consent": "explicit", "available": true,
		"grants": "observe output",
	},
	"terminal.write": {
		"risk": "critical", "consent": "explicit+trust", "available": true,
		"grants": "inject input",
	},
	"ui.shell": {
		"risk": "high", "consent": "explicit", "available": true,
		"grants": "exclusive takeover, host chrome remains",
	},
	"ui.layout": {
		"risk": "low", "consent": "explicit", "available": true,
		"grants": "hide/show core panels",
	},
	"clipboard.write": {
		"risk": "low", "consent": "explicit", "available": true,
		"grants": "clipboard writes",
	},
	"clipboard.read": {
		"risk": "high", "consent": "explicit", "available": true,
		"grants": "clipboard reads",
	},
	"settings.read": {
		"risk": "low", "consent": "explicit", "available": true,
		"grants": "read global settings",
	},
	"input.observe": {
		"risk": "critical", "consent": "not_in_v1", "available": false,
		"grants": "raw keystrokes",
	},
	"network": {
		"risk": "critical", "consent": "not_in_v1", "available": false,
		"grants": "network access",
	},
}

## Permissions whose use is additionally gated by workspace trust.
const TRUST_REQUIRED := ["files.read", "files.write", "run", "terminal.write"]

var path: String = DEFAULT_PATH
var last_error: String = ""

## id -> {version, hash, permissions, granted_at}
var _records: Dictionary = {}

## id -> Array, the permission set activation validated this session.
var _active: Dictionary = {}


func _init(store_path: String = DEFAULT_PATH) -> void:
	path = store_path


static func available_names() -> Array:
	var out: Array = []
	for name in CATALOGUE.keys():
		if bool(CATALOGUE[name].get("available", true)):
			out.append(name)
	out.sort()
	return out


static func risk_of(permission: String) -> String:
	return str(CATALOGUE.get(permission, {}).get("risk", "unknown"))


static func requires_trust(permission: String) -> bool:
	return TRUST_REQUIRED.has(permission)


## Permissions that need an explicit consent record.
static func sensitive(permissions: Array) -> Array:
	var out: Array = []
	for permission in permissions:
		var name := str(permission)
		if name == CORE:
			continue
		if !CATALOGUE.has(name):
			continue
		if str(CATALOGUE[name].get("consent", "explicit")) == "install":
			continue
		out.append(name)
	return out


## Validates a declared permission list. Returns the cleaned list and every
## problem, so a manifest error names the exact permission.
func validate(permissions: Array) -> Dictionary:
	var cleaned: Array = []
	var errors: Array = []

	for item in permissions:
		var permission := str(item)
		if !CATALOGUE.has(permission):
			errors.append({
				"code": "permission.unknown",
				"message": "'%s' is not a permission." % permission,
				"permission": permission,
			})
			continue
		if !bool(CATALOGUE[permission].get("available", true)):
			errors.append({
				"code": "manifest.unknown_permission",
				"message": "'%s' is not available in this version." % permission,
				"permission": permission,
			})
			continue
		if !cleaned.has(permission):
			cleaned.append(permission)

	if !cleaned.has(CORE):
		cleaned.insert(0, CORE)

	return {"ok": errors.is_empty(), "permissions": cleaned, "errors": errors}


# ── PERSISTENCE ─────────────────────────────────────────────────────────────

func load_records() -> Dictionary:
	_records.clear()
	last_error = ""

	if path.is_empty() or !FileAccess.file_exists(path):
		return Result.ok()

	var loaded := Store.load_json(path)
	if !loaded.get("ok", false):
		last_error = str(loaded.get("error", "Could not read mod_permissions.json."))
		return Result.error("registry.invalid", last_error)

	var data: Variant = loaded.get("data", {})
	var raw: Variant = data.get("records", {}) if data is Dictionary else {}
	if !(raw is Dictionary):
		last_error = "mod_permissions.json has no records object."
		return Result.error("registry.invalid", last_error)

	for key in (raw as Dictionary).keys():
		var record: Variant = raw[key]
		if !(record is Dictionary):
			continue
		var permissions: Array = []
		var raw_permissions: Variant = record.get("permissions", [])
		if raw_permissions is Array:
			for permission in raw_permissions:
				permissions.append(str(permission))
		_records[str(key)] = {
			"version": str(record.get("version", "")),
			"hash": str(record.get("hash", "")),
			"permissions": permissions,
			"granted_at": int(record.get("granted_at", 0)),
		}

	return Result.ok()


func save() -> Dictionary:
	var records: Dictionary = {}
	for id in _records.keys():
		records[id] = _records[id].duplicate(true)

	var saved := Store.save_json(path, {"version": VERSION, "records": records})
	last_error = str(saved.get("error", ""))
	return saved


func record(id: String) -> Dictionary:
	var found: Variant = _records.get(str(id))
	return (found as Dictionary).duplicate(true) if found is Dictionary else {}


func all_records() -> Dictionary:
	return _records.duplicate(true)


# ── CONSENT ─────────────────────────────────────────────────────────────────

## Decides whether an activation may proceed.
## Returns {granted, missing: Array, reason, refresh: bool}.
##
## Sensitive permissions that were already recorded stay consented across a
## version update; only a permission that is new to the record needs the user
## again. `refresh` asks the caller to update the stored version/hash so the next
## launch sees the current identity.
func consent_status(id: String, version: String, hash: String, permissions: Array) -> Dictionary:
	var required := sensitive(permissions)
	if required.is_empty():
		return {"granted": true, "missing": [], "reason": "", "refresh": false}

	var stored := record(id)
	if stored.is_empty():
		return {"granted": false, "missing": required, "reason": "no_record", "refresh": false}

	var recorded: Array = stored.get("permissions", [])
	var missing: Array = []
	for permission in required:
		if !recorded.has(permission):
			missing.append(permission)

	if !missing.is_empty():
		return {"granted": false, "missing": missing, "reason": "permission_growth", "refresh": false}

	var stale := str(stored.get("version", "")) != version or str(stored.get("hash", "")) != hash
	return {"granted": true, "missing": [], "reason": "", "refresh": stale}


func grant(id: String, version: String, hash: String, permissions: Array) -> Dictionary:
	var validated := validate(permissions)
	if !validated.get("ok", false):
		return Result.error("permission.unknown", "The permission list contains an unknown name.", {"errors": validated["errors"]})

	_records[str(id)] = {
		"version": str(version),
		"hash": str(hash),
		"permissions": validated["permissions"],
		"granted_at": int(Time.get_unix_time_from_system()),
	}

	var saved := save()
	if !saved.get("ok", false):
		_records.erase(str(id))
		return Result.error("registry.invalid", "Could not save the consent record: " + str(saved.get("error", "")))

	return Result.ok(validated["permissions"])


func revoke(id: String) -> Dictionary:
	if !_records.has(str(id)):
		return Result.ok()
	_records.erase(str(id))
	return save()


# ── RUNTIME ─────────────────────────────────────────────────────────────────

## Marks the validated set for this session. Called by ModManager on activation.
func set_active(id: String, permissions: Array) -> void:
	_active[str(id)] = permissions.duplicate()


func clear_active(id: String) -> void:
	_active.erase(str(id))


func active_permissions(id: String) -> Array:
	# Consent records are not a grant: only a mod that is active this session has
	# its permissions in the runtime set. The record answers "may this version
	# activate", never "may this call run".
	var found: Variant = _active.get(str(id))
	return (found as Array).duplicate() if found is Array else []


func has(id: String, permission: String) -> bool:
	if permission == CORE:
		return true
	return active_permissions(id).has(permission)
