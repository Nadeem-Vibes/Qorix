extends TestCase

## Gate F samples: the three Phase 2 samples must activate from a clean install
## (with consent where the manifest declares sensitive permissions), and the
## Phase 5 Preview Lab must be a valid, loadable package that demonstrates the
## surfaces the developer guide teaches.

const ManagerScript = preload("res://src/features/mods/mod_manager.gd")
const UiScript = preload("res://src/features/mods/ui/mod_ui_registry.gd")
const RegistryScript = preload("res://src/platform/command_registry.gd")
const KeybindingScript = preload("res://src/platform/keybinding_service.gd")
const TrustScript = preload("res://src/platform/trust_service.gd")
const Manifest = preload("res://src/features/mods/mod_manifest.gd")
const Permissions = preload("res://src/features/mods/mod_permissions.gd")

const ROOT := "user://griddy_phase5/samples"
const SOURCE := "res://samples/mods"
const CLEAN_INSTALL := [
	"griddycode.hello_dock",
	"griddycode.word_count",
	"griddycode.note_taker",
]
const NOTE_TAKER := "griddycode.note_taker"
const PREVIEW_LAB := "griddycode.preview_lab"
const PLATFORM_TOUR := "griddycode.platform_tour"


func before_each() -> void:
	_clean(ROOT)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(ROOT + "/mods"))


func after_each() -> void:
	_clean(ROOT)


func _make(ui = null):
	var commands = RegistryScript.new()
	var keybindings = KeybindingScript.new()
	keybindings.setup(commands)

	var manager = ManagerScript.new()
	var context := {
		"mods_root": ROOT + "/mods",
		"dev_root": ROOT + "/mods_dev",
		"data_root": ROOT + "/data",
		"registry_path": ROOT + "/mod_registry.json",
		"permissions_path": ROOT + "/mod_permissions.json",
		"session_path": ROOT + "/mod_session.json",
		"command_registry": commands,
		"keybinding_service": keybindings,
		"trust_service": TrustScript.new(),
		"editor_version": "1.4.0",
		"preview_build": true,
	}
	if ui != null:
		context["ui"] = ui
	manager.setup(context)
	return manager


func _status(manager, id: String) -> String:
	return str(manager.state(id).get("status", ""))


func test_three_samples_activate_from_a_clean_install() -> void:
	for id in CLEAN_INSTALL:
		_copy_tree(SOURCE + "/" + id + "/1.0.0", ROOT + "/mods/" + id + "/1.0.0")

	var manager = _make()
	var start_result: Dictionary = manager.start()
	check(bool(start_result.get("ok", false)), "start reports ok")
	var report: Dictionary = manager.status_report()
	assert_true(bool(report.get("preview_build", false)), "the preview build is labeled")

	assert_eq(_status(manager, "griddycode.hello_dock"), "active", "Hello Dock activates")
	assert_eq(_status(manager, "griddycode.word_count"), "blocked", "Word Count asks for consent first")
	assert_eq(_status(manager, NOTE_TAKER), "blocked", "Note Taker asks for consent first")

	var word_blocked: Dictionary = manager.state("griddycode.word_count")
	check(
		(word_blocked.get("missing_permissions", []) as Array).has("documents.read"),
		"Word Count requests documents.read",
	)

	var blocked: Dictionary = manager.state(NOTE_TAKER)
	var missing: Array = blocked.get("missing_permissions", [])
	for permission in ["files.read", "files.write", "workspace.read"]:
		check(missing.has(permission), "Note Taker requests %s" % permission)

	for id in ["griddycode.word_count", NOTE_TAKER]:
		var granted: Dictionary = manager.grant_consent(id)
		check(bool(granted.get("ok", false)), "%s consent grants activation" % id)
		assert_eq(_status(manager, id), "active", "%s activates after consent" % id)

	var commands := {
		"griddycode.hello_dock": "griddycode.hello_dock.reset",
		"griddycode.word_count": "griddycode.word_count.report",
		"griddycode.note_taker": "griddycode.note_taker.save",
	}
	for id in CLEAN_INSTALL:
		check(manager.command_registry.has(str(commands[id])), "%s registered a command" % id)

	manager.stop()


