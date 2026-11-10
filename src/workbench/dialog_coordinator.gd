class_name DialogCoordinator
extends RefCounted

## Creates the editor's native dialogs in one place.
##
## The coordinator owns construction only. Behaviour remains in FileManager,
## which receives the created controls and handles their signals.

const HISTORY_DIALOG_SCRIPT = preload("res://src/features/learning/beginner/history_dialog.gd")
const GIT_DIFF_DIALOG_SCRIPT = preload("res://src/features/git/git_diff_dialog.gd")

var _editor = null


func setup(editor) -> Dictionary:
	_editor = editor
	var dialogs := {}

	dialogs["save_dialog"] = _file_dialog(
		editor,
		"Save As",
		FileDialog.FILE_MODE_SAVE_FILE,
		PackedStringArray(["*.* ; All files"])
	)
	dialogs["save_dialog"].file_selected.connect(editor._on_save_as_file_selected)
	dialogs["save_dialog"].canceled.connect(editor._on_save_as_canceled)

	dialogs["folder_dialog"] = _file_dialog(
		editor,
		"Open Folder",
		FileDialog.FILE_MODE_OPEN_DIR
	)
	dialogs["folder_dialog"].dir_selected.connect(editor._on_folder_selected)

	dialogs["mod_import_dialog"] = _file_dialog(
		editor,
		"Import Mod Package",
		FileDialog.FILE_MODE_OPEN_FILE,
		PackedStringArray([
			"*.gcm, *.zip ; Qorix mod packages",
			"*.gcm ; Qorix package",
			"*.zip ; ZIP archive",
		])
	)
	dialogs["mod_import_dialog"].file_selected.connect(editor._on_mod_import_selected)

	dialogs["template_folder_dialog"] = _file_dialog(
		editor,
		"Choose a folder for this template",
		FileDialog.FILE_MODE_OPEN_DIR
	)
	dialogs["template_folder_dialog"].dir_selected.connect(editor._on_template_folder_selected)
	dialogs["template_folder_dialog"].canceled.connect(editor._on_template_folder_canceled)

	var history_dialog = HISTORY_DIALOG_SCRIPT.new()
	history_dialog.name = "History"
	editor.add_child(history_dialog)
	dialogs["history_dialog"] = history_dialog

	var external_dialog := ConfirmationDialog.new()
	external_dialog.title = "File changed on disk"
	external_dialog.ok_button_text = "Reload"
	external_dialog.cancel_button_text = "Keep mine"
	external_dialog.add_button("Compare", false, "compare")
	external_dialog.confirmed.connect(editor._reload_external_tab)
	external_dialog.canceled.connect(editor._keep_external_tab)
	external_dialog.custom_action.connect(editor._on_external_custom_action)
	editor.add_child(external_dialog)
	dialogs["external_dialog"] = external_dialog

	var compare := _build_compare_dialog(editor)
	dialogs.merge(compare)

	var git_diff_dialog = GIT_DIFF_DIALOG_SCRIPT.new()
	git_diff_dialog.name = "GitDiff"
	editor.add_child(git_diff_dialog)
	dialogs["git_diff_dialog"] = git_diff_dialog

	var close_tab_dialog := ConfirmationDialog.new()
	close_tab_dialog.title = "Unsaved document"
	close_tab_dialog.ok_button_text = "Save"
	close_tab_dialog.cancel_button_text = "Cancel"
	close_tab_dialog.add_button("Don't save", false, "discard")
	close_tab_dialog.confirmed.connect(editor._on_close_tab_save)
	close_tab_dialog.custom_action.connect(editor._on_close_tab_discard)
	close_tab_dialog.canceled.connect(editor._on_close_tab_canceled)
	editor.add_child(close_tab_dialog)
	dialogs["close_tab_dialog"] = close_tab_dialog

	var close_dialog := ConfirmationDialog.new()
	close_dialog.title = "Unsaved documents"
	close_dialog.ok_button_text = "Quit anyway"
	close_dialog.cancel_button_text = "Cancel"
	close_dialog.confirmed.connect(editor._finish_quit)
	editor.add_child(close_dialog)
	dialogs["close_dialog"] = close_dialog

	return dialogs


func _file_dialog(editor, title: String, mode: FileDialog.FileMode, filters: PackedStringArray = PackedStringArray()) -> FileDialog:
	var dialog := FileDialog.new()
	dialog.title = title
	dialog.file_mode = mode
	dialog.access = FileDialog.ACCESS_FILESYSTEM
	dialog.use_native_dialog = true
	if !filters.is_empty():
		dialog.filters = filters
	editor.add_child(dialog)
	return dialog


func _build_compare_dialog(editor) -> Dictionary:
	var dialog := AcceptDialog.new()
	dialog.title = "Compare: editor buffer vs disk"
	dialog.ok_button_text = "Close"
	dialog.min_size = Vector2i(1100, 680)
	dialog.exclusive = false

	var box := HBoxContainer.new()
	box.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	box.offset_left = 12
	box.offset_top = 12
	box.offset_right = -12
	box.offset_bottom = -54
	box.add_theme_constant_override("separation", 10)
	dialog.add_child(box)

	var left := VBoxContainer.new()
	left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	left.add_theme_constant_override("separation", 4)
	box.add_child(left)
	var buffer_label := Label.new()
	buffer_label.text = "Editor buffer"
	left.add_child(buffer_label)
	var buffer_edit := _make_compare_edit()
	left.add_child(buffer_edit)

	var right := VBoxContainer.new()
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right.add_theme_constant_override("separation", 4)
	box.add_child(right)
	var disk_label := Label.new()
	disk_label.text = "On disk"
	right.add_child(disk_label)
	var disk_edit := _make_compare_edit()
	right.add_child(disk_edit)

	editor.add_child(dialog)
	return {
		"compare_dialog": dialog,
		"compare_buffer_label": buffer_label,
		"compare_buffer_edit": buffer_edit,
		"compare_disk_label": disk_label,
		"compare_disk_edit": disk_edit,
	}


func _make_compare_edit() -> CodeEdit:
	var edit := CodeEdit.new()
	edit.editable = false
	edit.context_menu_enabled = true
	edit.gutters_draw_line_numbers = true
	edit.highlight_current_line = false
	edit.caret_blink = false
	edit.wrap_mode = TextEdit.LINE_WRAPPING_NONE
	edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	edit.size_flags_vertical = Control.SIZE_EXPAND_FILL
	edit.add_theme_font_size_override("font_size", 14)
	style_compare_edit(edit, "")
	return edit


func style_compare_edit(edit: CodeEdit, extension: String) -> void:
	if edit == null:
		return
	var lua = _editor.get_node_or_null("/root/LuaSingleton") if _editor != null else null
	if lua == null:
		return
	edit.theme = lua.editor_theme
	edit.add_theme_color_override("background_color", lua.gui.background_color)
	edit.add_theme_color_override("current_line_color", lua.gui.current_line_color)
	edit.add_theme_color_override("selection_color", lua.gui.selection_color)
	edit.add_theme_color_override("font_color", lua.gui.font_color)
	edit.add_theme_color_override("word_highlighted_color", lua.gui.word_highlighted_color)
	edit.add_theme_color_override("caret_color", lua.gui.caret_color)
	if !extension.is_empty() and lua.language_service != null:
		edit.syntax_highlighter = lua.language_service.get_highlighter(extension)
