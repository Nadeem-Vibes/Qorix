extends RefCounted

## Ghost geometry shared by the overlay and the hint layer.
##
## Ghost text is not part of the document, so a column past the end of the
## real line does not exist for `TextEdit.get_rect_at_line_column`: Godot
## returns `(-1, -1, 0, 0)` and logs an error. The editor also returns a
## zero rect for column 0 of a completely empty document. Anchoring every
## ghost cluster at that rect stacked the whole ghost on one point.
##
## This module anchors at the last real position and advances the rest of the
## slice with the same font the editor draws. A line past the end of the
## document is placed below the last line with the editor's line height.

const TAB_FALLBACK := 4


## The editor draws with its theme font, not with the engine fallback. Ghost
## text measured with the wrong font drifts horizontally and is the wrong size.
static func view_font(view) -> Font:
	if view != null and view.has_method("get_theme_font"):
		var themed: Font = view.get_theme_font("font")
		if themed != null:
			return themed
	if view != null and view.has_method("get_theme_default_font"):
		return view.get_theme_default_font()
	return null


static func view_font_size(view) -> int:
	if view != null and view.has_method("get_theme_font_size"):
		var themed := int(view.get_theme_font_size("font_size"))
		if themed > 0:
			return themed
	if view != null and view.has_method("get_theme_default_font_size"):
		var fallback := int(view.get_theme_default_font_size())
		if fallback > 0:
			return fallback
	return 16


static func line_height(view, font: Font, font_size: int) -> float:
	if view != null and view.has_method("get_line_height"):
		var measured := float(view.get_line_height())
		if measured > 0.0:
			return measured
	if font != null:
		return maxf(1.0, font.get_height(font_size))
	return maxf(1.0, float(font_size))


## Offset from the top of the line cell to the font baseline. TextEdit centres
## the shaped line inside the row (the row includes line spacing), so the ghost
## must add that leading before its ascent.
static func baseline_offset(view, font: Font, font_size: int) -> float:
	if font == null:
		return 0.0
	var leading := maxf(0.0, (line_height(view, font, font_size) - font.get_height(font_size)) * 0.5)
	return leading + font.get_ascent(font_size)


static func text_origin(view, font: Font, font_size: int) -> Vector2:
	if view == null:
		return Vector2.ZERO

	var x := 0.0
	var y := 0.0
	var valid := false
	if view.has_method("get_rect_at_line_column"):
		var rect: Rect2 = view.get_rect_at_line_column(0, 0)
		# A completely empty document reports (0, 0, 0, 0) for column zero.
		valid = rect.size.y > 0.0
		if valid:
			x = rect.position.x
			y = rect.position.y

	# The caret still knows the real text origin on the first line.
	if x <= 0.0 and view.has_method("get_caret_draw_pos"):
		x = float(view.get_caret_draw_pos().x)
	if y <= 0.0:
		y = _top_margin(view)
	return Vector2(x, y)


## Top content margin of the editor stylebox, i.e. the top of line zero.
static func _top_margin(view) -> float:
	if view == null or !view.has_method("get_theme_stylebox"):
		return 0.0
	var style: StyleBox = view.get_theme_stylebox("normal")
	if style == null and view.has_method("get_theme_stylebox"):
		style = view.get_theme_stylebox("read_only")
	if style == null:
		return 0.0
	return maxf(0.0, style.get_margin(SIDE_TOP))


static func position_rect(view, line: int, col: int, font: Font, font_size: int) -> Rect2:
	if view == null or font == null or font_size <= 0:
		return Rect2()
	if line < 0:
		return Rect2()

	var height := line_height(view, font, font_size)
	var origin := text_origin(view, font, font_size)
	var count := _line_count(view)
	var anchor := _line_anchor(view, line, col, font, font_size, height, count, origin)

	# The anchor is the caret position. The box covers the character that
	# starts there, or a one-pixel caret cell at the end of the line.
	var width := 1.0
	if line < count:
		var text := _line_text(view, line)
		var at := clampi(col, 0, text.length())
		if at < text.length():
			width = maxf(1.0, _measure(font, font_size, text.substr(at, 1), anchor.x, _tab_size(view)))
	return Rect2(anchor.x, anchor.y, width, height)


