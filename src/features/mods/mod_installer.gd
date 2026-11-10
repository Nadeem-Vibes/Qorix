extends RefCounted

## Phase 6 import lifecycle. The installer is deliberately separate from
## ModManager: it owns package review, staging, version folders, the registry
## record and data retention, while the manager owns activation and consent
## prompts. Every install follows the same order:
##
##   validate archive -> check signature + publisher -> check version policy
##   -> extract to staging -> validate extracted folder -> digest equality
##   -> move into user://mods/<id>/<version> -> update the registry
##
## A package is never extracted before validation and signature verification
## succeed. Updates keep the previous version folder on disk so rollback only
## changes the active record.

const Package = preload("res://src/features/mods/mod_package.gd")
const Publishers = preload("res://src/features/mods/mod_publishers.gd")
const Permissions = preload("res://src/features/mods/mod_permissions.gd")
const Manifest = preload("res://src/features/mods/mod_manifest.gd")
const Result = preload("res://src/features/mods/mod_result.gd")
const Version = preload("res://src/base/version_utils.gd")
const Paths = preload("res://src/base/path_utils.gd")

var mods_root: String = "user://mods"
var staging_root: String = "user://mod_staging"
var data_root: String = "user://mod_data"
var allow_unsigned_default: bool = false

var registry = null
var permissions = null
var publishers = null


func _init() -> void:
	publishers = Publishers.new()


func setup(context: Dictionary = {}) -> Dictionary:
	if context.has("mods_root"):
		mods_root = str(context["mods_root"])
	if context.has("staging_root"):
		staging_root = str(context["staging_root"])
	if context.has("data_root"):
		data_root = str(context["data_root"])
	if context.has("allow_unsigned"):
		allow_unsigned_default = bool(context["allow_unsigned"])
	if context.has("registry"):
		registry = context["registry"]
	if context.has("permissions"):
		permissions = context["permissions"]
	if context.has("publishers"):
		publishers = context["publishers"]
	if context.has("publishers_path") and publishers != null:
		publishers.path = str(context["publishers_path"])
	if publishers != null:
		publishers.load_store()
	return Result.ok()


# ── REVIEW ──────────────────────────────────────────────────────────────────

## Validates a package and returns everything the import UI needs. This method
## mutates nothing; install() repeats the validation before touching disk.
func inspect(package_path: String, options: Dictionary = {}) -> Dictionary:
	var validation := Package.validate_archive(package_path)
	if !bool(validation.get("ok", false)):
		var errors: Array = validation.get("errors", [])
		var message := "The package failed validation."
		if !errors.is_empty():
			message = str((errors[0] as Dictionary).get("message", message))
		return Result.error("package.invalid", message, {"errors": errors})

	var manifest: Dictionary = validation.get("manifest", {})
	var signature: Dictionary = validation.get("signature", {})
	var publisher := _publisher_state(signature)
	var id := str(manifest.get("id", ""))
	var version := str(manifest.get("version", ""))
	var hash := str(validation.get("digest", ""))

	var declared: Array = manifest.get("permissions", [])
	var record := _consent_record(id)
	var consented: Array = record.get("permissions", []) if !record.is_empty() else []
	var sensitive := Permissions.sensitive(declared)
	var added: Array = []
	var removed: Array = []
	for permission in sensitive:
		if !consented.has(str(permission)):
			added.append(str(permission))
	for permission in consented:
		if !declared.has(str(permission)):
			removed.append(str(permission))
	var growth := {
		"first_consent": record.is_empty(),
		"growing": !record.is_empty() and !added.is_empty(),
		"requires_consent": !added.is_empty(),
		"added": added,
		"removed": removed,
		"declared": declared.duplicate(),
		"sensitive": sensitive.duplicate(),
		"consented": consented.duplicate(),
		"details": _permission_details(added),
	}

	var current := _registry_entry(id)
	var update := _update_info(current, id, version, hash)
	var review := {
		"id": id,
		"name": str(manifest.get("name", id)),
		"version": version,
		"author": str(manifest.get("author", "")),
		"description": str(manifest.get("description", "")),
		"entry": str(manifest.get("entry", "")),
		"manifest": manifest,
		"entries": validation.get("entries", []),
		"counts": validation.get("counts", {}),
		"sizes": validation.get("sizes", {}),
		"hash": hash,
		"signature": _signature_summary(signature),
		"publisher": publisher,
		"unsigned": !bool(signature.get("present", false)),
		"allow_unsigned": bool(options.get("allow_unsigned", allow_unsigned_default)),
		"trust_publisher": bool(options.get("trust_publisher", false)),
		"permission_growth": growth,
		"update": update,
		"blockers": [],
		"warnings": [],
		"can_install": false,
		"can_activate": false,
	}

	_apply_policy(review, options)
	return Result.ok(review)


