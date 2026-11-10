extends ConfirmationDialog

## Small modal that asks for a new symbol name. The rename itself is requested
## by LspManager; this dialog only collects the text and validates the obvious
## cases (empty or unchanged name).

signal submitted(new_name: String)

var _name_edit: LineEdit
var _context_label: Label
var _hint_label: Label
var _current_name: String = ""
var _path: String = ""
var _line: int = 0
var _submitting: bool = false


func _ready() -> void:
	title = "Rename Symbol"
	ok_button_text = "Rename"
	cancel_button_text = "Cancel"
	dialog_hide_on_ok = true
	min_size = Vector2i(520, 190)
	exclusive = true

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 8)
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_child(box)

	_context_label = Label.new()
	_context_label.add_theme_font_size_override("font_size", 12)
	context_label_clip()
	box.add_child(_context_label)

	_name_edit = LineEdit.new()
	_name_edit.placeholder_text = "New name"
	_name_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_name_edit.text_changed.connect(_on_name_changed)
	_name_edit.text_submitted.connect(_on_text_submitted)
	box.add_child(_name_edit)

	_hint_label = Label.new()
	_hint_label.text = "The language server decides which files change. You will see a preview before anything is written."
	_hint_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_hint_label.add_theme_font_size_override("font_size", 11)
	box.add_child(_hint_label)

	confirmed.connect(_on_confirmed)
	about_to_popup.connect(_on_about_to_popup)
	LuaSingleton.on_theme_load.connect(restyle)
	LuaSingleton.on_settings_change.connect(restyle)
	restyle()


func context_label_clip() -> void:
	if _context_label != null:
		_context_label.clip_text = true
		_context_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL


func open_for(current_name: String, path: String, line: int) -> void:
	_current_name = current_name.strip_edges()
	_path = path
	_line = line
	_submitting = false

	if _context_label != null:
		var where := path.get_file()
		if line > 0:
			where += ":" + str(line)
		_context_label.text = "Rename \"%s\" in %s" % [_current_name, where]
	if _name_edit != null:
		_name_edit.text = _current_name
		_name_edit.caret_column = _name_edit.text.length()
	_name_edit.select_all()
	popup_centered()
	_name_edit.grab_focus()


func _on_about_to_popup() -> void:
	_submitting = false
	_name_edit.text = _current_name
	_name_edit.select_all()
	_name_edit.grab_focus()
	_update_ok_button()


func _on_name_changed(_text: String) -> void:
	_update_ok_button()


func _update_ok_button() -> void:
	var okay := get_ok_button()
	if okay == null:
		return
	var name := _name_edit.text.strip_edges()
	okay.disabled = name.is_empty() or name == _current_name


func _on_text_submitted(_text: String) -> void:
	_submit()


func _on_confirmed() -> void:
	_submit()


func _submit() -> void:
	if _submitting:
		return
	var name := _name_edit.text.strip_edges()
	if name.is_empty():
		_hint_label.text = "Enter a name first."
		_name_edit.grab_focus()
		return
	if name == _current_name:
		hide()
		return
	_submitting = true
	hide()
	submitted.emit(name)


func restyle() -> void:
	if !is_inside_tree():
		return
	if _context_label != null:
		_context_label.add_theme_color_override("font_color", LuaSingleton.gui.font_color)
	if _hint_label != null:
		_hint_label.add_theme_color_override("font_color", LuaSingleton.gui.font_color)
	if _name_edit != null:
		_name_edit.add_theme_font_override("font", _ui_font())


func _ui_font() -> Font:
	if LuaSingleton.editor_theme != null:
		return LuaSingleton.editor_theme.get_font("font", "MyType")
	return ThemeDB.fallback_font
