extends "res://tests/support/test_case.gd"

## Guide layout: ghost columns beyond the document line must get real rects.
## `TextEdit.get_rect_at_line_column` only accepts existing columns, and a
## completely empty document reports a zero rect for column zero. Anchoring
## every ghost cluster at that rect stacked the whole ghost on one point.

const Layout = preload("res://src/features/learning/guide/guide_layout.gd")


class FakeView:
	var lines: Array = [""]
	var caret := Vector2(42, 17)
	var height := 26.0
	var tab_size := 4
	var char_width := 8.0
	var origin_y := 0.0
	var style_top := 4.0
	var theme_font_size := 21

	func get_line_count() -> int:
		return lines.size()

	func get_line(index: int) -> String:
		return str(lines[index])

	func get_line_height() -> float:
		return height

	func get_tab_size() -> int:
		return tab_size

	func get_caret_draw_pos() -> Vector2:
		return caret

	func get_theme_font(_name: String) -> Font:
		return ThemeDB.fallback_font

	func get_theme_font_size(_name: String) -> int:
		return theme_font_size

	func get_theme_default_font() -> Font:
		return ThemeDB.fallback_font

	func get_theme_default_font_size() -> int:
		return 16

	func get_theme_stylebox(_name: String) -> StyleBox:
		var box := StyleBoxFlat.new()
		box.set_content_margin(SIDE_TOP, style_top)
		return box

	func get_rect_at_line_column(line: int, col: int) -> Rect2:
		if line < 0 or line >= lines.size():
			return Rect2(-1, -1, 0, 0)
		var text := str(lines[line])
		if col < 0 or col > text.length():
			return Rect2(-1, -1, 0, 0)
		if text.is_empty():
			if line == 0:
				# Godot returns this for the only line of an empty document.
				return Rect2(0, 0, 0, 0)
			return Rect2(caret.x, origin_y + float(line) * height, 0.0, height)
		# TextEdit's rect describes the cell that *ends* at the caret:
		# column 0 and 1 both point at character zero.
		var cell := maxi(0, col - 1)
		var x := caret.x + float(cell) * char_width
		return Rect2(x, origin_y + float(line) * height, char_width, height)


func _font() -> Font:
	return ThemeDB.fallback_font


func _ghost(clusters: Array, line: int = 0) -> Dictionary:
	return {"lines": [{"line": line, "col": int(clusters[0].get("col", 0)), "clusters": clusters}]}


func test_empty_document_anchors_at_the_caret_origin() -> void:
	var view := FakeView.new()
	var entries := Layout.cluster_rects(view, _ghost([
		{"line": 0, "col": 0, "text": "i"},
		{"line": 0, "col": 1, "text": "d"},
		{"line": 0, "col": 2, "text": " "},
	]), _font(), 16)

	assert_eq(entries.size(), 3, "one rect per drawable cluster")
	if entries.size() != 3:
		return
	check(is_equal_approx((entries[0]["rect"] as Rect2).position.x, 42.0), "the first ghost glyph starts at the caret x")
	check(is_equal_approx((entries[0]["rect"] as Rect2).position.y, 4.0), "the empty document uses the editor's top margin, not y=0")
	check((entries[1]["rect"] as Rect2).position.x > (entries[0]["rect"] as Rect2).position.x, "the second glyph is to the right")
	check((entries[2]["rect"] as Rect2).position.x > (entries[1]["rect"] as Rect2).position.x, "every glyph has its own x")
	check(is_equal_approx((entries[0]["rect"] as Rect2).size.y, 26.0), "the rect carries the line height")

	var box := Layout.position_rect(view, 0, 0, _font(), 16)
	check(is_equal_approx(box.position.x, 42.0), "the next-cluster box also uses the caret x")
	check(is_equal_approx(box.position.y, 4.0), "the next-cluster box also uses the editor's top margin")


func test_ghost_uses_the_editor_theme_font_and_baseline() -> void:
	var view := FakeView.new()
	assert_eq(Layout.view_font_size(view), 21, "the ghost uses the editor's theme font size, not the 16 px fallback")
	check(Layout.view_font(view) != null, "the ghost gets a font")

	var expected := maxf(0.0, (26.0 - _font().get_height(16)) * 0.5) + _font().get_ascent(16)
	check(is_equal_approx(Layout.baseline_offset(view, _font(), 16), expected), "the baseline includes the editor's leading")
	check(Layout.baseline_offset(view, _font(), 16) > _font().get_ascent(16), "line spacing is split above and below the text")


func test_ghost_past_the_typed_prefix_advances_by_font_widths() -> void:
	var view := FakeView.new()
	view.lines = ["id = "]
	view.height = 27.0
	view.origin_y = 4.0
	var entries := Layout.cluster_rects(view, _ghost([
		{"line": 0, "col": 5, "text": "e"},
		{"line": 0, "col": 6, "text": "x"},
		{"line": 0, "col": 7, "text": "a"},
	]), _font(), 16)

	assert_eq(entries.size(), 3, "the remainder is laid out")
	if entries.size() != 3:
		return
	var prefix_width := _font().get_string_size("id = ", HORIZONTAL_ALIGNMENT_LEFT, -1, 16).x
	var x0 := (entries[0]["rect"] as Rect2).position.x
	var x1 := (entries[1]["rect"] as Rect2).position.x
	var x2 := (entries[2]["rect"] as Rect2).position.x
	check(is_equal_approx(x0, 42.0 + prefix_width), "the ghost starts at the end of the typed prefix")
	check(is_equal_approx((entries[0]["rect"] as Rect2).position.y, 4.0), "the ghost sits on the line top, not the caret baseline")
	check(is_equal_approx(x1 - x0, _font().get_string_size("e", HORIZONTAL_ALIGNMENT_LEFT, -1, 16).x), "the next glyph advances by the measured width")
	check(x2 > x1, "columns past the line do not collapse onto one rect")
	check((entries[0]["rect"] as Rect2).position.x >= 0.0, "no invalid rects are returned")


func test_block_ghost_places_lines_below_the_document() -> void:
	var view := FakeView.new()
	view.lines = ["a"]
	view.height = 26.0
	view.origin_y = 4.0
	var ghost := {
		"lines": [
			{"line": 0, "col": 0, "clusters": [{"line": 0, "col": 0, "text": "b"}]},
			{"line": 1, "col": 0, "clusters": [{"line": 1, "col": 0, "text": "c"}]},
			{"line": 2, "col": 0, "clusters": [{"line": 2, "col": 0, "text": "d"}]},
		],
	}
	var entries := Layout.cluster_rects(view, ghost, _font(), 16)
	assert_eq(entries.size(), 3, "three ghost lines")
	if entries.size() != 3:
		return
	check(is_equal_approx((entries[1]["rect"] as Rect2).position.y, 30.0), "line 1 sits one line lower")
	check(is_equal_approx((entries[2]["rect"] as Rect2).position.y, 56.0), "line 2 sits two lines lower")
	check(is_equal_approx((entries[1]["rect"] as Rect2).position.x, 42.0), "extra lines start at the text origin")

	var anchor := Layout.position_rect(view, 2, 0, _font(), 16)
	check(is_equal_approx(anchor.position.x, 42.0), "a position past the document uses the text origin")
	check(is_equal_approx(anchor.position.y, 56.0), "a position past the document uses the line height")