## Returns one entry per drawable ghost cluster:
##   {line, col, text, rect}
## `rect` is in the view's local coordinates and has the editor's line height.
static func cluster_rects(view, ghost: Dictionary, font: Font, font_size: int) -> Array:
	var out: Array = []
	if view == null or font == null or font_size <= 0:
		return out

	var height := line_height(view, font, font_size)
	var count := _line_count(view)
	var origin := text_origin(view, font, font_size)
	var tab := _tab_size(view)
	var lines: Variant = ghost.get("lines", [])
	if !(lines is Array):
		return out

	for line_entry in lines:
		if !(line_entry is Dictionary):
			continue
		var clusters: Variant = (line_entry as Dictionary).get("clusters", [])
		if !(clusters is Array) or (clusters as Array).is_empty():
			continue

		var line := int((line_entry as Dictionary).get("line", 0))
		var first: Dictionary = (clusters as Array)[0]
		var start_col := maxi(0, int(first.get("col", 0)))
		var anchor := _line_anchor(view, line, start_col, font, font_size, height, count, origin)
		var x := anchor.x
		var y := anchor.y

		for cluster in clusters:
			var text := str((cluster as Dictionary).get("text", ""))
			if text.is_empty() or text == "\n":
				continue
			var width := _measure(font, font_size, text, x, tab)
			out.append({
				"line": line,
				"col": int((cluster as Dictionary).get("col", 0)),
				"text": text,
				"rect": Rect2(x, y, maxf(1.0, width), height),
			})
			x += width
	return out


## Caret position for `start_col` on `line`. TextEdit's
## `get_rect_at_line_column(line, col)` describes the cell that *ends* at the
## caret, so its right edge is the caret's x. The prefix is measured from the
## line start instead of trusting the integer cell, which keeps animating
## carets and ghost glyphs on the same fractional position.
static func _line_anchor(
	view,
	line: int,
	start_col: int,
	font: Font,
	font_size: int,
	height: float,
	count: int,
	origin: Vector2,
) -> Vector2:
	if line < 0:
		return origin

	var line_top := origin.y + float(line) * height
	var line_start := origin.x
	if line < count and view.has_method("get_rect_at_line_column"):
		var zero: Rect2 = view.get_rect_at_line_column(line, 0)
		if zero.position.x >= 0.0 and zero.size.y > 0.0:
			line_start = zero.position.x
		var cell: Rect2 = view.get_rect_at_line_column(line, clampi(start_col, 0, _line_text(view, line).length()))
		if cell.size.y > 0.0 and cell.position.y >= 0.0:
			line_top = cell.position.y

	var text := _line_text(view, line) if line < count else ""
	var prefix := text.substr(0, clampi(start_col, 0, text.length()))
	return Vector2(line_start + _measure(font, font_size, prefix, line_start, _tab_size(view)), line_top)


static func _measure(font: Font, font_size: int, text: String, start_x: float, tab_size: int) -> float:
	if !text.contains("\t"):
		return font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x

	# TextEdit expands tabs to the next tab stop, measured in space widths.
	var space := font.get_char_size(0x20, font_size).x
	var tab := maxf(1.0, float(tab_size) * space)
	var width := 0.0
	for index in range(text.length()):
		var character := text[index]
		if character == "\t":
			width += tab - fmod(start_x + width, tab)
		else:
			width += font.get_char_size(character.unicode_at(0), font_size).x
	return width


static func _line_count(view) -> int:
	if view != null and view.has_method("get_line_count"):
		return maxi(0, int(view.get_line_count()))
	return 1


static func _line_text(view, line: int) -> String:
	if view != null and view.has_method("get_line"):
		return str(view.get_line(line))
	return ""


static func _tab_size(view) -> int:
	if view != null and view.has_method("get_tab_size"):
		return maxi(1, int(view.get_tab_size()))
	return TAB_FALLBACK
