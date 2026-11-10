extends PanelContainer

## Floating tooltip for `textDocument/hover` and diagnostic messages.
##
## It lives in the HUD because the code itself is a world-space canvas that the
## camera moves; the tooltip has to stay in screen space next to the caret's
## projected position. It never takes focus, so typing continues while it is
## visible and the editor closes it on the next caret move.

const MAX_WIDTH := 620.0
const MIN_WIDTH := 280.0
const MAX_HEIGHT := 320.0
const MARGIN := 10.0
const GAP := 8.0

var editor = null

var _label: RichTextLabel
var _show_token: int = 0
var _pending_view = null
var _pending_line: int = 0
var _pending_column: int = 0
var _hint: Label


func _ready() -> void:
	editor = _find_editor()
	theme = LuaSingleton.editor_theme
	visible = false
	mouse_filter = Control.MOUSE_FILTER_STOP
	z_index = 20

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 2)
	add_child(box)

	_label = RichTextLabel.new()
	_label.bbcode_enabled = true
	_label.fit_content = true
	_label.scroll_active = false
	_label.selection_enabled = true
	_label.context_menu_enabled = true
	_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_label.custom_minimum_size = Vector2(MIN_WIDTH, 0)
	_label.mouse_filter = Control.MOUSE_FILTER_STOP
	box.add_child(_label)

	_hint = Label.new()
	_hint.text = "Esc or move the caret to close"
	_hint.add_theme_font_size_override("font_size", 11)
	_hint.visible = false
	box.add_child(_hint)

	LuaSingleton.on_theme_load.connect(restyle)
	LuaSingleton.on_settings_change.connect(restyle)
	restyle()


func _find_editor() -> FileManager:
	var node = get_parent()
	while node != null and !(node is FileManager):
		node = node.get_parent()
	return node


func show_hover(bbcode: String, view, line: int, column: int) -> void:
	if bbcode.strip_edges().is_empty():
		hide_now()
		return
	_present(bbcode, view, line, column)


func show_message(bbcode: String, view, line: int, column: int) -> void:
	_present(bbcode, view, line, column)


func _present(bbcode: String, view, line: int, column: int) -> void:
	if view == null or !is_instance_valid(view):
		return
	_show_token += 1
	var token := _show_token

	_label.text = bbcode
	_label.custom_minimum_size.x = _content_width()
	_hint.visible = false
	visible = true
	modulate.a = 1.0

	_pending_view = view
	_pending_line = line
	_pending_column = column

	# The label learns its final width when the container lays it out, and the
	# wrapped height follows from that width. Measure one frame later so the
	# panel never shows a one-line sliver or clips the last paragraph.
	await get_tree().process_frame
	if token != _show_token or !visible or _pending_view == null:
		return
	if !is_instance_valid(_pending_view):
		hide_now()
		return
	_fit_and_place(_pending_view, _pending_line, _pending_column)


func _content_width() -> float:
	var viewport_width := get_viewport_rect().size.x
	return clampf(viewport_width * 0.42, MIN_WIDTH, MAX_WIDTH)


func _fit_and_place(view, line: int, column: int) -> void:
	var width := _content_width()
	_label.size.x = width
	var content_height := _label.get_content_height()
	if content_height <= 0.0:
		content_height = float(_label.get_line_count()) * float(_font_size()) * 1.5
	var clipped := content_height + 22.0 > MAX_HEIGHT
	var height := clampf(content_height + 22.0, 34.0, MAX_HEIGHT)
	size = Vector2(width + 20.0, height)
	if _hint != null:
		_hint.visible = clipped

	var rect := _screen_rect(view, line, column)
	var viewport := get_viewport_rect().size
	var dock_top := _bottom_dock_top()
	var bottom_limit := viewport.y - MARGIN
	if dock_top < viewport.y:
		bottom_limit = minf(bottom_limit, dock_top - GAP)

	var pos := Vector2(rect.position.x, rect.end.y + GAP)
	if pos.y + size.y > bottom_limit:
		pos.y = rect.position.y - size.y - GAP
	if pos.y < MARGIN:
		pos.y = maxf(MARGIN, bottom_limit - size.y)

	pos.x = clampf(pos.x, MARGIN, maxf(MARGIN, viewport.x - size.x - MARGIN))
	pos.y = clampf(pos.y, MARGIN, maxf(MARGIN, bottom_limit - size.y))
	position = pos


