extends RefCounted

## Manifest schema, 1.
##
## Validation is field-by-field and reports every problem at once: an install
## never fails with "invalid manifest" and nothing else. Unknown top-level fields
## are rejected on purpose, so a typo like `permission` cannot silently drop a
## capability request.

const Result = preload("res://src/features/mods/mod_result.gd")
const SemverRange = preload("res://src/features/mods/semver_range.gd")
const Permissions = preload("res://src/features/mods/mod_permissions.gd")
const Version = preload("res://src/base/version_utils.gd")

const SCHEMA := 1
const API_VERSION := 1
const MAX_MANIFEST_BYTES := 256 * 1024
const MAX_ENTRY_BYTES := 2 * 1024 * 1024
const MAX_ID_LENGTH := 64

const ALLOWED_FIELDS := [
	"schema", "id", "name", "version", "api", "min_editor", "max_editor",
	"entry", "author", "description", "license", "homepage", "permissions",
	"dependencies", "optional", "conflicts", "settings", "assets",
]

const SETTING_FIELDS := ["key", "type", "default", "label", "min", "max", "options"]
const SETTING_TYPES := ["bool", "int", "float", "string"]
const ASSET_FIELDS := ["icon"]
const MEDIA_EXTENSIONS := ["png", "jpg", "jpeg", "webp", "svg"]
const MAX_SETTINGS := 64
const MAX_DEPENDENCIES := 32

const ID_PATTERN := "^[a-z0-9][a-z0-9_-]*(\\.[a-z0-9][a-z0-9_-]*)+$"
const SETTING_KEY_PATTERN := "^[a-z][a-z0-9_]{0,63}$"


## Reads and validates a manifest file. `context` may carry {root, path}; both
## are stored on the result so later stages do not have to re-derive them.
static func read_manifest(path: String, context: Dictionary = {}) -> Dictionary:
	if path.is_empty() or !FileAccess.file_exists(path):
		return _failure("manifest.unreadable", "The manifest file does not exist: " + path, "manifest", context)

	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return _failure("manifest.unreadable", "The manifest could not be opened (error %d)." % FileAccess.get_open_error(), "manifest", context)

	var size := file.get_length()
	if size > MAX_MANIFEST_BYTES:
		file.close()
		return _failure("manifest.unreadable", "manifest.json is larger than %d bytes." % MAX_MANIFEST_BYTES, "manifest", context)

	var text := file.get_as_text()
	file.close()

	var json := JSON.new()
	if json.parse(text) != OK:
		return _failure(
			"manifest.unreadable",
			"manifest.json is not valid JSON: %s (line %d)." % [json.get_error_message(), json.get_error_line()],
			"manifest",
			context,
		)

	var merged := context.duplicate(true)
	merged["path"] = path
	return validate(json.data, merged)


