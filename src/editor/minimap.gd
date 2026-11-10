class_name Minimap
extends Control

## Screen-space minimap for the camera-driven editor.
##
## Godot's built-in TextEdit minimap paints inside the control's own rect.
## In Qorix that rect is a 2044 x 44630 world-space canvas seen through
## a zoomed Camera2D, so the strip always ended up thousands of pixels off
## screen and the "Minimap" setting did nothing visible.
##
## This one lives in the HUD CanvasLayer instead: it is pinned to the right
## edge of the window whatever the camera is doing, it is drawn in screen
## space, and clicking it moves the caret — the camera follows the caret, so
## that is how this editor navigates.
##
## The strip is drawn the way a minimap should be: the file is tokenised and
## every word becomes its own little block, so the column shows the *shape*
## of the code instead of one solid bar per line.

const Scroll = preload("res://src/editor/scroll_math.gd")

const TOP_OFFSET := 62.0        ## below the top bar + tab strip
const REBUILD_INTERVAL := 0.25  ## seconds between cache rebuilds
const PADDING := 2.0            ## horizontal padding inside the strip
const MIN_CHARS := 24           ## a line this long fills the whole strip
const BAR_ALPHA := 0.75         ## the minimap is a hint, not the text itself
const INDENT_ALPHA := 0.22      ## the indentation is a hint of its own

var editor = null
var enabled: bool = true
var strip_width: int = 80
## Large-file mode hides the strip without changing the user's Minimap
## setting, so leaving the big file restores the previous choice.
var suppressed: bool = false

var _view: CodeEdit = null
var _marker: Panel

## The thumbnail: one entry per coloured run of characters, plus the
## per-line bookkeeping that maps lines onto runs.
var _run_starts := PackedInt32Array()
var _run_lengths := PackedInt32Array()
var _run_colors := PackedColorArray()
var _line_offsets := PackedInt32Array()
var _line_indents := PackedInt32Array()
var _line_lengths := PackedInt32Array()
var _line_count: int = 0
var _longest: int = 0

## The tokenizer's tables. They are rebuilt with the document.
var _keyword_colors := {}
var _region_list: Array = []
var _region_first_chars := {}
var _string_color := Color(0, 0, 0, 0)
var _number_color := Color(0, 0, 0, 0)
var _plain_color := Color(0, 0, 0, 0)
var _indent_color := Color(0, 0, 0, 0)
var _summary_colors := PackedColorArray()

var _dirty: bool = true
var _rebuild_timer: float = 0.0
var _dragging: bool = false


func _ready() -> void:
	editor = _find_editor()
	if editor != null:
		editor.minimap = self

	theme = LuaSingleton.editor_theme
	mouse_filter = Control.MOUSE_FILTER_STOP
	focus_mode = Control.FOCUS_NONE
	clip_contents = true

	set_anchors_and_offsets_preset(Control.PRESET_RIGHT_WIDE)
	offset_top = TOP_OFFSET
	offset_bottom = 0.0
	_apply_width()

	_marker = Panel.new()
	_marker.name = "Marker"
	_marker.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_marker.add_theme_stylebox_override("panel", _marker_style())
	_marker.visible = false
	add_child(_marker)

	LuaSingleton.on_theme_load.connect(_on_theme_load)
	LuaSingleton.on_settings_change.connect(_on_settings_change)

	# The strip can grow or shrink (the terminal dock opens), and that can
	# switch it between the word mode and the summary mode.
	resized.connect(func() -> void: _dirty = true)

	if editor != null:
		if editor.editor_host != null:
			editor.editor_host.view_created.connect(_on_view_created)
			editor.editor_host.active_view_changed.connect(_on_active_view_changed)

	_apply_settings()


## The terminal dock shrinks the strip's bottom edge. The HUD builds the
## terminal after the minimap, so the link is made explicitly.
func attach_terminal(terminal: Control) -> void:
	attach_bottom_dock(terminal)


