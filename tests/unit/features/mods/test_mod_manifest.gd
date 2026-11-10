extends TestCase

## Manifest schema 1: every field, field-level errors and compatibility ranges.

const Manifest = preload("res://src/features/mods/mod_manifest.gd")

const MINIMAL_MANIFEST := "res://tests/fixtures/mods/minimal/griddycode.minimal/1.0.0/manifest.json"
const BAD_MANIFEST := "res://tests/fixtures/mods/bad_manifest/bad.id/1.0.0/manifest.json"


func _base() -> Dictionary:
	return {
		"schema": 1,
		"id": "com.example.mod",
		"name": "Example Mod",
		"version": "1.0.0",
		"api": 1,
		"min_editor": "1.0.0",
		"entry": "main.lua",
		"author": "Example Author",
		"description": "An example manifest used by the schema tests.",
		"permissions": ["core"],
	}


func _error_codes(result: Dictionary) -> Array:
	var out: Array = []
	for error in result.get("errors", []):
		out.append(str(error.get("code", "")))
	var single: Variant = result.get("error")
	if single is Dictionary:
		out.append(str((single as Dictionary).get("code", "")))
	return out


func _has_error(result: Dictionary, field: String) -> bool:
	for error in result.get("errors", []):
		if str(error.get("field", "")) == field:
			return true
	return false


func test_minimal_fixture_is_valid() -> void:
	var result := Manifest.read_manifest(MINIMAL_MANIFEST)
	check(result.get("ok", false), "minimal fixture validates: " + JSON.stringify(result.get("errors", [])))
	var manifest: Dictionary = result.get("manifest", {})
	assert_eq(manifest.get("id"), "griddycode.minimal")
	assert_eq(manifest.get("entry"), "main.lua")
	check((manifest.get("permissions", []) as Array).has("core"), "core is present")
	assert_eq((manifest.get("settings", []) as Array).size(), 1)


func test_invalid_fixture_reports_fields() -> void:
	var result := Manifest.read_manifest(BAD_MANIFEST)
	check(!result.get("ok", false), "invalid fixture is rejected")
	var codes := _error_codes(result)
	check(codes.has("manifest.invalid"), "schema errors use manifest.invalid")
	check(codes.has("manifest.unknown_permission"), "unknown permissions have their own code")
	check(_has_error(result, "extra_field"), "unknown top-level field is named")
	check(_has_error(result, "entry"), "entry is named")
	check(_has_error(result, "version"), "version is named")
	check(_has_error(result, "author"), "author is named")


func test_unknown_field() -> void:
	var data := _base()
	data["permission"] = ["core"]
	var result := Manifest.validate(data)
	check(!result.get("ok", false), "typo field is rejected")
	check(_has_error(result, "permission"), "the typo is named")


func test_missing_required_fields() -> void:
	var data := _base()
	for field in ["id", "name", "version", "api", "min_editor", "entry", "author", "description", "permissions"]:
		data.erase(field)
	var result := Manifest.validate(data)
	check(!result.get("ok", false), "missing fields are rejected")
	for field in ["id", "name", "version", "api", "min_editor", "entry", "author", "description", "permissions"]:
		check(_has_error(result, field), "missing " + field + " is named")


func test_permissions() -> void:
	var unknown := _base()
	unknown["permissions"] = ["core", "made.up"]
	var unknown_result := Manifest.validate(unknown)
	check(_error_codes(unknown_result).has("manifest.unknown_permission"), "unknown permission code")

	var reserved := _base()
	reserved["permissions"] = ["core", "network"]
	check(_error_codes(Manifest.validate(reserved)).has("manifest.unknown_permission"), "network is reserved")

	var duplicate := _base()
	duplicate["permissions"] = ["core", "documents.read", "documents.read"]
	check(!Manifest.validate(duplicate).get("ok", false), "duplicate permission is rejected")

	var implicit := _base()
	implicit["permissions"] = []
	var implicit_result := Manifest.validate(implicit)
	check(implicit_result.get("ok", false), "empty permissions is core only")
	check((implicit_result["manifest"]["permissions"] as Array).has("core"), "core is added")


