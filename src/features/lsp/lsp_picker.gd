extends PanelContainer

## Floating result list for "Go to definition", "Find references" and code
## actions. It is keyboard-first: the filter keeps focus, Up/Down moves the
## highlighted row, Enter runs it and Escape closes the card.

const Fuzzy = preload("res://src/base/fuzzy_match.gd")

const WIDTH := 860.0
const HEIGHT := 380.0

var editor = null

var _title: Label
var _filter: LineEdit
var _status: Label
var _list: ItemList

var _mode: String = ""
var _items: Array = []
var _filtered: Array = []
var _selected: int = 0
var _restore_focus: bool = true


func _ready() -> void:
	editor = _find_editor()
	theme = LuaSingleton.editor_theme
	visible = false
	z_index = 30

	set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP)
	offset_left = -WIDTH * 0.5
	offset_right = WIDTH * 0.5
	offset_top = 88.0
	offset_bottom = 88.0 + HEIGHT

	var panel := StyleBoxFlat.new()
	panel.bg_color = LuaSingleton.gui.background_color
	panel.set_content_margin_all(8)
	panel.content_margin_left = 12
	panel.content_margin_right = 12
	panel.corner_radius_top_left = 5
	panel.corner_radius_top_right = 5
	panel.corner_radius_bottom_left = 5
	panel.corner_radius_bottom_right = 5
	panel.border_width_bottom = 1
	panel.border_width_top = 1
	panel.border_width_left = 1
	panel.border_width_right = 1
	panel.border_color = LuaSingleton.gui.current_line_color
	add_theme_stylebox_override("panel", panel)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 6)
	add_child(box)

	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 8)
	box.add_child(header)

	_title = Label.new()
	_title.add_theme_font_size_override("font_size", 14)
	_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(_title)

	var close := Button.new()
	close.text = "✕"
	close.tooltip_text = "Close (Esc)"
	close.pressed.connect(_close)
	header.add_child(close)

	_filter = LineEdit.new()
	_filter.placeholder_text = "Filter…"
	_filter.text_changed.connect(func(_text: String) -> void: _refilter())
	_filter.text_submitted.connect(func(_text: String) -> void: _activate(_selected))
	box.add_child(_filter)

	_status = Label.new()
	_status.add_theme_font_size_override("font_size", 11)
	box.add_child(_status)

	_list = ItemList.new()
	_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_list.item_activated.connect(_on_item_activated)
	box.add_child(_list)

	LuaSingleton.on_theme_load.connect(restyle)
	LuaSingleton.on_settings_change.connect(restyle)
	restyle()


func _find_editor() -> FileManager:
	var node = get_parent()
	while node != null and !(node is FileManager):
		node = node.get_parent()
	return node


# ── OPENING ─────────────────────────────────────────────────────────────────

func show_locations(title: String, items: Array) -> void:
	if items.is_empty():
		return
	_mode = "location"
	_items = items
	_restore_focus = true
	_open(title)


func show_actions(title: String, actions: Array) -> void:
	if actions.is_empty():
		return
	_mode = "action"
	_items = actions
	_restore_focus = true
	_open(title)


func _open(title: String) -> void:
	if editor != null:
		if editor.lsp_hover_panel != null:
			editor.lsp_hover_panel.hide_now()
		if editor.lsp_signature_panel != null:
			editor.lsp_signature_panel.hide_now()

	_title.text = title
	_filter.text = ""
	_visible_open(title)
	_refilter()
	_filter.grab_focus()
	_filter.select_all()
	visible = true


func _visible_open(_title: String) -> void:
	# Kept separate so tests and plugins can override the presentation without
	# touching the data flow.
	pass


func _refilter() -> void:
	var query := _filter.text.strip_edges()
	_filtered.clear()

	for item in _items:
		if !(item is Dictionary):
			continue
		var entry: Dictionary = item
		var label := _entry_label(entry)
		var score := 0.0
		if !query.is_empty():
			score = float(Fuzzy.score(label, query))
			if score < 0.0:
				continue
			var tooltip := str(entry.get("detail", ""))
			if score < 0.0 and !tooltip.is_empty():
				score = float(Fuzzy.score(tooltip, query))
				if score < 0.0:
					continue
		entry["_score"] = score
		_filtered.append(entry)

	# Fuzzy scores are lower-is-better; with an empty query keep server order.
	if !query.is_empty():
		_filtered.sort_custom(func(a, b) -> bool: return float(a.get("_score", 0.0)) < float(b.get("_score", 0.0)))

	_populate()


func _entry_label(entry: Dictionary) -> String:
	if _mode == "action":
		var preferred := "★ " if bool(entry.get("is_preferred", false)) else ""
		return preferred + str(entry.get("title", "Code action"))
	var label := str(entry.get("label", ""))
	var detail := str(entry.get("detail", ""))
	return label + ("  —  " + detail if !detail.is_empty() else "")