## Both bottom docks (terminal and Run output) use this. Reading the shared
## FileManager value means the inset is correct whichever drawer is open.
func attach_bottom_dock(dock: Control) -> void:
	if dock == null:
		return
	dock.visibility_changed.connect(_apply_bottom)
	_apply_bottom()


func _process(delta: float) -> void:
	# The active tab can change without a signal reaching us in time (the
	# view is created, then activated), so the binding is checked every frame.
	if editor != null:
		var view := _active_view()
		if view != _view:
			_set_view(view)

	_update_marker()

	if !_dirty:
		return

	_rebuild_timer -= delta
	if _rebuild_timer > 0.0:
		return

	_rebuild_timer = _rebuild_interval()
	_rebuild()


## How often the strip is rebuilt. Bigger files are refreshed less often:
## the strip is a hint, not the text, and tokenising a thousand lines must
## not cost a frame every time a key is pressed.
func _rebuild_interval() -> float:
	if _line_count > 4000:
		return 1.0
	if _line_count > 400:
		return 0.5
	return REBUILD_INTERVAL


func _draw() -> void:
	# Opaque background: the strip floats over the code, so the text behind it
	# must not show through the blocks.
	var background: Color = LuaSingleton.gui.get("background_color", Color(0.05, 0.06, 0.08))
	draw_rect(Rect2(Vector2.ZERO, size), background)

	if _line_count <= 0:
		return

	var row_h := Scroll.strip_row_height(_line_count, size.y)
	if row_h >= 1.0:
		_draw_words(row_h)
		return

	_draw_summary()


## One block per word, at the column the word is at. Whitespace is left
## empty, so the words read as separate blocks and the indentation shows up
## as a gap before them.
func _draw_words(row_h: float) -> void:
	var char_px := _char_width()
	var h := maxf(1.0, row_h - 1.0)

	for i in _line_count:
		var y := i * row_h

		var indent := _line_indents[i]
		if indent > 0:
			draw_rect(Rect2(PADDING, y, minf(indent * char_px, size.x - PADDING), h), _indent_color)

		var from := _line_offsets[i]
		var to := _line_offsets[i + 1]
		for r in range(from, to):
			var x := PADDING + _run_starts[r] * char_px
			if x >= size.x:
				break
			var w := _run_lengths[r] * char_px
			draw_rect(Rect2(x, y, minf(w, size.x - x), h), _run_colors[r])


## More lines than the strip has pixels: every screen row summarises a range
## of lines instead of drawing them word by word.
func _draw_summary() -> void:
	var char_px := _char_width()
	var rows := int(size.y)

	for r in rows:
		var start := int(floor(float(r) * _line_count / float(rows)))
		var stop := int(floor(float(r + 1) * _line_count / float(rows)))
		if stop <= start:
			stop = start + 1

		var best := 0
		var color := Color(0, 0, 0, 0)
		for i in range(start, mini(stop, _line_count)):
			if _line_lengths[i] > best:
				best = _line_lengths[i]

		if r < _summary_colors.size():
			color = _summary_colors[r]

		if best <= 0:
			continue

		var w := minf(float(best) * char_px, size.x - PADDING * 2.0)
		draw_rect(Rect2(PADDING, r, w, 1.0), color)


## How wide one character is in the strip. At least a pixel, so the words
## stay apart, and never more than the strip can show.
func _char_width() -> float:
	var usable := maxf(4.0, size.x - PADDING * 2.0)
	return maxf(1.0, usable / float(maxi(_longest, int(MIN_CHARS))))


# ── SETTINGS ────────────────────────────────────────────────────────────────

func set_enabled(value: bool) -> void:
	enabled = value
	visible = enabled and !suppressed
	if visible:
		_dirty = true
		_update_marker()


func set_suppressed(value: bool) -> void:
	if suppressed == value:
		return
	suppressed = value
	visible = enabled and !suppressed
	if visible:
		_dirty = true
		_update_marker()