## Validates an already-parsed manifest object.
## Returns {ok, errors: [{field, code, message}], warnings, manifest}.
static func validate(data: Variant, context: Dictionary = {}) -> Dictionary:
	var errors: Array = []
	var warnings: Array = []
	var out: Dictionary = {}

	if !(data is Dictionary):
		_add(errors, "manifest", "manifest.invalid", "The manifest must be a JSON object.")
		return _finish(out, errors, warnings, context)

	var source: Dictionary = data

	for key in source.keys():
		if !ALLOWED_FIELDS.has(str(key)):
			_add(errors, str(key), "manifest.invalid", "Unknown field '%s'." % str(key))

	var schema := _required_int(source, "schema", errors)
	if schema != 0 and schema != SCHEMA:
		_add(errors, "schema", "manifest.invalid", "Unsupported schema %d; this editor reads schema %d." % [schema, SCHEMA])
	out["schema"] = SCHEMA if schema == SCHEMA else schema

	var id := _required_string(source, "id", 3, MAX_ID_LENGTH, errors)
	if !id.is_empty() and !is_valid_id(id):
		_add(errors, "id", "manifest.invalid", "'%s' is not a reverse-DNS id (lowercase letters, digits, '.', '_' or '-', at least two segments)." % id)
	out["id"] = id

	out["name"] = _required_string(source, "name", 1, 80, errors)
	out["author"] = _required_string(source, "author", 1, 120, errors)
	out["description"] = _required_string(source, "description", 1, 500, errors)

	var version := _required_string(source, "version", 5, 80, errors)
	if !version.is_empty() and !SemverRange.is_version(version):
		_add(errors, "version", "manifest.invalid", "'%s' is not a MAJOR.MINOR.PATCH version." % version)
	out["version"] = version

	var api := _required_int(source, "api", errors)
	if api != 0 and api != API_VERSION:
		_add(errors, "api", "manifest.version_range", "This mod targets API %d; this editor provides API %d." % [api, API_VERSION])
	out["api"] = api

	var min_editor := _required_string(source, "min_editor", 3, 40, errors)
	if !min_editor.is_empty() and !_is_version_like(min_editor):
		_add(errors, "min_editor", "manifest.invalid", "'%s' is not a version." % min_editor)
	out["min_editor"] = min_editor

	var max_editor := _optional_string(source, "max_editor", 40, errors)
	if !max_editor.is_empty() and !_is_version_like(max_editor):
		_add(errors, "max_editor", "manifest.invalid", "'%s' is not a version." % max_editor)
	if !min_editor.is_empty() and !max_editor.is_empty() and _is_version_like(min_editor) and _is_version_like(max_editor):
		if Version.compare_versions(min_editor, max_editor) > 0:
			_add(errors, "max_editor", "manifest.invalid", "max_editor is lower than min_editor.")
	out["max_editor"] = max_editor

	var entry := _required_string(source, "entry", 5, 260, errors)
	if !entry.is_empty() and !_is_relative_path(entry, "lua"):
		_add(errors, "entry", "manifest.invalid", "entry must be a relative .lua path inside the mod folder.")
	out["entry"] = entry

	out["license"] = _optional_string(source, "license", 200, errors)

	var homepage := _optional_string(source, "homepage", 300, errors)
	if !homepage.is_empty() and !homepage.begins_with("https://"):
		_add(errors, "homepage", "manifest.invalid", "homepage must be an https:// URL.")
	out["homepage"] = homepage

	out["permissions"] = _validate_permissions(source, errors)
	out["dependencies"] = _validate_dependency_map(source, "dependencies", errors)
	out["optional"] = _validate_dependency_map(source, "optional", errors)
	out["conflicts"] = _validate_conflicts(source, id, errors)
	out["settings"] = _validate_settings(source, errors)
	out["assets"] = _validate_assets(source, errors)

	if out["license"] == "":
		warnings.append({"field": "license", "code": "manifest.invalid", "message": "No license declared."})

	return _finish(out, errors, warnings, context)


## Compares a validated manifest with the running editor. Range mismatches block
## activation but keep the install, so the user can update instead of losing it.
static func check_compatibility(manifest: Dictionary, api_version: int, editor_version: String) -> Dictionary:
	var api := int(manifest.get("api", 0))
	if api != api_version:
		return Result.error(
			"manifest.version_range",
			"This mod targets API %d; this editor provides API %d." % [api, api_version],
		)

	var min_editor := str(manifest.get("min_editor", ""))
	if !min_editor.is_empty() and Version.compare_versions(editor_version, min_editor) < 0:
		return Result.error(
			"manifest.version_range",
			"This mod needs Qorix %s or newer; this build is %s." % [min_editor, editor_version],
		)

	var max_editor := str(manifest.get("max_editor", ""))
	if !max_editor.is_empty() and Version.compare_versions(editor_version, max_editor) > 0:
		return Result.error(
			"manifest.version_range",
			"This mod supports Qorix up to %s; this build is %s. Check for an update." % [max_editor, editor_version],
		)

	return Result.ok()


static func is_valid_id(id: String) -> bool:
	if id.length() < 3 or id.length() > MAX_ID_LENGTH:
		return false
	if id.contains(".."):
		return false
	return _match(ID_PATTERN, id)


# ── FIELD VALIDATION ────────────────────────────────────────────────────────

