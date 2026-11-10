extends "res://tests/support/test_case.gd"

const RegistryScript = preload("res://src/platform/command_registry.gd")
const ServiceScript = preload("res://src/platform/keybinding_service.gd")
const KeyChordScript = preload("res://src/platform/key_chord.gd")

const TEST_DIR := "user://tests_tmp"
const TEST_PATH := "user://tests_tmp/keybindings.json"

var registry = null
var service = null


func before_each() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(TEST_DIR))
	_remove_file(TEST_PATH)
	_erase_actions()

	registry = RegistryScript.new()
	registry.register("file.save", {
		"label": "Save", "category": "File", "scope": "global", "shortcut": "Ctrl+S",
		"handler": func() -> void: pass,
	})
	registry.register("file.save_as", {
		"label": "Save As", "category": "File", "scope": "global", "shortcut": "Ctrl+Shift+S",
		"handler": func() -> void: pass,
	})
	registry.register("edit.find", {
		"label": "Find in File", "category": "Edit", "scope": "editor", "shortcut": "Ctrl+F",
		"handler": func() -> void: pass,
	})
	registry.register("terminal.clear", {
		"label": "Clear Terminal", "category": "Terminal", "scope": "terminal", "shortcut": "Ctrl+L",
		"handler": func() -> void: pass,
	})

	service = ServiceScript.new()
	service.path = TEST_PATH
	service.setup(registry)
	service.load_bindings()


func after_each() -> void:
	if service != null:
		service.free()
	service = null
	registry = null
	_remove_file(TEST_PATH)
	_erase_actions()


func _remove_file(path: String) -> void:
	var global := ProjectSettings.globalize_path(path)
	if FileAccess.file_exists(global):
		DirAccess.remove_absolute(global)


func _erase_actions() -> void:
	for action in InputMap.get_actions():
		if str(action).begins_with("cmd_"):
			InputMap.erase_action(action)


func _write_bindings(bindings: Dictionary) -> void:
	var file := FileAccess.open(TEST_PATH, FileAccess.WRITE)
	file.store_string(JSON.stringify({"version": 1, "bindings": bindings}))


func _key_event(keycode: Key, ctrl: bool = false, shift: bool = false, alt: bool = false) -> InputEventKey:
	var event := InputEventKey.new()
	event.physical_keycode = keycode
	event.ctrl_pressed = ctrl
	event.shift_pressed = shift
	event.alt_pressed = alt
	event.pressed = true
	return event


func test_defaults_come_from_the_registry() -> void:
	assert_eq(service.binding_for("file.save"), "Ctrl+S")
	assert_eq(service.default_for("file.save"), "Ctrl+S")
	assert_eq(str(registry.get_command("file.save").get("shortcut", "")), "Ctrl+S")
	assert_false(service.has_override("file.save"))
	assert_eq(service.overrides().size(), 0)


func test_set_binding_persists_only_the_override() -> void:
	var result: Dictionary = service.set_binding("file.save", "Ctrl+Alt+S")
	assert_true(result.get("ok", false), str(result.get("error", "")))
	assert_eq(service.binding_for("file.save"), "Ctrl+Alt+S")
	assert_eq(str(registry.get_command("file.save").get("shortcut", "")), "Ctrl+Alt+S")
	assert_true(service.has_override("file.save"))
	assert_true(FileAccess.file_exists(TEST_PATH), "keybindings.json is written")

	var data = JSON.parse_string(FileAccess.get_file_as_string(TEST_PATH))
	assert_true(data is Dictionary, "the file is valid JSON")
	assert_eq(str(data.get("bindings", {}).get("file.save", "")), "Ctrl+Alt+S")
	assert_eq(data.get("bindings", {}).size(), 1, "only overrides are stored")


func test_conflict_is_reported_and_force_overrides_it() -> void:
	var blocked: Dictionary = service.set_binding("file.save", "Ctrl+Shift+S")
	assert_false(blocked.get("ok", true), "the conflicting binding is rejected")
	assert_true(blocked.get("conflicts", []).has("file.save_as"), "the other command is listed")
	assert_eq(service.binding_for("file.save"), "Ctrl+S", "a rejected binding changes nothing")

	var forced: Dictionary = service.set_binding("file.save", "Ctrl+Shift+S", true)
	assert_true(forced.get("ok", false), str(forced.get("error", "")))
	assert_eq(service.binding_for("file.save"), "Ctrl+Shift+S")


func test_different_scopes_do_not_conflict() -> void:
	var result: Dictionary = service.set_binding("terminal.clear", "Ctrl+F")
	assert_true(result.get("ok", false), str(result.get("error", "")))
	assert_eq(service.binding_for("terminal.clear"), "Ctrl+F")
	assert_eq(service.binding_for("edit.find"), "Ctrl+F")


func test_handle_respects_scope() -> void:
	assert_eq(service.handle(_key_event(KEY_F, true), "editor"), "edit.find")
	assert_eq(service.handle(_key_event(KEY_F, true), "terminal"), "", "Ctrl+F is not an editor command in the terminal")
	assert_eq(service.handle(_key_event(KEY_S, true), "terminal"), "file.save", "global commands work in the terminal")
	assert_eq(service.handle(_key_event(KEY_F, true, true), "editor"), "", "Ctrl+Shift+F is not Ctrl+F")


func test_handle_ignores_release_and_echo() -> void:
	var release := _key_event(KEY_S, true)
	release.pressed = false
	assert_eq(service.handle(release, "editor"), "", "release is ignored")

	var echo := _key_event(KEY_S, true)
	echo.echo = true
	assert_eq(service.handle(echo, "editor"), "", "echo is ignored")