func test_id_and_version() -> void:
	var bad_id := _base()
	bad_id["id"] = "Com.Example"
	check(_has_error(Manifest.validate(bad_id), "id"), "uppercase id rejected")

	var single_segment := _base()
	single_segment["id"] = "example"
	check(_has_error(Manifest.validate(single_segment), "id"), "single segment rejected")

	var bad_version := _base()
	bad_version["version"] = "1.0"
	check(_has_error(Manifest.validate(bad_version), "version"), "partial version rejected")

	var bad_api := _base()
	bad_api["api"] = 2
	var api_result := Manifest.validate(bad_api)
	check(_error_codes(api_result).has("manifest.version_range"), "API 2 is a range error")


func test_entry_paths() -> void:
	for entry in ["../escape.lua", "/absolute.lua", "C:/mods/main.lua", "main.txt", ""]:
		var data := _base()
		data["entry"] = entry
		check(_has_error(Manifest.validate(data), "entry"), "rejects entry: " + entry)

	var nested := _base()
	nested["entry"] = "src/main.lua"
	check(Manifest.validate(nested).get("ok", false), "nested entry is allowed")


func test_dependencies_and_conflicts() -> void:
	var data := _base()
	data["dependencies"] = {"griddycode.base": "^1.0.0"}
	data["optional"] = {"griddycode.extra": "~2.1"}
	check(Manifest.validate(data).get("ok", false), "valid dependency maps")

	var bad_range := _base()
	bad_range["dependencies"] = {"griddycode.base": "nonsense"}
	check(_has_error(Manifest.validate(bad_range), "dependencies.griddycode.base"), "bad range is named")

	var self_conflict := _base()
	self_conflict["conflicts"] = ["com.example.mod"]
	check(_has_error(Manifest.validate(self_conflict), "conflicts"), "self conflict is rejected")


func test_settings() -> void:
	var data := _base()
	data["settings"] = [
		{"key": "level", "type": "int", "default": 3, "min": 0, "max": 10, "label": "Level"},
		{"key": "mode", "type": "string", "default": "easy", "label": "Mode"},
	]
	var result := Manifest.validate(data)
	check(result.get("ok", false), "valid settings: " + JSON.stringify(result.get("errors", [])))
	assert_eq((result["manifest"]["settings"] as Array).size(), 2)

	var bad_type := _base()
	bad_type["settings"] = [{"key": "level", "type": "vector", "default": 1, "label": "Level"}]
	check(_has_error(Manifest.validate(bad_type), "settings[0].type"), "unknown setting type is named")

	var bad_default := _base()
	bad_default["settings"] = [{"key": "level", "type": "int", "default": "three", "label": "Level"}]
	check(_has_error(Manifest.validate(bad_default), "settings[0].default"), "default type is checked")

	var bad_key := _base()
	bad_key["settings"] = [{"key": "Level", "type": "int", "default": 1, "label": "Level"}]
	check(_has_error(Manifest.validate(bad_key), "settings[0].key"), "setting key shape is checked")


func test_compatibility() -> void:
	var manifest: Dictionary = Manifest.validate(_base())["manifest"]
	check(Manifest.check_compatibility(manifest, 1, "1.3.0").get("ok", false), "matching build")

	check(
		_error_codes(Manifest.check_compatibility(manifest, 2, "1.3.0")).has("manifest.version_range"),
		"API mismatch",
	)

	var too_new := _base()
	too_new["min_editor"] = "2.0.0"
	check(
		_error_codes(Manifest.check_compatibility(Manifest.validate(too_new)["manifest"], 1, "1.3.0")).has("manifest.version_range"),
		"editor too old",
	)

	var too_old := _base()
	too_old["max_editor"] = "1.0.0"
	check(
		_error_codes(Manifest.check_compatibility(Manifest.validate(too_old)["manifest"], 1, "1.3.0")).has("manifest.version_range"),
		"editor too new",
	)


func test_unreadable_manifest() -> void:
	var missing := Manifest.read_manifest("res://tests/fixtures/mods/does_not_exist/manifest.json")
	check(!missing.get("ok", false), "missing manifest fails")
	check(_error_codes(missing).has("manifest.unreadable"), "missing manifest code")
