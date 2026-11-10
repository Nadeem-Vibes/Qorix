extends "res://tests/support/test_case.gd"

## Phase 2 partial UI: declarative catalog, slot registry, in-place widget
## diffing, event routing, modal value collection and the mods settings page.

const Catalog = preload("res://src/features/mods/ui/mod_widget_catalog.gd")
const Ui = preload("res://src/features/mods/ui/mod_ui_registry.gd")
const SettingsPanel = preload("res://src/features/mods/ui/mod_settings_panel.gd")
const ModShell = preload("res://src/features/mods/shell/mod_shell.gd")
const Result = preload("res://src/features/mods/mod_result.gd")

const MOD := "griddycode.ui_test"


class FakeManager:
	var toggles: Array = []

	func installed() -> Array:
		return [{"id": MOD, "name": "UI Test", "version": "1.0.0", "root": "", "hash": ""}]

	func state(id: String) -> Dictionary:
		return {"id": id, "name": "UI Test", "status": "active", "reason": "", "missing_permissions": []}

	func pending_activations() -> int:
		return 0

	func settings_for(id: String) -> Dictionary:
		return {
			"definitions": [
				{"key": "enabled", "type": "bool", "label": "Enabled", "default": true},
				{"key": "label", "type": "string", "label": "Label", "default": "Hello"},
			],
			"values": {"enabled": true, "label": "Hello"},
		}

	func set_mod_setting(id: String, key: String, value: Variant) -> Dictionary:
		toggles.append([id, key, value])
		return {"ok": true}

	func set_enabled(id: String, enabled: bool, reason: String = "") -> Dictionary:
		return {"ok": true}

	func reload_mod(id: String) -> Dictionary:
		return {"ok": true}

	func grant_consent(id: String, permissions: Array = []) -> Dictionary:
		return {"ok": true}


var ui
var dispatch_calls: Array = []
var notifications: Array = []
var layout_calls: Array = []


func before_each() -> void:
	dispatch_calls.clear()
	notifications.clear()
	layout_calls.clear()
	ui = Ui.new()
	Engine.get_main_loop().root.add_child(ui)
	# The headless runner's root is not processing yet when a suite runs, so a
	# newly added Control does not receive _ready(). Build it explicitly.
	if ui._right_column == null:
		ui._ready()
	ui.setup({
		"dispatch": Callable(self, "_dispatch"),
		"notify": Callable(self, "_notify"),
		"set_core_visible": Callable(self, "_set_core_visible"),
	})


func after_each() -> void:
	if is_instance_valid(ui):
		ui.free()
	ui = null


func _dispatch(mod_id: String, handle: int, payload: Variant) -> Dictionary:
	dispatch_calls.append({"mod_id": mod_id, "handle": handle, "payload": payload})
	return Result.ok(true)


func _notify(text: String, severity: String) -> void:
	notifications.append([text, severity])


func _set_core_visible(panel: String, visible: bool) -> Variant:
	if panel == "unknown":
		return null
	layout_calls.append([panel, visible])
	return !visible


func test_catalog_validates_before_building() -> void:
	check(Catalog.validate({"type": "label", "text": "hi"}).get("ok", false), "label valid")
	check(!Catalog.validate({"type": "webview"}).get("ok", false), "unknown type rejected")
	check(!Catalog.validate({"type": "vbox", "children": [{"type": "label", "children": "no"}]}).get("ok", false), "bad children rejected")
	check(!Catalog.validate({"type": "vbox", "children": [{"type": "vbox", "id": 3}]}).get("ok", false), "non-string id rejected")

	var deep := {"type": "vbox", "children": []}
	var cursor := deep
	for index in range(10):
		var child := {"type": "vbox", "children": []}
		cursor["children"] = [child]
		cursor = child
	check(!Catalog.validate(deep).get("ok", false), "depth limit enforced")