func test_invalid_shortcut_is_rejected() -> void:
	var result: Dictionary = service.set_binding("file.save", "Ctrl+")
	assert_false(result.get("ok", true), "an incomplete shortcut is rejected")
	assert_eq(service.binding_for("file.save"), "Ctrl+S")


func test_empty_binding_unbinds_the_command() -> void:
	var result: Dictionary = service.set_binding("file.save", "")
	assert_true(result.get("ok", false), str(result.get("error", "")))
	assert_eq(service.binding_for("file.save"), "")
	assert_eq(service.handle(_key_event(KEY_S, true), "editor"), "", "the command no longer matches")
	assert_true(service.chord_for("file.save").is_empty(), "there is no parsed chord")


func test_reset_binding_restores_the_default() -> void:
	service.set_binding("file.save", "Ctrl+Alt+S")
	var result: Dictionary = service.reset_binding("file.save")
	assert_true(result.get("ok", false))
	assert_eq(service.binding_for("file.save"), "Ctrl+S")
	assert_false(service.has_override("file.save"))


func test_reset_all_clears_every_override() -> void:
	service.set_binding("file.save", "Ctrl+Alt+S")
	service.set_binding("edit.find", "Ctrl+Shift+F")
	assert_eq(service.overrides().size(), 2)

	var result: Dictionary = service.reset_all()
	assert_true(result.get("ok", false))
	assert_eq(service.overrides().size(), 0)
	assert_eq(service.binding_for("file.save"), "Ctrl+S")
	assert_eq(service.binding_for("edit.find"), "Ctrl+F")


func test_load_reads_overrides_and_reports_conflicts() -> void:
	service.free()
	service = null
	_write_bindings({
		"file.save": "Ctrl+Shift+S",
		"file.save_as": "Ctrl+Shift+S",
	})

	service = ServiceScript.new()
	service.path = TEST_PATH
	service.setup(registry)
	service.load_bindings()

	assert_eq(service.binding_for("file.save"), "Ctrl+Shift+S")
	assert_eq(service.binding_for("file.save_as"), "Ctrl+Shift+S")

	var conflicts: Array = service.conflicts()
	assert_eq(conflicts.size(), 1, "one conflicting chord is reported")
	if !conflicts.is_empty():
		var ids: Array = conflicts[0].get("commands", [])
		assert_true(ids.has("file.save") and ids.has("file.save_as"), "both commands are listed")


func test_invalid_override_is_ignored_with_an_error() -> void:
	service.free()
	service = null
	_write_bindings({"file.save": "Ctrl+NotAKey"})

	service = ServiceScript.new()
	service.path = TEST_PATH
	service.setup(registry)
	var loaded: Dictionary = service.load_bindings()

	assert_false(loaded.get("ok", true), "the load reports the invalid entry")
	assert_true(str(loaded.get("error", "")).contains("file.save"))
	assert_eq(service.binding_for("file.save"), "Ctrl+S", "the default is still used")


func test_build_input_map_creates_discoverable_actions() -> void:
	var action: String = str(service.action_name("file.save"))
	assert_eq(action, "cmd_file_save")
	assert_true(InputMap.has_action(action), "the action exists")
	assert_false(InputMap.action_get_events(action).is_empty(), "the action has a key event")

	var event: InputEventKey = InputMap.action_get_events(action)[0]
	assert_eq(int(event.physical_keycode), KEY_S)
	assert_true(event.ctrl_pressed)

	service.set_binding("file.save", "Ctrl+Alt+S")
	assert_eq(int(InputMap.action_get_events(action)[0].physical_keycode), KEY_S)
	assert_true(InputMap.action_get_events(action)[0].alt_pressed, "rebuilding follows the override")


func test_new_command_is_synced_after_load() -> void:
	registry.register("plugin.hello", {
		"label": "Plugin Hello", "category": "Other", "scope": "editor",
		"shortcut": "Ctrl+Alt+J", "handler": func() -> void: pass,
	})
	assert_eq(service.binding_for("plugin.hello"), "Ctrl+Alt+J", "the default is captured on registration")
	assert_eq(service.default_for("plugin.hello"), "Ctrl+Alt+J")
	assert_false(service.chord_for("plugin.hello").is_empty(), "the chord is parsed")
	assert_eq(str(registry.get_command("plugin.hello").get("shortcut", "")), "Ctrl+Alt+J")
	assert_eq(service.handle(_key_event(KEY_J, true, false, true), "editor"), "plugin.hello", "the shortcut routes")
	assert_true(InputMap.has_action(service.action_name("plugin.hello")), "the InputMap action is created")


func test_unregistered_command_stops_routing() -> void:
	service.set_binding("file.save", "Ctrl+Alt+U")
	assert_true(registry.unregister("file.save"))
	assert_eq(service.handle(_key_event(KEY_U, true, false, true), "editor"), "", "a removed command no longer routes")
	assert_true(service.chord_for("file.save").is_empty())

	registry.register("file.save", {
		"label": "Save", "category": "File", "scope": "global", "shortcut": "Ctrl+S",
		"handler": func() -> void: pass,
	})
	assert_eq(service.binding_for("file.save"), "Ctrl+Alt+U", "the user override survives re-registration")


func test_unknown_command_cannot_be_bound() -> void:
	var result: Dictionary = service.set_binding("missing.command", "Ctrl+S")
	assert_false(result.get("ok", true))
	assert_true(str(result.get("error", "")).contains("Unknown"))
