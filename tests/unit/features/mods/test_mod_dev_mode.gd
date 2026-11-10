extends TestCase

## Phase 5 developer mode: `user://mods_dev` discovery, consent and activation
## through the same path as installed mods, hot reload through the watcher, and
## the guarantee that installed packages are never watched.

const ManagerScript = preload("res://src/features/mods/mod_manager.gd")
const RegistryScript = preload("res://src/platform/command_registry.gd")
const KeybindingScript = preload("res://src/platform/keybinding_service.gd")
const TrustScript = preload("res://src/platform/trust_service.gd")
const Result = preload("res://src/features/mods/mod_result.gd")

const ROOT := "user://griddy_phase5/dev_mode"
const SOURCE := "res://samples/mods"
const DEV_ID := "griddycode.preview_lab"
const INSTALLED_ID := "griddycode.hello_dock"

var _signatures: Dictionary = {}


func before_each() -> void:
	_clean(ROOT)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(ROOT + "/mods"))
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(ROOT + "/mods_dev"))
	_signatures.clear()


func after_each() -> void:
	_clean(ROOT)


func _signature_source(id: String, _root: String) -> Dictionary:
	var found: Variant = _signatures.get(id, {})
	return (found as Dictionary).duplicate(true) if found is Dictionary else {}


func _make(developer_mode: bool = true):
	var commands = RegistryScript.new()
	var keybindings = KeybindingScript.new()
	keybindings.setup(commands)

	var manager = ManagerScript.new()
	manager.setup({
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
		"developer_mode": developer_mode,
		"preview_build": true,
		"watch_poll_ms": 100,
		"watch_debounce_ms": 100,
	})
	# Keep mtime granularity out of the test: the watcher accepts an injected
	# signature so a save is deterministic on every filesystem.
	manager.dev_watcher.configure({
		"signature_source": Callable(self, "_signature_source"),
	})
	return manager


func _status(manager, id: String) -> String:
	return str(manager.state(id).get("status", ""))


func _kv(id: String) -> Dictionary:
	var path := ROOT + "/data/" + id + "/kv.json"
	if !FileAccess.file_exists(path):
		return {}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	return parsed if parsed is Dictionary else {}


func _record(manager, id: String) -> Dictionary:
	for item in manager.installed():
		if str((item as Dictionary).get("id", "")) == id:
			return item
	return {}


func test_dev_sample_activates_and_hot_reloads_storage_backed_state() -> void:
	_copy_tree(
		SOURCE + "/" + DEV_ID + "/1.0.0",
		ROOT + "/mods_dev/" + DEV_ID + "/1.0.0"
	)
	_signatures[DEV_ID] = {"main.lua": 1, "lib/build.lua": 1}

	var manager = _make()
	var start_result: Dictionary = manager.start()
	check(bool(start_result.get("ok", false)), "start reports ok")
	var report: Dictionary = manager.status_report()
	assert_eq(_status(manager, DEV_ID), "active", "dev sample activates")
	assert_eq(int(_kv(DEV_ID).get("activations", 0)), 1, "first activation persisted")

	assert_true(bool(report.get("developer_mode", false)), "developer mode is on")
	assert_true(bool(report.get("preview_build", false)), "preview build is labeled")
	assert_true(bool(report.get("hot_reload", false)), "hot reload is advertised")
	assert_eq(str(report.get("api_semver", "")), "1.0.0", "status carries the frozen API")
	assert_true(bool(report.get("api_frozen", false)), "status says the API is frozen")
	assert_eq(str(report.get("dev_root", "")), ROOT + "/mods_dev", "dev root")
	assert_eq(int((report.get("dev_mods", []) as Array).size()), 1, "one dev mod")
	assert_eq(report.get("dev_watched"), [DEV_ID], "only the dev mod is watched")

	var installed: Dictionary = _record(manager, DEV_ID)
	check(bool(installed.get("dev", false)), "installed report marks the dev copy")
	check(str(installed.get("root", "")).begins_with(ROOT + "/mods_dev"), "dev root is used")

	# A save is seen on one poll and reloaded after the quiet window. Storage is
	# flushed on deactivate and loaded again on activate, so the counter grows.
	_signatures[DEV_ID] = {"main.lua": 2, "lib/build.lua": 1}
	manager.tick(0.1)
	assert_eq(_status(manager, DEV_ID), "active", "still active while the save settles")
	assert_eq(int(_kv(DEV_ID).get("activations", 0)), 1, "no reload before the debounce")

	manager.tick(0.1)
	assert_eq(_status(manager, DEV_ID), "active", "active again after hot reload")
	assert_eq(int(_kv(DEV_ID).get("activations", 0)), 2, "activation counter survived the reload")
	assert_eq(manager.dev_watcher.watched_ids(), [DEV_ID], "watcher rewires after reload")

	manager.stop()
	assert_eq(_status(manager, DEV_ID), "inactive", "stop deactivates the dev mod")
	assert_eq(manager.dev_watcher.watched_ids(), [], "stop clears the watcher")