func test_catalog_rows_and_panel_titles_keep_their_layout() -> void:
	var built = Catalog.new().build({
		"type": "vbox",
		"id": "root",
		"children": [
			{
				"type": "hbox",
				"id": "row",
				"children": [
					{"type": "label", "id": "title", "text": "C++ Learning Journey", "font_size": 18},
					{"type": "spacer", "id": "push", "grow": 1},
				],
			},
			{
				"type": "panel",
				"id": "card",
				"title": "Lessons",
				"children": [{"type": "label", "id": "body_label", "text": "Body"}],
			},
			{
				"type": "vbox",
				"id": "stack",
				"children": [
					{"type": "label", "id": "wrapped", "text": "A long line that should wrap inside a vertical stack."},
				],
			},
		],
	}, MOD)

	var title = built.find_child("ModWidget_title", true, false)
	check(title is Label, "the row title builds")
	if title is Label:
		check((title as Label).autowrap_mode == TextServer.AUTOWRAP_OFF, "row labels keep their text width")
		check((title as Label).get_combined_minimum_size().x > 50.0, "the row title has a usable minimum width")

	var wrapped = built.find_child("ModWidget_wrapped", true, false)
	check(wrapped is Label, "the vertical-stack label builds")
	if wrapped is Label:
		check((wrapped as Label).autowrap_mode == TextServer.AUTOWRAP_WORD_SMART, "vertical-stack labels still wrap")

	var card = built.find_child("ModWidget_card", true, false)
	check(card is PanelContainer, "the titled panel builds")
	if card is PanelContainer:
		assert_eq((card as PanelContainer).get_child_count(), 1, "a panel has one frame child")
		var frame = (card as PanelContainer).get_child(0)
		var title_row = frame.get_node_or_null("TitleRow")
		var body = frame.get_node_or_null("Body")
		check(title_row is Control, "the panel title has its own row")
		check(body is Control, "the panel body survives beside the title")
		if title_row is Control and body is Control:
			check((title_row as Control).get_index() < (body as Control).get_index(), "the title row precedes the body")


func test_mount_update_diffing_and_unmount() -> void:
	var mounted: Dictionary = ui.mount(MOD, "right", {
		"type": "panel",
		"id": "dock",
		"title": "Counter",
		"children": [
			{"type": "label", "id": "count", "text": "0"},
			{"type": "button", "id": "bump", "text": "+1"},
		],
	})
	check(mounted.get("ok", false), "mount succeeds")
	var panel_id := str(mounted.get("value", ""))
	assert_eq(panel_id, MOD + ".dock")
	assert_eq(ui.mount_count(MOD), 1)

	var label = ui._node_for(MOD, MOD + ".count")
	check(label is Label, "label indexed")
	assert_eq((label as Label).text, "0")

	var updated: Dictionary = ui.update(MOD, panel_id, {
		"type": "panel",
		"title": "Counter",
		"children": [
			{"type": "label", "id": "count", "text": "1"},
			{"type": "button", "id": "bump", "text": "+1"},
		],
	})
	check(updated.get("ok", false), "update succeeds")
	assert_eq(ui._node_for(MOD, MOD + ".count"), label, "label node reused")
	assert_eq((label as Label).text, "1", "label text updated")

	var full: Dictionary = ui.mount(MOD, "right", {"type": "label", "id": "one"})
	check(full.get("ok", false), "second mount fits")
	for index in range(2):
		check(ui.mount(MOD, "right", {"type": "label", "id": "extra%d" % index}).get("ok", false), "slot has room")
	var overflow: Dictionary = ui.mount(MOD, "right", {"type": "label", "id": "overflow"})
	assert_eq(Result.code_of(overflow), "ui.slot_full")

	check(ui.unmount(MOD, panel_id).get("ok", false), "unmount succeeds")
	assert_eq(ui.mount_count(MOD), 3)