## Full review plus the parsed manifest; used by ModManager.
func _apply_policy(review: Dictionary, options: Dictionary) -> void:
	var blockers: Array = review["blockers"]
	var warnings: Array = review["warnings"]
	var signature: Dictionary = review["signature"]
	var publisher: Dictionary = review["publisher"]
	var update: Dictionary = review["update"]
	var growth: Dictionary = review["permission_growth"]

	if bool(review["unsigned"]):
		if !bool(review["allow_unsigned"]):
			_block(blockers, "signature.required", "This package is unsigned. Unsigned packages need an explicit opt-in.")
		else:
			_add(warnings, "signature.unsigned", "This package is unsigned; its origin cannot be verified.")
	elif !bool(signature.get("ok", false)):
		_block(blockers, "signature.invalid", str(signature.get("error", "The package signature is invalid.")))
	elif bool(publisher.get("requires_trust", false)) and !bool(review["trust_publisher"]):
		var code := "publisher.key_changed" if str(publisher.get("status", "")) == "key_changed" else "publisher.trust_required"
		_block(
			blockers,
			code,
			"Publisher '%s' %s" % [
				str(publisher.get("publisher_id", "")),
				"changed its signing key; review and re-trust it." if code == "publisher.key_changed" else "has not been trusted yet.",
			],
		)

	var kind := str(update.get("kind", "install"))
	if kind == "downgrade" and !bool(options.get("allow_downgrade", false)):
		_block(blockers, "update.downgrade", "This package is older than the installed version. Enable downgrades to install it.")
	if (kind == "reinstall" or kind == "replace" or bool(update.get("target_exists", false))) and !bool(options.get("replace", false)):
		_block(blockers, "update.exists", "This version is already on disk. Choose replace to reinstall it.")

	if bool(growth.get("requires_consent", false)):
		var names: Array = growth.get("added", [])
		if bool(growth.get("first_consent", false)):
			_add(warnings, "consent.required", "This mod needs consent for: " + ", ".join(names))
		else:
			_add(warnings, "permission.growth", "This update adds permissions: " + ", ".join(names))

	review["can_install"] = blockers.is_empty()
	review["can_activate"] = blockers.is_empty() and (
		!bool(growth.get("requires_consent", false)) or bool(options.get("consent", false))
	)


func _publisher_state(signature: Dictionary) -> Dictionary:
	if publishers == null:
		return Publishers.new().state(signature)
	return publishers.state(signature)


func _consent_record(id: String) -> Dictionary:
	if permissions == null or id.is_empty():
		return {}
	return permissions.record(id)


func _registry_entry(id: String) -> Dictionary:
	if registry == null or id.is_empty():
		return {}
	return registry.entry(id)


func _update_info(current: Dictionary, id: String, version: String, hash: String) -> Dictionary:
	var target := mods_root.path_join(id).path_join(version)
	var current_version := str(current.get("version", ""))
	var kind := "install"
	if !current_version.is_empty():
		var comparison := Version.compare_versions(version, current_version)
		if comparison == 0:
			kind = "reinstall" if str(current.get("hash", "")) == hash else "replace"
		elif comparison > 0:
			kind = "update"
		else:
			kind = "downgrade"

	var previous: Dictionary = current.get("previous", {}) if current.get("previous") is Dictionary else {}
	return {
		"kind": kind,
		"current_version": current_version,
		"current_hash": str(current.get("hash", "")),
		"incoming_version": version,
		"incoming_hash": hash,
		"previous_version": str(previous.get("version", current.get("previous_version", ""))),
		"target_path": target,
		"target_exists": DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(target)),
		"can_rollback": !previous.is_empty() or !str(current.get("previous_version", "")).is_empty(),
	}


func _permission_details(names: Array) -> Array:
	var out: Array = []
	for item in names:
		var name := str(item)
		var info: Dictionary = Permissions.CATALOGUE.get(name, {})
		out.append({
			"name": name,
			"risk": str(info.get("risk", "unknown")),
			"consent": str(info.get("consent", "explicit")),
			"grants": str(info.get("grants", "")),
		})
	return out


