extends TestCase

## Phase 5 freezes API 1.0. These tests pin the contract: the version constants,
## the exact golden surface, its content hash, and the docs that must describe
## every public native method, permission and manifest field.

const Api = preload("res://src/features/mods/api/api_v1.gd")
const Manifest = preload("res://src/features/mods/mod_manifest.gd")
const Permissions = preload("res://src/features/mods/mod_permissions.gd")

const GOLDEN := "res://tests/fixtures/mods/api_v1_surface.json"
const GOLDEN_SHA256 := "e27c1c0d341956d77751814df97a98bbea1724c462547c0f22f61effb0ff2467"

const DOCS := "res://docs/mods"
const API_REFERENCE := DOCS + "/api-reference.md"
const MANIFEST_REFERENCE := DOCS + "/manifest-reference.md"

const REQUIRED_DOCS := [
	"README.md",
	"developer-guide.md",
	"api-reference.md",
	"manifest-reference.md",
	"migration-notes.md",
	"known-issues.md",
	"feedback.md",
	"preview-packaging.md",
]


func _api():
	return Api.new(
		{"id": "griddycode.contract", "name": "Contract", "version": "1.0.0"},
		{},
	)


func test_api_is_frozen_at_1_0_0() -> void:
	assert_eq(Api.API_VERSION, 1, "major API version")
	assert_eq(Api.API_SEMVER, "1.0.0", "frozen semantic version")
	assert_eq(Api.API_STATUS, "frozen", "status is frozen")
	assert_true(Api.API_FROZEN, "freeze flag is set")

	var contract: Dictionary = _api().contract()
	assert_eq(int(contract.get("major", 0)), 1, "contract major")
	assert_eq(str(contract.get("semver", "")), "1.0.0", "contract semver")
	assert_eq(str(contract.get("status", "")), "frozen", "contract status")
	assert_true(bool(contract.get("frozen", false)), "contract frozen flag")
	assert_eq(int(contract.get("methods", 0)), 100, "contract method count")


func test_golden_file_is_the_frozen_surface() -> void:
	var bytes := FileAccess.get_file_as_bytes(GOLDEN)
	check(!bytes.is_empty(), "golden fixture exists")
	var context := HashingContext.new()
	context.start(HashingContext.HASH_SHA256)
	context.update(bytes)
	var digest := context.finish().hex_encode()
	assert_eq(digest, GOLDEN_SHA256, "golden surface hash")

	var parsed: Variant = JSON.parse_string(bytes.get_string_from_utf8())
	check(parsed is Array, "golden file is an array")
	var golden: Array = parsed
	assert_eq(golden.size(), 100, "golden method count")
	assert_eq(golden.size(), _api().surface().size(), "native table and golden agree")


func test_every_method_is_documented() -> void:
	check(FileAccess.file_exists(API_REFERENCE), "api-reference.md exists")
	var reference := FileAccess.get_file_as_string(API_REFERENCE)
	check(!reference.is_empty(), "api-reference.md is not empty")
	if reference.is_empty():
		return

	for entry in _api().surface():
		var name := str((entry as Dictionary).get("name", ""))
		check(reference.contains(name), "documented native method: %s" % name)


func test_every_permission_is_documented() -> void:
	var reference := FileAccess.get_file_as_string(API_REFERENCE)
	var manifest_reference := FileAccess.get_file_as_string(MANIFEST_REFERENCE)
	for permission in Permissions.CATALOGUE.keys():
		var name := str(permission)
		check(reference.contains(name), "permission in api reference: %s" % name)
		check(manifest_reference.contains(name), "permission in manifest reference: %s" % name)

	# The reserved entries must be described as unavailable, not left to look
	# like working capabilities.
	for permission in ["input.observe", "network"]:
		var entry: Dictionary = Permissions.CATALOGUE[permission]
		check(!bool(entry.get("available", true)), "%s is reserved" % permission)
		check(reference.contains(permission), "%s is documented as reserved" % permission)


func test_manifest_documentation_covers_every_field() -> void:
	var reference := FileAccess.get_file_as_string(MANIFEST_REFERENCE)
	check(!reference.is_empty(), "manifest-reference.md is not empty")
	if reference.is_empty():
		return

	for field in Manifest.ALLOWED_FIELDS:
		check(reference.contains(str(field)), "manifest field documented: %s" % field)
	for field in Manifest.SETTING_FIELDS:
		check(reference.contains(str(field)), "setting field documented: %s" % field)
	for type_name in Manifest.SETTING_TYPES:
		check(reference.contains(str(type_name)), "setting type documented: %s" % type_name)


func test_phase5_document_set_is_complete() -> void:
	for file in REQUIRED_DOCS:
		check(FileAccess.file_exists(DOCS + "/" + str(file)), "phase 5 doc exists: %s" % file)

	check(FileAccess.file_exists("res://samples/mods/README.md"), "samples README exists")
	check(
		FileAccess.file_exists("res://.github/ISSUE_TEMPLATE/mod-preview.yml"),
		"feedback issue form exists",
	)


func test_preview_build_is_opt_in_and_labeled() -> void:
	var presets := FileAccess.get_file_as_string("res://export_presets.cfg")
	check(presets.contains('name="Windows Developer Preview"'), "Windows preview preset exists")
	check(presets.contains('name="Linux/X11 Developer Preview"'), "Linux preview preset exists")
	check(
		presets.contains('export_path="Builds/Preview/Windows/Qorix-Preview.exe"'),
		"Windows preview artifact is separate",
	)
	check(
		presets.contains('export_path="Builds/Preview/Linux/Qorix-Preview.x86_64"'),
		"Linux preview artifact is separate",
	)
	assert_eq(
		presets.count('custom_features="mod_preview"'),
		2,
		"only the two preview presets carry the opt-in feature",
	)

	var file_manager := FileAccess.get_file_as_string("res://src/main/file_manager.gd")
	check(file_manager.contains('OS.has_feature("mod_preview")'), "preview feature is detected")
	check(file_manager.contains('"--mod-preview"'), "preview command-line flag is detected")
	check(file_manager.contains('"--mod-dev"'), "developer command-line flag is detected")
	check(file_manager.contains('"developer_mode":'), "developer mode is passed to the manager")
	check(file_manager.contains('"preview_build":'), "preview label is passed to the manager")

	var manager := FileAccess.get_file_as_string("res://src/features/mods/mod_manager.gd")
	check(manager.contains("Modding Developer Preview"), "the app announces the preview")
	check(manager.contains('"preview_build": preview_build'), "status reports the preview label")
	check(manager.contains('"api_frozen": Api.API_FROZEN'), "status reports the frozen API")

	check(
		FileAccess.file_exists("res://tools/mod-package/build_mod_preview.ps1"),
		"test-gated preview build script exists",
	)