func test_widget_events_route_to_the_owner_only() -> void:
	ui.mount(MOD, "right", {"type": "panel", "id": "panel", "children": [{"type": "button", "id": "go", "text": "Go"}]})
	check(ui.on(MOD, MOD + ".go", "click", 42).get("ok", false), "handler registered")

	ui._on_widget_event(MOD + ".go", "click", {"text": "Go"})
	assert_eq(dispatch_calls.size(), 1, "one handler call")
	assert_eq(dispatch_calls[0].get("mod_id"), MOD)
	assert_eq(dispatch_calls[0].get("handle"), 42)
	assert_eq(dispatch_calls[0].get("payload", {}).get("source"), MOD + ".go")

	ui._on_widget_event("othermod.go", "click", {})
	assert_eq(dispatch_calls.size(), 1, "foreign widget is ignored")
	assert_eq(Result.code_of(ui.on(MOD, MOD + ".missing", "click", 1)), "ui.widget_invalid")


func test_child_widget_events_use_the_local_id() -> void:
	var mounted: Dictionary = ui.mount(MOD, "right", {
		"type": "panel",
		"id": "panel",
		"children": [{"type": "button", "id": "go", "text": "Go"}],
	})
	check(bool(mounted.get("ok", false)), "panel mounts")
	var panel_id := str(mounted.get("value", ""))
	assert_eq(panel_id, MOD + ".panel", "mount returns the root widget id")

	# Callers pass the child's local id (or the full <mod_id>.<local_id>).
	# mount_id is the panel id and is deliberately not a prefix for children.
	check(ui.on(MOD, "go", "click", 77).get("ok", false), "local child id registers a handler")
	var button = ui._nodes.get(MOD + ".go")
	check(button is Button, "the button is indexed by <mod_id>.<local_id>")
	if button is Button:
		(button as Button).pressed.emit()
	assert_eq(dispatch_calls.size(), 1, "pressing the button dispatches once")
	assert_eq(dispatch_calls[0].get("handle"), 77)
	assert_eq(dispatch_calls[0].get("payload", {}).get("source"), MOD + ".go")


func test_handlers_survive_in_place_updates() -> void:
	var mounted: Dictionary = ui.mount(MOD, "right", {
		"type": "panel",
		"id": "panel",
		"children": [
			{"type": "label", "id": "count", "text": "0"},
			{"type": "button", "id": "bump", "text": "+1"},
		],
	})
	check(bool(mounted.get("ok", false)), "panel mounts")
	var panel_id := str(mounted.get("value", ""))
	check(ui.on(MOD, "bump", "click", 91).get("ok", false), "handler registered")

	var updated: Dictionary = ui.update(MOD, panel_id, {
		"type": "panel",
		"id": "panel",
		"children": [
			{"type": "label", "id": "count", "text": "1"},
			{"type": "button", "id": "bump", "text": "+1"},
		],
	})
	check(bool(updated.get("ok", false)), "in-place update succeeds")

	var button = ui._nodes.get(MOD + ".bump")
	check(button is Button, "the updated button keeps its id")
	if button is Button:
		(button as Button).pressed.emit()
	assert_eq(dispatch_calls.size(), 1, "the handler still fires after an update")
	assert_eq(dispatch_calls[0].get("handle"), 91)

	var removed: Dictionary = ui.update(MOD, panel_id, {
		"type": "panel",
		"id": "panel",
		"children": [{"type": "label", "id": "count", "text": "1"}],
	})
	check(bool(removed.get("ok", false)), "a removed child updates cleanly")
	check(!ui._handlers.has(MOD + ".bump"), "handlers for removed widgets are pruned")