func _signature_summary(signature: Dictionary) -> Dictionary:
	return {
		"present": bool(signature.get("present", false)),
		"ok": bool(signature.get("ok", false)),
		"status": str(signature.get("status", "unsigned")),
		"publisher_id": str(signature.get("publisher_id", "")),
		"fingerprint": str(signature.get("fingerprint", "")),
		"public_key": str(signature.get("public_key", "")),
		"display_name": str(signature.get("display_name", "")),
		"signed_at": int(signature.get("signed_at", 0)),
		"error": str(signature.get("error", "")),
	}


# ── INSTALL ─────────────────────────────────────────────────────────────────

## Installs a validated package. `options` mirrors inspect() (allow_unsigned,
## trust_publisher, replace_key, replace, allow_downgrade, consent). Returns
## {id, version, path, hash, previous_version, review, installed_at}.
func install(package_path: String, options: Dictionary = {}) -> Dictionary:
	var inspected := inspect(package_path, options)
	if !inspected.get("ok", false):
		return inspected

	var review: Dictionary = inspected["value"]
	if !bool(review.get("can_install", false)):
		var blocker: Dictionary = (review["blockers"] as Array)[0] if !(review["blockers"] as Array).is_empty() else {}
		return Result.error(
			str(blocker.get("code", "package.invalid")),
			str(blocker.get("message", "This package cannot be installed.")),
			{"blockers": review["blockers"], "review": review},
		)

	var signature: Dictionary = review["signature"]
	if bool((review["publisher"] as Dictionary).get("requires_trust", false)):
		var trusted: Dictionary = publishers.trust(signature, {"replace_key": bool(options.get("replace_key", false))})
		if !trusted.get("ok", false):
			return trusted

	var validation := Package.validate_archive(package_path)
	if !bool(validation.get("ok", false)):
		return Result.error("package.invalid", "The package changed while it was being reviewed.", {
			"errors": validation.get("errors", []),
		})

	var id := str(review["id"])
	var version := str(review["version"])
	var target := mods_root.path_join(id).path_join(version)
	if !Paths.is_subpath(mods_root, target) or target == mods_root:
		return Result.error("package.invalid", "The manifest id or version resolves outside the mods folder.")

	var staging := _new_staging_path(id, version)
	var extracted := Package.extract(package_path, validation.get("entries", []), staging)
	if !extracted.get("ok", false):
		_remove_tree(staging)
		return extracted

	var folder := Package.validate_folder(staging)
	if !bool(folder.get("ok", false)):
		_remove_tree(staging)
		return Result.error(
			"package.invalid",
			"The extracted package failed validation.",
			{"errors": folder.get("errors", [])},
		)
	if str(folder.get("digest", "")) != str(review["hash"]):
		_remove_tree(staging)
		return Result.error("install.digest_mismatch", "The extracted files do not match the signed package digest.")

	var backup := ""
	if DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(target)):
		backup = _new_backup_path(id, version)
		var moved_aside := _move_folder(target, backup)
		if !moved_aside.get("ok", false):
			_remove_tree(staging)
			return moved_aside

	var placed := _move_folder(staging, target)
	if !placed.get("ok", false):
		if !backup.is_empty():
			_move_folder(backup, target)
		_remove_tree(staging)
		return placed

	if !backup.is_empty():
		_remove_tree(backup)

	var current := _registry_entry(id)
	var previous: Dictionary = current.get("previous", {}) if current.get("previous") is Dictionary else {}
	if !current.is_empty() and str(current.get("version", "")) != version:
		previous = _snapshot(current)

	var now := int(Time.get_unix_time_from_system())
	var record := {
		"version": version,
		"hash": str(review["hash"]),
		"path": target,
		"manifest_mtime": int(FileAccess.get_modified_time(target.path_join("manifest.json"))),
		"package_mtime": int(folder.get("mtime", 0)),
		"enabled": bool(current.get("enabled", true)),
		"previous": previous,
		"previous_version": str(previous.get("version", "")),
		"signature": review["signature"],
		"allow_unsigned": bool(review["unsigned"]) and bool(review["allow_unsigned"]),
		"installed_at": int(current.get("installed_at", now)),
		"updated_at": now,
	}
	var saved: Dictionary = registry.record(id, record) if registry != null else Result.ok(record)
	if !saved.get("ok", false):
		_remove_tree(target)
		if !backup.is_empty() and DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(backup)):
			_move_folder(backup, target)
		return saved

	if publishers != null and bool(signature.get("present", false)):
		publishers.note_seen(str(signature.get("publisher_id", "")))

	return Result.ok({
		"id": id,
		"version": version,
		"path": target,
		"hash": str(review["hash"]),
		"previous_version": str(previous.get("version", "")),
		"signature": review["signature"],
		"allow_unsigned": bool(record["allow_unsigned"]),
		"review": review,
		"installed_at": now,
	})


