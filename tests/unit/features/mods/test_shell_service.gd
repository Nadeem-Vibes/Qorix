extends "res://tests/support/test_case.gd"

## Shell takeover: exclusivity, layout validation, the single editor slot,
## inset application, exact restore and the panic path.

const Shell = preload("res://src/features/mods/shell/shell_service.gd")
const Snapshot = preload("res://src/features/mods/shell/shell_snapshot.gd")
const Result = preload("res://src/features/mods/mod_result.gd")

const MOD := "griddycode.shell_test"

var _panels: Dictionary = {}
var _layers: Array = []
var _insets: Array = []
var _markers: Array = []
var _world: Array = []
var _world_visible := true


class FakePanel:
	extends Control
	pass


func _build_panels() -> Dictionary:
	_panels = {}
	var host := Node.new()
	for name in ["TopBar", "Tabs", "Explorer"]:
		var panel := FakePanel.new()
		panel.name = name
		panel.offset_left = 4.0
		panel.offset_top = 4.0
		panel.offset_right = 120.0
		panel.offset_bottom = 40.0
		host.add_child(panel)
		_panels[name.to_lower()] = panel
	return _panels


func _service():
	_build_panels()
	_layers = []
	_insets = []
	_markers = []
	_world = []
	_world_visible = true

	var service = Shell.new()
	service.setup({
		"panels": Callable(self, "_panel_map"),
		"add_layer": Callable(self, "_add_layer"),
		"remove_layer": Callable(self, "_remove_layer"),
		"apply_insets": Callable(self, "_apply_insets"),
		"set_world_visible": Callable(self, "_set_world"),
		"ui": null,
		"mod_name": Callable(self, "_mod_name"),
		"set_shell_marker": Callable(self, "_marker"),
		"viewport_size": Callable(self, "_viewport"),
	})
	return service


func _panel_map() -> Dictionary:
	return _panels


func _add_layer(layer) -> void:
	_layers.append(layer)


func _remove_layer(layer) -> void:
	_layers.erase(layer)


func _apply_insets(values: Dictionary) -> void:
	_insets.append(values.duplicate(true))


func _set_world(visible: bool) -> Variant:
	var previous := _world_visible
	_world_visible = bool(visible)
	_world.append(bool(visible))
	return previous


func _marker(active: bool) -> void:
	_markers.append(bool(active))


func _mod_name(_id: String) -> String:
	return "Shell Test"


func _viewport() -> Vector2:
	return Vector2(1280, 720)


func _layout() -> Dictionary:
	return {
		"type": "hbox",
		"children": [
			{"type": "panel", "id": "nav", "width": 280, "children": [
				{"type": "heading", "id": "title", "text": "Lessons"},
			]},
			{"type": "vbox", "id": "main", "grow": 1, "children": [
				{"type": "editor", "id": "code", "grow": 1},
			]},
			{"type": "panel", "id": "coach", "width": 320, "children": [
				{"type": "label", "id": "body", "text": "Type."},
			]},
		],
	}


func test_takeover_snapshots_and_hides_then_exit_restores() -> void:
	var service = _service()
	var original := Snapshot.capture(_panels, Vector2(1280, 720))

	var taken: Dictionary = service.takeover(MOD, {"layout": _layout()})
	check(bool(taken.get("ok", false)), "takeover succeeds")
	assert_eq(str(service.state().get("owner", "")), MOD, "owner recorded")
	assert_true(bool(service.state().get("active", false)), "shell active")
	assert_eq(_layers.size(), 1, "one shell layer was added")
	assert_eq(_markers, [true], "the crash marker records the shell")
	check((_panels["topbar"] as Control) != null, "panels remain alive")
	assert_false((_panels["topbar"] as Control).visible, "the top bar is hidden, not freed")
	assert_false((_panels["tabs"] as Control).visible, "tabs are hidden")
	assert_false((_panels["explorer"] as Control).visible, "the explorer is hidden")

	var exited: Dictionary = service.exit(MOD, "test")
	check(bool(exited.get("ok", false)), "exit succeeds")
	assert_eq(_layers.size(), 0, "the layer was removed")
	assert_eq(_markers, [true, false], "the crash marker was cleared")
	check((_panels["topbar"] as Control).visible, "the top bar is visible again")
	check((_panels["explorer"] as Control).visible, "the explorer is visible again")
	check(Snapshot.equals(original, Snapshot.capture(_panels, Vector2(1280, 720))), "snapshot equality after exit")
	assert_eq(bool(_insets[-1].get("active", true)), false, "the camera insets were dropped")


