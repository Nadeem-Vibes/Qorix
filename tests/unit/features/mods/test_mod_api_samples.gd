extends "res://tests/support/test_case.gd"

## The samples are documentation you can run. CI validates their manifests and
## entry files, so a docs edit cannot silently produce an unloadable package.

const Manifest = preload("res://src/features/mods/mod_manifest.gd")
const Permissions = preload("res://src/features/mods/mod_permissions.gd")
const Result = preload("res://src/features/mods/mod_result.gd")

const ROOT := "res://samples/mods"
const SAMPLES := [
	"griddycode.hello_dock",
	"griddycode.word_count",
	"griddycode.note_taker",
]


func test_samples_have_valid_manifests_and_entries() -> void:
	for id in SAMPLES:
		var folder := ROOT.path_join(id).path_join("1.0.0")
		var result: Dictionary = Manifest.read_manifest(folder.path_join("manifest.json"), {"root": folder})
		check(result.get("ok", false), "%s manifest validates: %s" % [id, str(result.get("errors", []))])
		if !result.get("ok", false):
			continue

		var manifest: Dictionary = result.get("manifest", {})
		assert_eq(str(manifest.get("id", "")), id, "manifest id")
		assert_eq(int(manifest.get("api", 0)), 1, "API version")
		check(FileAccess.file_exists(folder.path_join(str(manifest.get("entry", "")))), "%s entry exists" % id)
		for permission in manifest.get("permissions", []):
			check(Permissions.CATALOGUE.has(str(permission)), "%s permission is catalogued: %s" % [id, permission])
		for definition in manifest.get("settings", []):
			check(definition is Dictionary, "%s setting is an object" % id)


func test_samples_use_the_phase2_surfaces_they_document() -> void:
	var expected := {
		"griddycode.hello_dock": ["editor.ui.mount", "editor.ui.update", "editor.ui.on", "editor.storage", "editor.ui.notify"],
		"griddycode.word_count": ["editor.docs.active", "editor.docs.text", "editor.events.on", "editor.ui.update"],
		"griddycode.note_taker": ["editor.dialogs.prompt", "editor.files.write", "editor.workspace.has_workspace"],
	}
	for id in expected.keys():
		var source := FileAccess.get_file_as_string(ROOT.path_join(id).path_join("1.0.0/main.lua"))
		check(!source.is_empty(), "%s has a main.lua" % id)
		for needle in expected[id]:
			check(source.contains(needle), "%s demonstrates %s" % [id, needle])


func test_every_sample_is_compatible_with_this_build() -> void:
	# The manifests are the contract a user sees. A version bump must update the
	# samples in the same change, or every sample is rejected at discovery.
	var loop := Engine.get_main_loop()
	var lua = loop.root.get_node_or_null("LuaSingleton") if loop != null else null
	assert_ne(lua, null, "LuaSingleton autoload is missing")
	if lua == null:
		return
	var editor_version := str(lua.version)
	check(!editor_version.is_empty(), "LuaSingleton advertises a version")

	var directory := DirAccess.open(ROOT)
	check(directory != null, "samples folder is readable")
	if directory == null:
		return
	directory.list_dir_begin()
	var seen: Array = []
	var name := directory.get_next()
	while !name.is_empty():
		if directory.current_is_dir() and !name.begins_with("."):
			var folder := ROOT.path_join(name).path_join("1.0.0")
			var manifest_path := folder.path_join("manifest.json")
			if FileAccess.file_exists(manifest_path):
				var result: Dictionary = Manifest.read_manifest(manifest_path, {"root": folder})
				check(result.get("ok", false), "%s manifest validates: %s" % [name, str(result.get("errors", []))])
				if result.get("ok", false):
					var manifest: Dictionary = result.get("manifest", {})
					var compatible: Dictionary = Manifest.check_compatibility(manifest, 1, editor_version)
					check(
						compatible.get("ok", false),
						"%s accepts editor %s: %s" % [name, editor_version, str(Result.message_of(compatible))],
					)
					seen.append(name)
		name = directory.get_next()
	directory.list_dir_end()
	assert_true(seen.size() >= 4, "all sample families were checked")