static func _validate_permissions(source: Dictionary, errors: Array) -> Array:
	var out: Array = []
	if !source.has("permissions"):
		_add(errors, "permissions", "manifest.invalid", "permissions is required (use [] for core only).")
		return out

	var raw: Variant = source["permissions"]
	if !(raw is Array):
		_add(errors, "permissions", "manifest.invalid", "permissions must be an array.")
		return out

	for item in raw:
		var permission := str(item)
		if !Permissions.CATALOGUE.has(permission):
			_add(
				errors,
				"permissions",
				"manifest.unknown_permission",
				"'%s' is not a permission. Valid names: %s." % [permission, ", ".join(Permissions.available_names())],
			)
			continue
		if !bool(Permissions.CATALOGUE[permission].get("available", true)):
			_add(
				errors,
				"permissions",
				"manifest.unknown_permission",
				"'%s' is reserved and not available in this version." % permission,
			)
			continue
		if out.has(permission):
			_add(errors, "permissions", "manifest.invalid", "'%s' is declared twice." % permission)
			continue
		out.append(permission)

	if !out.has("core"):
		out.insert(0, "core")

	return out


static func _validate_dependency_map(source: Dictionary, field: String, errors: Array) -> Dictionary:
	var out: Dictionary = {}
	if !source.has(field):
		return out

	var raw: Variant = source[field]
	if !(raw is Dictionary):
		_add(errors, field, "manifest.invalid", "'%s' must be an object of mod id -> version range." % field)
		return out

	if (raw as Dictionary).size() > MAX_DEPENDENCIES:
		_add(errors, field, "manifest.invalid", "'%s' declares more than %d entries." % [field, MAX_DEPENDENCIES])

	var keys: Array = (raw as Dictionary).keys()
	keys.sort()
	for key in keys:
		var dep_id := str(key)
		if !is_valid_id(dep_id):
			_add(errors, "%s.%s" % [field, dep_id], "manifest.invalid", "'%s' is not a valid mod id." % dep_id)
			continue
		var range_text := str(raw[key]).strip_edges()
		if !SemverRange.is_range(range_text):
			_add(
				errors,
				"%s.%s" % [field, dep_id],
				"manifest.invalid",
				"'%s' is not a valid version range for '%s'." % [range_text, dep_id],
			)
			continue
		out[dep_id] = range_text

	return out


static func _validate_conflicts(source: Dictionary, own_id: String, errors: Array) -> Array:
	var out: Array = []
	if !source.has("conflicts"):
		return out

	var raw: Variant = source["conflicts"]
	if !(raw is Array):
		_add(errors, "conflicts", "manifest.invalid", "conflicts must be an array of mod ids.")
		return out

	for item in raw:
		var other := str(item)
		if !is_valid_id(other):
			_add(errors, "conflicts", "manifest.invalid", "'%s' is not a valid mod id." % other)
			continue
		if other == own_id:
			_add(errors, "conflicts", "manifest.invalid", "A mod cannot conflict with itself.")
			continue
		if out.has(other):
			_add(errors, "conflicts", "manifest.invalid", "'%s' is listed twice." % other)
			continue
		out.append(other)

	return out