func test_modal_collects_input_values_and_closes() -> void:
	var opened: Dictionary = ui.dialog(MOD, {
		"title": "Name",
		"message": "Pick a name",
		"body": {"type": "vbox", "children": [{"type": "input", "id": "value", "text": "Ada"}]},
		"confirm": "Save",
		"cancel": "Cancel",
	})
	check(opened.get("ok", false), "dialog opens")
	var dialog_id := str(opened.get("value", ""))
	assert_eq(ui.dialog_count(), 1)
	assert_eq(ui.on(MOD, dialog_id, "click", 7).get("ok", false), true, "dialog handler registered")

	var input = ui._node_for(MOD, MOD + ".value")
	check(input is LineEdit, "input indexed")
	(input as LineEdit).text = "Grace"

	var buttons := _buttons(ui._node_for(MOD, dialog_id))
	var confirm: Button = null
	for button in buttons:
		if button.text == "Save":
			confirm = button
	check(confirm != null, "confirm button exists")
	confirm.pressed.emit()

	assert_eq(dispatch_calls.size(), 1, "dialog callback ran")
	var payload: Dictionary = dispatch_calls[0].get("payload", {})
	assert_eq(str(payload.get("value", "")), "Grace", "typed value reached the callback")
	assert_eq(payload.get("values", {}).get("value", ""), "Grace")
	assert_eq(ui.dialog_count(), 0, "dialog closed after the button")

	var close_missing: Dictionary = ui.close_dialog(MOD, "nope")
	check(close_missing.get("ok", false), "closing a missing dialog is a no-op")


func test_theme_tokens_and_layout_overrides() -> void:
	var token: Dictionary = ui.theme_token("accent")
	check(token.get("ok", false), "known token")
	check(str(token.get("value", "")).begins_with("#"), "token is a hex colour")
	assert_eq(Result.code_of(ui.theme_token("not_a_token")), "api.bad_args")

	var layout: Dictionary = ui.set_core_panel_visible(MOD, "terminal", false)
	check(layout.get("ok", false), "layout override accepted")
	assert_eq(layout_calls.size(), 1)
	assert_eq(layout_calls[0], ["terminal", false])
	assert_eq(Result.code_of(ui.set_core_panel_visible(MOD, "unknown", false)), "api.bad_args")

	ui.reset_mod(MOD)
	assert_eq(layout_calls.size(), 2, "reset restored every hidden panel")
	assert_eq(layout_calls[1], ["terminal", true])


func test_notify_and_slot_validation() -> void:
	check(ui.notify("hello", "warning").get("ok", false), "notify succeeds")
	assert_eq(notifications, [["hello", "warning"]])
	assert_eq(Result.code_of(ui.mount(MOD, "left", {"type": "label"})), "ui.widget_invalid")
	assert_eq(Result.code_of(ui.mount(MOD, "right", {"type": "unknown"})), "ui.widget_invalid")


func test_settings_page_renders_definitions() -> void:
	var manager := FakeManager.new()
	var panel := SettingsPanel.new()
	panel.setup(manager)
	Engine.get_main_loop().root.add_child(panel)
	if panel._list == null:
		panel._ready()
	panel.open()
	check(panel.visible, "settings page opens")
	check(panel._list.get_child_count() >= 1, "mod card rendered")
	panel.free()


