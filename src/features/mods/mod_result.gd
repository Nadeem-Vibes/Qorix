extends RefCounted

## Result envelope shared by every mod-platform service.
##
##   success: {ok = true,  value = ...}
##   failure: {ok = false, error = {code = "...", message = "...", details = {...}}}
##
## The codes started as the mod-core contract
## (docs/archive/mod-platform/contracts.md, section 4). Later additions are
## grouped by area below and listed in docs/archive/mod-platform/mod-core.md;
## overloading an existing code is not allowed, so a caller can always branch
## on the code alone.

const CODES := {
	# Contract codes.
	"manifest.invalid": "Schema or field validation failed.",
	"manifest.unknown_permission": "Permission not in the catalogue.",
	"manifest.version_range": "Editor/API range mismatch.",
	"dependency.missing": "Required mod absent.",
	"dependency.cycle": "Cycle in the dependency graph.",
	"permission.denied": "Capability not granted.",
	"trust.required": "Workspace trust missing.",
	"path.outside_workspace": "Path escape.",
	"path.invalid": "Absolute path or '..'.",
	"doc.stale_handle": "Document closed.",
	"doc.column_splits_grapheme": "Insertion splits a grapheme cluster.",
	"ui.slot_full": "Slot at capacity.",
	"ui.widget_invalid": "Unknown widget or property.",
	"shell.busy": "Another shell owns the screen.",
	"budget.exceeded": "Instruction/step budget exhausted.",
	"memory.exceeded": "Lua allocation limit reached.",
	"storage.quota": "KV/blob quota exceeded.",
	"run.blocked": "RunService/trust gate refused the run.",
	"run.timeout": "Validation run exceeded its timeout.",
	"event.queue_full": "Per-mod event queue capped.",
	"mod.failed": "Activation or runtime failure.",

	# Mod core additions.
	"manifest.unreadable": "The manifest file is missing, too large or not JSON.",
	"dependency.conflict": "Two mods declare a conflict.",
	"dependency.version": "An installed dependency does not satisfy the declared range.",
	"permission.consent_required": "Sensitive permissions have not been consented to.",
	"permission.unknown": "The permission name is not in the catalogue.",
	"registry.invalid": "The mod registry file could not be read.",
	"state.invalid": "The action is not valid in the mod's current state.",
	"settings.invalid": "A declared setting is malformed or unknown.",
	"settings.conflict": "A setting key was declared twice with different definitions.",
	"api.bad_args": "An API argument has the wrong shape.",
	"api.unknown_method": "The native API method does not exist.",
	"api.unavailable": "The method exists but is not implemented in this build.",
	"event.invalid": "The event name or payload is invalid.",
	"event.forbidden": "Mods may only emit their own namespaced events.",
	"command.invalid": "A command id or specification is invalid.",
	"command.duplicate": "A command with that id already exists.",
	"command.unknown": "The command is not registered.",
	"key.collision": "The shortcut is already in use.",
	"key.invalid": "The shortcut chord could not be parsed.",
	"storage.invalid_key": "The storage key is invalid.",
	"storage.invalid_value": "The value is not JSON-serializable.",
	"module.not_found": "The module file does not exist.",
	"module.invalid": "The module file is not valid for its loader.",
	"host.not_started": "The Lua host is not running.",
	"host.fatal": "A fatal Lua VM error destroyed the state.",
	"host.reentrant": "Re-entrant task execution is not allowed.",
	"timer.invalid": "The timer specification is invalid.",

	# API and partial-UI additions.
	"doc.not_found": "The document file does not exist.",
	"doc.exists": "The document path already exists; open it instead.",
	"doc.open_failed": "The editor did not open or create the document.",
	"doc.invalid_position": "The line or column is outside the document.",
	"doc.too_large": "The document text is over the size limit.",
	"doc.unsaved": "The document has no path to save to.",
	"doc.save_failed": "The document could not be written.",
	"doc.dirty": "The document has unsaved changes.",
	"workspace.required": "No workspace folder is open.",
	"workspace.open_failed": "The workspace folder could not be opened.",
	"module.unreadable": "The file exists but could not be read.",
	"module.too_large": "The file is over the size limit.",
	"module.unwritable": "The file or folder could not be written.",
	"module.not_empty": "The folder is not empty.",
	"ui.confirmation_required": "The operation needs explicit user confirmation.",
	"clipboard.too_large": "The clipboard value is over the size limit.",

	# Shell and learning additions.
	"guide.invalid_spec": "A guide target, mark, hint or display option is invalid.",
	"guide.unsupported": "The target uses text this API does not support (for example RTL).",
	"exercise.invalid_spec": "An exercise kind, phase or validation is invalid.",
	"exercise.unknown": "The exercise or validation session does not exist.",
	"exercise.invalid_state": "The exercise cannot do that in its current state.",
	"shell.invalid_spec": "A shell layout is not a valid container tree.",
	"shell.insets_invalid": "A content inset is not a number.",
	"shell.editor_slot": "A shell reserved more than one editor rectangle.",

	# Distribution and installation additions.
	"package.invalid": "The package archive is malformed or contains an unsafe entry.",
	"package.unreadable": "The package could not be read or written.",
	"package.too_large": "The package exceeds an entry, total-size or count limit.",
	"package.blocked_file": "The package contains an executable or native-library file.",
	"package.compression_ratio": "An entry expands beyond the compression-ratio limit.",
	"package.zip64": "ZIP64 archives are not supported.",
	"install.digest_mismatch": "The extracted files do not match the signed package digest.",
	"install.move_failed": "The staged package could not be moved into the mods folder.",
	"signature.required": "The package is unsigned and unsigned imports are disabled.",
	"signature.invalid": "The package signature is invalid or does not match the contents.",
	"publisher.trust_required": "The publisher key has not been trusted yet.",
	"publisher.key_changed": "The publisher is already pinned to a different key.",
	"publisher.invalid": "The publisher id or key fingerprint is invalid.",
	"publisher.store_invalid": "The publisher trust store could not be read or written.",
	"update.exists": "That version is already on disk and needs an explicit replace.",
	"update.downgrade": "The package is older than the installed version.",
	"update.no_previous": "There is no previous version to roll back to.",
	"update.rollback_blocked": "The previous version cannot be restored safely.",
}


