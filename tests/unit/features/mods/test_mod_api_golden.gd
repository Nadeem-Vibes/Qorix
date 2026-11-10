extends TestCase

## API golden: the exact method list and permission annotations are contract.
## Accidental exposure fails here before it reaches a mod.

const Api = preload("res://src/features/mods/api/api_v1.gd")
const Permissions = preload("res://src/features/mods/mod_permissions.gd")
const Result = preload("res://src/features/mods/mod_result.gd")

const GOLDEN := "res://tests/fixtures/mods/api_v1_surface.json"


func _api():
	return Api.new(
		{"id": "griddycode.golden", "name": "Golden", "version": "1.0.0"},
		{},
	)


func test_surface_matches_golden_file() -> void:
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(GOLDEN))
	check(parsed is Array, "golden file is an array")
	var golden: Array = parsed

	var surface: Array = _api().surface()
	assert_eq(surface.size(), golden.size(), "method count")

	for index in range(mini(surface.size(), golden.size())):
		var actual: Dictionary = surface[index]
		var expected: Dictionary = golden[index]
		assert_eq(str(actual.get("name", "")), str(expected.get("name", "")), "method name at %d" % index)
		assert_eq(str(actual.get("permission", "")), str(expected.get("permission", "")), "permission for " + str(expected.get("name", "")))


func test_every_permission_is_in_the_catalogue() -> void:
	for entry in _api().surface():
		check(Permissions.CATALOGUE.has(str(entry["permission"])), "known permission: " + str(entry["permission"]))


func test_unknown_method_is_rejected() -> void:
	var result: Dictionary = _api().invoke("docs.explode", {})
	assert_eq(Result.code_of(result), "api.unknown_method")


func test_surface_is_sorted() -> void:
	var names: Array = []
	for entry in _api().surface():
		names.append(str(entry["name"]))
	var sorted_names := names.duplicate()
	sorted_names.sort()
	assert_eq(names, sorted_names, "surface is deterministic and sorted")


func test_result_codes_are_known() -> void:
	check(Result.known("budget.exceeded"), "contract code present")
	check(Result.known("storage.quota"), "storage code present")
	check(Result.known("permission.consent_required"), "phase 1 code present")
	check(Result.known("doc.not_found"), "phase 2 document code present")
	check(Result.known("workspace.required"), "phase 2 workspace code present")
	check(Result.known("ui.confirmation_required"), "phase 2 UI code present")
	check(!Result.known("definitely.not.a.code"), "unknown code is not accepted")