func test_preview_lab_is_a_valid_loadable_package() -> void:
	var folder := SOURCE + "/" + PREVIEW_LAB + "/1.0.0"
	var read: Dictionary = Manifest.read_manifest(folder.path_join("manifest.json"), {"root": folder})
	check(bool(read.get("ok", false)), "preview_lab manifest validates: %s" % str(read.get("errors", [])))
	if !bool(read.get("ok", false)):
		return

	var manifest: Dictionary = read["manifest"]
	assert_eq(str(manifest.get("id", "")), PREVIEW_LAB, "manifest id")
	assert_eq(int(manifest.get("api", 0)), 1, "API version")
	assert_eq(str(manifest.get("entry", "")), "main.lua", "entry")
	check(FileAccess.file_exists(folder.path_join("main.lua")), "main.lua exists")
	check(FileAccess.file_exists(folder.path_join("lib/build.lua")), "lib/build.lua exists")
	check(FileAccess.file_exists(folder.path_join("README.md")), "the sample has a README")

	for permission in manifest.get("permissions", []):
		check(Permissions.CATALOGUE.has(str(permission)), "permission is catalogued: %s" % permission)
		check(
			bool((Permissions.CATALOGUE[str(permission)] as Dictionary).get("available", false)),
			"permission is available in v1: %s" % permission,
		)

	var compatible: Dictionary = Manifest.check_compatibility(manifest, 1, "1.4.0")
	check(bool(compatible.get("ok", false)), "preview_lab is compatible with 1.4.0")

	var source := FileAccess.get_file_as_string(folder.path_join("main.lua"))
	check(!source.is_empty(), "main.lua is not empty")
	for needle in [
		"require(\"build\")",
		"editor.storage",
		"editor.settings.get",
		"editor.ui.mount",
		"editor.ui.update",
		"function deactivate()",
	]:
		check(source.contains(needle), "preview_lab demonstrates %s" % needle)

	var module := FileAccess.get_file_as_string(folder.path_join("lib/build.lua"))
	check(module.contains("return {"), "lib/build.lua returns a module table")


func test_preview_lab_activates_from_an_installed_copy() -> void:
	_copy_tree(SOURCE + "/" + PREVIEW_LAB + "/1.0.0", ROOT + "/mods/" + PREVIEW_LAB + "/1.0.0")

	var manager = _make()
	manager.start()
	assert_eq(_status(manager, PREVIEW_LAB), "active", "preview_lab loads as an installed mod")
	var kv := _kv(PREVIEW_LAB)
	assert_eq(int(kv.get("activations", 0)), 1, "the activation counter is stored")
	manager.stop()


func test_platform_tour_is_a_valid_loadable_package() -> void:
	var folder := SOURCE + "/" + PLATFORM_TOUR + "/1.0.0"
	var read: Dictionary = Manifest.read_manifest(folder.path_join("manifest.json"), {"root": folder})
	check(bool(read.get("ok", false)), "platform_tour manifest validates: %s" % str(read.get("errors", [])))
	if !bool(read.get("ok", false)):
		return

	var manifest: Dictionary = read["manifest"]
	assert_eq(str(manifest.get("id", "")), PLATFORM_TOUR, "manifest id")
	assert_eq(int(manifest.get("api", 0)), 1, "API version")
	assert_eq(str(manifest.get("entry", "")), "main.lua", "entry")
	for file in [
		"main.lua",
		"lib/build.lua",
		"lib/tour.lua",
		"content/lessons/01_manifest.lua",
		"README.md",
	]:
		check(FileAccess.file_exists(folder.path_join(file)), "%s exists" % file)

	var declared: Array = manifest.get("permissions", [])
	check(declared.has("documents.read"), "the tour declares documents.read")
	check(declared.has("documents.write"), "the tour declares documents.write")
	var requested := declared.duplicate()
	requested.erase("core")
	assert_eq(requested.size(), 2, "the tour declares only the two document permissions")
	for permission in declared:
		check(Permissions.CATALOGUE.has(str(permission)), "permission is catalogued: %s" % permission)
		check(
			bool((Permissions.CATALOGUE[str(permission)] as Dictionary).get("available", false)),
			"permission is available in v1: %s" % permission,
		)

	var compatible: Dictionary = Manifest.check_compatibility(manifest, 1, "1.4.0")
	check(bool(compatible.get("ok", false)), "platform_tour is compatible with 1.4.0")

	var source := FileAccess.get_file_as_string(folder.path_join("main.lua"))
	check(!source.is_empty(), "main.lua is not empty")
	for needle in [
		"require(\"build\")",
		"require(\"tour\")",
		"editor.ui.mount",
		"editor.commands.register",
		"editor.docs.create",
		"function deactivate()",
	]:
		check(source.contains(needle), "platform_tour demonstrates %s" % needle)

	var tour := FileAccess.get_file_as_string(folder.path_join("lib/tour.lua"))
	check(tour.contains("editor.exercise.start"), "lib/tour.lua starts the hybrid exercise")
	var lesson := FileAccess.get_file_as_string(folder.path_join("content/lessons/01_manifest.lua"))
	check(lesson.contains("permissions"), "the lesson teaches the permissions table")
	check(lesson.contains("documents.read"), "the lesson uses a real permission")

	var readme := FileAccess.get_file_as_string(folder.path_join("README.md"))
	check(readme.contains("lib/build.lua"), "the README documents the hot reload file")
	check(readme.contains("## Self-check"), "the README documents the self-check")


func test_samples_subscribe_with_child_widget_ids() -> void:
	# A mounted panel has id <mod_id>.<root>; its children are
	# <mod_id>.<child>, not <mount_id>.<child>. Using mount_id as a prefix
	# silently registers a handler on a widget that does not exist.
	for id in CLEAN_INSTALL + [PREVIEW_LAB, PLATFORM_TOUR]:
		var path: String = SOURCE + "/" + id + "/1.0.0/main.lua"
		var source := FileAccess.get_file_as_string(path)
		check(!source.contains("editor.ui.on(mount_id"), "%s uses local widget ids" % id)