func set_strip_width(width: int) -> void:
	strip_width = maxi(20, width)
	_apply_width()
	_dirty = true


func _apply_width() -> void:
	offset_left = -float(strip_width)
	offset_right = 0.0


func _apply_settings() -> void:
	var minimap_setting: Array = LuaSingleton.get_setting("minimap")
	if minimap_setting.size() >= 2 && minimap_setting[1] != -1:
		var entry: Dictionary = minimap_setting[0]
		set_enabled(bool(entry.get("value", true)))

	var width_setting: Array = LuaSingleton.get_setting("minimap_width")
	if width_setting.size() >= 2 && width_setting[1] != -1:
		var entry: Dictionary = width_setting[0]
		set_strip_width(int(entry.get("value", 80)))


func _on_settings_change() -> void:
	_apply_settings()


func _on_theme_load() -> void:
	_marker.add_theme_stylebox_override("panel", _marker_style())
	_dirty = true


# ── LAYOUT ───────────────────────────────────────────────────────────────────

func _apply_bottom() -> void:
	var top := 0.0
	if editor != null and editor.has_method("bottom_dock_top"):
		top = float(editor.bottom_dock_top())
	offset_bottom = minf(0.0, top)


func _marker_style() -> StyleBoxFlat:
	var accent: Color = LuaSingleton.gui.get("selection_color", Color(0.4, 0.6, 1.0))
	var style := StyleBoxFlat.new()
	style.bg_color = Color(accent, 0.12)
	style.border_color = Color(accent, 0.55)
	style.border_width_left = 1
	style.border_width_top = 1
	style.border_width_right = 1
	style.border_width_bottom = 1
	return style


# ── DATA ─────────────────────────────────────────────────────────────────────

func _set_view(view) -> void:
	var next: CodeEdit = view as CodeEdit
	if _view == next:
		return

	if _view != null && is_instance_valid(_view):
		if _view.text_changed.is_connected(_on_text_changed):
			_view.text_changed.disconnect(_on_text_changed)

	_view = next

	if _view != null:
		_view.text_changed.connect(_on_text_changed)

	_dirty = true


func _on_view_created(_view_created) -> void:
	if editor != null && editor.active_view == _view_created:
		_set_view(_view_created)


func _on_active_view_changed(view) -> void:
	_set_view(view)


func _on_text_changed() -> void:
	_dirty = true


func _rebuild() -> void:
	var view := _active_view()
	if view == null || !is_instance_valid(view):
		_clear()
		return

	var state := _language_state(view)
	_keyword_colors = _build_keyword_colors(state)
	_region_list = _build_regions(state)
	_plain_color = _build_plain_color()
	_string_color = _palette_color("string", _plain_color)
	_number_color = _palette_color("binary", _plain_color)
	_indent_color = Color(_plain_color.r, _plain_color.g, _plain_color.b, INDENT_ALPHA)

	var lines: PackedStringArray = view.text.split("\n")
	_line_count = lines.size()
	_line_offsets.resize(_line_count + 1)
	_line_indents.resize(_line_count)
	_line_lengths.resize(_line_count)
	_summary_colors = PackedColorArray()
	_run_starts = PackedInt32Array()
	_run_lengths = PackedInt32Array()
	_run_colors = PackedColorArray()

	# A file with more lines than the strip has pixels is only summarised:
	# tokenising 20,000 lines word by word would cost more than the frame it
	# is drawn in, and the summary cannot show them anyway.
	var word_path := Scroll.strip_row_height(_line_count, size.y) >= 1.0

	var in_region := -1
	var longest := 0

	for i in _line_count:
		_line_offsets[i] = _run_starts.size()
		var raw: String = lines[i]

		if word_path:
			in_region = _tokenize(raw, i, in_region)
		else:
			_line_lengths[i] = raw.length()
			_line_indents[i] = _indent_of(raw)

		var code := raw.strip_edges().length()
		if code > longest:
			longest = code

	_line_offsets[_line_count] = _run_starts.size()
	_longest = longest

	if !word_path:
		_build_summary_colors(lines)

	_dirty = false
	queue_redraw()


