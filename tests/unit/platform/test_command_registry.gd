extends "res://tests/support/test_case.gd"

const RegistryScript = preload("res://src/platform/command_registry.gd")

var registry = null
var changes: int = 0


func before_each() -> void:
	registry = RegistryScript.new()
	changes = 0
	registry.changed.connect(func() -> void: changes += 1)


func after_each() -> void:
	registry = null


func test_register_normalizes_entry() -> void:
	var entry: Dictionary = registry.register("file.save", {
		"label": "Save",
		"category": "File",
		"shortcut": "Ctrl+S",
		"scope": "global",
	})
	assert_eq(str(entry.get("id", "")), "file.save")
	assert_eq(str(entry.get("label", "")), "Save")
	assert_eq(str(entry.get("default_shortcut", "")), "Ctrl+S")
	assert_eq(str(entry.get("scope", "")), "global")
	assert_eq(int(entry.get("toolbar_order", 0)), 100)
	assert_false(bool(entry.get("hidden", true)))
	assert_true(registry.has("file.save"))


func test_duplicate_registration_updates_in_place() -> void:
	registry.register("file.save", {"label": "Save", "category": "File"})
	registry.register("file.save", {"label": "Save File", "category": "File"})
	assert_eq(registry.all().size(), 1, "the command is not listed twice")
	assert_eq(str(registry.get_command("file.save").get("label", "")), "Save File")


func test_empty_id_is_ignored() -> void:
	var entry: Dictionary = registry.register("  ", {"label": "Nothing"})
	assert_true(entry.is_empty(), "an empty id returns an empty entry")
	assert_eq(registry.all().size(), 0)


func test_for_scope_includes_global_and_matching_scope() -> void:
	registry.register("file.save", {"scope": "global"})
	registry.register("edit.find", {"scope": "editor"})
	registry.register("terminal.clear", {"scope": "terminal"})
	registry.register("dialog.close", {"scope": "dialog"})

	var editor_ids := _ids(registry.for_scope("editor"))
	assert_true(editor_ids.has("file.save"), "global commands apply to the editor")
	assert_true(editor_ids.has("edit.find"), "editor commands apply to the editor")
	assert_false(editor_ids.has("terminal.clear"), "terminal commands do not leak into the editor")
	assert_false(editor_ids.has("dialog.close"), "dialog commands do not leak into the editor")

	var terminal_ids := _ids(registry.for_scope("terminal"))
	assert_true(terminal_ids.has("file.save"), "global commands apply to the terminal")
	assert_true(terminal_ids.has("terminal.clear"), "terminal commands apply to the terminal")
	assert_false(terminal_ids.has("edit.find"), "editor commands do not leak into the terminal")


func test_execute_calls_the_handler_with_args() -> void:
	var received: Array = []
	registry.register("test.echo", {
		"handler": func(a, b) -> void: received.append([a, b]),
	})
	var result: Dictionary = registry.execute("test.echo", ["one", 2])
	assert_true(result.get("ok", false), "execute succeeds")
	assert_eq(received.size(), 1)
	assert_eq(received[0], ["one", 2])


func test_execute_reports_unknown_and_disabled_commands() -> void:
	var unknown: Dictionary = registry.execute("missing.command")
	assert_false(unknown.get("ok", true), "unknown command fails")
	assert_true(str(unknown.get("error", "")).contains("Unknown"))

	registry.register("test.disabled", {
		"enabled": false,
		"handler": func() -> void: pass,
	})
	var disabled: Dictionary = registry.execute("test.disabled")
	assert_false(disabled.get("ok", true), "disabled command fails")
	assert_true(str(disabled.get("error", "")).contains("disabled"))


func test_enabled_and_checked_accept_callables() -> void:
	# A Dictionary is a reference, so the lambdas see later mutations. Plain
	# local variables would be captured by value.
	var state := {"allowed": false, "checked": false}
	registry.register("test.state", {
		"enabled": func() -> bool: return state.allowed,
		"checked": func() -> bool: return state.checked,
	})
	assert_false(registry.is_enabled("test.state"))
	assert_false(registry.is_checked("test.state"))

	state.allowed = true
	state.checked = true
	assert_true(registry.is_enabled("test.state"))
	assert_true(registry.is_checked("test.state"))


func test_batch_coalesces_changed_signals() -> void:
	registry.begin_batch()
	registry.register("a", {})
	registry.register("b", {})
	registry.register("c", {})
	assert_eq(changes, 0, "no signal while batching")
	registry.end_batch()
	assert_eq(changes, 1, "one signal after the batch")


func test_set_shortcut_and_unregister() -> void:
	registry.register("file.save", {"shortcut": "Ctrl+S"})
	assert_true(registry.set_shortcut("file.save", "Ctrl+Alt+S"))
	assert_eq(str(registry.get_command("file.save").get("shortcut", "")), "Ctrl+Alt+S")
	assert_false(registry.set_shortcut("missing", "Ctrl+S"))

	assert_true(registry.unregister("file.save"))
	assert_false(registry.has("file.save"))
	assert_false(registry.unregister("file.save"), "unregistering twice reports false")


func test_categories_follow_registration_order() -> void:
	registry.register("a", {"category": "File"})
	registry.register("b", {"category": "Edit"})
	registry.register("c", {"category": "File"})
	assert_eq(",".join(registry.categories()), "File,Edit")


func _ids(commands: Array) -> Array[String]:
	var out: Array[String] = []
	for command in commands:
		out.append(str(command.get("id", "")))
	return out
