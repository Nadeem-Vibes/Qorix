extends ConfirmationDialog

## Review card for a multi-file `WorkspaceEdit` (rename, code action, import
## cleanup). A single-file edit is applied directly by LspManager; this dialog
## exists so a refactor that touches five files is never a surprise.

signal applied

var _summary: Label
var _files: ItemList
var _details: RichTextLabel
var _warning: Label


func _ready() -> void:
	title = "Preview Changes"
	ok_button_text = "Apply Changes"
	cancel_button_text = "Cancel"
	dialog_hide_on_ok = true
	min_size = Vector2i(760, 480)
	exclusive = true

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 6)
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(box)

	_summary = Label.new()
	_summary.add_theme_font_size_override("font_size", 13)
	box.add_child(_summary)

	_files = ItemList.new()
	_files.custom_minimum_size = Vector2(0, 160)
	_files.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_files.item_selected.connect(_on_file_selected)
	box.add_child(_files)

	_details = RichTextLabel.new()
	_details.bbcode_enabled = true
	_details.fit_content = false
	_details.scroll_active = true
	_details.selection_enabled = true
	_details.custom_minimum_size = Vector2(0, 140)
	_details.size_flags_vertical = Control.SIZE_EXPAND_FILL
	box.add_child(_details)

	_warning = Label.new()
	_warning.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_warning.add_theme_font_size_override("font_size", 11)
	_warning.visible = false
	box.add_child(_warning)

	confirmed.connect(_on_confirmed)
	about_to_popup.connect(_on_about_to_popup)
	LuaSingleton.on_theme_load.connect(restyle)
	LuaSingleton.on_settings_change.connect(restyle)
	restyle()

	_entries = []
	_operations = []


var _entries: Array = []
var _operations: Array = []


func show_preview(title_text: String, entries: Array, operations: Array) -> void:
	_entries = entries.duplicate(true)
	_operations = operations.duplicate(true)
	title = "Preview: " + title_text
	_render()
	popup_centered()
	get_ok_button().grab_focus()


func _on_about_to_popup() -> void:
	_render()


func _render() -> void:
	if _files == null:
		return
	_files.clear()

	var total_edits := 0
	var modified := 0
	var missing := 0
	for entry in _entries:
		if !(entry is Dictionary):
			continue
		var data: Dictionary = entry
		var edits := int(data.get("edits", 0))
		total_edits += edits
		if bool(data.get("modified", false)):
			modified += 1
		if !bool(data.get("exists", true)):
			missing += 1

		var flags: Array[String] = []
		if bool(data.get("modified", false)):
			flags.append("unsaved buffer")
		if !bool(data.get("exists", true)):
			flags.append("missing on disk")
		else:
			flags.append("on disk")
		var suffix := "  (" + ", ".join(flags) + ")" if !flags.is_empty() else ""
		var text := "%s — %d edit(s)%s" % [str(data.get("file", "file")), edits, suffix]
		_files.add_item(text)
		var index := _files.item_count - 1
		if !bool(data.get("exists", true)):
			_files.set_item_custom_fg_color(index, _c("error", Color(1.0, 0.4, 0.4)))
		elif bool(data.get("modified", false)):
			_files.set_item_custom_fg_color(index, _c("variable", Color(0.85, 0.7, 0.3)))

	_summary.text = "%d file(s), %d edit(s). Open buffers are updated in the editor and saved files are written to disk." % [
		_entries.size(), total_edits,
	]

	var problems: Array[String] = []
	if modified > 0:
		problems.append("%d open buffer(s) have unsaved changes; they will be updated in memory, not overwritten on disk." % modified)
	if missing > 0:
		problems.append("%d file(s) no longer exist and will be skipped." % missing)
	if !_operations.is_empty():
		var kinds: Array[String] = []
		for operation in _operations:
			if operation is Dictionary:
				kinds.append(str(operation.get("kind", "operation")))
		if !kinds.is_empty():
			problems.append("Resource operations are not applied by Qorix: " + ", ".join(kinds) + ".")
	if problems.is_empty():
		_warning.visible = false
	else:
		_warning.visible = true
		_warning.text = "\n".join(problems)
		_warning.add_theme_color_override("font_color", _c("variable", Color(0.85, 0.7, 0.3)))

	# Single-file edits bypass this preview today; keep it safe regardless.
	if _entries.is_empty():
		_files.deselect_all()
		_details.text = ""
		return
	_files.select(0)
	_on_file_selected(0)


func _on_file_selected(index: int) -> void:
	if _details == null or index < 0 or index >= _entries.size():
		return
	var entry: Dictionary = _entries[index]
	var lines: Array = entry.get("locations", [])
	var text := "[b]%s[/b]\n" % _escape(str(entry.get("path", "")))
	if lines.is_empty():
		text += "[color=#9aa4b2]The server did not report line positions.[/color]"
	else:
		var bits: Array[String] = []
		for line in lines:
			bits.append(str(int(line) + 1))
		text += "[color=#9aa4b2]Changes at line(s):[/color] " + ", ".join(bits)
	_details.text = text


func _on_confirmed() -> void:
	applied.emit()


func restyle() -> void:
	if !is_inside_tree():
		return
	if _summary != null:
		_summary.add_theme_color_override("font_color", LuaSingleton.gui.font_color)
	if _details != null:
		_details.add_theme_color_override("default_color", LuaSingleton.gui.font_color)
		_details.add_theme_font_override("normal_font", _ui_font())
		_details.add_theme_font_override("bold_font", _ui_font())
	if _files != null:
		var font: Color = LuaSingleton.gui.font_color
		var background: Color = LuaSingleton.gui.background_color
		if absf(font.get_luminance() - background.get_luminance()) < 0.22:
			font = Color(0.92, 0.92, 0.92) if background.get_luminance() < 0.5 else Color(0.09, 0.09, 0.09)
		_files.add_theme_color_override("font_color", font)
		_files.add_theme_color_override("font_selected_color", font)
	if _warning != null:
		_warning.add_theme_font_override("font", _ui_font())


func _ui_font() -> Font:
	if LuaSingleton.editor_theme != null:
		return LuaSingleton.editor_theme.get_font("font", "MyType")
	return ThemeDB.fallback_font


func _c(key: String, fallback: Color) -> Color:
	var value: Variant = LuaSingleton.keywords.get(key)
	if value is Color and (value as Color).a > 0.0:
		return value
	return fallback


func _escape(text: String) -> String:
	return str(text).replace("[", "[lb]")
