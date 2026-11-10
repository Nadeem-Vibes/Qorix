extends "res://tests/support/test_case.gd"

## The Phase 3 sample is documentation you can run. CI checks the manifest, the
## lesson content file and that main.lua actually uses the surfaces it teaches.

const Manifest = preload("res://src/features/mods/mod_manifest.gd")
const Permissions = preload("res://src/features/mods/mod_permissions.gd")

const ID := "griddycode.python_journey"
const ROOT := "res://samples/mods/griddycode.python_journey/1.0.0"


func test_manifest_declares_what_the_sample_uses() -> void:
	var result: Dictionary = Manifest.read_manifest(ROOT.path_join("manifest.json"), {"root": ROOT})
	check(result.get("ok", false), "manifest validates: %s" % str(result.get("errors", [])))
	if !result.get("ok", false):
		return
	var manifest: Dictionary = result.get("manifest", {})
	assert_eq(str(manifest.get("id", "")), ID, "manifest id")
	assert_eq(int(manifest.get("api", 0)), 1, "API version")
	check(FileAccess.file_exists(ROOT.path_join(str(manifest.get("entry", "")))), "entry exists")
	for permission in manifest.get("permissions", []):
		check(Permissions.CATALOGUE.has(str(permission)), "permission is catalogued: %s" % permission)
		check(bool((Permissions.CATALOGUE[str(permission)] as Dictionary).get("available", false)), "permission is available in v1")
	check((manifest.get("permissions", []) as Array).has("ui.shell"), "shell takeover is declared")
	check((manifest.get("permissions", []) as Array).has("run"), "run-backed validation is declared")


func test_lesson_content_exists_and_declares_a_guide_and_exercise() -> void:
	var path := ROOT.path_join("content/lessons/01_hello.lua")
	check(FileAccess.file_exists(path), "lesson content exists")
	var source := FileAccess.get_file_as_string(path)
	for needle in ["target =", "marks =", "hints =", "exercise =", "stdout_contains"]:
		check(source.contains(needle), "lesson declares %s" % needle)


func test_sample_uses_shell_guide_and_exercise() -> void:
	var source := FileAccess.get_file_as_string(ROOT.path_join("main.lua"))
	check(!source.is_empty(), "main.lua exists")
	for folder in ["lib"]:
		var dir := DirAccess.open(ROOT.path_join(folder))
		if dir == null:
			continue
		for file in dir.get_files():
			if str(file).ends_with(".lua"):
				source += FileAccess.get_file_as_string(ROOT.path_join(folder).path_join(str(file)))
	for needle in [
		"editor.ui.shell.takeover",
		"editor.ui.shell.exit",
		"editor.ui.on(",
		"editor.exercise.start",
		"editor.exercise.submit",
		"editor.content.load",
		"editor.progress",
		"function deactivate()",
	]:
		check(source.contains(needle), "the sample demonstrates %s" % needle)