func _populate() -> void:
	_list.clear()
	for i in range(_filtered.size()):
		var entry: Dictionary = _filtered[i]
		var text := _entry_label(entry)
		if _mode == "location":
			var preview := str(entry.get("preview", ""))
			if !preview.is_empty():
				text += "\n    " + preview
		_list.add_item(text)
		_list.set_item_tooltip(i, _tooltip(entry))
		if _mode == "action":
			var disabled: Variant = entry.get("disabled")
			_list.set_item_disabled(i, disabled is String and !str(disabled).is_empty())
			var kind := str(entry.get("kind", ""))
			if kind.begins_with("quickfix"):
				_list.set_item_custom_fg_color(i, _c("variable", Color(0.85, 0.7, 0.3)))
			elif kind.begins_with("refactor"):
				_list.set_item_custom_fg_color(i, _c("function", Color(0.4, 0.75, 1.0)))
		else:
			_list.set_item_custom_fg_color(i, _c("function", Color(0.4, 0.75, 1.0)))

	_selected = 0
	if !_filtered.is_empty():
		_list.select(0)
		_list.ensure_current_is_visible()

	if _filtered.is_empty():
		_status.text = "No matches" if !_filter.text.strip_edges().is_empty() else "Nothing to show"
	else:
		_status.text = "%d item(s) · Enter to open · Esc to close" % _filtered.size()


func _tooltip(entry: Dictionary) -> String:
	if _mode == "action":
		var bits: Array[String] = []
		var kind := str(entry.get("kind", ""))
		if !kind.is_empty():
			bits.append(kind)
		var disabled: Variant = entry.get("disabled")
		if disabled is String and !str(disabled).is_empty():
			bits.append("Unavailable: " + str(disabled))
		return "\n".join(bits)
	var path := str(entry.get("path", ""))
	var line := int(entry.get("line", 0)) + 1
	return "%s:%d" % [path, line]


# ── NAVIGATION ──────────────────────────────────────────────────────────────

func _input(event: InputEvent) -> void:
	if !visible:
		return
	# The filter keeps keyboard focus, so navigation has to be routed here
	# rather than relying on the ItemList's own focus handling.
	if event is InputEventKey and event.pressed and !event.echo:
		match event.keycode:
			KEY_ESCAPE:
				_close()
				get_viewport().set_input_as_handled()
			KEY_UP:
				_move(-1)
				get_viewport().set_input_as_handled()
			KEY_DOWN:
				_move(1)
				get_viewport().set_input_as_handled()
			KEY_ENTER, KEY_KP_ENTER:
				# LineEdit emits text_submitted; handling it here too would run
				# the selection twice.
				pass


func _move(direction: int) -> void:
	if _filtered.is_empty():
		return
	_selected = (_selected + direction + _filtered.size()) % _filtered.size()
	_list.select(_selected)
	_list.ensure_current_is_visible()


func _on_item_activated(index: int) -> void:
	_activate(index)


func _activate(index: int) -> void:
	if index < 0 or index >= _filtered.size():
		return
	var entry: Dictionary = _filtered[index]
	if _mode == "action":
		var disabled: Variant = entry.get("disabled")
		if disabled is String and !str(disabled).is_empty():
			_status.text = str(disabled)
			return
		_close(false)
		if editor != null and editor.lsp_manager != null:
			editor.lsp_manager.apply_code_action(entry)
		return

	var path := str(entry.get("path", ""))
	if path.is_empty():
		return
	var line := int(entry.get("line", 0))
	var column := int(entry.get("column", 0))
	_close(false)
	if editor != null:
		editor.open_search_result(path, line, column)


func _close(restore_focus: bool = true) -> void:
	visible = false
	_filter.release_focus()
	_items = []
	_filtered = []
	_list.clear()
	if restore_focus and _restore_focus and editor != null and editor.editor_host != null:
		editor.editor_host.grab_active_focus()


func close_now() -> void:
	_close(false)


# ── THEME ───────────────────────────────────────────────────────────────────

func restyle() -> void:
	if !is_inside_tree():
		return
	var panel := StyleBoxFlat.new()
	panel.bg_color = LuaSingleton.gui.background_color
	panel.set_content_margin_all(8)
	panel.content_margin_left = 12
	panel.content_margin_right = 12
	panel.corner_radius_top_left = 5
	panel.corner_radius_top_right = 5
	panel.corner_radius_bottom_left = 5
	panel.corner_radius_bottom_right = 5
	panel.border_width_left = 1
	panel.border_width_top = 1
	panel.border_width_right = 1
	panel.border_width_bottom = 1
	panel.border_color = LuaSingleton.gui.current_line_color
	add_theme_stylebox_override("panel", panel)

	if _title != null:
		_title.add_theme_color_override("font_color", LuaSingleton.gui.font_color)
	if _status != null:
		_status.add_theme_color_override("font_color", _c("comments", Color(0.55, 0.6, 0.65)))
	if _filter != null:
		_filter.add_theme_font_override("font", _ui_font())
	if _list != null:
		_list.add_theme_stylebox_override("panel", StyleBoxEmpty.new())
		_list.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
		var selected := StyleBoxFlat.new()
		selected.bg_color = LuaSingleton.gui.selection_color
		selected.set_content_margin_all(2)
		_list.add_theme_stylebox_override("selected", selected)
		var font: Color = LuaSingleton.gui.font_color
		var background: Color = LuaSingleton.gui.background_color
		if absf(font.get_luminance() - background.get_luminance()) < 0.22:
			font = Color(0.92, 0.92, 0.92) if background.get_luminance() < 0.5 else Color(0.09, 0.09, 0.09)
		_list.add_theme_color_override("font_color", font)
		_list.add_theme_color_override("font_hovered_color", font)
		_list.add_theme_color_override("font_selected_color", font)


func _ui_font() -> Font:
	if LuaSingleton.editor_theme != null:
		return LuaSingleton.editor_theme.get_font("font", "MyType")
	return ThemeDB.fallback_font


func _c(key: String, fallback: Color) -> Color:
	var value: Variant = LuaSingleton.keywords.get(key)
	if value is Color and (value as Color).a > 0.0:
		return value
	return fallback