static func _validate_settings(source: Dictionary, errors: Array) -> Array:
	var out: Array = []
	if !source.has("settings"):
		return out

	var raw: Variant = source["settings"]
	if !(raw is Array):
		_add(errors, "settings", "manifest.invalid", "settings must be an array of declarations.")
		return out
	if (raw as Array).size() > MAX_SETTINGS:
		_add(errors, "settings", "manifest.invalid", "A manifest may declare at most %d settings." % MAX_SETTINGS)

	var seen: Dictionary = {}
	for index in range((raw as Array).size()):
		var field := "settings[%d]" % index
		var item: Variant = raw[index]
		if !(item is Dictionary):
			_add(errors, field, "manifest.invalid", "Each setting must be an object.")
			continue

		for key in (item as Dictionary).keys():
			if !SETTING_FIELDS.has(str(key)):
				_add(errors, "%s.%s" % [field, str(key)], "manifest.invalid", "Unknown setting field '%s'." % str(key))

		var key := str((item as Dictionary).get("key", ""))
		if !_match(SETTING_KEY_PATTERN, key):
			_add(errors, field + ".key", "manifest.invalid", "Setting keys are lowercase letters, digits and '_' (max 64).")
			continue
		if seen.has(key):
			_add(errors, field + ".key", "manifest.invalid", "Setting '%s' is declared twice." % key)
			continue
		seen[key] = true

		var type := str((item as Dictionary).get("type", ""))
		if !SETTING_TYPES.has(type):
			_add(errors, field + ".type", "manifest.invalid", "Setting type must be one of: " + ", ".join(SETTING_TYPES))
			continue

		var label := str((item as Dictionary).get("label", key))
		if label.is_empty() or label.length() > 120:
			_add(errors, field + ".label", "manifest.invalid", "Setting labels are 1-120 characters.")

		var default_value: Variant = (item as Dictionary).get("default")
		if !_valid_default(type, default_value):
			_add(errors, field + ".default", "manifest.invalid", "The default does not match type '%s'." % type)

		var declaration := {
			"key": key,
			"type": type,
			"default": _coerce_default(type, default_value),
			"label": label,
		}

		for bound in ["min", "max"]:
			if (item as Dictionary).has(bound):
				var value: Variant = (item as Dictionary)[bound]
				if !_is_number(value):
					_add(errors, "%s.%s" % [field, bound], "manifest.invalid", "'%s' must be a number." % bound)
					continue
				declaration[bound] = value

		if (item as Dictionary).has("options"):
			var options := _validate_options((item as Dictionary)["options"], field, errors)
			if !options.is_empty():
				declaration["options"] = options

		out.append(declaration)

	return out


static func _validate_options(raw: Variant, field: String, errors: Array) -> Array:
	var out: Array = []
	if !(raw is Array):
		_add(errors, field + ".options", "manifest.invalid", "options must be an array of {display, value}.")
		return out

	for index in range((raw as Array).size()):
		var option: Variant = raw[index]
		if !(option is Dictionary) or !(option as Dictionary).has("value"):
			_add(errors, "%s.options[%d]" % [field, index], "manifest.invalid", "Each option needs a value.")
			continue

		var value: Variant = (option as Dictionary)["value"]
		if typeof(value) != TYPE_BOOL and !_is_number(value) and typeof(value) != TYPE_STRING and typeof(value) != TYPE_STRING_NAME:
			_add(errors, "%s.options[%d].value" % [field, index], "manifest.invalid", "Option values must be a string, number or boolean.")
			continue

		out.append({
			"display": str((option as Dictionary).get("display", value)),
			"value": str(value) if typeof(value) == TYPE_STRING or typeof(value) == TYPE_STRING_NAME else value,
		})

	return out


static func _validate_assets(source: Dictionary, errors: Array) -> Dictionary:
	var out: Dictionary = {}
	if !source.has("assets"):
		return out

	var raw: Variant = source["assets"]
	if !(raw is Dictionary):
		_add(errors, "assets", "manifest.invalid", "assets must be an object.")
		return out

	for key in (raw as Dictionary).keys():
		if !ASSET_FIELDS.has(str(key)):
			_add(errors, "assets." + str(key), "manifest.invalid", "Unknown asset field '%s'." % str(key))

	if (raw as Dictionary).has("icon"):
		var icon := str((raw as Dictionary)["icon"])
		if !_is_relative_path(icon, "") or !MEDIA_EXTENSIONS.has(icon.get_extension().to_lower()):
			_add(errors, "assets.icon", "manifest.invalid", "assets.icon must be a relative image path (png, jpg, webp, svg).")
		else:
			out["icon"] = icon

	return out


# ── HELPERS ─────────────────────────────────────────────────────────────────