func _screen_rect(view, line: int, column: int) -> Rect2:
	var safe_line := clampi(line, 0, maxi(0, view.get_line_count() - 1))
	var safe_column := clampi(column, 0, view.get_line(safe_line).length())
	var cell: Rect2 = view.get_rect_at_line_column(safe_line, safe_column)
	# The engine reports a -1 origin when the line is scrolled out of the
	# viewable area; fall back to the caret instead of clamping to the corner.
	if cell.size.y <= 0.0 or cell.position.x < 0.0 or cell.position.y < 0.0:
		cell = Rect2(view.get_caret_draw_pos(), Vector2(8.0, float(view.get_line_height())))
	if cell.size.x <= 0.0:
		cell.size.x = 8.0
	var xform: Transform2D = view.get_global_transform_with_canvas()
	return Rect2(xform * cell.position, xform.basis_xform(cell.size))


func _bottom_dock_top() -> float:
	if editor != null and editor.has_method("bottom_dock_top"):
		var top := float(editor.bottom_dock_top())
		# `bottom_dock_top()` is an offset from the bottom edge (negative while
		# a dock is open). Convert it to a screen y.
		return get_viewport_rect().size.y + top
	return get_viewport_rect().size.y


func hide_now() -> void:
	_show_token += 1
	_pending_view = null
	if visible:
		visible = false
	modulate.a = 0.0


func _input(event: InputEvent) -> void:
	if !visible:
		return
	if event is InputEventKey and event.pressed and !event.echo and event.keycode == KEY_ESCAPE:
		hide_now()
		get_viewport().set_input_as_handled()
	elif event is InputEventMouseButton and event.pressed:
		# Clicking anywhere else dismisses the tooltip; clicks inside it are
		# allowed through for text selection.
		if !get_global_rect().has_point(event.position):
			hide_now()


func restyle() -> void:
	if !is_inside_tree():
		return
	var panel := StyleBoxFlat.new()
	panel.bg_color = _shade(LuaSingleton.gui.background_color, 0.06)
	panel.set_content_margin_all(6)
	panel.content_margin_left = 10
	panel.content_margin_right = 10
	panel.content_margin_top = 8
	panel.content_margin_bottom = 8
	panel.corner_radius_top_left = 5
	panel.corner_radius_top_right = 5
	panel.corner_radius_bottom_left = 5
	panel.corner_radius_bottom_right = 5
	panel.border_width_left = 1
	panel.border_width_top = 1
	panel.border_width_right = 1
	panel.border_width_bottom = 1
	panel.border_color = _c("function", Color(0.4, 0.75, 1.0))
	add_theme_stylebox_override("panel", panel)

	if _label != null:
		var font := _ui_font()
		_label.add_theme_font_override("normal_font", font)
		_label.add_theme_font_override("bold_font", font)
		_label.add_theme_font_override("italics_font", font)
		_label.add_theme_font_override("mono_font", font)
		_label.add_theme_font_size_override("normal_font_size", _font_size())
		_label.add_theme_font_size_override("bold_font_size", _font_size())
		_label.add_theme_font_size_override("mono_font_size", _font_size())
		_label.add_theme_color_override("default_color", LuaSingleton.gui.font_color)
	if _hint != null:
		_hint.add_theme_color_override("font_color", _c("comments", Color(0.55, 0.6, 0.65)))
		_hint.add_theme_font_override("font", _ui_font())


func _ui_font() -> Font:
	if LuaSingleton.editor_theme != null:
		return LuaSingleton.editor_theme.get_font("font", "MyType")
	return ThemeDB.fallback_font


func _font_size() -> int:
	var size := 14
	var found = LuaSingleton.get_setting("editor_font_size")
	if found is Array and found.size() >= 2 and int(found[1]) != -1:
		size = clampi(int(found[0].get("value", size)) - 2, 10, 28)
	return size


func _c(key: String, fallback: Color) -> Color:
	var value: Variant = LuaSingleton.keywords.get(key)
	if value is Color and (value as Color).a > 0.0:
		return value
	return fallback


func _shade(color: Color, amount: float) -> Color:
	var light := color.get_luminance() > 0.5
	return color.lightened(amount) if light else color.darkened(amount)