## One colour per screen row for the summary mode. Only the first non-blank
## line of a row's range is looked at, so a 20,000 line file costs a thousand
## colour lookups instead of twenty thousand.
func _build_summary_colors(lines: PackedStringArray) -> void:
	var rows := int(size.y)
	_summary_colors = PackedColorArray()
	_summary_colors.resize(rows)

	for r in rows:
		var start := int(floor(float(r) * _line_count / float(rows)))
		var stop := int(floor(float(r + 1) * _line_count / float(rows)))
		if stop <= start:
			stop = start + 1

		for i in range(start, mini(stop, _line_count)):
			if _line_indents[i] >= _line_lengths[i]:
				continue
			_summary_colors[r] = _quick_color(lines[i])
			break


func _clear() -> void:
	_line_offsets = PackedInt32Array()
	_line_indents = PackedInt32Array()
	_line_lengths = PackedInt32Array()
	_summary_colors = PackedColorArray()
	_run_starts = PackedInt32Array()
	_run_lengths = PackedInt32Array()
	_run_colors = PackedColorArray()
	_line_count = 0
	_longest = 0
	_dirty = false
	queue_redraw()


## The width of the line's indentation, in characters.
func _indent_of(raw: String) -> int:
	var indent := 0
	var length := raw.length()
	while indent < length && (raw[indent] == " " || raw[indent] == "\t"):
		indent += 1
	return indent


## The colour of a line's first meaningful token, without tokenising the
## whole line. The summary mode only needs one colour per screen row, and
## walking every character of a 20,000 line file for that is not worth it.
func _quick_color(raw: String) -> Color:
	var col := _indent_of(raw)
	if col >= raw.length():
		return Color(0, 0, 0, 0)

	var region_index := _region_at(raw, col)
	if region_index >= 0:
		return _region_list[region_index]["color"]

	var c := raw[col]
	if c == "\"" || c == "'":
		return _string_color
	if _is_digit(c):
		return _number_color
	if _is_word_char(c):
		var at := col
		while at < raw.length() && _is_word_char(raw[at]):
			at += 1
		return _keyword_colors.get(raw.substr(col, at - col), _plain_color)

	return _plain_color


# ── TOKENIZER ────────────────────────────────────────────────────────────────

## Splits one line into coloured runs of characters and returns the region
## the line ends in (-1 when it ends outside every region).
func _tokenize(raw: String, line_index: int, in_region: int) -> int:
	var length := raw.length()
	_line_lengths[line_index] = length

	# The indentation is measured, not drawn as text: it gets its own dim
	# block so the nesting of the code is visible.
	var indent := _indent_of(raw)
	_line_indents[line_index] = indent

	var col := indent

	# Still inside a multi-line region (a block comment, a long string)?
	if in_region >= 0:
		var region: Dictionary = _region_list[in_region]
		var end_key: String = region["end"]
		var at := raw.find(end_key, col) if !end_key.is_empty() else -1
		if at == -1:
			_add_run(col, length - col, region["color"])
			return in_region
		_add_run(col, at + end_key.length() - col, region["color"])
		col = at + end_key.length()
		in_region = -1

	while col < length:
		var c := raw[col]

		# Whitespace is left out — it keeps the blocks per word instead of
		# rendering every line as a solid bar.
		if _is_space(c):
			col += 1
			continue

		# A colour region (a comment, a string) starts here?
		var region_index := _region_at(raw, col)
		if region_index >= 0:
			var region: Dictionary = _region_list[region_index]
			var start_key: String = region["start"]
			var end_key: String = region["end"]
			var from := col + start_key.length()
			var at := raw.find(end_key, from) if !end_key.is_empty() else -1
			if at == -1:
				_add_run(col, length - col, region["color"])
				if !bool(region["line_only"]):
					return region_index
				break
			_add_run(col, at + end_key.length() - col, region["color"])
			col = at + end_key.length()
			continue

		# A string?
		if c == "\"" || c == "'":
			var at := _string_end(raw, col)
			_add_run(col, at - col, _string_color)
			col = at
			continue

		# A number?
		if c >= "0" && c <= "9":
			var at := col
			while at < length && _is_number_char(raw[at]):
				at += 1
			_add_run(col, at - col, _number_color)
			col = at
			continue

		# A word?
		if _is_word_char(c):
			var at := col
			while at < length && _is_word_char(raw[at]):
				at += 1
			var word := raw.substr(col, at - col)
			var color := _plain_color
			if _keyword_colors.has(word):
				color = _keyword_colors[word]
			_add_run(col, at - col, color)
			col = at
			continue

		# Punctuation: drawn like any other character, but it keeps the words
		# apart because whitespace is left out.
		var at := col + 1
		while at < length && !raw[at].is_empty() && !_is_space(raw[at]) && !_is_word_char(raw[at]) && !_is_digit(raw[at]) && raw[at] != "\"" && raw[at] != "'":
			at += 1
		_add_run(col, at - col, _plain_color)
		col = at

	return in_region