static func _required_string(source: Dictionary, field: String, min_length: int, max_length: int, errors: Array) -> String:
	if !source.has(field):
		_add(errors, field, "manifest.invalid", "'%s' is required." % field)
		return ""

	var value: Variant = source[field]
	if typeof(value) != TYPE_STRING and typeof(value) != TYPE_STRING_NAME:
		_add(errors, field, "manifest.invalid", "'%s' must be a string." % field)
		return ""

	var text := str(value).strip_edges()
	if text.length() < min_length or text.length() > max_length:
		_add(errors, field, "manifest.invalid", "'%s' must be %d-%d characters." % [field, min_length, max_length])
		return ""
	return text


static func _optional_string(source: Dictionary, field: String, max_length: int, errors: Array) -> String:
	if !source.has(field) or source[field] == null:
		return ""

	var value: Variant = source[field]
	if typeof(value) != TYPE_STRING and typeof(value) != TYPE_STRING_NAME:
		_add(errors, field, "manifest.invalid", "'%s' must be a string." % field)
		return ""

	var text := str(value).strip_edges()
	if text.length() > max_length:
		_add(errors, field, "manifest.invalid", "'%s' is longer than %d characters." % [field, max_length])
		return ""
	return text


static func _required_int(source: Dictionary, field: String, errors: Array) -> int:
	if !source.has(field):
		_add(errors, field, "manifest.invalid", "'%s' is required." % field)
		return 0

	var value: Variant = source[field]
	if typeof(value) == TYPE_INT:
		return int(value)
	if typeof(value) == TYPE_FLOAT and is_finite(float(value)) and float(value) == floor(float(value)):
		return int(value)

	_add(errors, field, "manifest.invalid", "'%s' must be an integer." % field)
	return 0


static func _valid_default(type: String, value: Variant) -> bool:
	match type:
		"bool":
			return typeof(value) == TYPE_BOOL
		"int":
			return _is_number(value) and float(value) == floor(float(value))
		"float":
			return _is_number(value)
		"string":
			return typeof(value) == TYPE_STRING or typeof(value) == TYPE_STRING_NAME
	return false


static func _coerce_default(type: String, value: Variant) -> Variant:
	match type:
		"bool":
			return bool(value)
		"int":
			return int(value) if _is_number(value) else 0
		"float":
			return float(value) if _is_number(value) else 0.0
		"string":
			return str(value)
	return value


static func _is_number(value: Variant) -> bool:
	return typeof(value) == TYPE_INT or (typeof(value) == TYPE_FLOAT and is_finite(float(value)))


static func _is_version_like(text: String) -> bool:
	return _match("^[0-9]+(\\.[0-9]+){0,2}([-+][0-9A-Za-z.-]+)?$", text)


static func _is_relative_path(path: String, extension: String) -> bool:
	var value := path.replace("\\", "/")
	if value.is_empty() or value.length() > 260:
		return false
	if value.begins_with("/") or value.contains(":") or value.contains(".."):
		return false
	for segment in value.split("/", true):
		if segment.is_empty() or segment == ".":
			return false
	if !extension.is_empty() and value.get_extension().to_lower() != extension:
		return false
	return true


static func _finish(out: Dictionary, errors: Array, warnings: Array, context: Dictionary) -> Dictionary:
	if context.has("root"):
		out["root"] = str(context["root"])
	if context.has("path"):
		out["path"] = str(context["path"])
	return {
		"ok": errors.is_empty(),
		"errors": errors,
		"warnings": warnings,
		"manifest": out,
	}


static func _failure(code: String, message: String, field: String, context: Dictionary) -> Dictionary:
	var out: Dictionary = {}
	if context.has("root"):
		out["root"] = str(context["root"])
	if context.has("path"):
		out["path"] = str(context["path"])
	return {
		"ok": false,
		"errors": [_error(field, code, message)],
		"warnings": [],
		"manifest": out,
	}


static func _add(errors: Array, field: String, code: String, message: String) -> void:
	errors.append(_error(field, code, message))


static func _error(field: String, code: String, message: String) -> Dictionary:
	return {"field": field, "code": code, "message": message}


static func _match(pattern: String, value: String) -> bool:
	var regex := RegEx.new()
	if regex.compile(pattern) != OK:
		return false
	return regex.search(value) != null
