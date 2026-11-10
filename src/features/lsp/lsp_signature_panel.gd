extends PanelContainer

## Floating signature-help card shown while the caret is inside a call.
##
## The server may return several overloads; the active one is rendered with the
## current parameter in bold. It is deliberately small and non-focusable: the
## user keeps typing, and the editor closes it on the first caret move that
## leaves the argument list.

const LspText = preload("res://src/features/lsp/lsp_text.gd")

const MAX_WIDTH := 620.0
const MIN_WIDTH := 300.0
const MAX_HEIGHT := 260.0
const MARGIN := 10.0
const GAP := 8.0

var editor = null

var _label: RichTextLabel
var _hint: Label
var _show_token: int = 0
var _pending_view = null
var _pending_line: int = 0
var _pending_column: int = 0


func _ready() -> void:
	editor = _find_editor()
	theme = LuaSingleton.editor_theme
	visible = false
	mouse_filter = Control.MOUSE_FILTER_STOP
	z_index = 19

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
	box.add_child(_label)

	_hint = Label.new()
	_hint.add_theme_font_size_override("font_size", 11)
	box.add_child(_hint)

	LuaSingleton.on_theme_load.connect(restyle)
	LuaSingleton.on_settings_change.connect(restyle)
	restyle()


func _find_editor() -> FileManager:
	var node = get_parent()
	while node != null and !(node is FileManager):
		node = node.get_parent()
	return node


func show_for(view, line: int, column: int, parsed: Dictionary) -> void:
	var signatures: Array = parsed.get("signatures", [])
	if signatures.is_empty():
		hide_now()
		return
	var active := clampi(int(parsed.get("active_signature", 0)), 0, signatures.size() - 1)
	var signature: Dictionary = signatures[active]
	var active_parameter := int(parsed.get("active_parameter", -1))

	var text := LspText.signature_line(signature, active_parameter)
	var parameter_doc := ""
	if active_parameter >= 0:
		var parameters: Array = signature.get("parameters", [])
		if active_parameter < parameters.size():
			var parameter: Dictionary = parameters[active_parameter]
			parameter_doc = str(parameter.get("documentation", ""))
	var documentation := str(signature.get("documentation_bbcode", ""))
	var details := parameter_doc if !parameter_doc.is_empty() else LspText.markdown_to_plain(documentation).strip_edges()
	if !details.is_empty():
		text += "\n[color=#9aa4b2]" + _escape(details) + "[/color]"

	var hint := ""
	if signatures.size() > 1:
		hint = "%d of %d overloads" % [active + 1, signatures.size()]
	if !details.is_empty():
		hint = hint + ("" if hint.is_empty() else "  ·  ") + "Esc to close"

	_present(text, hint, view, line, column)


func _present(bbcode: String, hint: String, view, line: int, column: int) -> void:
	if view == null or !is_instance_valid(view):
		return
	_show_token += 1
	var token := _show_token

	_label.text = bbcode
	_label.custom_minimum_size.x = _content_width()
	_hint.text = hint
	_hint.visible = !hint.is_empty()
	visible = true
	modulate.a = 1.0

	_pending_view = view
	_pending_line = line
	_pending_column = column

	await get_tree().process_frame
	if token != _show_token or !visible or _pending_view == null:
		return
	if !is_instance_valid(_pending_view):
		hide_now()
		return
	_fit_and_place(_pending_view, _pending_line, _pending_column)


func _content_width() -> float:
	var viewport_width := get_viewport_rect().size.x
	return clampf(viewport_width * 0.40, MIN_WIDTH, MAX_WIDTH)


func _fit_and_place(view, line: int, column: int) -> void:
	var width := _content_width()
	_label.size.x = width
	var content_height := _label.get_content_height()
	if content_height <= 0.0:
		content_height = float(_label.get_line_count()) * float(_font_size()) * 1.5
	var height := clampf(content_height + 24.0, 40.0, MAX_HEIGHT)
	size = Vector2(width + 20.0, height)

	var rect := _screen_rect(view, line, column)
	var viewport := get_viewport_rect().size
	var bottom_limit := viewport.y - MARGIN
	if editor != null and editor.has_method("bottom_dock_top"):
		var dock_top := viewport.y + float(editor.bottom_dock_top())
		if dock_top < viewport.y:
			bottom_limit = minf(bottom_limit, dock_top - GAP)

	# Signature help reads best above the call it belongs to, like a tooltip
	# hanging off the function name. Fall below when the top is out of room.
	var pos := Vector2(rect.position.x, rect.position.y - size.y - GAP)
	if pos.y < MARGIN:
		pos.y = rect.end.y + GAP
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


func restyle() -> void:
	if !is_inside_tree():
		return
	var panel := StyleBoxFlat.new()
	panel.bg_color = _shade(LuaSingleton.gui.background_color, 0.06)
	panel.set_content_margin_all(6)
	panel.content_margin_left = 10
	panel.content_margin_right = 10
	panel.content_margin_top = 7
	panel.content_margin_bottom = 7
	panel.corner_radius_top_left = 5
	panel.corner_radius_top_right = 5
	panel.corner_radius_bottom_left = 5
	panel.corner_radius_bottom_right = 5
	panel.border_width_left = 1
	panel.border_width_top = 1
	panel.border_width_right = 1
	panel.border_width_bottom = 1
	panel.border_color = _c("variable", Color(0.85, 0.7, 0.3))
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


func _escape(text: String) -> String:
	return str(text).replace("[", "[lb]")
