extends AcceptDialog

## "Previous Versions" dialog.
##
## The left column lists automatic snapshots (newest first); the right column
## shows a unified diff between the selected snapshot (old) and the current
## editor buffer (new). Restoring first snapshots the current buffer as
## "before_restore", so a restore can itself be undone from History.

const History = preload("res://src/features/learning/beginner/history_service.gd")

var editor: FileManager = null

var _path: String = ""
var _document = null
var _snapshots: Array = []
var _selected_file: String = ""
var _confirm: ConfirmationDialog

var _header_label: Label
var _stats_label: Label
var _list: ItemList
var _diff: CodeEdit
var _restore_button: Button
var _empty_label: Label


func _ready() -> void:
	editor = _find_editor()
	title = "History"
	ok_button_text = "Close"
	min_size = Vector2i(1100, 680)
	exclusive = false

	_build()
	_build_confirm()
	LuaSingleton.on_theme_load.connect(restyle)
	LuaSingleton.on_settings_change.connect(restyle)
	restyle()


func _find_editor() -> FileManager:
	var node = get_parent()
	while node != null and !(node is FileManager):
		node = node.get_parent()
	return node


func _build() -> void:
	var root := VBoxContainer.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.offset_left = 12
	root.offset_top = 10
	root.offset_right = -12
	root.offset_bottom = -52
	root.add_theme_constant_override("separation", 8)
	add_child(root)

	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 10)
	root.add_child(header)

	_header_label = Label.new()
	_header_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_header_label.clip_text = true
	header.add_child(_header_label)

	_stats_label = Label.new()
	header.add_child(_stats_label)

	var split := HBoxContainer.new()
	split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	split.add_theme_constant_override("separation", 10)
	root.add_child(split)

	var left := VBoxContainer.new()
	left.custom_minimum_size = Vector2(340, 0)
	left.add_theme_constant_override("separation", 6)
	split.add_child(left)

	var list_title := Label.new()
	list_title.text = "VERSIONS"
	list_title.add_theme_font_size_override("font_size", 12)
	left.add_child(list_title)

	_list = ItemList.new()
	_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_list.item_selected.connect(_on_selected)
	left.add_child(_list)

	_restore_button = Button.new()
	_restore_button.text = "Restore this version"
	_restore_button.custom_minimum_size = Vector2(0, 36)
	_restore_button.pressed.connect(_on_restore_pressed)
	left.add_child(_restore_button)

	var right := VBoxContainer.new()
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right.add_theme_constant_override("separation", 6)
	split.add_child(right)

	var diff_title := Label.new()
	diff_title.text = "WHAT CHANGED"
	diff_title.add_theme_font_size_override("font_size", 12)
	right.add_child(diff_title)

	_diff = CodeEdit.new()
	_diff.editable = false
	_diff.context_menu_enabled = true
	_diff.gutters_draw_line_numbers = false
	_diff.highlight_current_line = false
	_diff.caret_blink = false
	_diff.wrap_mode = TextEdit.LINE_WRAPPING_NONE
	_diff.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_diff.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_diff.add_theme_font_size_override("font_size", 14)
	right.add_child(_diff)

	_empty_label = Label.new()
	_empty_label.visible = false
	_empty_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	right.add_child(_empty_label)


func _build_confirm() -> void:
	_confirm = ConfirmationDialog.new()
	_confirm.title = "Restore this version?"
	_confirm.ok_button_text = "Restore"
	_confirm.cancel_button_text = "Keep the current version"
	_confirm.confirmed.connect(_do_restore)
	add_child(_confirm)


# ── PUBLIC ENTRY POINTS ─────────────────────────────────────────────────────

func open_document(document) -> void:
	_document = document
	_path = str(document.path) if document != null else ""
	_open()


func open_path(path: String, document = null) -> void:
	_document = document
	_path = str(path)
	_open()


func _open() -> void:
	if _path.is_empty():
		_show_empty("Save this file first. History starts once a file has a place on disk.")
		popup_centered_ratio(0.85)
		return

	title = "History: " + _path.get_file()
	_header_label.text = _path
	_header_label.tooltip_text = _path
	_snapshots = editor.history.snapshots(_path) if editor != null and editor.history != null else []

	_list.clear()
	for entry in _snapshots:
		var reason := str(entry.get("reason_label", History.reason_label(str(entry.get("reason", "")))))
		var time := str(entry.get("time_label", ""))
		var index := _list.add_item("%s\n%s" % [reason, time])
		_list.set_item_metadata(index, str(entry.get("file", "")))
		_list.set_item_tooltip(index, "%s · %s" % [reason, time])

	if _snapshots.is_empty():
		_show_empty("No previous versions yet. Qorix saves one before a save, before a run, before closing, and every minute while a file has unsaved edits.")
	else:
		_empty_label.visible = false
		_diff.visible = true
		_list.select(0)
		_render(0)
	_restore_button.disabled = _snapshots.is_empty()
	popup_centered_ratio(0.85)