func _add_run(start: int, length: int, color: Color) -> void:
	if length <= 0:
		return
	_run_starts.append(start)
	_run_lengths.append(length)
	_run_colors.append(color)


## The colour region that starts at `col`, if any.
func _region_at(raw: String, col: int) -> int:
	var candidates = _region_first_chars.get(raw[col], [])
	for i in candidates:
		var region: Dictionary = _region_list[i]
		if raw.find(str(region["start"]), col) == col:
			return i
	return -1


## Where the string that starts at `start` ends (quotes and backslashes
## included).
func _string_end(raw: String, start: int) -> int:
	var quote := raw[start]
	var length := raw.length()
	var i := start + 1

	while i < length:
		var c := raw[i]
		if c == "\\":
			i += 2
			continue
		if c == quote:
			return i + 1
		i += 1

	return length


func _is_space(c: String) -> bool:
	return c == " " || c == "\t"


func _is_digit(c: String) -> bool:
	return c >= "0" && c <= "9"


func _is_word_char(c: String) -> bool:
	return _is_digit(c) || (c >= "a" && c <= "z") || (c >= "A" && c <= "Z") || c == "_"


func _is_number_char(c: String) -> bool:
	return _is_digit(c) || c == "." || (c >= "a" && c <= "f") || (c >= "A" && c <= "F")


# ── COLOURS ──────────────────────────────────────────────────────────────────

func _language_state(view: CodeEdit) -> Dictionary:
	if LuaSingleton.language_service == null:
		return {}

	var extension := str(view.get("language_extension"))
	var state: Dictionary = LuaSingleton.language_service.get_extension(extension)
	if bool(state.get("error", false)):
		return {}

	return state


func _build_keyword_colors(state: Dictionary) -> Dictionary:
	var out := {}
	var keywords: Dictionary = state.get("keywords", {})
	for keyword in keywords.keys():
		var name := str(keywords[keyword])
		if !LuaSingleton.keywords.has(name):
			continue
		var color: Color = LuaSingleton.keywords[name]
		color.a = BAR_ALPHA
		out[str(keyword)] = color
	return out


func _build_regions(state: Dictionary) -> Array:
	var out := []
	_region_first_chars = {}
	for entry in state.get("regions", []):
		if !(entry is Array) || entry.size() < 3:
			continue
		var name := str(entry[2])
		if !LuaSingleton.keywords.has(name):
			continue
		var color: Color = LuaSingleton.keywords[name]
		color.a = BAR_ALPHA
		var start_key := str(entry[0])
		out.append({
			"start": start_key,
			"end": str(entry[1]),
			"color": color,
			"line_only": bool(entry[3]) if entry.size() > 3 else false,
		})
		# Only a handful of characters can begin a region, so the lookup is
		# done through the first character instead of scanning every region
		# at every position of every line.
		if !start_key.is_empty():
			var first := start_key[0]
			if !_region_first_chars.has(first):
				_region_first_chars[first] = []
			_region_first_chars[first].append(out.size() - 1)
	return out