# ── ROLLBACK ────────────────────────────────────────────────────────────────

## Switches the active version back to the previous record. The old folder was
## left in place by install(), so this only rewrites the registry and verifies
## that the bytes still match what was installed.
func rollback(id: String, options: Dictionary = {}) -> Dictionary:
	var current := _registry_entry(id)
	if current.is_empty():
		return Result.error("dependency.missing", "'%s' is not installed." % str(id))

	var previous: Dictionary = current.get("previous", {}) if current.get("previous") is Dictionary else {}
	if previous.is_empty():
		var previous_version := str(current.get("previous_version", ""))
		if previous_version.is_empty():
			return Result.error("update.no_previous", "There is no previous version of '%s' to roll back to." % str(id))
		previous = {"version": previous_version, "path": mods_root.path_join(str(id)).path_join(previous_version)}

	var path := str(previous.get("path", ""))
	var id_root := mods_root.path_join(str(id))
	if path.is_empty() or !Paths.is_subpath(id_root, path) or !Paths.same_file(path.get_base_dir(), id_root):
		return Result.error("path.outside_workspace", "The previous version path is not inside the mod's folder.")

	var folder := Package.validate_folder(path)
	if !bool(folder.get("ok", false)):
		return Result.error("update.rollback_blocked", "The previous version is no longer valid.", {"errors": folder.get("errors", [])})

	var expected := str(previous.get("hash", ""))
	if !expected.is_empty() and str(folder.get("digest", "")) != expected:
		return Result.error("update.rollback_blocked", "The previous version's files were modified; it cannot be restored safely.")

	var signature: Dictionary = folder.get("signature", {})
	if bool(signature.get("present", false)):
		if !bool(signature.get("ok", false)):
			return Result.error("signature.invalid", "The previous version's signature is invalid.")
		var state: Dictionary = publishers.state(signature) if publishers != null else {}
		if !bool(state.get("trusted", false)) and !bool(options.get("trust_publisher", false)):
			return Result.error("publisher.trust_required", "The publisher of the previous version is no longer trusted.")
		if bool(state.get("requires_trust", false)) and bool(options.get("trust_publisher", false)):
			var trusted: Dictionary = publishers.trust(signature, {"replace_key": bool(options.get("replace_key", false))})
			if !trusted.get("ok", false):
				return trusted
	elif !bool(current.get("allow_unsigned", false)) and !bool(options.get("allow_unsigned", false)):
		return Result.error("signature.required", "The previous version is unsigned.")

	var now := int(Time.get_unix_time_from_system())
	var replaced := _snapshot(current)
	var restored := {
		"version": str(previous.get("version", "")),
		"hash": str(folder.get("digest", expected)),
		"path": path,
		"manifest_mtime": int(FileAccess.get_modified_time(path.path_join("manifest.json"))),
		"package_mtime": int(folder.get("mtime", 0)),
		"signature": _signature_summary(signature),
		"allow_unsigned": bool(previous.get("allow_unsigned", current.get("allow_unsigned", false))),
		"previous": replaced,
		"previous_version": str(current.get("version", "")),
		"enabled": bool(current.get("enabled", true)),
		"installed_at": int(current.get("installed_at", now)),
		"updated_at": now,
	}
	var saved: Dictionary = registry.record(id, restored) if registry != null else Result.ok(restored)
	if !saved.get("ok", false):
		return saved

	return Result.ok({
		"id": str(id),
		"version": str(restored["version"]),
		"path": path,
		"hash": str(restored["hash"]),
		"restored_from_version": str(current.get("version", "")),
		"signature": restored["signature"],
	})


# ── UNINSTALL ───────────────────────────────────────────────────────────────

## Removes every version folder and the registry record. Mod data is kept by
## default; `remove_data` deletes user://mod_data/<id> as well. Consent records
## are always revoked so a reinstall asks again.
func uninstall(id: String, options: Dictionary = {}) -> Dictionary:
	var key := str(id)
	var id_root := mods_root.path_join(key)
	if !Paths.is_subpath(mods_root, id_root) or id_root == mods_root:
		return Result.error("path.outside_workspace", "The mod id does not resolve inside the mods folder.")

	var entry := _registry_entry(key)
	var version_count := 0
	var directory := DirAccess.open(id_root)
	if directory != null:
		version_count = directory.get_directories().size()
	_remove_tree(id_root)

	var data_path := data_root.path_join(key)
	var data_removed := false
	if bool(options.get("remove_data", false)) and Paths.is_subpath(data_root, data_path) and data_path != data_root:
		if DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(data_path)):
			_remove_tree(data_path)
			data_removed = true

	if permissions != null:
		permissions.revoke(key)
	if registry != null:
		var forgotten: Dictionary = registry.forget(key)
		if !forgotten.get("ok", false):
			return forgotten

	return Result.ok({
		"id": key,
		"name": str((entry.get("signature", {}) as Dictionary).get("display_name", key)),
		"removed_versions": version_count,
		"data_removed": data_removed,
		"data_kept": !data_removed and DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(data_path)),
	})