func refresh() -> void:
	_open()


func _show_empty(message: String) -> void:
	_snapshots = []
	_selected_file = ""
	_list.clear()
	_diff.text = ""
	_diff.visible = false
	_empty_label.text = message
	_empty_label.visible = true
	_stats_label.text = ""
	_restore_button.disabled = true


func _on_selected(index: int) -> void:
	_render(index)


func _render(index: int) -> void:
	if index < 0 or index >= _snapshots.size():
		return
	if editor == null or editor.history == null:
		return
	var entry: Dictionary = _snapshots[index]
	_selected_file = str(entry.get("file", ""))
	var current := _current_text()
	var result: Dictionary = editor.history.diff(_path, _selected_file, current)
	if !bool(result.get("ok", false)):
		_diff.text = str(result.get("error", "The diff could not be built."))
		_stats_label.text = ""
		return

	_diff.text = ""
	for line in result.get("lines", []):
		_diff.text += str(line.get("text", "")) + "\n"

	for i in range(result.get("lines", []).size()):
		var kind := str(result.get("lines", [])[i].get("kind", "context"))
		if kind == "add":
			_diff.set_line_background_color(i, _tint(_color("string", Color(0.55, 0.8, 0.45)), 0.14))
		elif kind == "delete":
			_diff.set_line_background_color(i, _tint(_color("error", Color(0.9, 0.35, 0.35)), 0.14))
		elif kind == "gap":
			_diff.set_line_background_color(i, _tint(LuaSingleton.gui.font_color, 0.05))

	_stats_label.text = "+%d  −%d  ~%d   ·   %s" % [
		int(result.get("added", 0)),
		int(result.get("deleted", 0)),
		int(result.get("modified", 0)),
		str(entry.get("time_label", "")),
	]


func _current_text() -> String:
	if _document != null and is_instance_valid(_document):
		return str(_document.text())
	if !_path.is_empty() and FileAccess.file_exists(_path):
		return FileAccess.get_file_as_string(_path)
	return ""


func _on_restore_pressed() -> void:
	if _selected_file.is_empty():
		return
	var entry := _snapshot_by_file(_selected_file)
	var when := str(entry.get("time_label", ""))
	var reason := str(entry.get("reason_label", ""))
	_confirm.dialog_text = "Restore the version from %s (%s)?\n\nThe current version is copied into History first, so you can come back to it." % [when, reason]
	if editor != null and editor.beginner_mode_enabled():
		_confirm.dialog_text += "\n\nThis replaces what is in the editor right now."
	_confirm.popup_centered()


func _do_restore() -> void:
	if editor == null or _selected_file.is_empty():
		return
	var result: Dictionary = editor.restore_history_snapshot(_path, _selected_file)
	if bool(result.get("ok", false)):
		hide()
	else:
		_diff.text = str(result.get("error", "The version could not be restored."))


func _snapshot_by_file(file_name: String) -> Dictionary:
	for entry in _snapshots:
		if str(entry.get("file", "")) == file_name:
			return entry
	return {}


func _color(key: String, fallback: Color) -> Color:
	var value: Variant = LuaSingleton.keywords.get(key)
	if value is Color:
		return value
	return fallback


func _tint(color: Color, amount: float) -> Color:
	var background: Color = LuaSingleton.gui.background_color
	return background.lerp(color, amount)


func restyle() -> void:
	if LuaSingleton.gui == null:
		return
	var text: Color = LuaSingleton.gui.font_color
	if _header_label != null:
		_header_label.add_theme_color_override("font_color", text)
	if _stats_label != null:
		_stats_label.add_theme_color_override("font_color", text.darkened(0.25))
	if _empty_label != null:
		_empty_label.add_theme_color_override("font_color", text.darkened(0.2))
	if _diff != null:
		_diff.add_theme_color_override("font_color", text)
		_diff.add_theme_color_override("font_readonly_color", text)
		_diff.add_theme_font_size_override("font_size", 14)