static func ok(value: Variant = null) -> Dictionary:
	return {"ok": true, "value": value}


static func error(code: String, message: String, details: Dictionary = {}) -> Dictionary:
	var failure := {"code": code, "message": message}
	if !details.is_empty():
		failure["details"] = details
	return {"ok": false, "error": failure}


static func is_ok(result: Variant) -> bool:
	return result is Dictionary and bool(result.get("ok", false))


static func code_of(result: Variant) -> String:
	if result is Dictionary:
		var failure: Variant = result.get("error")
		if failure is Dictionary:
			return str(failure.get("code", ""))
	return ""


static func message_of(result: Variant) -> String:
	if result is Dictionary:
		var failure: Variant = result.get("error")
		if failure is Dictionary:
			return str(failure.get("message", ""))
	return ""


static func value_of(result: Variant, fallback: Variant = null) -> Variant:
	if is_ok(result):
		return result.get("value", fallback)
	return fallback


static func permission_denied(permission: String) -> Dictionary:
	return error(
		"permission.denied",
		"The mod has not been granted the '%s' permission." % permission,
		{"permission": permission},
	)


static func trust_required(permission: String) -> Dictionary:
	return error(
		"trust.required",
		"The '%s' permission also needs the workspace to be trusted." % permission,
		{"permission": permission},
	)


static func consent_required(permissions: Array) -> Dictionary:
	return error(
		"permission.consent_required",
		"Sensitive permissions need explicit consent: %s." % ", ".join(permissions),
		{"permissions": permissions},
	)


static func known(code: String) -> bool:
	return CODES.has(code)