func _build_plain_color() -> Color:
	# The same colour the CodeEdit paints its text with.
	var color: Color = LuaSingleton.gui.get("font_color", Color(0.8, 0.8, 0.8))
	color.a = BAR_ALPHA
	return color


func _palette_color(name: String, fallback: Color) -> Color:
	var color: Color = LuaSingleton.keywords.get(name, fallback)
	color.a = BAR_ALPHA
	return color


# ── VIEWPORT MARKER ──────────────────────────────────────────────────────────

func _update_marker() -> void:
	var view := _active_view()
	if view == null || !is_instance_valid(view) || _line_count <= 0 || !enabled:
		_marker.visible = false
		return

	var line_range := _visible_line_range(view)
	var top := Scroll.line_to_strip_y(line_range.x, _line_count, size.y)
	var bottom := Scroll.line_to_strip_y(line_range.y + 1, _line_count, size.y)

	_marker.visible = true
	_marker.position = Vector2(0, top)
	_marker.size = Vector2(size.x, maxf(2.0, bottom - top))


## The lines the camera currently shows. The camera follows the caret, so the
## caret's line anchors the world-pixel <-> line-number mapping.
func _visible_line_range(view: CodeEdit) -> Vector2i:
	var last := _line_count - 1
	var camera := _camera()
	if camera == null:
		return Vector2i(0, last)

	var line_height := float(view.get_line_height())
	if line_height <= 0.0:
		return Vector2i(0, last)

	var line_zero_y := _line_zero_y(view)

	var viewport := get_viewport()
	if viewport == null:
		return Vector2i(0, last)

	var world_size := viewport.get_visible_rect().size / camera.zoom
	var center := camera.get_screen_center_position()
	var top := center.y - world_size.y * 0.5
	var bottom := center.y + world_size.y * 0.5

	var first := int(floor((top - line_zero_y) / line_height))
	var last_visible := int(ceil((bottom - line_zero_y) / line_height))

	return Vector2i(clampi(first, 0, last), clampi(last_visible, 0, last))


## World y of the first line. Line 0 is always inside the drawn area, so its
## rectangle is the exact anchor; the theme is only a fallback for the frames
## before the first draw.
func _line_zero_y(view: CodeEdit) -> float:
	var rect := view.get_rect_at_line_column(0, 0)
	if rect.position.x != -1:
		return float(rect.position.y)

	var offset_y := 0.0
	var style := view.get_theme_stylebox("normal")
	if style != null:
		offset_y = style.get_offset().y * 0.5

	return offset_y + float(view.get_theme_constant("line_spacing")) * 0.5


# ── INPUT ───────────────────────────────────────────────────────────────────

func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var button := event as InputEventMouseButton
		if button.button_index == MOUSE_BUTTON_LEFT:
			if button.pressed:
				_dragging = true
				_jump_to(button.position.y)
			else:
				_dragging = false
	elif event is InputEventMouseMotion && _dragging:
		_jump_to((event as InputEventMouseMotion).position.y)


func _jump_to(y: float) -> void:
	var view := _active_view()
	if view == null || !is_instance_valid(view):
		return

	view.set_caret_line(Scroll.strip_y_to_line(y, _line_count, size.y))


# ── HELPERS ──────────────────────────────────────────────────────────────────

func _active_view() -> CodeEdit:
	if editor == null:
		return null
	return editor.active_view as CodeEdit


func _camera() -> Camera2D:
	if editor == null:
		return null
	return editor.camera as Camera2D


func _find_editor():
	var node := get_parent()
	while node != null && !(node is FileManager):
		node = node.get_parent()
	return node