# ── HELPERS ─────────────────────────────────────────────────────────────────

func _snapshot(entry: Dictionary) -> Dictionary:
	var signature: Variant = entry.get("signature", {})
	return {
		"version": str(entry.get("version", "")),
		"hash": str(entry.get("hash", "")),
		"path": str(entry.get("path", "")),
		"manifest_mtime": int(entry.get("manifest_mtime", 0)),
		"package_mtime": int(entry.get("package_mtime", 0)),
		"signature": (signature as Dictionary).duplicate(true) if signature is Dictionary else {},
		"allow_unsigned": bool(entry.get("allow_unsigned", false)),
	}


func _new_staging_path(id: String, version: String) -> String:
	_ensure_dir(staging_root)
	var stamp := str(Time.get_ticks_usec())
	var candidate := staging_root.path_join("%s-%s-%s" % [id.replace(".", "_"), version, stamp])
	var suffix := 0
	while DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(candidate)):
		suffix += 1
		candidate = staging_root.path_join("%s-%s-%s-%d" % [id.replace(".", "_"), version, stamp, suffix])
	return candidate


func _new_backup_path(id: String, version: String) -> String:
	_ensure_dir(staging_root.path_join("backups"))
	var stamp := str(Time.get_ticks_usec())
	return staging_root.path_join("backups").path_join("%s-%s-%s" % [id.replace(".", "_"), version, stamp])


func _ensure_dir(path: String) -> void:
	if path.is_empty():
		return
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(path))


func _move_folder(from: String, to: String) -> Dictionary:
	var absolute_from := ProjectSettings.globalize_path(from)
	var absolute_to := ProjectSettings.globalize_path(to)
	_ensure_dir(to.get_base_dir())
	if !DirAccess.dir_exists_absolute(absolute_from):
		return Result.error("install.move_failed", "The folder '%s' does not exist." % from)

	var renamed := DirAccess.rename_absolute(absolute_from, absolute_to)
	if renamed == OK:
		return Result.ok({"path": to})

	# A locked file or a cross-volume move can make rename fail. Copy first,
	# then remove the source, so a failure leaves the source intact.
	var copied := _copy_tree(from, to)
	if !copied.get("ok", false):
		_remove_tree(to)
		return copied
	_remove_tree(from)
	return Result.ok({"path": to})


func _copy_tree(from: String, to: String) -> Dictionary:
	_ensure_dir(to)
	var directory := DirAccess.open(from)
	if directory == null:
		return Result.error("install.move_failed", "Could not read '%s'." % from)

	for name in directory.get_files():
		var file_name := str(name)
		var source := from.path_join(file_name)
		var target := to.path_join(file_name)
		var bytes := FileAccess.get_file_as_bytes(source)
		var output := FileAccess.open(target, FileAccess.WRITE)
		if output == null:
			return Result.error("install.move_failed", "Could not write '%s'." % target)
		output.store_buffer(bytes)
		output.close()

	for name in directory.get_directories():
		var folder := str(name)
		var copied := _copy_tree(from.path_join(folder), to.path_join(folder))
		if !copied.get("ok", false):
			return copied
	return Result.ok()


func _remove_tree(path: String) -> void:
	var absolute := ProjectSettings.globalize_path(path)
	if !DirAccess.dir_exists_absolute(absolute):
		return
	var directory := DirAccess.open(path)
	if directory == null:
		DirAccess.remove_absolute(absolute)
		return

	for name in directory.get_files():
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path.path_join(str(name))))
	for name in directory.get_directories():
		var child := str(name)
		if directory.is_link(ProjectSettings.globalize_path(path.path_join(child))):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(path.path_join(child)))
			continue
		_remove_tree(path.path_join(child))
	DirAccess.remove_absolute(absolute)


func _add(list: Array, code: String, message: String) -> void:
	list.append({"code": code, "message": message})


func _block(list: Array, code: String, message: String) -> void:
	_add(list, code, message)