func test_shell_is_exclusive() -> void:
	var service = _service()
	service.takeover(MOD, {"layout": _layout()})
	var other: Dictionary = service.takeover("griddycode.other", {"layout": _layout()})
	assert_eq(Result.code_of(other), "shell.busy", "a second owner is refused")


func test_one_editor_slot_is_enforced() -> void:
	var service = _service()
	var layout := {
		"type": "hbox",
		"children": [
			{"type": "editor", "id": "one"},
			{"type": "editor", "id": "two"},
		],
	}
	assert_eq(Result.code_of(service.takeover(MOD, {"layout": layout})), "shell.editor_slot")


func test_invalid_layouts_are_refused_before_any_state_changes() -> void:
	var service = _service()
	assert_eq(Result.code_of(service.takeover(MOD, {})), "shell.invalid_spec")
	assert_eq(Result.code_of(service.takeover(MOD, {"layout": {"type": "label"}})), "shell.invalid_spec")
	assert_false(bool(service.state().get("active", true)), "a refused takeover leaves no shell")
	check((_panels["topbar"] as Control).visible, "panels were not hidden by a refused takeover")


func test_custom_insets_are_clamped_and_reported() -> void:
	var service = _service()
	service.takeover(MOD, {"layout": _layout()})
	var applied: Dictionary = service.set_content_insets(MOD, {"left": 120, "top": -4, "right": "no", "bottom": 20})
	assert_eq(Result.code_of(applied), "shell.insets_invalid", "a non-number is refused")

	check(bool(service.set_content_insets(MOD, {"left": 120, "top": -4, "right": 80, "bottom": 20}).get("ok", false)), "valid insets apply")
	var state: Dictionary = service.state()
	assert_eq(float(state.get("insets", {}).get("left", 0.0)), 120.0, "left inset recorded")
	assert_eq(float(state.get("insets", {}).get("top", -1.0)), 0.0, "negative inset clamps to zero")
	assert_true(bool(state.get("custom_insets", false)), "custom insets flag")
	assert_eq(bool(_insets[-1].get("active", false)), true, "the camera was told to frame")


func test_editor_visibility_is_host_restored() -> void:
	var service = _service()
	service.takeover(MOD, {"layout": _layout(), "editor_visible": false})
	assert_eq(_world, [false], "the world was hidden")
	check(bool(service.set_editor_visible(MOD, true).get("ok", false)), "visibility can be changed")
	assert_eq(_world[-1], true, "the world was shown")
	service.exit(MOD, "done")
	assert_eq(_world[-1], true, "exit restores the recorded world visibility")


func test_panic_exits_quickly_and_reports_the_shell() -> void:
	var service = _service()
	service.takeover(MOD, {"layout": _layout()})
	var started := Time.get_ticks_msec()
	var result: Dictionary = service.panic()
	var elapsed := Time.get_ticks_msec() - started
	check(bool(result.get("had_shell", false)), "panic reports an exited shell")
	assert_eq(str(result.get("owner", "")), MOD, "panic names the owner")
	assert_false(bool(service.state().get("active", true)), "the shell is gone")
	check(elapsed < 100, "panic exits within 100 ms (took %d ms)" % elapsed)
	check((_panels["topbar"] as Control).visible, "panic restored the HUD")

	var again: Dictionary = service.panic()
	assert_false(bool(again.get("had_shell", true)), "a second panic with no shell reports nothing to exit")


func test_reset_mod_only_exits_its_own_shell() -> void:
	var service = _service()
	service.takeover(MOD, {"layout": _layout()})
	service.reset_mod("griddycode.other")
	assert_true(bool(service.state().get("active", false)), "a foreign reset leaves the shell alone")
	service.reset_mod(MOD)
	assert_false(bool(service.state().get("active", true)), "the owner's reset exits")