func test_installed_mods_are_never_watched() -> void:
	_copy_tree(
		SOURCE + "/" + INSTALLED_ID + "/1.0.0",
		ROOT + "/mods/" + INSTALLED_ID + "/1.0.0"
	)
	_signatures[INSTALLED_ID] = {"main.lua": 1}

	var manager = _make()
	manager.start()
	assert_eq(_status(manager, INSTALLED_ID), "active", "installed sample activates")
	assert_eq(manager.dev_watcher.watched_ids(), [], "installed mods are not watched")
	assert_eq((manager.status_report().get("dev_mods", []) as Array).size(), 0, "no dev mods")

	# Even if the file signature changes, no reload can be triggered because the
	# id was never registered with the watcher.
	_signatures[INSTALLED_ID] = {"main.lua": 2}
	manager.tick(0.1)
	manager.tick(0.1)
	assert_eq(_status(manager, INSTALLED_ID), "active", "installed mod stays active")
	assert_eq(manager.dev_watcher.watched_ids(), [], "still nothing watched")
	manager.stop()


func test_dev_copy_overrides_an_installed_copy_for_the_session() -> void:
	_copy_tree(
		SOURCE + "/" + DEV_ID + "/1.0.0",
		ROOT + "/mods/" + DEV_ID + "/1.0.0"
	)
	_copy_tree(
		SOURCE + "/" + DEV_ID + "/1.0.0",
		ROOT + "/mods_dev/" + DEV_ID + "/1.0.0"
	)
	_signatures[DEV_ID] = {"main.lua": 1, "lib/build.lua": 1}

	var manager = _make()
	manager.start()
	assert_eq(_status(manager, DEV_ID), "active", "overridden copy activates")
	var record: Dictionary = _record(manager, DEV_ID)
	check(bool(record.get("dev", false)), "the dev copy wins in the report")
	check(str(record.get("root", "")).begins_with(ROOT + "/mods_dev"), "dev path is active")
	assert_eq(manager.status_report().get("dev_watched"), [DEV_ID], "the dev copy is watched")
	manager.stop()


func test_a_disabled_installed_entry_does_not_disable_the_dev_copy() -> void:
	_copy_tree(
		SOURCE + "/" + DEV_ID + "/1.0.0",
		ROOT + "/mods/" + DEV_ID + "/1.0.0"
	)

	# First session: disable the installed copy in the shared registry.
	var installed_session = _make()
	installed_session.start()
	assert_eq(_status(installed_session, DEV_ID), "active", "installed copy starts active")
	installed_session.set_enabled(DEV_ID, false, "test disable")
	assert_eq(_status(installed_session, DEV_ID), "disabled", "installed copy is disabled")
	installed_session.stop()

	# Second session: the author adds a dev copy. The old registry flag belongs
	# to the installed package and must not hide the folder being edited.
	_copy_tree(
		SOURCE + "/" + DEV_ID + "/1.0.0",
		ROOT + "/mods_dev/" + DEV_ID + "/1.0.0"
	)
	_signatures[DEV_ID] = {"main.lua": 1, "lib/build.lua": 1}
	var dev_session = _make()
	dev_session.start()
	assert_eq(_status(dev_session, DEV_ID), "active", "dev copy ignores the installed disabled flag")
	check(bool(_record(dev_session, DEV_ID).get("dev", false)), "the dev copy is the active record")
	dev_session.stop()


func test_developer_mode_off_leaves_the_dev_folder_alone() -> void:
	_copy_tree(
		SOURCE + "/" + DEV_ID + "/1.0.0",
		ROOT + "/mods_dev/" + DEV_ID + "/1.0.0"
	)

	var manager = _make(false)
	manager.start()
	var report: Dictionary = manager.status_report()
	assert_eq(manager.dev_watcher.watched_ids(), [], "nothing is watched without developer mode")
	assert_eq((report.get("dev_mods", []) as Array).size(), 0, "dev mods are not scanned")
	assert_eq(_status(manager, DEV_ID), "", "dev mod is not installed")
	manager.stop()


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