func test_shell_layout_routes_clicks_and_passes_editor_input() -> void:
	var shell = ModShell.new()
	shell.setup(
		{
			"type": "hbox",
			"id": "root",
			"children": [
				{
					"type": "vbox",
					"id": "middle",
					"grow": 1,
					"children": [
						{"type": "editor", "id": "code", "grow": 1},
						{"type": "button", "id": "start", "text": "Start"},
					],
				},
			],
		},
		"UI Test",
		MOD,
		ui,
	)
	Engine.get_main_loop().root.add_child(shell)
	var layout := shell.layout_root()
	check(layout != null, "the shell builds a layout")
	if layout == null:
		shell.free()
		return
	assert_eq(layout.mouse_filter, Control.MOUSE_FILTER_IGNORE, "the shell root does not swallow editor clicks")
	var middle = layout.find_child("ModWidget_middle", true, false)
	check(middle is VBoxContainer, "the center column builds")
	if middle is VBoxContainer:
		assert_eq((middle as VBoxContainer).mouse_filter, Control.MOUSE_FILTER_IGNORE, "layout columns pass input through")
	var slot = layout.find_child("ModWidget_code", true, false)
	check(slot is Control, "the editor slot builds")
	if slot is Control:
		assert_eq((slot as Control).mouse_filter, Control.MOUSE_FILTER_IGNORE, "the editor slot passes input through")

	check(ui.on(MOD, "start", "click", 91).get("ok", false), "the shell button can be bound")
	var start_button = layout.find_child("ModWidget_start", true, false)
	check(start_button is Button, "the shell start button builds")
	if start_button is Button:
		(start_button as Button).pressed.emit()
	assert_eq(dispatch_calls.size(), 1, "a real shell button click reaches the handler")
	if dispatch_calls.size() == 1:
		assert_eq(str(dispatch_calls[0].get("mod_id", "")), MOD, "the handler is namespaced to the mod")
		assert_eq(int(dispatch_calls[0].get("handle", 0)), 91, "the registered handler ran")
		assert_eq(str(dispatch_calls[0].get("payload", {}).get("source", "")), MOD + ".start", "the event carries the shell widget id")

	Engine.get_main_loop().root.remove_child(shell)
	shell.free()


func test_shell_hands_focus_back_to_the_code_view() -> void:
	var focus_calls := [0]
	var restore := func() -> void: focus_calls[0] += 1

	var shell = ModShell.new()
	shell.setup(
		{
			"type": "hbox",
			"id": "root",
			"children": [
				{"type": "vbox", "id": "middle", "grow": 1, "children": [
					{"type": "editor", "id": "code", "grow": 1},
					{"type": "button", "id": "start", "text": "Start"},
				]},
			],
		},
		"UI Test",
		MOD,
		ui,
		Callable(),
		restore,
	)
	Engine.get_main_loop().root.add_child(shell)
	assert_eq(focus_calls[0], 1, "takeover with an editor slot hands focus back to the code view")

	check(ui.on(MOD, "start", "click", 91).get("ok", false), "the shell button can bind")
	var button = shell.layout_root().find_child("ModWidget_start", true, false)
	check(button is Button, "the shell start button builds")
	if button is Button:
		(button as Button).pressed.emit()
	assert_eq(focus_calls[0], 2, "a shell button press hands focus back to the code view")
	assert_eq(dispatch_calls.size(), 1, "the press still reaches the handler")
	Engine.get_main_loop().root.remove_child(shell)
	shell.free()


func test_shell_without_an_editor_slot_leaves_focus_alone() -> void:
	var focus_calls := [0]
	var restore := func() -> void: focus_calls[0] += 1

	var shell = ModShell.new()
	shell.setup(
		{
			"type": "hbox",
			"id": "root",
			"children": [
				{"type": "button", "id": "go", "text": "Go"},
			],
		},
		"UI Test",
		MOD + ".quiz",
		ui,
		Callable(),
		restore,
	)
	Engine.get_main_loop().root.add_child(shell)
	assert_eq(focus_calls[0], 0, "no reserved code view, no focus theft at takeover")
	check(ui.on(MOD + ".quiz", "go", "click", 91).get("ok", false), "the button can bind")
	var button = shell.layout_root().find_child("ModWidget_go", true, false)
	check(button is Button, "the quiz button builds")
	if button is Button:
		(button as Button).pressed.emit()
	assert_eq(focus_calls[0], 0, "no reserved code view, no focus theft after events")
	assert_eq(dispatch_calls.size(), 1, "the quiz handler still runs")
	Engine.get_main_loop().root.remove_child(shell)
	shell.free()


func _buttons(node: Node) -> Array:
	var out: Array = []
	if node is Button:
		out.append(node)
	for child in node.get_children():
		out.append_array(_buttons(child))
	return out
