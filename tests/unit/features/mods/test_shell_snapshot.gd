extends "res://tests/support/test_case.gd"

## Shell snapshot: capture, hide, restore and exact equality across 50 cycles,
## plus the screen-space inset maths the camera consumes.

const Snapshot = preload("res://src/features/mods/shell/shell_snapshot.gd")


class FakePanel:
	extends Control
	pass


func _panels() -> Dictionary:
	var host := Node.new()
	host.name = "Hud"

	var top := FakePanel.new()
	top.name = "TopBar"
	top.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	top.offset_bottom = 48.0
	top.z_index = 3
	host.add_child(top)

	var dock := FakePanel.new()
	dock.name = "Explorer"
	dock.anchor_left = 0.0
	dock.anchor_top = 0.0
	dock.anchor_right = 0.0
	dock.anchor_bottom = 1.0
	dock.offset_left = 0.0
	dock.offset_top = 48.0
	dock.offset_right = 320.0
	dock.offset_bottom = -20.0
	dock.z_index = 0
	host.add_child(dock)

	var hidden := FakePanel.new()
	hidden.name = "Minimap"
	hidden.visible = false
	hidden.offset_left = 980.0
	hidden.offset_top = 80.0
	hidden.offset_right = 1100.0
	hidden.offset_bottom = 400.0
	host.add_child(hidden)

	return {"top_bar": top, "explorer": dock, "minimap": hidden}


func test_capture_hide_restore_is_exact_for_fifty_cycles() -> void:
	var panels := _panels()
	var original := Snapshot.capture(panels, Vector2(1280, 720))
	check(bool(original.get("panels", {}).has("top_bar")), "every panel is captured")
	assert_eq(int((original.get("panels", {}) as Dictionary).size()), 3, "capture keeps all entries")

	for cycle in range(50):
		Snapshot.hide(panels)
		check(!(panels["top_bar"] as Control).visible, "cycle %d hides the top bar" % cycle)
		check(!(panels["explorer"] as Control).visible, "cycle %d hides the explorer" % cycle)
		assert_eq(Snapshot.hidden_count(panels), 3, "cycle %d hides every panel" % cycle)

		check(Snapshot.restore(original, panels), "cycle %d restores every panel" % cycle)
		check((panels["top_bar"] as Control).visible, "cycle %d restores the top bar" % cycle)
		check((panels["explorer"] as Control).visible, "cycle %d restores the explorer" % cycle)
		assert_false((panels["minimap"] as Control).visible, "cycle %d keeps the minimap hidden" % cycle)

		var after := Snapshot.capture(panels, Vector2(1280, 720))
		check(Snapshot.equals(original, after), "cycle %d snapshot equality" % cycle)


func test_restore_records_anchors_offsets_and_z_order() -> void:
	var panels := _panels()
	var original := Snapshot.capture(panels)
	var dock: Control = panels["explorer"]
	dock.anchor_bottom = 0.0
	dock.offset_left = 10.0
	dock.offset_right = 20.0
	dock.z_index = 9

	check(Snapshot.restore(original, panels), "restore succeeds")
	assert_eq(dock.anchor_bottom, 1.0, "anchor restored")
	assert_eq(dock.offset_right, 320.0, "offset restored")
	assert_eq(dock.z_index, 0, "z-order restored")
	check(Snapshot.equals(original, Snapshot.capture(panels)), "second capture equals the first")


func test_equals_is_deep_not_by_reference() -> void:
	var panels := _panels()
	var a := Snapshot.capture(panels)
	var b := Snapshot.capture(panels)
	check(Snapshot.equals(a, b), "two captures of unchanged nodes are equal")
	check(!Snapshot.equals(a, {"version": 1}), "different shapes are not equal")

	(panels["top_bar"] as Control).z_index = 12
	var c := Snapshot.capture(panels)
	check(!Snapshot.equals(a, c), "a changed z-order breaks equality")


func test_insets_are_the_distance_to_the_reserved_rectangle() -> void:
	var insets := Snapshot.insets_for(Rect2(280, 34, 640, 400), Vector2(1280, 720))
	assert_eq(insets["left"], 280.0, "left inset")
	assert_eq(insets["top"], 34.0, "top inset")
	assert_eq(insets["right"], 360.0, "right inset")
	assert_eq(insets["bottom"], 286.0, "bottom inset")


func test_insets_clamp_a_rectangle_bigger_than_the_window() -> void:
	var insets := Snapshot.insets_for(Rect2(-40, -10, 2000, 900), Vector2(1280, 720))
	assert_eq(insets["left"], 0.0, "negative origin clamps to zero")
	assert_eq(insets["top"], 0.0, "negative top clamps to zero")
	assert_eq(insets["right"], 0.0, "an oversized rect has no right inset")
	assert_eq(insets["bottom"], 0.0, "an oversized rect has no bottom inset")