func test_platform_tour_waits_for_consent_and_then_activates() -> void:
	_copy_tree(SOURCE + "/" + PLATFORM_TOUR + "/1.0.0", ROOT + "/mods/" + PLATFORM_TOUR + "/1.0.0")

	var manager = _make()
	manager.start()
	assert_eq(_status(manager, PLATFORM_TOUR), "blocked", "the tour waits for consent")
	var blocked: Dictionary = manager.state(PLATFORM_TOUR)
	var missing: Array = blocked.get("missing_permissions", [])
	check(missing.has("documents.read"), "the tour requests documents.read")
	check(missing.has("documents.write"), "the tour requests documents.write")

	var granted: Dictionary = manager.grant_consent(PLATFORM_TOUR)
	check(bool(granted.get("ok", false)), "consent grants activation")
	assert_eq(_status(manager, PLATFORM_TOUR), "active", "the tour activates after consent")

	check(
		manager.command_registry.has("griddycode.platform_tour.start"),
		"the tour registers its start command",
	)
	check(
		manager.command_registry.has("griddycode.platform_tour.selfcheck"),
		"the tour registers its self-check command",
	)
	var kv := _kv(PLATFORM_TOUR)
	assert_eq(int(kv.get("activations", 0)), 1, "the activation counter is stored")
	var log_text: String = manager.diagnostics.text(PLATFORM_TOUR)
	check(!log_text.contains("could not load the lesson"), "the lesson content loads")
	check(!log_text.contains("could not register"), "every tour command registers")
	manager.stop()


func test_platform_tour_buttons_run_through_the_real_registry() -> void:
	_copy_tree(SOURCE + "/" + PLATFORM_TOUR + "/1.0.0", ROOT + "/mods/" + PLATFORM_TOUR + "/1.0.0")

	var ui = UiScript.new()
	Engine.get_main_loop().root.add_child(ui)
	if ui._right_column == null:
		ui._ready()

	var manager = _make(ui)
	ui.setup({
		"manager": manager,
		"dispatch": Callable(manager, "invoke_handler"),
		"notify": Callable(self, "_ignore_notify"),
		"set_core_visible": Callable(self, "_ignore_layout"),
	})

	manager.start()
	check(bool(manager.grant_consent(PLATFORM_TOUR).get("ok", false)), "consent grants activation")
	assert_eq(_status(manager, PLATFORM_TOUR), "active", "the tour is active")

	for local in ["start", "check", "retry", "selfcheck", "strict", "reset"]:
		var key: String = PLATFORM_TOUR + "." + str(local)
		check(ui._nodes.has(key), "%s is mounted" % key)
		check(ui._handlers.has(key), "%s has a registered click handler" % key)

	var status = ui._nodes.get(PLATFORM_TOUR + ".status")
	var strict = ui._nodes.get(PLATFORM_TOUR + ".strict")
	check(status is Label, "the status label is mounted")
	check(strict is Button, "the strict typing button is mounted")
	if status is Label and strict is Button:
		# Emit the real Button signal: this drives catalog -> registry ->
		# ModManager -> Lua. toggle_strict ends in ui.update, so the second
		# click also proves the handler survives an in-place update.
		(strict as Button).pressed.emit()
		check((status as Label).text.contains("Strict typing is on"), "the first click runs the Lua handler")
		(strict as Button).pressed.emit()
		check((status as Label).text.contains("Strict typing is off"), "the handler survives the update")

	manager.stop()
	ui.free()


func _ignore_notify(_text: String, _severity: String) -> void:
	pass


func _ignore_layout(_panel: String, _visible: bool) -> Variant:
	return null


func _kv(id: String) -> Dictionary:
	var path := ROOT + "/data/" + id + "/kv.json"
	if !FileAccess.file_exists(path):
		return {}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	return parsed if parsed is Dictionary else {}


func _copy_tree(source: String, destination: String) -> int:
	var directory := DirAccess.open(source)
	if directory == null:
		check(false, "missing sample source: %s" % source)
		return 0

	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(destination))
	var copied := 0
	for name in directory.get_files():
		var bytes := FileAccess.get_file_as_bytes(source.path_join(str(name)))
		if bytes.is_empty():
			continue
		var output := FileAccess.open(destination.path_join(str(name)), FileAccess.WRITE)
		if output == null:
			continue
		output.store_buffer(bytes)
		output.close()
		copied += 1

	for name in directory.get_directories():
		copied += _copy_tree(
			source.path_join(str(name)),
			destination.path_join(str(name))
		)
	return copied


func _clean(path: String) -> void:
	var dir := DirAccess.open(path)
	if dir != null:
		for name in dir.get_files():
			DirAccess.remove_absolute(ProjectSettings.globalize_path(path.path_join(str(name))))
		for name in dir.get_directories():
			_clean(path.path_join(str(name)))
			DirAccess.remove_absolute(ProjectSettings.globalize_path(path.path_join(str(name))))
	var absolute := ProjectSettings.globalize_path(path)
	if DirAccess.dir_exists_absolute(absolute):
		DirAccess.remove_absolute(absolute)
